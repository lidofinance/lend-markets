// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id, IMorpho, IMorphoStaticTyping, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUntil} from "../utils/PausableUntil.sol";
import {ISuspectsRegistry} from "../interfaces/ISuspectsRegistry.sol";
import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../libs/CollateralActivationLib.sol";
import {SettlementQueueLib} from "../libs/SettlementQueueLib.sol";

/// @notice One-read borrower snapshot for off-chain dashboards: collateral split, activation timer,
///         suspicion, debt, personal watermark, and live settle exposure.
struct PositionView {
    uint256 rawCollateral;
    uint256 active; // matured, borrowable
    uint256 activating; // in the activation timer
    uint256 dust; // below the activation threshold, withdrawable
    uint256 unlockTime; // 0 = no timer, NEVER_UNLOCK-far = banned
    bool readyToSettle; // activating would move to active on the next action now
    uint256 suspicion; // live, WAD-scaled (WAD = banned)
    uint256 debtAssets;
    uint256 watermarkLtv; // 0 = unset
    bool isQueueRoot; // next in line for settle
    uint256 allowedSlice; // loan assets that may be cut from this position now
}

/// @notice Lido-policy controller for a Lido Lend market: collateral activation, freeze and pause,
///         suspect gating, and the settlement queue. All hook policy enters through `on`.
contract LidoLendMarketController layout at erc7201("lido.lending.storage.LidoLendMarketController")
    is
    ILidoLendBaseMarketController,
    Initializable,
    AccessControlUpgradeable,
    PausableUntil
{
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using CollateralActivationLib for CollateralActivationLib.State;
    using SettlementQueueLib for SettlementQueueLib.State;

    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");
    bytes32 public constant RISK_STEWARD_ROLE = keccak256("RISK_STEWARD_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER_ROLE");
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE_ROLE");

    IMorphoStaticTyping public immutable LIDO_LEND;
    Id internal immutable _MARKET_ID;

    error Unauthorized();
    error InvalidMarketId();
    error UnknownHookEvent();
    error MarketIsFrozen();
    error AddressBlocked();
    error ConfigNotTightened();
    error InsufficientActiveCollateral();
    error SettlementRootBadDebt();
    error SettlementIneligible();
    error SettlementExceedsAllowed();
    error SettlementExceedsDebt();
    error SettlementInvalidSeize();
    error SettlementBelowMin();

    event ConfigSet(CollateralActivationLib.Config config);
    event SlicePolicySet(uint16 sliceFloorBps, uint96 sliceFloorAssets, uint96 fallbackMinRequest);
    event FrozenSet(bool frozen, address indexed account);
    event ActivatingHoldSet(uint128 activatingHold);

    bool private _isFrozen;
    ISuspectsRegistry private _suspectsRegistry;
    /// @dev Config + inflow accumulator + per-borrower activation pipeline.
    CollateralActivationLib.State private _activation;
    /// @dev Risk queue + watermarks + slice policy.
    SettlementQueueLib.State private _settlementQueue;

    modifier onlyControlledMarket(Id id) {
        if (msg.sender != address(LIDO_LEND)) revert Unauthorized();
        if (Id.unwrap(id) != Id.unwrap(_MARKET_ID)) revert InvalidMarketId();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(IMorphoStaticTyping lidoLend, Id marketId_) {
        LIDO_LEND = lidoLend;
        _MARKET_ID = marketId_;
        _disableInitializers();
    }

    /// @notice One-shot proxy initializer: grants roles and wires the suspects registry and config.
    function initialize(address admin, ISuspectsRegistry suspects, CollateralActivationLib.Config calldata cfg)
        external
        initializer
    {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _suspectsRegistry = suspects;
        _settlementQueue.init();
        _applyConfig(cfg);
    }

    /// @notice Market this controller is bound to, checked by the core when it binds at market creation.
    function marketId() external view override returns (Id) {
        return _MARKET_ID;
    }

    /// @notice Update the governance-tunable activation parameters. Risk-increasing path: the role is
    ///         meant to be held by the EasyTrack factory, which adds the objection window.
    function setConfig(CollateralActivationLib.Config calldata cfg) external onlyRole(CONFIGURATOR_ROLE) {
        _applyConfig(cfg);
    }

    /// @notice Fast risk-reducing path: raise the activation delay floor and dust threshold only,
    ///         bypassing the objection window. Reverts if either value would loosen.
    function tightenConfig(uint64 newMinActivationDelay, uint128 newMinActivationAmount)
        external
        onlyRole(RISK_STEWARD_ROLE)
    {
        CollateralActivationLib.Config memory cfg = _activation.config;
        if (newMinActivationDelay < cfg.minActivationDelay) revert ConfigNotTightened();
        if (newMinActivationAmount < cfg.minActivationAmount) revert ConfigNotTightened();
        cfg.minActivationDelay = newMinActivationDelay;
        cfg.minActivationAmount = newMinActivationAmount;
        _applyConfig(cfg);
    }

    /// @notice Set the settle slice policy in one shot — the knobs tune the same cut and move
    ///         together. Overshoot per cut is `max(debt * sliceFloorBps / 10000, sliceFloorAssets)` on
    ///         top of the closed-form slice; `fallbackMinRequest` floors one call's total.
    function setSlicePolicy(SettlementQueueLib.SlicePolicy calldata policy) external onlyRole(CONFIGURATOR_ROLE) {
        _settlementQueue.setSlicePolicy(policy);
        emit SlicePolicySet(policy.sliceFloorBps, policy.sliceFloorAssets, policy.fallbackMinRequest);
    }

    function slicePolicy() external view returns (SettlementQueueLib.SlicePolicy memory) {
        return _settlementQueue.policy;
    }

    /// @notice Committee lever (Sybil protection): hold up to `activatingHold` of each position's
    ///         activating collateral unwithdrawable until it matures. 0 (the default) disables it.
    /// @dev Forced paths (liquidation, settle) ignore the hold. The hold is temporary: held collateral
    ///      matures into `active` on its timer and becomes withdrawable, so this is not a custody power.
    function setActivatingHold(uint128 activatingHold) external onlyRole(COMMITTEE_ROLE) {
        _activation.setActivatingHold(activatingHold);
        emit ActivatingHoldSet(activatingHold);
    }

    /// @notice Borrower opts into auto-settle down to a target post-cut LTV (WAD); 0 clears it.
    /// @dev `msg.sender` is the borrower. Setting it makes the caller eligible for settle even
    ///      when it is not the queue root, capped at the slice that brings its LTV to `ltv`.
    function setBorrowerWatermark(uint256 ltv) external {
        _settlementQueue.setWatermark(msg.sender, ltv);
    }

    /// @notice Freeze the market: new borrows and debt-bearing collateral withdrawals revert, and
    ///         activation settlement is deferred. Debt-free positions can still withdraw their collateral.
    function freeze() external onlyRole(RISK_STEWARD_ROLE) {
        _isFrozen = true;
        emit FrozenSet(true, msg.sender);
    }

    function unfreeze() external onlyRole(CONFIGURATOR_ROLE) {
        _isFrozen = false;
        emit FrozenSet(false, msg.sender);
    }

    /// @notice Pause every hook for `duration` seconds; pass PAUSE_INFINITELY for an indefinite pause.
    function pauseFor(uint256 duration) external onlyRole(PAUSER_ROLE) {
        _pauseFor(duration);
    }

    function resume() external onlyRole(UNPAUSER_ROLE) {
        _resume();
    }

    function isFrozen() external view returns (bool) {
        return _isFrozen;
    }

    /// @notice Current decayed activation inflow (the throttle accumulator) — for monitoring and tests.
    function currentInflow() external view returns (uint256) {
        return _activation.getInflow();
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
        } else if (hookEvent == HookEvent.Settle) {
            _handleSettle(id, abi.decode(data, (SettleHookData)));
        } else if (
            hookEvent == HookEvent.Supply || hookEvent == HookEvent.Withdraw || hookEvent == HookEvent.AccrueInterest
        ) {
            // received but carry no controller policy: lender flows (cut) and interest accrual
        } else {
            revert UnknownHookEvent();
        }
    }

    // ---
    // SETTLEMENT QUEUE VIEWS
    // ---

    function settlementQueueSize() external view returns (uint256) {
        return _settlementQueue.size();
    }

    /// @notice True if the queue root (the riskiest borrower) is bad debt: its debt value exceeds its
    ///         collateral value. The root is the highest debt/collateral position, so a solvent root means
    ///         no tracked position is bad debt, which is why the settle gate need only check the root.
    function rootHasBadDebt() external view returns (bool) {
        address top = _settlementQueue.peekRoot();
        if (top == address(0)) return false;
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(_MARKET_ID, top);
        (uint256 totalBorrowAssets, uint256 totalBorrowShares) = _totalBorrowTotals(_MARKET_ID);
        return
            _isBadDebt(borrowShares, rawCollateral, totalBorrowAssets, totalBorrowShares, _collateralPrice(_MARKET_ID));
    }

    /// @notice Next borrower to cut (queue root) and the max slice the policy allows for it: the larger
    ///         of the heap re-order slice and the root's own watermark slice (same bound the hook caps
    ///         at, and the same value `allowedSliceFor` returns). `borrower` is address(0) when the queue
    ///         is empty; `sliceAssets` is type(uint256).max for a lone borrower (caller caps it to the
    ///         remaining exit).
    function nextSettlementCut() external view returns (address borrower, uint256 sliceAssets) {
        borrower = _settlementQueue.peekRoot();
        if (borrower == address(0)) return (address(0), 0);
        sliceAssets = _allowedSlice(borrower, _marketView(_MARKET_ID, borrower));
    }

    /// @notice Maximum loan-asset slice the policy allows for a single settle cut against
    ///         `borrower` (max of heap slice and watermark slice). Zero means ineligible.
    function allowedSliceFor(address borrower) external view returns (uint256) {
        return _allowedSlice(borrower, _marketView(_MARKET_ID, borrower));
    }

    /// @notice Borrowers currently in the queue (approximate top-down order) and their risk keys.
    function eligibleBorrowers(uint256 maxCount)
        external
        view
        returns (address[] memory borrowers, uint256[] memory keys)
    {
        return _settlementQueue.eligibleBorrowers(maxCount);
    }

    /// @notice Borrower's personal watermark LTV and the corresponding watermark-derived slice.
    function watermarkInfo(address borrower) external view returns (uint256 watermarkLtv, uint256 sliceAssets) {
        SettlementQueueLib.State storage queue = _settlementQueue;
        watermarkLtv = queue.watermarkOf(borrower);
        if (watermarkLtv == 0) return (0, 0);
        sliceAssets = queue.watermarkSlice(borrower, _marketView(_MARKET_ID, borrower));
    }

    /// @notice One-call borrower dashboard: collateral split, activation unlock, suspicion, debt,
    ///         personal watermark, and live settle exposure (queue root + allowed slice).
    function positionOf(address borrower) external view returns (PositionView memory positionView) {
        uint256 suspicion = _suspectsRegistry.suspicion(_MARKET_ID, borrower);
        (, uint256 rawCollateral) = _currentPosition(_MARKET_ID, borrower);

        (positionView.active, positionView.activating, positionView.dust) = _activation.getBuckets(borrower);
        positionView.rawCollateral = rawCollateral;
        positionView.unlockTime = _activation.getUnlockTime(borrower, suspicion);
        positionView.readyToSettle =
            positionView.unlockTime != 0 && !_isFrozen && block.timestamp >= positionView.unlockTime;
        positionView.suspicion = suspicion;
        positionView.debtAssets = _debtAssets(_MARKET_ID, borrower);
        positionView.watermarkLtv = _settlementQueue.watermarkOf(borrower);
        positionView.isQueueRoot = _settlementQueue.peekRoot() == borrower;
        positionView.allowedSlice = _allowedSlice(borrower, _marketView(_MARKET_ID, borrower));
    }

    // ---
    // HANDLERS
    // ---

    function _handleSupplyCollateral(Id id, SupplyCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;

        // raw is pre-deposit: this hook runs before core's `collateral += assets`
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, borrower);

        // settle anything already matured, then book the deposit (promotes past the dust threshold).
        // A freeze defers maturation.
        if (!_isFrozen) {
            _activation.syncActivation(borrower, _suspectsRegistry.suspicion(_MARKET_ID, borrower));
        }
        _activation.deposit(borrower, hookData.assets);

        _settlementQueue.sync(borrower, borrowShares, rawCollateral + hookData.assets);
    }

    function _handleWithdrawCollateral(Id id, WithdrawCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;

        // raw and borrowShares are pre-withdraw: this hook runs before core's `collateral -= assets`
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, borrower);

        // Freeze blocks withdraw only while there is open debt. A zero-debt withdraw is always allowed
        // as a non-custody exit. No suspects gate either: a banned address can still pull its own collateral.
        if (_isFrozen && borrowShares != 0) revert MarketIsFrozen();

        // settle activation, then debit the buckets (dust, activating, active) and reverse any same-tx
        // flash addition to the inflow (the lib owns the undo); a revert below rolls this back
        if (!_isFrozen) {
            _activation.syncActivation(borrower, _suspectsRegistry.suspicion(_MARKET_ID, borrower));
        }
        uint256 active = _activation.withdraw(borrower, hookData.assets);

        // with open debt, the remaining active must still cover it at LLTV (stricter than core's raw check)
        if (borrowShares != 0) _requireActiveHealth(id, borrower, active, 0);

        _settlementQueue.sync(
            borrower, borrowShares, rawCollateral > hookData.assets ? rawCollateral - hookData.assets : 0
        );
    }

    function _handleBorrow(Id id, BorrowHookData memory hookData) internal {
        _checkNotFrozen();
        // A banned actor cannot take on debt (onBehalf), receive the loan (receiver), or initiate the
        // borrow (caller). Soft suspicion only delays activation; a ban hard-blocks the borrow path.
        _checkNotBlocked(hookData.caller);
        _checkNotBlocked(hookData.onBehalf);
        _checkNotBlocked(hookData.receiver);

        // Stricter Lido constraint: borrow capacity uses active (matured) collateral only. The core's
        // standard health check uses raw collateral; this adds the active-only ceiling on the settled state.
        // not frozen here: _checkNotFrozen above gates the borrow path
        uint256 suspicion = _suspectsRegistry.suspicion(_MARKET_ID, hookData.onBehalf);
        uint256 active = _activation.syncActivation(hookData.onBehalf, suspicion);
        _requireActiveHealth(id, hookData.onBehalf, active, hookData.assets);

        (uint256 currentBorrowShares, uint256 currentRawCollateral) = _currentPosition(id, hookData.onBehalf);
        _settlementQueue.sync(hookData.onBehalf, currentBorrowShares + hookData.shares, currentRawCollateral);
    }

    function _handleRepay(Id id, RepayHookData memory hookData) internal {
        // repay lowers debt: re-key the queue on the post-repay shares (drops out at zero debt)
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, hookData.onBehalf);
        uint256 projected = borrowShares > hookData.shares ? borrowShares - hookData.shares : 0;
        _settlementQueue.sync(hookData.onBehalf, projected, rawCollateral);
    }

    function _handleLiquidate(Id id, LiquidateHookData memory hookData) internal {
        address borrower = hookData.borrower;
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, borrower);

        // debit the seized collateral from the buckets before core decrements raw
        if (hookData.seizedAssets != 0) _activation.debit(borrower, hookData.seizedAssets, 0);

        // re-key on the post-liquidation position
        uint256 shares = borrowShares > hookData.repaidShares ? borrowShares - hookData.repaidShares : 0;
        uint256 raw = rawCollateral > hookData.seizedAssets ? rawCollateral - hookData.seizedAssets : 0;
        _settlementQueue.sync(borrower, shares, raw);
    }

    function _handleSettle(Id id, SettleHookData memory hookData) internal {
        address borrower = hookData.borrower;

        if (hookData.debtCanceled < _settlementQueue.policy.fallbackMinRequest) revert SettlementBelowMin();

        // Borrower market view, re-read from core (payload stays minimal). The core already bounded the
        // cut (seize <= raw, shares <= debt); the controller adds only its policy layer.
        SettlementQueueLib.MarketView memory marketView = _marketView(id, borrower);

        // bad-debt gate on the queue root; reuse the payload when the root is the target, else read the root
        address root = _settlementQueue.peekRoot();
        if (root != address(0)) {
            (uint256 rootShares, uint256 rootRaw) =
                root == borrower ? (marketView.borrowShares, marketView.rawCollateral) : _currentPosition(id, root);
            if (_isBadDebt(
                    rootShares, rootRaw, marketView.totalBorrowAssets, marketView.totalBorrowShares, marketView.price
                )) {
                revert SettlementRootBadDebt();
            }
        }

        // eligibility + cut bound: only the queue root or a watermarked borrower may be cut, capped at the
        // policy slice. A lone root's slice is unbounded here; the payload sanity checks below cap it.
        uint256 allowed = _allowedSlice(borrower, marketView);
        if (allowed == 0) revert SettlementIneligible();
        if (hookData.debtCanceled > allowed) revert SettlementExceedsAllowed();

        // payload consistency (core already enforces these; cheap to re-check on the trusted values, no reads)
        uint256 sharesToBurn =
            hookData.debtCanceled.toSharesUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        if (sharesToBurn > marketView.borrowShares) revert SettlementExceedsDebt();
        if (hookData.collateralSeized == 0 || hookData.collateralSeized > marketView.rawCollateral) {
            revert SettlementInvalidSeize();
        }

        // settle activation, then debit buckets by the exact amount core seizes from raw (lockstep).
        // A freeze defers maturation, seizure still reaches all collateral via debit.
        if (!_isFrozen) {
            _activation.syncActivation(borrower, _suspectsRegistry.suspicion(_MARKET_ID, borrower));
        }
        _activation.debit(borrower, hookData.collateralSeized, 0);

        _settlementQueue.sync(
            borrower, marketView.borrowShares - sharesToBurn, marketView.rawCollateral - hookData.collateralSeized
        );
    }

    // ---
    // Internal Helpers
    // ---

    /// @dev Single source for the hook cap and the sizing views: the queue's policy slice with the
    ///      dust extension, fed the activation minimum as the dust threshold.
    function _allowedSlice(address borrower, SettlementQueueLib.MarketView memory marketView)
        internal
        view
        returns (uint256)
    {
        return _settlementQueue.allowedSlice(borrower, marketView, _activation.config.minActivationAmount);
    }

    function _applyConfig(CollateralActivationLib.Config memory cfg) internal {
        _activation.setConfig(cfg);
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

    function _debtAssets(Id id, address borrower) internal view returns (uint256) {
        (, uint128 borrowShares,) = LIDO_LEND.position(id, borrower);
        if (borrowShares == 0) return 0;
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = LIDO_LEND.market(id);
        return uint256(borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    /// @dev Max loan assets `active` collateral can back at the market LLTV.
    function _maxBorrow(Id id, uint256 active) internal view returns (uint256) {
        (,, address oracle,, uint256 lltv) = LIDO_LEND.idToMarketParams(id);
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

    function _marketView(Id id, address borrower)
        internal
        view
        returns (SettlementQueueLib.MarketView memory marketView)
    {
        marketView.price = _collateralPrice(id);
        (marketView.borrowShares, marketView.rawCollateral) = _currentPosition(id, borrower);
        (marketView.totalBorrowAssets, marketView.totalBorrowShares) = _totalBorrowTotals(id);
    }

    function _currentPosition(Id id, address borrower)
        internal
        view
        returns (uint256 borrowShares, uint256 rawCollateral)
    {
        (, uint128 bs, uint128 rc) = LIDO_LEND.position(id, borrower);
        return (bs, rc);
    }

    /// @dev Borrow totals with pending interest simulated, so view-driven slice sizing matches the
    ///      hook-time numbers (the core accrues before invoking hooks; with nothing pending this
    ///      reduces to the raw market read).
    function _totalBorrowTotals(Id id) internal view returns (uint256 totalBorrowAssets, uint256 totalBorrowShares) {
        (,, totalBorrowAssets, totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(LIDO_LEND)), _marketParamsOf(id));
    }

    function _marketParamsOf(Id id) internal view returns (MarketParams memory marketParams) {
        (
            marketParams.loanToken,
            marketParams.collateralToken,
            marketParams.oracle,
            marketParams.irm,
            marketParams.lltv
        ) = LIDO_LEND.idToMarketParams(id);
    }

    function _collateralPrice(Id id) internal view returns (uint256) {
        (,, address oracle,,) = LIDO_LEND.idToMarketParams(id);
        return IOracle(oracle).price();
    }

    function _checkNotFrozen() internal view {
        if (_isFrozen) revert MarketIsFrozen();
    }

    /// @dev Hard-block: a banned address may not borrow, receive a borrow, or initiate one. The soft
    ///      suspicion score only lengthens activation; a ban is the binary stop on the borrow path.
    function _checkNotBlocked(address user) internal view {
        if (_suspectsRegistry.isBanned(_MARKET_ID, user)) revert AddressBlocked();
    }
}
