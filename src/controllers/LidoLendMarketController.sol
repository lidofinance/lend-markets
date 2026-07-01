// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id, IMorpho, MarketParams, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {WAD} from "../libs/Constants.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUntil} from "../utils/PausableUntil.sol";
import {IGuardianSignals} from "../interfaces/IGuardianSignals.sol";
import {GuardiansOpinion, Status} from "../types/GuardianSignalsTypes.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";
import {ILidoLendMarketConfigurator} from "../interfaces/ILidoLendMarketConfigurator.sol";
import {CollateralActivationLib} from "../libs/CollateralActivationLib.sol";
import {SettlementQueueLib} from "../libs/SettlementQueueLib.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {MarketView, PositionView, SettlementConfig} from "../types/SettlementTypes.sol";

/// @notice Lido-policy controller for a Lido Lend market: collateral activation, freeze and pause,
///         address gating, and the settlement queue. All hook policy enters through `on`.
contract LidoLendMarketController layout at erc7201("lido.lending.storage.LidoLendMarketController")
    is
    Initializable,
    AccessControlUpgradeable,
    PausableUntil,
    ILidoLendMarketController
{
    using SharesMathLib for uint256;
    using CollateralActivationLib for CollateralActivationLib.State;
    using SettlementQueueLib for SettlementQueueLib.State;

    // ---
    // ROLES
    // ---

    /// @dev The single governance role: full activation and settlement config, grant and revoke instant
    ///      activation.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @dev Freezes the market: blocks new borrows and debt-bearing collateral withdrawals.
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    /// @dev Lifts a freeze.
    bytes32 public constant UNFREEZER_ROLE = keccak256("UNFREEZER_ROLE");
    /// @dev Pauses every hook for a bounded (or indefinite) duration.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev Lifts a pause.
    bytes32 public constant RESUMER_ROLE = keccak256("RESUMER_ROLE");

    // ---
    // IMMUTABLES
    // ---

    /// @dev The Morpho-fork core. The only authorized hook caller, and the source of position and market reads.
    IMorpho public immutable LIDO_LEND;
    /// @dev The single market this controller is bound to. Hooks for any other id revert.
    Id internal immutable _MARKET_ID;

    // ---
    // STORAGE
    // ---

    /// @dev When set, new borrows and debt-bearing collateral withdrawals revert and activation maturation
    ///      defers. Debt-free positions can still withdraw.
    bool private _isFrozen;
    /// @dev Guardian-signal registry read on every hook to gate borrowing (ban) and scale activation (strikes).
    IGuardianSignals private _guardianSignals;
    /// @dev Config + inflow accumulator + per-borrower activation pipeline.
    CollateralActivationLib.State private _activation;
    /// @dev Risk queue + settlement LTVs + settlement config.
    SettlementQueueLib.State private _settlementQueue;
    /// @dev Trusted caller contracts whose supplies skip the activation timer/throttle (instant-active).
    ///      Keyed on the supply `caller`, not the position owner, so a trusted router activating on behalf of
    ///      users qualifies. Must only ever hold access-gated contracts, never a permissionless helper.
    mapping(address caller => bool) private _instantActivationCallers;

    // ---
    // MODIFIERS
    // ---

    /// @dev Restricts a hook to the core acting on this controller's own market: the caller must be the core
    ///      and the id must match `_MARKET_ID`.
    modifier onlyControlledMarket(Id id) {
        if (msg.sender != address(LIDO_LEND)) revert Unauthorized();
        if (Id.unwrap(id) != Id.unwrap(_MARKET_ID)) revert InvalidMarketId();
        _;
    }

    // ---
    // INITIALIZATION
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(IMorpho lidoLend, Id marketId_) {
        LIDO_LEND = lidoLend;
        _MARKET_ID = marketId_;
        _disableInitializers();
    }

    /// @notice One-shot proxy initializer: grants roles and wires the guardian-signals registry and config.
    function initialize(address admin, IGuardianSignals guardianSignals, CollateralActivationConfig calldata cfg)
        external
        initializer
    {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _guardianSignals = guardianSignals;
        _settlementQueue.init();
        _activation.setConfig(cfg);
    }

    // ---
    // CORE HOOK INTERFACE
    // ---

    /// @notice Core hook entrypoint: dispatches each market action to its internal handler.
    /// @dev Reverts on an unknown event so any future Morpho-fork-side change without a controller update
    ///      fails closed instead of silently skipping policy.
    function on(Id id, HookEvent hookEvent, bytes calldata data) external onlyControlledMarket(id) {
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
            hookEvent != HookEvent.Supply && hookEvent != HookEvent.Withdraw && hookEvent != HookEvent.AccrueInterest
        ) {
            revert UnknownHookEvent();
        }
    }

    /// @notice The market this controller is bound to, checked by the core when it binds at market creation.
    function marketId() external view returns (Id) {
        return _MARKET_ID;
    }

    // ---
    // COLLATERAL ACTIVATION
    // ---

    /// @inheritdoc ILidoLendMarketConfigurator
    function setCollateralActivationConfig(CollateralActivationConfig calldata cfg) external onlyRole(MANAGER_ROLE) {
        _activation.setConfig(cfg);
    }

    /// @inheritdoc ILidoLendMarketConfigurator
    function collateralActivationConfig() external view returns (CollateralActivationConfig memory) {
        return _activation.config;
    }

    /// @inheritdoc ILidoLendMarketController
    function currentInflow() external view returns (uint256) {
        return _activation.calcDecayedInflow();
    }

    /// @inheritdoc ILidoLendMarketController
    function currentActivationDelay(uint256 inflowIncrement) external view returns (uint256) {
        return _activation.getCurrentActivationDelay(inflowIncrement);
    }

    /// @inheritdoc ILidoLendMarketController
    function grantInstantActivation(address caller) external onlyRole(MANAGER_ROLE) {
        _instantActivationCallers[caller] = true;
        emit InstantActivationSet(caller, true);
    }

    /// @inheritdoc ILidoLendMarketConfigurator
    function revokeInstantActivation(address caller) external onlyRole(MANAGER_ROLE) {
        _instantActivationCallers[caller] = false;
        emit InstantActivationSet(caller, false);
    }

    /// @inheritdoc ILidoLendMarketController
    function hasInstantActivation(address caller) external view returns (bool) {
        return _instantActivationCallers[caller];
    }

    // ---
    // SETTLEMENT QUEUE
    // ---

    /// @inheritdoc ILidoLendMarketController
    function setSettlementConfig(SettlementConfig calldata config) external onlyRole(MANAGER_ROLE) {
        _settlementQueue.setSettlementConfig(config);
    }

    /// @inheritdoc ILidoLendMarketController
    function settlementConfig() external view returns (SettlementConfig memory) {
        return _settlementQueue.config;
    }

    /// @inheritdoc ILidoLendMarketController
    /// @dev `msg.sender` is the borrower. Setting it makes the caller settle-eligible even when the
    ///      settlement would not otherwise pick it next, capped at the slice that brings its LTV to `ltv`.
    function setSettlementLtv(uint256 ltv) external {
        _settlementQueue.setSettlementLtv(msg.sender, ltv);
    }

    /// @inheritdoc ILidoLendMarketController
    function settlementLtv(address borrower) external view returns (uint256 ltv, uint256 sliceAssets) {
        SettlementQueueLib.State storage queue = _settlementQueue;
        ltv = queue.settlementLtvOf(borrower);
        if (ltv == 0) return (0, 0);
        sliceAssets = queue.settlementLtvSlice(_marketView(_MARKET_ID), borrower, _positionView(_MARKET_ID, borrower));
    }

    /// @inheritdoc ILidoLendMarketController
    function settlementBorrowersCount() external view returns (uint256) {
        return _settlementQueue.size();
    }

    /// @inheritdoc ILidoLendMarketController
    function hasBadDebt() external view returns (bool) {
        address top = _settlementQueue.peekRoot();
        if (top == address(0)) return false;
        return _isBadDebt(_marketView(_MARKET_ID), _positionView(_MARKET_ID, top));
    }

    /// @inheritdoc ILidoLendMarketController
    function nextSettlementBorrower()
        external
        view
        returns (address borrower, uint256 sliceAssets, uint256 sliceShares)
    {
        borrower = _settlementQueue.peekRoot();
        if (borrower == address(0)) return (address(0), 0, 0);
        MarketView memory marketView = _marketView(_MARKET_ID);
        sliceAssets = _settlementQueue.allowedSlice(marketView, borrower, _positionView(_MARKET_ID, borrower));
        sliceShares = sliceAssets.toSharesDown(marketView.totalSupplyAssets, marketView.totalSupplyShares);
    }

    /// @inheritdoc ILidoLendMarketController
    function settlementFor(address borrower) external view returns (uint256 sliceAssets, uint256 sliceShares) {
        MarketView memory marketView = _marketView(_MARKET_ID);
        sliceAssets = _settlementQueue.allowedSlice(marketView, borrower, _positionView(_MARKET_ID, borrower));
        sliceShares = sliceAssets.toSharesDown(marketView.totalSupplyAssets, marketView.totalSupplyShares);
    }

    /// @inheritdoc ILidoLendMarketController
    function settlementBorrowers(uint256 offset, uint256 maxCount)
        external
        view
        returns (address[] memory borrowers, uint256[] memory keys)
    {
        return _settlementQueue.settlementBorrowers(offset, maxCount);
    }

    // ---
    // FREEZE & PAUSE
    // ---

    /// @inheritdoc ILidoLendMarketController
    function freeze() external onlyRole(FREEZER_ROLE) {
        _isFrozen = true;
        emit FrozenSet(true, msg.sender);
    }

    /// @inheritdoc ILidoLendMarketController
    function unfreeze() external onlyRole(UNFREEZER_ROLE) {
        _isFrozen = false;
        emit FrozenSet(false, msg.sender);
    }

    /// @inheritdoc ILidoLendMarketController
    function pauseFor(uint256 duration) external onlyRole(PAUSER_ROLE) {
        _pauseFor(duration);
    }

    /// @inheritdoc ILidoLendMarketController
    function resume() external onlyRole(RESUMER_ROLE) {
        _resume();
    }

    /// @inheritdoc ILidoLendMarketController
    function isFrozen() external view returns (bool) {
        return _isFrozen;
    }

    // ---
    // POSITION VIEW
    // ---

    /// @inheritdoc ILidoLendMarketController
    function positionOf(address borrower)
        external
        view
        returns (ILidoLendMarketController.BorrowerPosition memory dashboard)
    {
        PositionView memory position = _positionView(_MARKET_ID, borrower);
        MarketView memory marketView = _marketView(_MARKET_ID);
        GuardiansOpinion memory opinion = _guardianSignals.getOpinion(_MARKET_ID, borrower);
        dashboard.banned = opinion.status == Status.Banned;
        dashboard.strikes = opinion.strikes;
        dashboard.flagCount = opinion.flagCount;
        (dashboard.activating, dashboard.dust) = _activation.getActivationState(borrower);
        dashboard.active = position.collateral - dashboard.activating - dashboard.dust;
        dashboard.unlockTime = _activation.getUnlockTime(borrower, opinion);
        dashboard.debtAssets = _debtAssets(marketView, position);
        dashboard.settlementLtv = _settlementQueue.settlementLtvOf(borrower);
        dashboard.isNextToSettle = _settlementQueue.peekRoot() == borrower;
        dashboard.slice = _settlementQueue.allowedSlice(marketView, borrower, position);
    }

    // ---
    // HOOK HANDLERS
    // ---

    /// @dev Supply hook: settle any matured activation, book the deposit into the activation pipeline, and
    ///      re-key the settlement queue on the post-deposit position.
    function _handleSupplyCollateral(Id id, SupplyCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;

        // raw is pre-deposit: this hook runs before core's `collateral += assets`
        PositionView memory position = _positionView(id, borrower);

        // settle anything already matured, then book the deposit. A sub-threshold deposit stays dust, and only
        // once it crosses the threshold does the lot enter the activation timer. A freeze or ban defers maturation.
        _activation.sync(_isFrozen, borrower, _guardianSignals.getOpinion(_MARKET_ID, borrower));
        _activation.credit(borrower, hookData.assets, _instantActivationCallers[hookData.caller]);

        position.collateral += hookData.assets;
        _settlementQueue.sync(borrower, position);
    }

    /// @dev Withdraw hook: with open debt a freeze blocks it, the remaining active must still cover the debt
    ///      at LLTV, and raw collateral may not fall below the minimum borrowable size. Debt-free exits are free.
    function _handleWithdrawCollateral(Id id, WithdrawCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;

        // raw and borrowShares are pre-withdraw: this hook runs before core's `collateral -= assets`
        PositionView memory position = _positionView(id, borrower);

        // Freeze blocks withdraw only while there is open debt. A zero-debt withdraw is always allowed
        // as a non-custody exit, and a banned address may still pull its own collateral.
        if (_isFrozen && position.borrowShares != 0) revert MarketIsFrozen();

        // settle activation, then drain the un-matured buckets (dust, then activating above the lock) and reverse
        // any same-tx flash addition to the inflow (the lib owns the undo); a revert below rolls this back. The
        // lib returns the post-debit inactive, so active is the post-withdraw raw minus it.
        _activation.sync(_isFrozen, borrower, _guardianSignals.getOpinion(_MARKET_ID, borrower));
        uint256 inactive = _activation.debit(borrower, hookData.assets);

        if (hookData.assets > position.collateral) revert PositionAccountingMismatch();
        position.collateral -= hookData.assets;
        uint256 activeCollateral = position.collateral - inactive;

        // With open debt: the remaining active collateral must still cover the debt at LLTV, and raw collateral
        // may not fall below the minimum borrowable size (repay the debt to zero to exit below the floor).
        if (position.borrowShares != 0) {
            MarketView memory marketView = _marketView(id);
            if (_debtAssets(marketView, position) > _getMaxBorrow(marketView, activeCollateral)) {
                revert InsufficientActiveCollateral();
            }
            if (position.collateral < _settlementQueue.config.minBorrowCollateral) {
                revert CollateralFloorBreached();
            }
        }

        _settlementQueue.sync(borrower, position);
    }

    /// @dev Borrow hook: blocked by a freeze or a ban on caller/receiver/borrower. Capacity uses active
    ///      (matured) collateral only.
    function _handleBorrow(Id id, BorrowHookData memory hookData) internal {
        if (_isFrozen) revert MarketIsFrozen();

        // A banned actor cannot take on debt (onBehalf), receive the loan (receiver), or initiate the
        // borrow (caller). Soft strikes only delay activation; a ban hard-blocks the borrow.
        if (_guardianSignals.getOpinion(_MARKET_ID, hookData.caller).status == Status.Banned) {
            revert AddressBanned();
        }

        if (_guardianSignals.getOpinion(_MARKET_ID, hookData.receiver).status == Status.Banned) {
            revert AddressBanned();
        }

        GuardiansOpinion memory borrowerOpinion = _guardianSignals.getOpinion(_MARKET_ID, hookData.onBehalf);

        if (borrowerOpinion.status == Status.Banned) {
            revert AddressBanned();
        }

        // Borrow capacity uses active (matured) collateral only. `sync` matures any ready lot, subject to the
        // quorum-scan gate, and returns the post-mature inactive total. Active is the raw collateral minus that.
        uint256 inactive = _activation.sync(_isFrozen, hookData.onBehalf, borrowerOpinion);

        PositionView memory position = _positionView(id, hookData.onBehalf);
        uint256 activeCollateral = position.collateral - inactive;

        // Position floor: a borrow may not open or grow debt against a position whose raw collateral is below
        // the minimum borrowable size, keeping debt positions economical to liquidate and settle. The check
        // reads the live config value, so a raised floor applies to subsequent borrows immediately.
        if (position.collateral < _settlementQueue.config.minBorrowCollateral) revert CollateralFloorBreached();

        MarketView memory marketView = _marketView(id);
        if (_debtAssets(marketView, position) + hookData.assets > _getMaxBorrow(marketView, activeCollateral)) {
            revert InsufficientActiveCollateral();
        }

        position.borrowShares += hookData.shares;
        _settlementQueue.sync(hookData.onBehalf, position);
    }

    /// @dev Repay hook: re-key the settlement queue on the post-repay shares (the borrower drops out at zero debt).
    function _handleRepay(Id id, RepayHookData memory hookData) internal {
        // repay lowers debt: re-key the queue on the post-repay shares (drops out at zero debt)
        PositionView memory position = _positionView(id, hookData.onBehalf);
        if (hookData.shares > position.borrowShares) revert PositionAccountingMismatch();
        position.borrowShares -= hookData.shares;
        _settlementQueue.sync(hookData.onBehalf, position);
    }

    /// @dev Liquidate hook: drain the seized collateral from the activation buckets and re-key the queue on
    ///      the post-liquidation position. Liquidation is a forced path.
    function _handleLiquidate(Id id, LiquidateHookData memory hookData) internal {
        address borrower = hookData.borrower;
        PositionView memory position = _positionView(id, borrower);

        // drain the seized collateral from the buckets before core decrements raw
        if (hookData.seizedAssets != 0) _activation.seize(borrower, hookData.seizedAssets);

        // re-key on the post-liquidation position
        if (hookData.repaidShares > position.borrowShares || hookData.seizedAssets > position.collateral) {
            revert PositionAccountingMismatch();
        }
        position.borrowShares -= hookData.repaidShares;
        position.collateral -= hookData.seizedAssets;
        _settlementQueue.sync(borrower, position);
    }

    /// @dev Settle hook: gates the cut on policy — reverts if the queue root is bad debt, if the target is
    ///      ineligible, or if the cut exceeds the allowed slice — then drains buckets in lockstep with the
    ///      raw seizure and re-keys the queue.
    function _handleSettle(Id id, SettleHookData memory hookData) internal {
        address borrower = hookData.borrower;

        // Re-read the borrower position and market view from core, since the payload carries only the cut
        // amounts. The policy checks below gate that cut.
        PositionView memory position = _positionView(id, borrower);
        MarketView memory marketView = _marketView(id);

        // bad-debt gate: revert if the queue root (riskiest position) is bad debt. An empty queue has no root
        // (peekRoot returns address(0)), so this falls through to the eligibility gate below.
        address riskiestBorrower = _settlementQueue.peekRoot();
        if (_isBadDebt(marketView, riskiestBorrower == borrower ? position : _positionView(id, riskiestBorrower))) {
            revert SettlementBadDebt();
        }

        // eligibility + cut bound: only the queue root or a borrower with a settlement LTV may be cut, capped at the
        // policy slice.
        uint256 allowed = _settlementQueue.allowedSlice(marketView, borrower, position);
        if (allowed == 0) revert SettlementIneligible();
        if (hookData.borrowAssetsCanceled > allowed) revert SettlementExceedsAllowed();

        // payload consistency (core already enforces these; cheap to re-check on the trusted values, no reads)
        uint256 sharesToBurn =
            hookData.borrowAssetsCanceled.toSharesUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        if (sharesToBurn > position.borrowShares) revert SettlementExceedsDebt();
        if (hookData.seizedAssets == 0 || hookData.seizedAssets > position.collateral) {
            revert SettlementInvalidSeize();
        }

        // settle activation, then drain buckets by the exact amount core seizes from raw (lockstep).
        // A freeze or ban defers maturation, and `seize` drains all buckets regardless of maturation state.
        _activation.sync(_isFrozen, borrower, _guardianSignals.getOpinion(_MARKET_ID, borrower));

        _activation.seize(borrower, hookData.seizedAssets);

        position.borrowShares -= sharesToBurn;
        position.collateral -= hookData.seizedAssets;
        _settlementQueue.sync(borrower, position);
    }

    // ---
    // INTERNAL HELPERS
    // ---

    /// @dev Borrower debt in loan assets, rounded up. 0 when the position carries no debt.
    function _debtAssets(MarketView memory marketView, PositionView memory position) internal pure returns (uint256) {
        return position.borrowShares.toAssetsUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
    }

    /// @dev Value of `collateral` units in loan assets at the market's oracle price, rounded down.
    function _collateralValue(MarketView memory marketView, uint256 collateral) internal pure returns (uint256) {
        return Math.mulDiv(collateral, marketView.price, ORACLE_PRICE_SCALE);
    }

    /// @dev Max loan assets `collateral` can back at the market LLTV.
    function _getMaxBorrow(MarketView memory marketView, uint256 collateral) internal pure returns (uint256) {
        return Math.mulDiv(_collateralValue(marketView, collateral), marketView.lltv, WAD);
    }

    /// @dev Bad debt over a position+market snapshot: debt value exceeds collateral value. Pure.
    function _isBadDebt(MarketView memory marketView, PositionView memory position) internal pure returns (bool) {
        if (position.borrowShares == 0) return false;
        return _debtAssets(marketView, position) > _collateralValue(marketView, position.collateral);
    }

    /// @dev Market snapshot for sizing: LLTV, oracle price, and supply/borrow totals with pending interest
    ///      simulated so view numbers match what the core sees at hook time.
    function _marketView(Id id) internal view returns (MarketView memory marketView) {
        MarketParams memory params = LIDO_LEND.idToMarketParams(id);

        marketView.lltv = params.lltv;
        marketView.price = IOracle(params.oracle).price();
        // supply and borrow totals with pending interest simulated, so view sizing matches the hook-time
        // numbers (the core accrues before invoking hooks)
        (
            marketView.totalSupplyAssets,
            marketView.totalSupplyShares,
            marketView.totalBorrowAssets,
            marketView.totalBorrowShares
        ) = MorphoBalancesLib.expectedMarketBalances(LIDO_LEND, params);
    }

    /// @dev Borrower's settle-relevant position, widened from the core `Position` (uint128 fields).
    function _positionView(Id id, address borrower) internal view returns (PositionView memory) {
        Position memory p = LIDO_LEND.position(id, borrower);
        return PositionView({borrowShares: p.borrowShares, collateral: p.collateral});
    }
}
