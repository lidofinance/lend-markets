// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Id, IMorphoStaticTyping} from "@lido-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-blue/src/interfaces/IOracle.sol";
import {MathLib} from "@lido-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "@lido-blue/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-blue/src/libraries/ConstantsLib.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUntil} from "../utils/PausableUntil.sol";
import {ISuspectsRegistry} from "../interfaces/ISuspectsRegistry.sol";
import {ILidoBlueMarketController} from "@lido-blue/src/interfaces/ILidoBlueMarketController.sol";
import {ActivationLib} from "../libs/ActivationLib.sol";
import {DeleverageQueue} from "../libs/DeleverageQueue.sol";

/// @notice One-read borrower snapshot for off-chain dashboards: collateral split, activation timer,
///         suspicion, debt, personal watermark, and live deleverage exposure.
struct PositionView {
    uint256 rawCollateral;
    uint256 active; // matured, borrowable
    uint256 activating; // in the activation timer
    uint256 dust; // below the activation threshold, withdrawable
    uint256 unlockAt; // 0 = no timer, NEVER_DELAY-far = banned
    bool readyToSettle; // activating would move to active on the next action now
    uint256 suspicion; // live 0..100
    uint256 debtAssets;
    uint256 watermarkLtv; // 0 = unset
    bool isQueueRoot; // next in line for deleverage
    uint256 allowedSlice; // loan assets that may be cut from this position now
}

