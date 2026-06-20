// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id, IMorpho, MarketParams, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MathLib, WAD} from "@lido-lend/src/libraries/MathLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUntil} from "../utils/PausableUntil.sol";
import {IGuardianSignals} from "../interfaces/IGuardianSignals.sol";
import {GuardiansOpinion, Status} from "../interfaces/GuardianSignalsTypes.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../libs/CollateralActivationLib.sol";
import {SettlementQueueLib} from "../libs/SettlementQueueLib.sol";
import {MarketView, PositionView, SlicePolicy} from "../types/SettlementTypes.sol";

/// @notice Lido-policy controller for a Lido Lend market: collateral activation, freeze and pause,
///         address gating, and the settlement queue. All hook policy enters through `on`.
contract LidoLendMarketController layout at erc7201("lido.lending.storage.LidoLendMarketController")
    is
    Initializable,
    AccessControlUpgradeable,
    PausableUntil,
    ILidoLendMarketController
{
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using CollateralActivationLib for CollateralActivationLib.State;
    using SettlementQueueLib for SettlementQueueLib.State;

    // ---
    // ROLES
    // ---

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant RISK_STEWARD_ROLE = keccak256("RISK_STEWARD_ROLE");
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    bytes32 public constant UNFREEZER_ROLE = keccak256("UNFREEZER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant RESUMER_ROLE = keccak256("RESUMER_ROLE");

    // ---
    // IMMUTABLES
    // ---

    IMorpho public immutable LIDO_LEND;
    Id internal immutable _MARKET_ID;

    // ---
    // STORAGE
    // ---

    bool private _isFrozen;
    IGuardianSignals private _guardianSignals;
    /// @dev Config + inflow accumulator + per-borrower activation pipeline.
    CollateralActivationLib.State private _activation;
    /// @dev Risk queue + watermarks + slice policy.
    SettlementQueueLib.State private _settlementQueue;
    /// @dev Minimum gap kept between borrow utilization and 100% (WAD): reserves that share of supply for
    ///      lender withdrawals, so a borrow that would close the gap reverts. 0 = no gap.
    uint256 private _borrowUtilizationGap;

    // ---
    // MODIFIERS
    // ---

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
    function initialize(address admin, IGuardianSignals guardianSignals, CollateralActivationLib.Config calldata cfg)
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

    /// @notice Core hook entrypoint, dispatches each market action to its internal handler.
    /// @dev Reverts on unknown event so any future Morpho-fork-side change without a controller update
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

    /// @notice Market this controller is bound to, checked by the core when it binds at market creation.
    function marketId() external view returns (Id) {
        return _MARKET_ID;
    }

    // ---
    // COLLATERAL ACTIVATION
    // ---

    /// @inheritdoc ILidoLendMarketController
    function setConfig(CollateralActivationLib.Config calldata cfg) external onlyRole(MANAGER_ROLE) {
        _activation.setConfig(cfg);
    }

    /// @inheritdoc ILidoLendMarketController
    function increaseMinActivationDelay(uint64 newMinActivationDelay) external onlyRole(RISK_STEWARD_ROLE) {
        if (newMinActivationDelay < _activation.config.minActivationDelay) revert ConfigNotTightened();
        _activation.setMinActivationDelay(newMinActivationDelay);
    }

    /// @inheritdoc ILidoLendMarketController
    function increaseMaxActivationDelay(uint64 newMaxActivationDelay) external onlyRole(RISK_STEWARD_ROLE) {
        if (newMaxActivationDelay < _activation.config.maxActivationDelay) revert ConfigNotTightened();
        _activation.setMaxActivationDelay(newMaxActivationDelay);
    }

    /// @inheritdoc ILidoLendMarketController
    /// @dev Forced paths (liquidation, settle) ignore the hold. The hold is temporary: held collateral
    ///      matures into `active` on its timer and becomes withdrawable, so this is not a custody power.
    function setActivatingHold(uint128 activatingHold) external onlyRole(RISK_STEWARD_ROLE) {
        _activation.setActivatingHold(activatingHold);
    }

    /// @inheritdoc ILidoLendMarketController
    function currentInflow() external view returns (uint256) {
        return _activation.getInflow();
    }

    /// @inheritdoc ILidoLendMarketController
    function grantInstantActivation(address borrower) external onlyRole(MANAGER_ROLE) {
        _activation.setInstantActivation(borrower, true);
    }

    /// @inheritdoc ILidoLendMarketController
    function revokeInstantActivation(address borrower) external onlyRole(RISK_STEWARD_ROLE) {
        _activation.setInstantActivation(borrower, false);
    }

    /// @inheritdoc ILidoLendMarketController
    function hasInstantActivation(address borrower) external view returns (bool) {
        return _activation.instantActivation[borrower];
    }

    // ---
    // BORROW UTILIZATION GAP
    // ---

    /// @inheritdoc ILidoLendMarketController
    function setBorrowUtilizationGap(uint256 newBorrowUtilizationGap) external onlyRole(MANAGER_ROLE) {
        if (newBorrowUtilizationGap >= WAD) revert BorrowUtilizationGapTooHigh();
        _borrowUtilizationGap = newBorrowUtilizationGap;
        emit BorrowUtilizationGapSet(newBorrowUtilizationGap);
    }

    /// @inheritdoc ILidoLendMarketController
    function increaseBorrowUtilizationGap(uint256 newBorrowUtilizationGap) external onlyRole(RISK_STEWARD_ROLE) {
        if (newBorrowUtilizationGap >= WAD) revert BorrowUtilizationGapTooHigh();
        if (newBorrowUtilizationGap <= _borrowUtilizationGap) revert ConfigNotTightened();
        _borrowUtilizationGap = newBorrowUtilizationGap;
        emit BorrowUtilizationGapSet(newBorrowUtilizationGap);
    }

    /// @inheritdoc ILidoLendMarketController
    function borrowUtilizationGap() external view returns (uint256) {
        return _borrowUtilizationGap;
    }

    /// @inheritdoc ILidoLendMarketController
    function maxBorrowUtilization() external view returns (uint256) {
        return WAD - _borrowUtilizationGap;
    }

    /// @inheritdoc ILidoLendMarketController
    function currentBorrowUtilization() external view returns (uint256) {
        MarketParams memory params = LIDO_LEND.idToMarketParams(_MARKET_ID);
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(LIDO_LEND, params);
        return totalSupplyAssets == 0 ? 0 : totalBorrowAssets * WAD / totalSupplyAssets;
    }

    // ---
    // SETTLEMENT QUEUE
    // ---

    /// @inheritdoc ILidoLendMarketController
    function setSlicePolicy(SlicePolicy calldata policy) external onlyRole(MANAGER_ROLE) {
        _settlementQueue.setSlicePolicy(policy);
    }

    /// @inheritdoc ILidoLendMarketController
    function slicePolicy() external view returns (SlicePolicy memory) {
        return _settlementQueue.policy;
    }

    /// @inheritdoc ILidoLendMarketController
    /// @dev `msg.sender` is the borrower. Setting it makes the caller eligible for settle even
    ///      when it is not the queue root, capped at the slice that brings its LTV to `ltv`.
    function setBorrowerWatermark(uint256 ltv) external {
        _settlementQueue.setWatermark(msg.sender, ltv);
    }

    /// @inheritdoc ILidoLendMarketController
    function watermarkInfo(address borrower) external view returns (uint256 watermarkLtv, uint256 sliceAssets) {
        SettlementQueueLib.State storage queue = _settlementQueue;
        watermarkLtv = queue.watermarkOf(borrower);
        if (watermarkLtv == 0) return (0, 0);
        sliceAssets = queue.watermarkSlice(_marketView(_MARKET_ID), borrower, _positionView(_MARKET_ID, borrower));
    }

    /// @inheritdoc ILidoLendMarketController
    function settlementQueueSize() external view returns (uint256) {
        return _settlementQueue.size();
    }

    /// @inheritdoc ILidoLendMarketController
    function rootHasBadDebt() external view returns (bool) {
        address top = _settlementQueue.peekRoot();
        if (top == address(0)) return false;
        return _isBadDebt(_marketView(_MARKET_ID), _positionView(_MARKET_ID, top));
    }

    /// @inheritdoc ILidoLendMarketController
    function nextSettlementCut() external view returns (address borrower, uint256 sliceAssets) {
        borrower = _settlementQueue.peekRoot();
        if (borrower == address(0)) return (address(0), 0);
        sliceAssets =
            _settlementQueue.allowedSlice(_marketView(_MARKET_ID), borrower, _positionView(_MARKET_ID, borrower));
    }

    /// @inheritdoc ILidoLendMarketController
    function allowedSliceFor(address borrower) external view returns (uint256) {
        return _settlementQueue.allowedSlice(_marketView(_MARKET_ID), borrower, _positionView(_MARKET_ID, borrower));
    }

    /// @inheritdoc ILidoLendMarketController
    function eligibleBorrowers(uint256 maxCount)
        external
        view
        returns (address[] memory borrowers, uint256[] memory keys)
    {
        return _settlementQueue.eligibleBorrowers(maxCount);
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
        (dashboard.active, dashboard.activating, dashboard.dust) = _activation.getBuckets(borrower);
        dashboard.unlockTime = _activation.getUnlockTime(borrower, opinion);
        dashboard.debtAssets = _debtAssets(marketView, position);
        dashboard.watermarkLtv = _settlementQueue.watermarkOf(borrower);
        dashboard.isQueueRoot = _settlementQueue.peekRoot() == borrower;
        dashboard.allowedSlice = _settlementQueue.allowedSlice(marketView, borrower, position);
    }

    // ---
    // HOOK HANDLERS
    // ---

    function _handleSupplyCollateral(Id id, SupplyCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;

        // raw is pre-deposit: this hook runs before core's `collateral += assets`
        PositionView memory position = _positionView(id, borrower);

        // settle anything already matured, then book the deposit (promotes past the dust threshold).
        // A freeze or ban defers maturation.
        _activation.syncActivation(_isFrozen, borrower, _guardianSignals.getOpinion(_MARKET_ID, borrower));
        _activation.deposit(borrower, hookData.assets);

        position.collateral += hookData.assets;
        _settlementQueue.sync(borrower, position);
    }

    function _handleWithdrawCollateral(Id id, WithdrawCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;

        // raw and borrowShares are pre-withdraw: this hook runs before core's `collateral -= assets`
        PositionView memory position = _positionView(id, borrower);

        // Freeze blocks withdraw only while there is open debt. A zero-debt withdraw is always allowed
        // as a non-custody exit. No guardian gate either: a banned address can still pull its own collateral.
        if (_isFrozen && position.borrowShares != 0) revert MarketIsFrozen();

        // settle activation, then debit the buckets (dust, activating, active) and reverse any same-tx
        // flash addition to the inflow (the lib owns the undo); a revert below rolls this back
        _activation.syncActivation(_isFrozen, borrower, _guardianSignals.getOpinion(_MARKET_ID, borrower));
        uint256 activeCollateral = _activation.withdraw(borrower, hookData.assets);

        // with open debt, the remaining active must still cover it at LLTV (stricter than core's raw check)
        if (position.borrowShares != 0) {
            MarketView memory marketView = _marketView(id);
            if (_debtAssets(marketView, position) > _getMaxBorrow(marketView, activeCollateral)) {
                revert InsufficientActiveCollateral();
            }
        }

        if (hookData.assets > position.collateral) revert PositionAccountingMismatch();
        position.collateral -= hookData.assets;

        // Open-debt collateral floor: while a borrower owes debt, raw collateral may not be drawn below the
        // activation minimum. Sub-minimum collateral reaches the book only via forced seizure, never voluntary
        // withdrawal, so a borrower cannot park a high-LTV dust position at the settlement-queue root. To exit
        // below the floor, repay the debt to zero first.
        if (position.borrowShares != 0 && position.collateral < _activation.config.minActivationAmount) {
            revert CollateralFloorBreached();
        }

        _settlementQueue.sync(borrower, position);
    }

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

        // Stricter Lido constraint: borrow capacity uses active (matured) collateral only. `syncActivation`
        // matures any ready lot — subject to the quorum-scan gate — and returns the post-mature active. The
        // core's standard health check uses raw collateral; this adds the active-only ceiling on the settled state.
        uint256 activeCollateral = _activation.syncActivation(_isFrozen, hookData.onBehalf, borrowerOpinion);

        PositionView memory position = _positionView(id, hookData.onBehalf);

        MarketView memory marketView = _marketView(id);
        if (_debtAssets(marketView, position) + hookData.assets > _getMaxBorrow(marketView, activeCollateral)) {
            revert InsufficientActiveCollateral();
        }

        // Borrow utilization gap: a borrow must leave at least `_borrowUtilizationGap` of supply
        // un-borrowed (a gap below 100% utilization) for lender withdrawals. Borrow totals here are
        // pre-this-borrow, so the prospective borrow adds `hookData.assets`. 0 = no gap.
        if (_borrowUtilizationGap != 0) {
            uint256 newBorrowAssets = marketView.totalBorrowAssets + hookData.assets;
            if (newBorrowAssets * WAD > (WAD - _borrowUtilizationGap) * marketView.totalSupplyAssets) {
                revert MaxBorrowUtilizationExceeded();
            }
        }

        position.borrowShares += hookData.shares;
        _settlementQueue.sync(hookData.onBehalf, position);
    }

    function _handleRepay(Id id, RepayHookData memory hookData) internal {
        // repay lowers debt: re-key the queue on the post-repay shares (drops out at zero debt)
        PositionView memory position = _positionView(id, hookData.onBehalf);
        if (hookData.shares > position.borrowShares) revert PositionAccountingMismatch();
        position.borrowShares -= hookData.shares;
        _settlementQueue.sync(hookData.onBehalf, position);
    }

    function _handleLiquidate(Id id, LiquidateHookData memory hookData) internal {
        address borrower = hookData.borrower;
        PositionView memory position = _positionView(id, borrower);

        // debit the seized collateral from the buckets before core decrements raw
        if (hookData.seizedAssets != 0) _activation.debit(borrower, hookData.seizedAssets, 0);

        // re-key on the post-liquidation position
        if (hookData.repaidShares > position.borrowShares || hookData.seizedAssets > position.collateral) {
            revert PositionAccountingMismatch();
        }
        position.borrowShares -= hookData.repaidShares;
        position.collateral -= hookData.seizedAssets;
        _settlementQueue.sync(borrower, position);
    }

    function _handleSettle(Id id, SettleHookData memory hookData) internal {
        address borrower = hookData.borrower;

        // Borrower position + market view, re-read from core (payload stays minimal). The core already
        // bounded the cut (seize <= raw, shares <= debt); the controller adds only its policy layer.
        PositionView memory position = _positionView(id, borrower);
        MarketView memory marketView = _marketView(id);

        // bad-debt gate: revert if the queue root (riskiest position) is bad debt. An empty queue has no root
        // (peekRoot returns address(0)), so this falls through to the eligibility gate below.
        address riskiestBorrower = _settlementQueue.peekRoot();
        if (_isBadDebt(marketView, riskiestBorrower == borrower ? position : _positionView(id, riskiestBorrower))) {
            revert SettlementRootBadDebt();
        }

        // eligibility + cut bound: only the queue root or a watermarked borrower may be cut, capped at the
        // policy slice.
        uint256 allowed = _settlementQueue.allowedSlice(marketView, borrower, position);
        if (allowed == 0) revert SettlementIneligible();
        if (hookData.debtCanceled > allowed) revert SettlementExceedsAllowed();

        // payload consistency (core already enforces these; cheap to re-check on the trusted values, no reads)
        uint256 sharesToBurn =
            hookData.debtCanceled.toSharesUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        if (sharesToBurn > position.borrowShares) revert SettlementExceedsDebt();
        if (hookData.collateralSeized == 0 || hookData.collateralSeized > position.collateral) {
            revert SettlementInvalidSeize();
        }

        // settle activation, then debit buckets by the exact amount core seizes from raw (lockstep).
        // A freeze or ban defers maturation, seizure still reaches all collateral via debit.
        _activation.syncActivation(_isFrozen, borrower, _guardianSignals.getOpinion(_MARKET_ID, borrower));

        _activation.debit(borrower, hookData.collateralSeized, 0);

        position.borrowShares -= sharesToBurn;
        position.collateral -= hookData.collateralSeized;
        _settlementQueue.sync(borrower, position);
    }

    // ---
    // INTERNAL HELPERS
    // ---

    /// @dev Max loan assets `collateral` can back at the market LLTV.
    function _getMaxBorrow(MarketView memory marketView, uint256 collateral) internal pure returns (uint256) {
        return collateral.mulDivDown(marketView.price, ORACLE_PRICE_SCALE).wMulDown(marketView.lltv);
    }

    /// @dev Borrower debt in loan assets from a position + market snapshot.
    function _debtAssets(MarketView memory marketView, PositionView memory position) internal pure returns (uint256) {
        if (position.borrowShares == 0) return 0;
        return position.borrowShares.toAssetsUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
    }

    /// @dev Bad debt over a position+market snapshot: debt value exceeds collateral value. Pure.
    function _isBadDebt(MarketView memory marketView, PositionView memory position) internal pure returns (bool) {
        if (position.borrowShares == 0) return false;
        if (position.collateral == 0) return true;
        uint256 debt = position.borrowShares.toAssetsUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        uint256 collateralValue = position.collateral.mulDivDown(marketView.price, ORACLE_PRICE_SCALE);
        return debt > collateralValue;
    }

    function _marketView(Id id) internal view returns (MarketView memory marketView) {
        MarketParams memory params = LIDO_LEND.idToMarketParams(id);

        marketView.lltv = params.lltv;
        marketView.price = IOracle(params.oracle).price();
        // supply and borrow totals with pending interest simulated, so view sizing matches the hook-time
        // numbers (the core accrues before invoking hooks; with nothing pending this is the raw market read)
        (marketView.totalSupplyAssets,, marketView.totalBorrowAssets, marketView.totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(LIDO_LEND, params);
    }

    /// @dev Borrower's settle-relevant position, widened from the core `Position` (uint128 fields).
    function _positionView(Id id, address borrower) internal view returns (PositionView memory) {
        Position memory p = LIDO_LEND.position(id, borrower);
        return PositionView({borrowShares: p.borrowShares, collateral: p.collateral});
    }
}
