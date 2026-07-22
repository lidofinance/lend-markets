// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id, IMorpho, MarketParams, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {WAD} from "../libs/Constants.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUntil} from "../utils/PausableUntil.sol";
import {IGuardianSignalsView} from "../interfaces/IGuardianSignalsView.sol";
import {GuardiansOpinion} from "../types/GuardianSignalsTypes.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";
import {ILidoLendMarketConfigurator} from "../interfaces/ILidoLendMarketConfigurator.sol";
import {CollateralActivationLib} from "../libs/CollateralActivationLib.sol";
import {SettlementQueueLib} from "../libs/SettlementQueueLib.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {MarketView, PositionView, SettlementConfig} from "../types/SettlementTypes.sol";

/// @notice Lido-policy controller for a Lido Lend market: collateral activation, freeze and pause,
///         address gating, and the settlement queue. All hook policy enters through `on`.
contract LidoLendMarketController layout at erc7201("lido.lend.storage.LidoLendMarketController")
    is
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

    /// @inheritdoc ILidoLendMarketController
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @inheritdoc ILidoLendMarketController
    bytes32 public constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    /// @inheritdoc ILidoLendMarketController
    bytes32 public constant UNFREEZER_ROLE = keccak256("UNFREEZER_ROLE");
    /// @inheritdoc ILidoLendMarketController
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @inheritdoc ILidoLendMarketController
    bytes32 public constant RESUMER_ROLE = keccak256("RESUMER_ROLE");

    // ---
    // CONFIG
    // ---

    /// @inheritdoc ILidoLendMarketController
    /// @dev 10x the natural rate (`VIRTUAL_SHARES / VIRTUAL_ASSETS = 1e6`).
    uint256 public constant MAX_BORROW_SHARE_RATE = 1e7;

    // ---
    // IMMUTABLES
    // ---

    /// @dev The Morpho-fork core. The only authorized hook caller, and the source of position and market reads.
    IMorpho public immutable LIDO_LEND;

    // ---
    // STORAGE
    // ---

    /// @dev The single market this controller is bound to. Hooks for any other id revert.
    Id public marketId;
    /// @dev Ceiling on total supplied loan assets (principal plus accrued interest), enforced on the Supply
    ///      hook against the market total. 0 means no cap.
    uint256 public supplyCap;
    /// @dev When set, new borrows and debt-bearing collateral withdrawals revert and activation maturation
    ///      defers. Debt-free positions can still withdraw.
    bool public isFrozen;
    /// @dev Guardian-signal registry read on every hook to gate borrowing (ban) and scale activation (strikes).
    IGuardianSignalsView private _guardianSignals;
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
    ///      and the id must match `marketId`.
    modifier onlyControlledMarket(Id id) {
        if (msg.sender != address(LIDO_LEND)) revert Unauthorized();
        if (Id.unwrap(id) != Id.unwrap(marketId)) revert InvalidMarketId();
        _;
    }

    // ---
    // INITIALIZATION
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(IMorpho lidoLend) {
        LIDO_LEND = lidoLend;
        _disableInitializers();
    }

    /// @notice One-shot initializer: binds the market, grants roles, wires the guardian-signals registry, and
    ///         sets the activation and settlement configs.
    function initialize(
        Id marketId_,
        address admin,
        IGuardianSignalsView guardianSignals,
        CollateralActivationConfig calldata activationConfig,
        SettlementConfig calldata settlementConfig
    ) external initializer {
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        marketId = marketId_;
        _guardianSignals = guardianSignals;
        _settlementQueue.init();
        _settlementQueue.setSettlementConfig(settlementConfig);
        _activation.setConfig(activationConfig);
    }

    // ---
    // CORE HOOK INTERFACE
    // ---

    /// @notice Core hook entrypoint: dispatches each market action to its internal handler.
    /// @dev Reverts on an unknown event so any future Morpho-fork-side change without a controller update
    ///      fails closed instead of silently skipping policy.
    function on(Id id, HookEvent hookEvent, bytes calldata data) external onlyControlledMarket(id) {
        _checkResumed();

        if (hookEvent == HookEvent.Supply) {
            _handleSupply(id, abi.decode(data, (SupplyHookData)));
        } else if (hookEvent == HookEvent.SupplyCollateral) {
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
        } else if (hookEvent != HookEvent.Withdraw && hookEvent != HookEvent.AccrueInterest) {
            revert UnknownHookEvent();
        }
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
    function guardianSignals() external view returns (address) {
        return address(_guardianSignals);
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
    // SUPPLY CAP
    // ---

    /// @inheritdoc ILidoLendMarketConfigurator
    function setSupplyCap(uint256 cap) external onlyRole(MANAGER_ROLE) {
        supplyCap = cap;
        emit SupplyCapSet(cap, msg.sender);
    }

    // ---
    // LENDER LIMITS
    // ---

    /// @inheritdoc ILidoLendMarketController
    function maxDeposit() external view returns (uint256) {
        if (isPaused()) return 0;
        if (supplyCap == 0) return type(uint256).max;
        (uint256 totalSupplyAssets,,,) = _marketTotals(LIDO_LEND.idToMarketParams(marketId));
        return Math.saturatingSub(supplyCap, totalSupplyAssets);
    }

    /// @inheritdoc ILidoLendMarketController
    function maxWithdrawableAssets(address supplier) external view returns (uint256) {
        if (isPaused()) return 0;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            _marketTotals(LIDO_LEND.idToMarketParams(marketId));
        uint256 supplyAssets =
            LIDO_LEND.position(marketId, supplier).supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
        return Math.min(supplyAssets, Math.saturatingSub(totalSupplyAssets, totalBorrowAssets));
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
        Id id = marketId;
        sliceAssets = queue.settlementLtvSlice(_marketView(id), borrower, _positionView(id, borrower));
    }

    /// @inheritdoc ILidoLendMarketController
    function settlementBorrowersCount() external view returns (uint256) {
        return _settlementQueue.size();
    }

    /// @inheritdoc ILidoLendMarketController
    function hasBadDebt() external view returns (bool) {
        address top = _settlementQueue.peekRoot();
        if (top == address(0)) return false;
        Id id = marketId;
        return _isBadDebt(_marketView(id), _positionView(id, top));
    }

    /// @inheritdoc ILidoLendMarketController
    function nextSettlementBorrower()
        external
        view
        returns (address borrower, uint256 supplyShares, uint256 borrowShares, uint256 remainingBorrowShares)
    {
        borrower = _settlementQueue.peekRoot();
        Id id = marketId;
        (supplyShares, borrowShares, remainingBorrowShares) =
            _settlementQueue.settlementSlice(_marketView(id), borrower, _positionView(id, borrower));
    }

    /// @inheritdoc ILidoLendMarketController
    function settlementFor(address borrower)
        external
        view
        returns (uint256 supplyShares, uint256 borrowShares, uint256 remainingBorrowShares)
    {
        Id id = marketId;
        (supplyShares, borrowShares, remainingBorrowShares) =
            _settlementQueue.settlementSlice(_marketView(id), borrower, _positionView(id, borrower));
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
        isFrozen = true;
        emit FrozenSet(true, msg.sender);
    }

    /// @inheritdoc ILidoLendMarketController
    function unfreeze() external onlyRole(UNFREEZER_ROLE) {
        isFrozen = false;
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

    // ---
    // POSITION VIEW
    // ---

    /// @inheritdoc ILidoLendMarketController
    function positionOf(address borrower)
        external
        view
        returns (ILidoLendMarketController.BorrowerPosition memory dashboard)
    {
        Id id = marketId;
        PositionView memory position = _positionView(id, borrower);
        MarketView memory marketView = _marketView(id);
        GuardiansOpinion memory opinion = _guardianSignals.getOpinion(id, borrower);
        dashboard.banned = opinion.banned;
        dashboard.flagCount = opinion.strikeCount;
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

    /// @dev Supply hook: enforce the market supply cap on the post-deposit total. The core has already accrued
    ///      interest but not yet booked this deposit, so `totalSupplyAssets` is the post-accrue, pre-supply
    ///      figure and the incoming `assets` is added here.
    function _handleSupply(Id id, SupplyHookData memory hookData) internal view {
        uint256 cap = supplyCap;
        if (cap == 0) return;

        uint256 attempted = LIDO_LEND.market(id).totalSupplyAssets + hookData.assets;
        if (attempted > cap) revert SupplyCapExceeded(cap, attempted);
    }

    /// @dev Supply hook: settle any matured activation, book the deposit into the activation pipeline, and
    ///      re-key the settlement queue on the post-deposit position.
    function _handleSupplyCollateral(Id id, SupplyCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;

        // raw is pre-deposit: this hook runs before core's `collateral += assets`
        PositionView memory position = _positionView(id, borrower);

        // settle anything already matured, then book the deposit. A sub-threshold deposit stays dust, and only
        // once it crosses the threshold does the lot enter the activation timer. A freeze or ban defers maturation.
        _activation.sync(isFrozen, borrower, _guardianSignals.getOpinion(id, borrower));
        _activation.credit(borrower, hookData.assets, _instantActivationCallers[hookData.caller]);

        position.collateral += hookData.assets;
        _settlementQueue.sync(borrower, position);
    }

    /// @dev Withdraw hook: with open debt a freeze blocks it, and the remaining active must still cover the debt
    ///      at LLTV. Debt-free exits are free.
    function _handleWithdrawCollateral(Id id, WithdrawCollateralHookData memory hookData) internal {
        address borrower = hookData.onBehalf;

        // raw and borrowShares are pre-withdraw: this hook runs before core's `collateral -= assets`
        PositionView memory position = _positionView(id, borrower);

        // Freeze blocks withdraw only while there is open debt. A zero-debt withdraw is always allowed
        // as a non-custody exit, and a banned address may still pull its own collateral.
        if (isFrozen && position.borrowShares != 0) revert MarketIsFrozen();

        // settle activation, then drain the un-matured buckets (dust, then activating above the lock) and reverse
        // any same-tx flash addition to the inflow (the lib owns the undo); a revert below rolls this back. The
        // lib returns the post-debit inactive, so active is the post-withdraw raw minus it.
        _activation.sync(isFrozen, borrower, _guardianSignals.getOpinion(id, borrower));
        uint256 inactive = _activation.debit(borrower, hookData.assets);

        if (hookData.assets > position.collateral) revert PositionAccountingMismatch();
        position.collateral -= hookData.assets;
        uint256 activeCollateral = position.collateral - inactive;

        // With open debt, the remaining active collateral must still cover the debt at LLTV. `_getMaxBorrow`
        // returns 0 for sub-threshold dust, so a debt-bearing position cannot be drained below
        // `minActivationAmount` — to exit below it, repay the debt to zero first (a zero-debt withdraw is
        // unconstrained here).
        if (position.borrowShares != 0) {
            MarketView memory marketView = _marketView(id);
            if (_debtAssets(marketView, position) > _getMaxBorrow(marketView, activeCollateral)) {
                revert InsufficientActiveCollateral();
            }
        }

        _settlementQueue.sync(borrower, position);
    }

    /// @dev Borrow hook: blocked by a freeze or a ban on caller/receiver/borrower. Capacity uses active
    ///      (matured) collateral only.
    function _handleBorrow(Id id, BorrowHookData memory hookData) internal {
        if (isFrozen) revert MarketIsFrozen();

        // A share-anchored borrow can round its assets to zero, minting borrow shares for nothing.
        if (hookData.assets == 0) revert ZeroBorrowAssets();

        MarketView memory marketView = _marketView(id);
        uint256 postBorrowAssets = marketView.totalBorrowAssets + hookData.assets;
        uint256 postBorrowShares = marketView.totalBorrowShares + hookData.shares;
        if (_isBorrowShareRateExceeded(postBorrowAssets, postBorrowShares)) revert BorrowShareRateExceeded();

        // A banned actor cannot take on debt (onBehalf), receive the loan (receiver), or initiate the
        // borrow (caller). Soft strikes only delay activation; a ban hard-blocks the borrow.
        if (_guardianSignals.isBanned(id, hookData.caller)) revert AddressBanned();

        if (_guardianSignals.isBanned(id, hookData.receiver)) revert AddressBanned();

        GuardiansOpinion memory opinion = _guardianSignals.getOpinion(id, hookData.onBehalf);
        if (opinion.banned) revert AddressBanned();

        // Borrow capacity uses active (matured) collateral only. `sync` matures any ready lot, subject to the
        // quorum-scan gate, and returns the post-mature inactive total. Active is the raw collateral minus that.
        uint256 inactive = _activation.sync(isFrozen, hookData.onBehalf, opinion);

        PositionView memory position = _positionView(id, hookData.onBehalf);
        uint256 activeCollateral = position.collateral - inactive;

        // Capacity check: active collateral must cover the post-borrow debt at LLTV. `_getMaxBorrow` returns 0
        // when active collateral is sub-threshold dust, so a sub-floor position cannot open or grow debt — the
        // position floor is folded in here rather than a separate raw-collateral revert.
        if (_debtAssets(marketView, position) + hookData.assets > _getMaxBorrow(marketView, activeCollateral)) {
            revert InsufficientActiveCollateral();
        }

        position.borrowShares += hookData.shares;
        _settlementQueue.sync(hookData.onBehalf, position);
    }

    /// @dev Repay hook: gate the borrow-share-rate transition, then re-key the settlement queue on the post-repay
    ///      shares (the borrower drops out at zero debt).
    function _handleRepay(Id id, RepayHookData memory hookData) internal {
        (,, uint256 preAssets, uint256 preShares) = _marketTotals(LIDO_LEND.idToMarketParams(id));
        _requireBorrowRateTransition(preAssets, preShares, hookData.assets, hookData.shares);

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

        uint256 preAssets = marketView.totalBorrowAssets;
        uint256 preShares = marketView.totalBorrowShares;
        _requireBorrowRateTransition(preAssets, preShares, hookData.borrowAssetsCanceled, hookData.borrowSharesCanceled);

        // bad-debt gate: revert if the queue root (riskiest position) is bad debt. An empty queue has no root
        // (peekRoot returns address(0)), so this falls through to the eligibility gate below.
        address riskiestBorrower = _settlementQueue.peekRoot();
        if (_isBadDebt(marketView, riskiestBorrower == borrower ? position : _positionView(id, riskiestBorrower))) {
            revert SettlementBadDebt();
        }

        // Cap the cut at the policy slice, in borrow shares (a zero slice means ineligible).
        uint256 allowedShares = _settlementQueue.allowedSlice(marketView, borrower, position)
            .toSharesUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        if (hookData.borrowSharesCanceled > allowedShares) revert SettlementExceedsAllowed();

        // The core enforces payload consistency before this hook — shares <= debt and 0 < seize <= collateral.
        uint256 sharesToBurn = hookData.borrowSharesCanceled;

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

    /// @dev Whether the market's borrow-share rate exceeds `MAX_BORROW_SHARE_RATE` (cross-multiplied, no division).
    function _isBorrowShareRateExceeded(uint256 borrowAssets, uint256 borrowShares) internal pure returns (bool) {
        return borrowShares + SharesMathLib.VIRTUAL_SHARES
            > MAX_BORROW_SHARE_RATE * (borrowAssets + SharesMathLib.VIRTUAL_ASSETS);
    }

    /// @dev Revert only if reducing borrow totals by (`reduceAssets`, `reduceShares`) crosses the rate ceiling
    ///      from under to over; a market already over the cap is left alone so it can be cleaned up.
    function _requireBorrowRateTransition(
        uint256 preAssets,
        uint256 preShares,
        uint256 reduceAssets,
        uint256 reduceShares
    ) internal pure {
        if (_isBorrowShareRateExceeded(preAssets, preShares)) return;
        uint256 postAssets = Math.saturatingSub(preAssets, reduceAssets);
        uint256 postShares = Math.saturatingSub(preShares, reduceShares);
        if (_isBorrowShareRateExceeded(postAssets, postShares)) revert BorrowShareRateExceeded();
    }

    /// @dev Value of `collateral` units in loan assets at the market's oracle price, rounded down.
    function _collateralValue(MarketView memory marketView, uint256 collateral) internal pure returns (uint256) {
        return Math.mulDiv(collateral, marketView.price, ORACLE_PRICE_SCALE);
    }

    /// @dev Max loan assets `collateral` can back at the market LLTV. Active collateral below the activation
    ///      dust threshold (`minActivationAmount`) backs no borrow and returns 0, so a sub-threshold position has
    ///      no capacity.
    function _getMaxBorrow(MarketView memory marketView, uint256 collateral) internal view returns (uint256) {
        if (collateral < _activation.config.minActivationAmount) return 0;
        return Math.mulDiv(_collateralValue(marketView, collateral), marketView.lltv, WAD);
    }

    /// @dev Bad debt over a position+market snapshot: debt value exceeds collateral value. Pure.
    function _isBadDebt(MarketView memory marketView, PositionView memory position) internal pure returns (bool) {
        if (position.borrowShares == 0) return false;
        return _debtAssets(marketView, position) > _collateralValue(marketView, position.collateral);
    }

    /// @dev Market snapshot for sizing: LLTV, oracle price, and the accrued totals.
    function _marketView(Id id) internal view returns (MarketView memory marketView) {
        MarketParams memory params = LIDO_LEND.idToMarketParams(id);

        marketView.lltv = params.lltv;
        marketView.price = IOracle(params.oracle).price();
        (
            marketView.totalSupplyAssets,
            marketView.totalSupplyShares,
            marketView.totalBorrowAssets,
            marketView.totalBorrowShares
        ) = _marketTotals(params);
    }

    /// @dev Supply/borrow totals with pending interest simulated, so view numbers match what the core sees
    ///      at hook time. No oracle read — the lender limits built on this stay available during an oracle
    ///      outage.
    function _marketTotals(MarketParams memory params)
        internal
        view
        returns (
            uint256 totalSupplyAssets,
            uint256 totalSupplyShares,
            uint256 totalBorrowAssets,
            uint256 totalBorrowShares
        )
    {
        (totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(LIDO_LEND, params);
    }

    /// @dev Borrower's settle-relevant position, widened from the core `Position` (uint128 fields).
    function _positionView(Id id, address borrower) internal view returns (PositionView memory) {
        Position memory p = LIDO_LEND.position(id, borrower);
        return PositionView({borrowShares: p.borrowShares, collateral: p.collateral});
    }
}