/// @notice Lido-policy controller for the wstETH/ETH market: collateral activation, freeze and pause,
///         suspect gating, and the deleverage queue. All hook policy enters through `on`.
contract WethWstEthController is ILidoBlueMarketController, Initializable, AccessControlUpgradeable, PausableUntil {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using ActivationLib for ActivationLib.State;
    using DeleverageQueue for DeleverageQueue.State;

    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");
    bytes32 public constant RISK_STEWARD_ROLE = keccak256("RISK_STEWARD_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE_ROLE");

    IMorphoStaticTyping public immutable LIDO_BLUE;
    Id public immutable override MARKET_ID;

    error Unauthorized();
    error InvalidMarketId();
    error UnknownHookEvent();
    error MarketIsFrozen();
    error AddressBlocked();
    error ConfigNotTightened();
    error InsufficientActiveCollateral();
    error DeleverageRootBadDebt();
    error DeleverageIneligible();
    error DeleverageExceedsAllowed();
    error DeleverageExceedsDebt();
    error DeleverageInvalidSeize();
    error DeleverageBelowMin();

    event ConfigSet(ActivationLib.Config config);
    event SliceFloorSet(uint128 sliceFloorAssets);
    event FallbackMinRequestSet(uint128 fallbackMinRequest);
    event FrozenSet(bool frozen, address indexed account);
    event ActivatingHoldSet(uint128 activatingHold);

    struct ControllerStorage {
        bool isFrozen;
        ISuspectsRegistry suspectsRegistry;
        ActivationLib.State activation; // config + load accumulator + per-borrower activation pipeline
        DeleverageQueue.State deleverage; // risk queue + watermarks + slice policy
        uint128 activatingHold; // committee Sybil hold (0 = off); see setActivatingHold
    }

    bytes32 private constant CONTROLLER_STORAGE_SLOT = keccak256("lido.lending.wsteth-market-controller.storage.v1");

    function _storage() private pure returns (ControllerStorage storage $) {
        bytes32 slot = CONTROLLER_STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    modifier onlyControlledMarket(Id id) {
        if (msg.sender != address(LIDO_BLUE)) revert Unauthorized();
        if (Id.unwrap(id) != Id.unwrap(MARKET_ID)) revert InvalidMarketId();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(IMorphoStaticTyping lidoBlue, Id marketId) {
        LIDO_BLUE = lidoBlue;
        MARKET_ID = marketId;
        _disableInitializers();
    }

    /// @notice One-shot proxy initializer: grants roles and wires the suspects registry and config.
    function initialize(address admin, ISuspectsRegistry suspects, ActivationLib.Config calldata cfg)
        external
        initializer
    {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _storage().suspectsRegistry = suspects;
        _storage().deleverage.init();
        _applyConfig(cfg);
    }

    /// @notice Update the governance-tunable activation parameters. Risk-increasing path: the role is
    ///         meant to be held by the EasyTrack factory (ADR 016), which adds the objection window.
    function setConfig(ActivationLib.Config calldata cfg) external onlyRole(CONFIGURATOR_ROLE) {
        _applyConfig(cfg);
    }

    /// @notice Fast risk-reducing path: raise the activation delay floor and dust threshold only,
    ///         bypassing the objection window. Reverts if either value would loosen.
    function tightenConfig(uint64 newMinActivationDelay, uint128 newMinActivationAmount)
        external
        onlyRole(RISK_STEWARD_ROLE)
    {
        ActivationLib.Config memory cfg = _storage().activation.config;
        if (newMinActivationDelay < cfg.minActivationDelay) revert ConfigNotTightened();
        if (newMinActivationAmount < cfg.minActivationAmount) revert ConfigNotTightened();
        cfg.minActivationDelay = newMinActivationDelay;
        cfg.minActivationAmount = newMinActivationAmount;
        _applyConfig(cfg);
    }

    /// @notice Set the minimum loan-asset slice a single deleverage cut may take.
    function setSliceFloor(uint128 sliceFloorAssets) external onlyRole(CONFIGURATOR_ROLE) {
        _storage().deleverage.setSliceFloor(sliceFloorAssets);
        emit SliceFloorSet(sliceFloorAssets);
    }

    /// @notice Set the minimum loan assets one deleverage (fallback) call may cancel (anti dust-spam).
    function setFallbackMinRequest(uint128 fallbackMinRequest) external onlyRole(CONFIGURATOR_ROLE) {
        _storage().deleverage.setFallbackMinRequest(fallbackMinRequest);
        emit FallbackMinRequestSet(fallbackMinRequest);
    }

    /// @notice Committee lever (Sybil protection): hold up to `activatingHold` of each position's
    ///         activating collateral unwithdrawable until it matures. 0 (the default) disables it.
    /// @dev Forced paths (liquidation, deleverage) ignore the hold. The hold is temporary: held collateral
    ///      matures into `active` on its timer and becomes withdrawable, so this is not a custody power.
    function setActivatingHold(uint128 activatingHold) external onlyRole(COMMITTEE_ROLE) {
        _storage().activatingHold = activatingHold;
        emit ActivatingHoldSet(activatingHold);
    }

    /// @notice Borrower opts into auto-deleverage down to a target post-cut LTV (WAD); 0 clears it.
    /// @dev `msg.sender` is the borrower. Setting it makes the caller eligible for deleverage even
    ///      when it is not the queue root, capped at the slice that brings its LTV to `ltv`.
    function setBorrowerWatermark(uint256 ltv) external {
        _storage().deleverage.setWatermark(msg.sender, ltv);
    }

    /// @notice Freeze the market: new borrows and debt-bearing collateral withdrawals revert, and
    ///         activation settlement is deferred. Debt-free positions can still withdraw their collateral.
    function freeze() external onlyRole(RISK_STEWARD_ROLE) {
        _storage().isFrozen = true;
        emit FrozenSet(true, msg.sender);
    }

    /// @notice Lift the freeze.
    function unfreeze() external onlyRole(CONFIGURATOR_ROLE) {
        _storage().isFrozen = false;
        emit FrozenSet(false, msg.sender);
    }

    /// @notice Pause every hook for `duration` seconds; pass PAUSE_INFINITELY for an indefinite pause.
    function pauseFor(uint256 duration) external onlyRole(PAUSER_ROLE) {
        _pauseFor(duration);
    }

    /// @notice Resume from a pause.
    function resume() external onlyRole(UNPAUSER_ROLE) {
        _resume();
    }

    /// @notice True if the market is frozen.
    function isFrozen() external view returns (bool) {
        return _storage().isFrozen;
    }

    /// @notice Current decayed activation load (the leaky-bucket accumulator) — for monitoring and tests.
    function currentLoad() external view returns (uint256) {
        return _storage().activation.currentLoad();
    }

    /// @notice Core hook entrypoint, dispatches each market action to its internal handler.
    /// @dev Reverts on unknown event so any future Morpho-fork-side change without a controller update
    ///      fails closed instead of silently skipping policy.
    function on(Id id, HookEvent hookEvent, bytes calldata data) external override onlyControlledMarket(id) {
        _checkResumed();
        if (hookEvent == HookEvent.SupplyCollateral) {
            _handleSupplyCollateral(id, abi.decode(data, (SupplyCollateralHookData)));
        } else if (hookEvent == HookEvent.WithdrawCollateral) {
            _handleWithdrawCollateral(id, abi.decode(data, (WithdrawCollateralHookData)));
        } else if (hookEvent == HookEvent.Borrow) {
            _handleBorrow(id, abi.decode(data, (BorrowHookData)));
        } else if (hookEvent == HookEvent.Repay) {
            _handleRepay(id, abi.decode(data, (RepayHookData)));
        } else if (hookEvent == HookEvent.Liquidate) {
            _handleLiquidate(id, abi.decode(data, (LiquidateHookData)));
        } else if (hookEvent == HookEvent.Deleverage) {
            _handleDeleverage(id, abi.decode(data, (DeleverageHookData)));
        } else if (
            hookEvent == HookEvent.Supply || hookEvent == HookEvent.Withdraw || hookEvent == HookEvent.AccrueInterest
        ) {
            // received but carry no controller policy: lender flows (cut) and interest accrual
        } else {
            revert UnknownHookEvent();
        }
    }

    // ---
    // DELEVERAGE QUEUE VIEWS
    // ---

    /// @notice Number of borrowers tracked in the deleverage queue.
    function deleverageQueueSize() external view returns (uint256) {
        return _storage().deleverage.size();
    }

    /// @notice True if the queue root (the riskiest borrower) is bad debt: its debt value exceeds its
    ///         collateral value. The root is the highest debt/collateral position, so a solvent root means
    ///         no tracked position is bad debt, which is why the deleverage gate need only check the root.
    function rootHasBadDebt() external view returns (bool) {
        address top = _storage().deleverage.peekRoot();
        if (top == address(0)) return false;
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(MARKET_ID, top);
        (uint256 totalBorrowAssets, uint256 totalBorrowShares) = _totalBorrowTotals(MARKET_ID);
        return
            _isBadDebt(borrowShares, rawCollateral, totalBorrowAssets, totalBorrowShares, _collateralPrice(MARKET_ID));
    }

    /// @notice Next borrower to cut (queue root) and the max slice the policy allows for it: the larger
    ///         of the heap re-order slice and the root's own watermark slice (same bound the hook caps
    ///         at, and the same value `allowedSliceFor` returns). `borrower` is address(0) when the queue
    ///         is empty; `sliceAssets` is type(uint256).max for a lone borrower (caller caps it to the
    ///         remaining exit).
    function nextDeleverageCut() external view override returns (address borrower, uint256 sliceAssets) {
        DeleverageQueue.State storage queue = _storage().deleverage;
        borrower = queue.peekRoot();
        if (borrower == address(0)) return (address(0), 0);
        sliceAssets = queue.allowedSlice(borrower, _marketView(MARKET_ID, borrower));
    }

    /// @notice Maximum loan-asset slice the policy allows for a single deleverage cut against
    ///         `borrower` (max of heap slice and watermark slice). Zero means ineligible.
    function allowedSliceFor(address borrower) external view override returns (uint256) {
        return _storage().deleverage.allowedSlice(borrower, _marketView(MARKET_ID, borrower));
    }

    /// @notice Borrowers currently in the queue (approximate top-down order) and their risk keys.
    function eligibleBorrowers(uint256 maxCount)
        external
        view
        returns (address[] memory borrowers, uint256[] memory keys)
    {
        return _storage().deleverage.eligibleBorrowers(maxCount);
    }

    /// @notice Borrower's personal watermark LTV and the corresponding watermark-derived slice.
    function watermarkInfo(address borrower) external view returns (uint256 watermarkLtv, uint256 sliceAssets) {
        DeleverageQueue.State storage queue = _storage().deleverage;
        watermarkLtv = queue.watermarkOf(borrower);
        if (watermarkLtv == 0) return (0, 0);
        sliceAssets = queue.watermarkSlice(borrower, _marketView(MARKET_ID, borrower));
    }

    /// @notice One-call borrower dashboard: collateral split, activation unlock, suspicion, debt,
    ///         personal watermark, and live deleverage exposure (queue root + allowed slice).
    function positionOf(address borrower) external view returns (PositionView memory positionView) {
        ControllerStorage storage $ = _storage();

        uint256 suspicion = $.suspectsRegistry.suspicion(MARKET_ID, borrower);
        (, uint256 rawCollateral) = _currentPosition(MARKET_ID, borrower);

        (positionView.active, positionView.activating, positionView.dust) =
            $.activation.bucketsOf(borrower, rawCollateral);
        positionView.rawCollateral = rawCollateral;
        positionView.unlockAt = $.activation.unlockAt(borrower, suspicion);
        positionView.readyToSettle =
            positionView.unlockAt != 0 && !$.isFrozen && block.timestamp >= positionView.unlockAt;
        positionView.suspicion = suspicion;
        positionView.debtAssets = _debtAssets(MARKET_ID, borrower);
        positionView.watermarkLtv = $.deleverage.watermarkOf(borrower);
        positionView.isQueueRoot = $.deleverage.peekRoot() == borrower;
        positionView.allowedSlice = $.deleverage.allowedSlice(borrower, _marketView(MARKET_ID, borrower));
    }

    // ---
    // HANDLERS
    // ---

    function _handleSupplyCollateral(Id id, SupplyCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;
        ControllerStorage storage $ = _storage();

        // raw is pre-deposit: this hook runs before core's `collateral += assets`
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, borrower);

        // settle anything already matured, then book the deposit (promotes past the dust threshold)
        uint256 suspicion = $.suspectsRegistry.suspicion(MARKET_ID, borrower);
        $.activation.syncActivation(borrower, suspicion, $.isFrozen);
        $.activation.deposit(borrower, hookData.assets, rawCollateral);

        $.deleverage.sync(borrower, borrowShares, rawCollateral + hookData.assets);
    }

    function _handleWithdrawCollateral(Id id, WithdrawCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;
        ControllerStorage storage $ = _storage();

        // raw and borrowShares are pre-withdraw: this hook runs before core's `collateral -= assets`
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, borrower);

        // Freeze blocks withdraw only while there is open debt. A zero-debt withdraw is always allowed
        // as a non-custody exit. No suspects gate either: a banned address can still pull its own collateral.
        if ($.isFrozen && borrowShares != 0) revert MarketIsFrozen();

        // settle activation, then debit the buckets (dust, activating, active) and reverse any same-tx
        // flash charge on the load (the lib owns the undo); a revert below rolls this back
        uint256 suspicion = $.suspectsRegistry.suspicion(MARKET_ID, borrower);
        $.activation.syncActivation(borrower, suspicion, $.isFrozen);
        uint256 active = $.activation.withdraw(borrower, hookData.assets, rawCollateral, $.activatingHold);

        // with open debt, the remaining active must still cover it at LLTV (stricter than core's raw check)
        if (borrowShares != 0) _requireActiveHealth(id, borrower, active, 0);

        $.deleverage.sync(borrower, borrowShares, rawCollateral > hookData.assets ? rawCollateral - hookData.assets : 0);
    }

    function _handleBorrow(Id id, BorrowHookData memory hookData) internal {
        _checkNotFrozen();
        // A banned actor cannot take on debt (onBehalf), receive the loan (receiver), or initiate the
        // borrow (caller). Soft suspicion only delays activation; a ban hard-blocks the borrow path.
        _checkNotBlocked(hookData.caller);
        _checkNotBlocked(hookData.onBehalf);
        _checkNotBlocked(hookData.receiver);

        ControllerStorage storage $ = _storage();

        // Stricter Lido constraint: borrow capacity uses active (matured) collateral only. The core's
        // standard health check uses raw collateral; this adds the active-only ceiling on the settled state.
        uint256 suspicion = $.suspectsRegistry.suspicion(MARKET_ID, hookData.onBehalf);
        uint256 active = $.activation.syncActivation(hookData.onBehalf, suspicion, $.isFrozen);
        _requireActiveHealth(id, hookData.onBehalf, active, hookData.assets);

        (uint256 currentBorrowShares, uint256 currentRawCollateral) = _currentPosition(id, hookData.onBehalf);
        $.deleverage.sync(hookData.onBehalf, currentBorrowShares + hookData.shares, currentRawCollateral);
    }

    function _handleRepay(Id id, RepayHookData memory hookData) internal {
        // repay lowers debt: re-key the queue on the post-repay shares (drops out at zero debt)
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, hookData.onBehalf);
        uint256 projected = borrowShares > hookData.shares ? borrowShares - hookData.shares : 0;
        _storage().deleverage.sync(hookData.onBehalf, projected, rawCollateral);
    }

    function _handleLiquidate(Id id, LiquidateHookData memory hookData) internal {
        address borrower = hookData.borrower;
        ControllerStorage storage $ = _storage();
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, borrower);

        // debit the seized collateral from the buckets before core decrements raw
        if (hookData.seizedAssets != 0) $.activation.consume(borrower, hookData.seizedAssets, rawCollateral, 0);

        // re-key on the post-liquidation position
        uint256 shares = borrowShares > hookData.repaidShares ? borrowShares - hookData.repaidShares : 0;
        uint256 raw = rawCollateral > hookData.seizedAssets ? rawCollateral - hookData.seizedAssets : 0;
        $.deleverage.sync(borrower, shares, raw);
    }

    function _handleDeleverage(Id id, DeleverageHookData memory hookData) internal {
        ControllerStorage storage $ = _storage();
        address borrower = hookData.borrower;

        if (hookData.assetsToCancel < $.deleverage.fallbackMinRequest) revert DeleverageBelowMin();

        // Borrower market view, re-read from core (payload stays minimal). The core already bounded the
        // cut (seize <= raw, shares <= debt); the controller adds only its policy layer.
        DeleverageQueue.MarketView memory marketView = _marketView(id, borrower);

        // bad-debt gate on the queue root; reuse the payload when the root is the target, else read the root
        address root = $.deleverage.peekRoot();
        if (root != address(0)) {
            (uint256 rootShares, uint256 rootRaw) =
                root == borrower ? (marketView.borrowShares, marketView.rawCollateral) : _currentPosition(id, root);
            if (_isBadDebt(
                    rootShares, rootRaw, marketView.totalBorrowAssets, marketView.totalBorrowShares, marketView.price
                )) {
                revert DeleverageRootBadDebt();
            }
        }

        // eligibility + cut bound: only the queue root or a watermarked borrower may be cut, capped at the
        // policy slice. A lone root's slice is unbounded here; the payload sanity checks below cap it.
        uint256 allowed = $.deleverage.allowedSlice(borrower, marketView);
        if (allowed == 0) revert DeleverageIneligible();
        if (hookData.assetsToCancel > allowed) revert DeleverageExceedsAllowed();

        // payload consistency (core already enforces these; cheap to re-check on the trusted values, no reads)
        uint256 sharesToBurn =
            hookData.assetsToCancel.toSharesUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        if (sharesToBurn > marketView.borrowShares) revert DeleverageExceedsDebt();
        if (hookData.collateralSeized == 0 || hookData.collateralSeized > marketView.rawCollateral) {
            revert DeleverageInvalidSeize();
        }

        // settle activation, then debit buckets by the exact amount core seizes from raw (lockstep)
        uint256 suspicion = $.suspectsRegistry.suspicion(MARKET_ID, borrower);
        $.activation.syncActivation(borrower, suspicion, $.isFrozen);
        $.activation.consume(borrower, hookData.collateralSeized, marketView.rawCollateral, 0);

        $.deleverage
            .sync(
                borrower, marketView.borrowShares - sharesToBurn, marketView.rawCollateral - hookData.collateralSeized
            );
    }

    // ---
    // Internal Helpers
    // ---

    /// @dev Validate and store the activation config through the lib, then surface the change.
    function _applyConfig(ActivationLib.Config memory cfg) internal {
        _storage().activation.setConfig(cfg);
        emit ConfigSet(cfg);
    }

    /// @dev Stricter Lido health: the borrower's debt (current + incoming delta) must fit the active
    ///      (matured) collateral at the market LLTV. Core's own check uses raw collateral, this adds
    ///      the active-only ceiling on top.
    function _requireActiveHealth(Id id, address borrower, uint256 active, uint256 deltaBorrowAssets) internal view {
        uint256 debt = deltaBorrowAssets + _debtAssets(id, borrower);
        if (debt == 0) return;
        if (debt > _maxBorrow(id, active)) revert InsufficientActiveCollateral();
    }

    /// @dev Borrower debt in loan assets, 0 if none.
    function _debtAssets(Id id, address borrower) internal view returns (uint256) {
        (, uint128 borrowShares,) = LIDO_BLUE.position(id, borrower);
        if (borrowShares == 0) return 0;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = LIDO_BLUE.market(id);
        return uint256(borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    /// @dev Max loan assets `active` collateral can back at the market LLTV.
    function _maxBorrow(Id id, uint256 active) internal view returns (uint256) {
        (,, address oracle,, uint256 lltv) = LIDO_BLUE.idToMarketParams(id);
        return active.mulDivDown(IOracle(oracle).price(), ORACLE_PRICE_SCALE).wMulDown(lltv);
    }

    /// @dev Bad debt: debt value exceeds collateral value. Pure; the caller supplies the position and
    ///      market figures (from the trusted hook payload, or a live read for the external view).
    function _isBadDebt(
        uint256 borrowShares,
        uint256 rawCollateral,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 price
    ) internal pure returns (bool) {
        if (borrowShares == 0) return false;
        if (rawCollateral == 0) return true;
        uint256 debt = borrowShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
        uint256 collateralValue = rawCollateral.mulDivDown(price, ORACLE_PRICE_SCALE);
        return debt > collateralValue;
    }

    /// @dev Live core/oracle snapshot for the deleverage slice math.
    function _marketView(Id id, address borrower) internal view returns (DeleverageQueue.MarketView memory marketView) {
        marketView.price = _collateralPrice(id);
        (marketView.borrowShares, marketView.rawCollateral) = _currentPosition(id, borrower);
        (marketView.totalBorrowAssets, marketView.totalBorrowShares) = _totalBorrowTotals(id);
    }

    /// @dev Borrower borrow shares and raw collateral from core.
    function _currentPosition(Id id, address borrower)
        internal
        view
        returns (uint256 borrowShares, uint256 rawCollateral)
    {
        (, uint128 bs, uint128 rc) = LIDO_BLUE.position(id, borrower);
        return (bs, rc);
    }

    /// @dev Market borrow totals from core.
    function _totalBorrowTotals(Id id) internal view returns (uint256 totalBorrowAssets, uint256 totalBorrowShares) {
        (,, uint128 ba, uint128 bs,,) = LIDO_BLUE.market(id);
        return (ba, bs);
    }

    /// @dev Collateral price from the market oracle.
    function _collateralPrice(Id id) internal view returns (uint256) {
        (,, address oracle,,) = LIDO_BLUE.idToMarketParams(id);
        return IOracle(oracle).price();
    }

    function _checkNotFrozen() internal view {
        if (_storage().isFrozen) revert MarketIsFrozen();
    }

    /// @dev Hard-block: a banned address may not borrow, receive a borrow, or initiate one. The soft
    ///      suspicion score only lengthens activation; a ban is the binary stop on the borrow path.
    function _checkNotBlocked(address user) internal view {
        if (_storage().suspectsRegistry.isBanned(MARKET_ID, user)) revert AddressBlocked();
    }
}
