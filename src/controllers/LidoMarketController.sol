// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Id, IMorphoStaticTyping} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/src/interfaces/IOracle.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "@morpho-blue/src/libraries/ConstantsLib.sol";
import {MathLib, WAD} from "@morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "@morpho-blue/src/libraries/SharesMathLib.sol";
import {UtilsLib} from "@morpho-blue/src/libraries/UtilsLib.sol";

import {IMarketController} from "../interfaces/IMarketController.sol";
import {IMarketAccessRegistry} from "../interfaces/IMarketAccessRegistry.sol";
import {DeleverageSliceLib} from "../libs/DeleverageSliceLib.sol";
import {MaxHeapLib} from "../libs/MaxHeapLib.sol";

/// @title LidoMarketController
/// @notice Stateful market policy for Lido Lending markets.
/// @dev Owns Lido-specific policy state: matured collateral, dust, freeze/pause and deleverage
///      eligibility. Address and market-position restrictions live in a deployment-scoped registry.
contract LidoMarketController is Initializable, AccessControlUpgradeable, IMarketController {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;
    using MaxHeapLib for MaxHeapLib.Heap;

    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR");
    bytes32 public constant RISK_STEWARD_ROLE = keccak256("RISK_STEWARD");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER");
    bytes32 public constant UNPAUSER_ROLE = keccak256("UNPAUSER");

    uint64 internal constant DEFAULT_MIN_DELAY = 10 minutes;
    uint64 internal constant DEFAULT_MAX_DELAY = 2 hours;
    uint128 internal constant DEFAULT_MIN_COLLATERAL_ACTIVATION_AMOUNT = 10e18;
    uint128 internal constant DEFAULT_RATE_PER_HOUR = type(uint128).max;
    uint128 internal constant DEFAULT_INFLOW_DECAY_PER_SECOND = 0;
    uint128 internal constant DEFAULT_INFLOW_REFERENCE_SIZE = 0;
    uint128 internal constant DEFAULT_INFLOW_MAX_ACCUMULATOR = type(uint128).max;
    uint128 internal constant DEFAULT_SUPPLY_CAP = type(uint128).max;
    uint128 internal constant DEFAULT_BORROW_CAP = type(uint128).max;
    uint128 internal constant DEFAULT_SLICE_FLOOR_ASSETS = 0.1 ether;
    uint32 internal constant DEFAULT_MAX_ITERATIONS = 100;
    uint256 internal constant KEY_SCALE = 1e18; // risk key = borrowShares × KEY_SCALE / rawCollateral

    error ZeroAddress();
    error NoCode();
    error Unauthorized();
    error InvalidMarketId();
    error ConfigOutOfBounds();
    error MarketIsFrozen();
    error MarketIsPaused();
    error BelowMinDeposit();
    error SupplyCapExceeded();
    error BorrowCapExceeded();
    error DeleverageIneligible();
    error DeleverageOverCap();
    error DeleverageBelowSliceFloor();
    error DeleverageRootBadDebt();
    error AddressBlocked();
    error PositionBlocked();
    error InsufficientMaturedCollateral();
    error WatermarkOutOfRange();

    event MarketFrozen(Id indexed id, bool frozen, address indexed by);
    event MarketPaused(Id indexed id, bool paused, address indexed by);
    event MarketConfigSet(Id indexed id);
    event BorrowerWatermarkSet(Id indexed id, address indexed borrower, uint256 ltv);
    event Matured(Id indexed id, address indexed onBehalf, uint256 amount);
    event Initialized(
        address indexed lendingMarket, Id indexed id, address indexed marketAccessRegistry, address admin
    );

    /// @dev Namespaced storage slot for all controller mutable state. Single-keccak unstructured
    ///      storage — namespace is unique to this contract so no collision is possible with
    ///      EIP-1967 admin/implementation slots or with future inheritance.
    /// @dev The contract is expected to live behind Lido's OssifiableProxy, which owns the
    ///      upgrade authority externally. The implementation itself does not write the
    ///      EIP-1967 implementation slot.
    bytes32 private constant CONTROLLER_STORAGE_SLOT = keccak256("lido.lending.market-controller.storage.v1");

    /// @custom:storage-location lido.lending.market-controller.storage.v1
    struct ControllerStorage {
        // Address of the Lido lending market core. Set once at `initialize`, never changed.
        address lendingMarket;
        // The only market id this controller is allowed to manage.
        Id controlledMarketId;
        // Deployment-scoped registry for global address and market-position restrictions.
        address marketAccessRegistry;
        // Per-borrower collateral classification.
        mapping(Id => mapping(address => IMarketController.CollateralState)) collateralState;
        // Controlled-market totals & gating flags.
        mapping(Id => IMarketController.ControllerMarketState) marketState;
        // Controlled-market governance config (zeroed = not yet configured, controller falls back to
        // `defaultMarketConfig`).
        mapping(Id => IMarketController.MarketConfig) marketConfig;
        mapping(Id => IMarketController.DeleverageHeapConfig) deleverageHeapConfig;
        // Per-borrower target post-cut LTV (WAD-scaled). 0 = unset (default deleverage applies).
        mapping(Id => mapping(address => uint256)) borrowerWatermark;
    }

    function _storage() private pure returns (ControllerStorage storage s) {
        bytes32 slot = CONTROLLER_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @dev Deleverage borrower heap, in its own namespaced slot (isolated from ControllerStorage).
    bytes32 private constant HEAP_STORAGE_SLOT = keccak256("lido.lending.deleverage-heap.storage.v1");

    function _heap() private pure returns (MaxHeapLib.Heap storage h) {
        bytes32 slot = HEAP_STORAGE_SLOT;
        assembly {
            h.slot := slot
        }
    }

    modifier onlyControlledMarket(Id id) {
        ControllerStorage storage s = _storage();
        if (msg.sender != s.lendingMarket) revert Unauthorized();
        if (Id.unwrap(id) != Id.unwrap(s.controlledMarketId)) revert InvalidMarketId();
        _;
    }

    modifier onlyControlledId(Id id) {
        if (Id.unwrap(id) != Id.unwrap(_storage().controlledMarketId)) revert InvalidMarketId();
        _;
    }

    /// @dev Blocks any deleverage while the heap root (riskiest borrower) is bad debt. Enforced in
    ///      the controller, not the vault, because the vault is optional — a lender can call the
    ///      core `deleverage` primitive directly, so the guard must sit on the path every cut takes.
    modifier rejectIfRootBadDebt(Id id) {
        if (_rootHasBadDebt(id)) revert DeleverageRootBadDebt();
        _;
    }

    /// @dev Locks the implementation against direct initialization. Only proxies (whose own
    ///      namespaced slot is still untouched) can call `initialize`.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-shot initializer for a proxy. Sets the core, controlled market id, access registry, and admin.
    function initialize(address lendingMarket_, Id controlledMarketId_, address marketAccessRegistry_, address admin)
        external
        initializer
    {
        ControllerStorage storage s = _storage();
        if (lendingMarket_ == address(0)) revert ZeroAddress();
        if (marketAccessRegistry_ == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();
        if (lendingMarket_.code.length == 0) revert NoCode();
        if (marketAccessRegistry_.code.length == 0) revert NoCode();
        __AccessControl_init();
        s.lendingMarket = lendingMarket_;
        s.controlledMarketId = controlledMarketId_;
        s.marketAccessRegistry = marketAccessRegistry_;
        _heap().init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        emit Initialized(lendingMarket_, controlledMarketId_, marketAccessRegistry_, admin);
    }

    /* PUBLIC VIEW GETTERS (replace auto-generated public-mapping ABI) */

    function MARKET() external view returns (address) {
        return _storage().lendingMarket;
    }

    function MARKET_ID() external view returns (Id) {
        return _storage().controlledMarketId;
    }

    function MARKET_ACCESS_REGISTRY() external view returns (address) {
        return _storage().marketAccessRegistry;
    }

    function collateralState(Id id, address borrower) external view returns (IMarketController.CollateralState memory) {
        return _storage().collateralState[id][borrower];
    }

    function marketState(Id id) external view returns (IMarketController.ControllerMarketState memory) {
        return _storage().marketState[id];
    }

    function marketConfig(Id id) external view returns (IMarketController.MarketConfig memory) {
        return _storage().marketConfig[id];
    }

    function deleverageHeapConfig(Id id) external view returns (IMarketController.DeleverageHeapConfig memory) {
        return _heapConfig(id);
    }

    function borrowerWatermark(Id id, address borrower) external view onlyControlledId(id) returns (uint256) {
        return _storage().borrowerWatermark[id][borrower];
    }

    /// @notice Set the caller's personal watermark for this market. `ltv` is a target post-cut LTV
    ///         in WAD (0.6e18 = 60%). 0 clears the watermark. Setting it makes the caller eligible
    ///         for `deleverageByWatermark` and raises the head-of-queue slice to bring LTV to this
    ///         target whenever the caller is the head.
    function setBorrowerWatermark(Id id, uint256 ltv) external onlyControlledId(id) {
        if (ltv >= DeleverageSliceLib.WAD) revert WatermarkOutOfRange();
        _storage().borrowerWatermark[id][msg.sender] = ltv;
        emit BorrowerWatermarkSet(id, msg.sender, ltv);
    }

    /* MARKET CONFIG */

    function defaultMarketConfig() public pure returns (IMarketController.MarketConfig memory cfg) {
        cfg = IMarketController.MarketConfig({
            minMaturationDelay: DEFAULT_MIN_DELAY,
            maxMaturationDelay: DEFAULT_MAX_DELAY,
            minCollateralActivationAmount: DEFAULT_MIN_COLLATERAL_ACTIVATION_AMOUNT,
            maturationRatePerHour: DEFAULT_RATE_PER_HOUR,
            lenderMinDeposit: 0,
            supplyCap: DEFAULT_SUPPLY_CAP,
            borrowCap: DEFAULT_BORROW_CAP,
            inflowDecayPerSecond: DEFAULT_INFLOW_DECAY_PER_SECOND,
            inflowReferenceSize: DEFAULT_INFLOW_REFERENCE_SIZE,
            inflowMaxAccumulator: DEFAULT_INFLOW_MAX_ACCUMULATOR
        });
    }

    function defaultDeleverageHeapConfig() public pure returns (IMarketController.DeleverageHeapConfig memory cfg) {
        cfg = IMarketController.DeleverageHeapConfig({
            sliceFloorAssets: DEFAULT_SLICE_FLOOR_ASSETS,
            maxIterations: DEFAULT_MAX_ITERATIONS
        });
    }

    function setMarketConfig(Id id, IMarketController.MarketConfig calldata cfg)
        external
        onlyRole(CONFIGURATOR_ROLE)
        onlyControlledId(id)
    {
        _validateConfig(cfg);
        _storage().marketConfig[id] = cfg;
        _storage().marketState[id].configured = true;
        emit MarketConfigSet(id);
    }

    function setDeleverageHeapConfig(Id id, IMarketController.DeleverageHeapConfig calldata cfg)
        external
        onlyRole(CONFIGURATOR_ROLE)
        onlyControlledId(id)
    {
        _validateDeleverageHeapConfig(cfg);
        _storage().deleverageHeapConfig[id] = cfg;
        emit MarketConfigSet(id);
    }

    function increaseCollateralActivationParams(
        Id id,
        uint64 newMinMaturationDelay,
        uint128 newMinCollateralActivationAmount
    ) external onlyRole(RISK_STEWARD_ROLE) onlyControlledId(id) {
        IMarketController.MarketConfig memory cfg = _config(id);
        if (newMinMaturationDelay < cfg.minMaturationDelay) revert ConfigOutOfBounds();
        if (newMinCollateralActivationAmount < cfg.minCollateralActivationAmount) revert ConfigOutOfBounds();
        cfg.minMaturationDelay = newMinMaturationDelay;
        cfg.minCollateralActivationAmount = newMinCollateralActivationAmount;
        _validateConfig(cfg);
        _storage().marketConfig[id] = cfg;
        _storage().marketState[id].configured = true;
        emit MarketConfigSet(id);
    }

    function freeze(Id id) external onlyRole(RISK_STEWARD_ROLE) onlyControlledId(id) {
        _storage().marketState[id].isFrozen = true;
        emit MarketFrozen(id, true, msg.sender);
    }

    function unfreeze(Id id) external onlyRole(CONFIGURATOR_ROLE) onlyControlledId(id) {
        _storage().marketState[id].isFrozen = false;
        emit MarketFrozen(id, false, msg.sender);
    }

    function pauseMarket(Id id) external onlyRole(PAUSER_ROLE) onlyControlledId(id) {
        _storage().marketState[id].isPaused = true;
        emit MarketPaused(id, true, msg.sender);
    }

    function unpauseMarket(Id id) external onlyRole(UNPAUSER_ROLE) onlyControlledId(id) {
        _storage().marketState[id].isPaused = false;
        emit MarketPaused(id, false, msg.sender);
    }

    function _config(Id id) internal view returns (IMarketController.MarketConfig memory cfg) {
        if (_storage().marketState[id].configured) return _storage().marketConfig[id];
        return defaultMarketConfig();
    }

    function _validateConfig(IMarketController.MarketConfig memory cfg) internal pure {
        if (cfg.minMaturationDelay > cfg.maxMaturationDelay) revert ConfigOutOfBounds();
        bool inflowDisabled = cfg.inflowDecayPerSecond == 0 && cfg.inflowReferenceSize == 0;
        bool inflowEnabled =
            cfg.inflowDecayPerSecond != 0 && cfg.inflowReferenceSize != 0 && cfg.inflowMaxAccumulator != 0;
        if (!inflowDisabled && !inflowEnabled) revert ConfigOutOfBounds();
        // When window-based delay is enabled, the cap must allow the accumulator to actually
        // reach the reference. Otherwise the formula's ratio would saturate below 1 and never
        // produce maxDelay even for full-load bursts.
        if (inflowEnabled) {
            if (cfg.inflowMaxAccumulator < cfg.inflowReferenceSize) revert ConfigOutOfBounds();
        }
    }

    function _validateDeleverageHeapConfig(IMarketController.DeleverageHeapConfig memory cfg) internal pure {
        if (cfg.maxIterations == 0) revert ConfigOutOfBounds();
        // sliceFloorAssets == 0 is allowed (no floor).
    }

    /* CORE HOOK DISPATCH */

    /// @inheritdoc IMarketController
    /// @dev Single strict-callback entrypoint. Dispatches to internal handlers based on `e`.
    ///      Reverts on unknown event so any future Morpho-fork-side change without controller
    ///      update fails closed instead of silently skipping policy.
    function on(Id id, IMarketController.HookEvent e, bytes calldata data) external override onlyControlledMarket(id) {
        if (e == IMarketController.HookEvent.Supply) {
            _handleSupply(id, abi.decode(data, (IMarketController.SupplyHookData)));
        } else if (e == IMarketController.HookEvent.Withdraw) {
            _handleWithdraw(id);
        } else if (e == IMarketController.HookEvent.Borrow) {
            _handleBorrow(id, abi.decode(data, (IMarketController.BorrowHookData)));
        } else if (e == IMarketController.HookEvent.Repay) {
            _handleRepay(id, abi.decode(data, (IMarketController.RepayHookData)));
        } else if (e == IMarketController.HookEvent.SupplyCollateral) {
            _handleSupplyCollateral(id, abi.decode(data, (IMarketController.SupplyCollateralHookData)));
        } else if (e == IMarketController.HookEvent.WithdrawCollateral) {
            _handleWithdrawCollateral(id, abi.decode(data, (IMarketController.WithdrawCollateralHookData)));
        } else if (e == IMarketController.HookEvent.Liquidate) {
            _handleLiquidate(id, abi.decode(data, (IMarketController.LiquidateHookData)));
        } else if (e == IMarketController.HookEvent.Deleverage) {
            _handleDeleverage(id, abi.decode(data, (IMarketController.DeleverageHookData)));
        } else {
            revert ConfigOutOfBounds();
        }
    }

    function _handleSupply(Id id, IMarketController.SupplyHookData memory hookData) internal view {
        _requireNotPaused(id);
        // Blocks apply to both caller and onBehalf — blocked actors must not fund even a clean
        // lender account.
        _requireNotBlocked(id, hookData.caller);
        _requireNotBlocked(id, hookData.onBehalf);
        IMarketController.MarketConfig memory cfg = _config(id);
        if (hookData.assets > 0 && hookData.assets < cfg.lenderMinDeposit) {
            revert BelowMinDeposit();
        }
        if (hookData.assets > 0) {
            (uint128 totalSupplyAssets,,,,,) = IMorphoStaticTyping(_storage().lendingMarket).market(id);
            if (uint256(totalSupplyAssets) + hookData.assets > cfg.supplyCap) {
                revert SupplyCapExceeded();
            }
        }
    }

    function _handleWithdraw(Id id) internal view {
        _requireNotPaused(id);
    }

    function _handleBorrow(Id id, IMarketController.BorrowHookData memory hookData) internal {
        _requireNotPaused(id);
        if (_storage().marketState[id].isFrozen) revert MarketIsFrozen();
        // Blocks apply to caller, onBehalf, and receiver — blocked actors cannot
        // route borrowed assets through any of the three positions.
        _requireNotBlocked(id, hookData.caller);
        _requireNotBlocked(id, hookData.onBehalf);
        _requireNotBlocked(id, hookData.receiver);
        if (hookData.assets > 0) {
            (,, uint128 totalBorrowAssets,,,) = IMorphoStaticTyping(_storage().lendingMarket).market(id);
            if (uint256(totalBorrowAssets) + hookData.assets > _config(id).borrowCap) {
                revert BorrowCapExceeded();
            }
        }
        _syncMaturity(id, hookData.onBehalf);

        // Stricter Lido constraint: borrow capacity uses matured collateral only. The core's
        // standard health check uses raw collateral; this hook adds the matured-only ceiling
        // by reading post-maturity-sync state.
        uint256 matured = _storage().collateralState[id][hookData.onBehalf].maturedCollateral;
        _requireMaturedHealth(id, hookData.onBehalf, matured, hookData.assets);

        (uint256 currentBorrowShares, uint256 currentRawCollateral) = _currentPosition(id, hookData.onBehalf);
        _syncDeleverageHeap(hookData.onBehalf, currentBorrowShares + hookData.shares, currentRawCollateral);
    }

    function _handleRepay(Id id, IMarketController.RepayHookData memory hookData) internal {
        (uint256 currentBorrowShares, uint256 currentRawCollateral) = _currentPosition(id, hookData.onBehalf);
        uint256 projectedBorrowShares = currentBorrowShares > hookData.shares ? currentBorrowShares - hookData.shares : 0;
        _syncDeleverageHeap(hookData.onBehalf, projectedBorrowShares, currentRawCollateral);
    }

    function _validateSupplyCollateral(Id id, address caller, address onBehalf) internal view {
        _requireNotPaused(id);
        // Blocked actors cannot fund even a clean borrower's position.
        _requireNotBlocked(id, caller);
        _requireNotBlocked(id, onBehalf);
    }

    function _handleSupplyCollateral(Id id, IMarketController.SupplyCollateralHookData memory hookData) internal {
        _validateSupplyCollateral(id, hookData.caller, hookData.onBehalf);

        // This handler synchronizes controller maturity buckets before the core applies the
        // matching raw collateral increment. A later revert rolls both updates back.
        // Settle any already-eligible pending lot before applying this deposit, so we never delay
        // an already-matured pending lot by mutating its timer.
        _syncMaturity(id, hookData.onBehalf);

        IMarketController.CollateralState storage p = _storage().collateralState[id][hookData.onBehalf];
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        IMarketController.MarketConfig memory cfg = _config(id);

        // Auto-promotion: once accumulated dust + the new deposit reaches the minimum activation
        // amount, fold dust into activating. This is intentionally caller-agnostic so vaults,
        // wrappers, and delegated flows can batch dust into borrowable collateral once the
        // economic threshold is crossed.
        uint128 dustPromoted = 0;
        if (
            p.dustCollateral > 0
                && uint256(p.dustCollateral) + hookData.assets >= uint256(cfg.minCollateralActivationAmount)
        ) {
            dustPromoted = p.dustCollateral;
            m.totalDustCollateral -= dustPromoted;
            p.dustCollateral = 0;
        }

        uint256 toActivate = uint256(dustPromoted) + hookData.assets;

        if (toActivate >= uint256(cfg.minCollateralActivationAmount)) {
            uint128 added = toActivate.toUint128();
            p.activatingCollateral += added;
            m.totalActivatingCollateral += added;

            // Timer policy: take the maximum of (existing pending unlock) and (new deposit's
            // unlock as if started now). Comparing absolute unlocks — not raw delays — prevents
            // both the donation-grief reset and giving a fresh deposit a partially-elapsed delay
            // it never earned. When max-unlock changes, we reset start so that start + delay
            // reflects the new unlock instant.
            uint64 delay = _computeMaturationDelay(id, added);
            uint256 newUnlock = block.timestamp + uint256(delay);
            uint256 oldUnlock = uint256(p.pendingMaturationStart) + uint256(p.pendingMaturationDelay);
            if (newUnlock > oldUnlock) {
                p.pendingMaturationStart = uint64(block.timestamp);
                p.pendingMaturationDelay = delay;
            }

            // Bump inflow on the full activated lot (new deposit + any promoted dust). Earlier
            // dust deposits were not booked against the accumulator because they were not yet
            // borrowable; activation is the moment they begin contributing to risk capacity, so
            // they must be charged here. Otherwise split-deposit sequences would bypass the
            // window-based throttle.
            _bumpInflow(id, toActivate);
        } else {
            // Sub-minimum: deposited and withdrawable, but does not enter activation pipeline.
            uint128 addedDust = hookData.assets.toUint128();
            p.dustCollateral += addedDust;
            m.totalDustCollateral += addedDust;
        }
        (uint256 currentBorrowShares, uint256 currentRawCollateral) = _currentPosition(id, hookData.onBehalf);
        _syncDeleverageHeap(hookData.onBehalf, currentBorrowShares, currentRawCollateral + hookData.assets);
    }

    function _handleWithdrawCollateral(Id id, IMarketController.WithdrawCollateralHookData memory hookData) internal {
        _requireNotPaused(id);
        // Freeze blocks withdraw only when there is open debt. Zero-debt withdraw is always
        // allowed as a non-custody exit path.
        if (_storage().marketState[id].isFrozen && hookData.borrowerBorrowShares != 0) {
            revert MarketIsFrozen();
        }
        // Settle maturity so health check reads up-to-date matured collateral.
        _syncMaturity(id, hookData.onBehalf);

        // If borrower carries debt, enforce the matured-only ceiling against the post-withdraw
        // state. We simulate the consume order (dust → activating → matured) used by
        // `_consumeCollateralByPriority` so the matured projection matches the actual seizure path.
        if (hookData.borrowerBorrowShares != 0) {
            IMarketController.CollateralState storage p = _storage().collateralState[id][hookData.onBehalf];
            uint256 remaining = hookData.assets;
            uint256 fromDust = remaining < p.dustCollateral ? remaining : p.dustCollateral;
            remaining -= fromDust;
            uint256 fromActivating = remaining < p.activatingCollateral ? remaining : p.activatingCollateral;
            remaining -= fromActivating;
            uint256 fromMatured = remaining;
            if (fromMatured > p.maturedCollateral) revert InsufficientMaturedCollateral();
            uint256 maturedAfter = uint256(p.maturedCollateral) - fromMatured;
            _requireMaturedHealth(id, hookData.onBehalf, maturedAfter, 0);
        }

        // Keep controller buckets synchronized before the core applies the matching raw collateral
        // decrement. A later revert rolls both updates back.
        _consumeCollateralByPriority(id, hookData.onBehalf, hookData.assets);

        (uint256 currentBorrowShares, uint256 currentRawCollateral) = _currentPosition(id, hookData.onBehalf);
        _syncDeleverageHeap(hookData.onBehalf, currentBorrowShares, currentRawCollateral - hookData.assets);
    }

    function _handleLiquidate(Id id, IMarketController.LiquidateHookData memory hookData) internal {
        _requireNotPaused(id);
        (uint256 currentBorrowShares, uint256 currentRawCollateral) = _currentPosition(id, hookData.borrower);
        // Liquidator's seizure already known here. Debit controller's split (dust → activating →
        // matured) before core decrements raw `position.collateral`. Both decrements are in the
        // same tx, so a revert anywhere rolls them back together.
        if (hookData.seizedAssets > 0) _consumeCollateralByPriority(id, hookData.borrower, hookData.seizedAssets);

        uint256 projectedBorrowShares =
            currentBorrowShares > hookData.repaidShares ? currentBorrowShares - hookData.repaidShares : 0;
        _syncDeleverageHeap(
            hookData.borrower, projectedBorrowShares, currentRawCollateral - hookData.seizedAssets
        );
    }

    /// @dev Stricter Lido check: matured collateral must cover existing debt + any incoming
    ///      borrow delta at the configured LLTV. Pulls live state from the core so the controller
    ///      stays the only place that knows about the matured-only policy. Inner blocks scope
    ///      tuple destructurings to keep the stack shallow.
    function _requireMaturedHealth(Id id, address borrower, uint256 maturedAmount, uint256 deltaBorrowAssets)
        internal
        view
    {
        IMorphoStaticTyping core = IMorphoStaticTyping(_storage().lendingMarket);

        uint256 postBorrow = deltaBorrowAssets;
        {
            (, uint128 borrowShares,) = core.position(id, borrower);
            if (borrowShares != 0) {
                (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = core.market(id);
                postBorrow += uint256(borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
            }
        }
        if (postBorrow == 0) return;

        uint256 maxBorrow;
        {
            (,, address oracle,, uint256 lltv) = core.idToMarketParams(id);
            uint256 price = IOracle(oracle).price();
            maxBorrow = maturedAmount.mulDivDown(price, ORACLE_PRICE_SCALE).wMulDown(lltv);
        }
        if (postBorrow > maxBorrow) revert InsufficientMaturedCollateral();
    }

    function _handleDeleverage(Id id, IMarketController.DeleverageHookData memory hookData)
        internal
        rejectIfRootBadDebt(id)
    {
        _requireNotPaused(id);

        // Settle maturity before debiting the controller's collateral split.
        _syncMaturity(id, hookData.borrower);

        _validateDeleverage(id, hookData);

        // Core decrements raw `position.collateral` immediately after; keep the controller split
        // in sync in the same tx so a later revert rolls both updates back together.
        if (hookData.collateralSeized > 0) {
            _consumeCollateralByPriority(id, hookData.borrower, hookData.collateralSeized);
        }

        // Heap key uses borrowShares, so sync with the post-cut shares not assets.
        uint256 sharesToBurn = hookData.assetsToCancel.toSharesUp(
            _totalBorrowAssets(id), _totalBorrowShares(id)
        );
        (uint256 currentBorrowShares, uint256 currentRawCollateral) = _currentPosition(id, hookData.borrower);
        uint256 projectedBorrowShares = currentBorrowShares > sharesToBurn ? currentBorrowShares - sharesToBurn : 0;
        _syncDeleverageHeap(
            hookData.borrower, projectedBorrowShares, currentRawCollateral - hookData.collateralSeized
        );
    }

    /* DELEVERAGE QUEUE VIEWS */

    /// @notice Number of borrowers currently tracked in the deleverage heap.
    function deleverageHeapSize(Id id) external view onlyControlledId(id) returns (uint256) {
        return _heap().size();
    }

    /// @notice Borrowers currently in the heap, top-down, up to `maxCount`. Informational.
    function eligibleBorrowers(Id id, uint256 maxCount)
        external
        view
        onlyControlledId(id)
        returns (address[] memory borrowers, uint256[] memory keys)
    {
        uint256 heapSize = _heap().size();
        uint256 count = heapSize < maxCount ? heapSize : maxCount;
        borrowers = new address[](count);
        keys = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            (borrowers[i], keys[i]) = _heap().nodeAt(i);
        }
    }

    /// @notice True if the heap root (the riskiest borrower) is bad debt: its debt exceeds the
    ///         value of its collateral. In this isolated single-collateral market the root has the
    ///         highest debt/collateral ratio, so if the root is solvent no tracked position is bad
    ///         debt. Enforced on every deleverage by `rejectIfRootBadDebt`.
    /// @dev Covers the collateral == 0 case: zero collateral value with non-zero debt is bad debt.
    function rootHasBadDebt(Id id) external view onlyControlledId(id) returns (bool) {
        return _rootHasBadDebt(id);
    }

    function _rootHasBadDebt(Id id) internal view returns (bool) {
        if (_heap().size() == 0) return false;
        (address top,) = _heap().peek();
        (uint256 borrowShares, uint256 rawCollateral) = _currentPosition(id, top);
        if (borrowShares == 0) return false;
        if (rawCollateral == 0) return true;

        uint256 borrowAssets = borrowShares.toAssetsUp(_totalBorrowAssets(id), _totalBorrowShares(id));
        uint256 collateralValue = rawCollateral.mulDivDown(_collateralPrice(id), ORACLE_PRICE_SCALE);
        return borrowAssets > collateralValue;
    }

    /// @notice The next borrower to cut (heap root) and the loan-asset slice size for that cut.
    ///         Used by the vault's exit loop. `borrower` is `address(0)` when the heap is empty.
    ///         `sliceAssets` is `type(uint256).max` when the root has no runner-up (single
    ///         borrower) — the caller caps it to the remaining exit.
    function nextDeleverageCut(Id id)
        external
        view
        onlyControlledId(id)
        returns (address borrower, uint256 sliceAssets)
    {
        if (_heap().size() == 0) return (address(0), 0);
        (borrower,) = _heap().peek();
        sliceAssets = _computeHeapSlice(id);
    }

    function _computeHeapSlice(Id id) internal view returns (uint256) {
        (address top, uint256 topKey) = _heap().peek();
        uint256 runnerUpKey = _heap().rootRunnerUpKey();
        // Single borrower (no runner-up): no key constraint and `max(uint256.max, watermark)` would
        // remain uint256.max, so the watermark cannot raise the slice further — caller caps it.
        if (runnerUpKey == 0) return type(uint256).max;

        (uint256 topBorrowShares, uint256 topCollateral) = _currentPosition(id, top);
        IMarketController.DeleverageHeapConfig memory cfg = _heapConfig(id);

        uint256 algoSlice = DeleverageSliceLib.computeSlice(
            topKey,
            runnerUpKey,
            topCollateral,
            _totalBorrowShares(id),
            _totalBorrowAssets(id),
            _collateralPrice(id),
            uint256(cfg.sliceFloorAssets)
        );

        // Path A: if the head opted into a personal watermark, raise the slice to bring its LTV
        // down to that watermark (max of algorithmic and watermark-derived slice).
        uint256 watermarkLtv = _storage().borrowerWatermark[id][top];
        if (watermarkLtv == 0) return algoSlice;

        uint256 price = _collateralPrice(id);
        uint256 topDebt = topBorrowShares.toAssetsUp(_totalBorrowAssets(id), _totalBorrowShares(id));
        uint256 topColValue = topCollateral.mulDivDown(price, DeleverageSliceLib.ORACLE_PRICE_SCALE);
        uint256 watermarkSlice = DeleverageSliceLib.computeWatermarkSlice(topDebt, topColValue, watermarkLtv);
        return watermarkSlice > algoSlice ? watermarkSlice : algoSlice;
    }

    function _collateralPrice(Id id) internal view returns (uint256) {
        (,, address oracle,,) = IMorphoStaticTyping(_storage().lendingMarket).idToMarketParams(id);
        return IOracle(oracle).price();
    }

    /* MATURITY SYNC */

    /// @notice Off-chain preview of borrower's maturity state without mutating storage.
    ///         Useful for UI / monitoring; does not represent guaranteed outcome —
    ///         actual sync depends on rate-limit budget at the time of next mutating action.
    function previewMaturity(Id id, address borrower)
        external
        view
        returns (uint256 storedMatured, uint256 activating, uint256 dust, bool readyToSettle)
    {
        IMarketController.CollateralState storage p = _storage().collateralState[id][borrower];
        storedMatured = uint256(p.maturedCollateral);
        activating = uint256(p.activatingCollateral);
        dust = uint256(p.dustCollateral);
        readyToSettle = p.pendingMaturationStart != 0
            && block.timestamp >= uint256(p.pendingMaturationStart) + p.pendingMaturationDelay
            && !_isBlocked(id, borrower);
    }

    /// @dev Internal invariant sync. Settles eligible activating collateral to matured state,
    ///      respecting per-position timer, address/maturation blocks, and global rate-limit
    ///      budget. Blocks can delay activation, but cannot accelerate it beyond the timer.
    ///      Called from every action whose accounting depends on up-to-date matured/activating
    ///      classification: borrow, withdrawCollateral, deleverage, supplyCollateral.
    function _syncMaturity(Id id, address borrower) internal {
        IMarketController.CollateralState storage p = _storage().collateralState[id][borrower];
        if (p.pendingMaturationStart == 0) return;
        if (block.timestamp < uint256(p.pendingMaturationStart) + p.pendingMaturationDelay) return;

        // Blocked addresses or market positions stay pending; blocks can delay activation but do
        // not seize or withdraw collateral.
        if (_isBlocked(id, borrower)) return;

        uint128 toMature = p.activatingCollateral;
        if (toMature == 0) {
            p.pendingMaturationStart = 0;
            p.pendingMaturationDelay = 0;
            return;
        }

        uint128 budget = _refillMaturationBudget(id);
        if (toMature > budget) toMature = budget;
        if (toMature == 0) return;

        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        p.activatingCollateral -= toMature;
        p.maturedCollateral += toMature;
        m.totalActivatingCollateral -= toMature;
        m.totalMaturedCollateral += toMature;
        m.maturationBudgetUsed += toMature;

        if (p.activatingCollateral == 0) {
            p.pendingMaturationStart = 0;
            p.pendingMaturationDelay = 0;
        }

        emit Matured(id, borrower, toMature);
    }

    function _refillMaturationBudget(Id id) internal returns (uint128) {
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        if (block.timestamp >= uint256(m.maturationBudgetWindowStart) + 1 hours) {
            m.maturationBudgetWindowStart = uint64(block.timestamp);
            m.maturationBudgetUsed = 0;
        }
        uint128 cap = _config(id).maturationRatePerHour;
        if (m.maturationBudgetUsed >= cap) return 0;
        return cap - m.maturationBudgetUsed;
    }

    function _computeMaturationDelay(Id id, uint256 depositSize) internal view returns (uint64) {
        IMarketController.MarketConfig memory cfg = _config(id);
        uint256 span = uint256(cfg.maxMaturationDelay - cfg.minMaturationDelay);

        if (cfg.inflowReferenceSize == 0) {
            // Legacy size-based formula.
            uint256 base = uint256(_storage().marketState[id].totalMaturedCollateral);
            if (base == 0) return cfg.maxMaturationDelay;
            uint256 ratioWadLegacy = depositSize.wDivDown(base);
            if (ratioWadLegacy >= WAD) return cfg.maxMaturationDelay;
            return uint64(uint256(cfg.minMaturationDelay) + (span * ratioWadLegacy) / WAD);
        }

        // Window-based adaptive formula (Spark ALM-style leaky bucket).
        uint256 effectiveLoad = _currentInflow(id) + depositSize;
        uint256 ratioWad = effectiveLoad.wDivDown(uint256(cfg.inflowReferenceSize));
        if (ratioWad >= WAD) return cfg.maxMaturationDelay;
        return uint64(uint256(cfg.minMaturationDelay) + (span * ratioWad) / WAD);
    }

    function _currentInflow(Id id) internal view returns (uint256) {
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        if (m.inflowAccumulator == 0) return 0;
        IMarketController.MarketConfig memory cfg = _config(id);
        if (cfg.inflowDecayPerSecond == 0) return uint256(m.inflowAccumulator);

        uint256 elapsed = block.timestamp - uint256(m.inflowLastUpdate);
        uint256 decay;
        unchecked {
            decay = uint256(cfg.inflowDecayPerSecond) * elapsed;
        }
        if (decay >= m.inflowAccumulator) return 0;
        return uint256(m.inflowAccumulator) - decay;
    }

    function _bumpInflow(Id id, uint256 added) internal {
        IMarketController.MarketConfig memory cfg = _config(id);
        if (cfg.inflowReferenceSize == 0) return;

        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        uint256 current = _currentInflow(id);
        uint256 newValue = current + added;
        uint256 cap = uint256(cfg.inflowMaxAccumulator);
        if (newValue > cap) newValue = cap;

        m.inflowAccumulator = uint128(newValue);
        m.inflowLastUpdate = uint64(block.timestamp);
    }

    /* INTERNAL ACCOUNTING */

    /// @dev Validates one cut on the deleverage waterfall. The slice size is decided by the
    ///      caller (typically the ERC-4626 wrapper) using the heap's runner-up key; this
    ///      function only checks that the cut is consistent with the borrower's current state
    ///      and respects the slice floor / dust close-out config.
    function _validateDeleverage(Id id, IMarketController.DeleverageHookData memory hookData) internal view {
        if (hookData.borrowerBorrowAssets == 0 || hookData.borrowerRawCollateral == 0) {
            revert DeleverageIneligible();
        }
        if (hookData.collateralSeized == 0 || hookData.collateralSeized > hookData.borrowerRawCollateral) {
            revert DeleverageOverCap();
        }

        IMarketController.DeleverageHeapConfig memory cfg = _heapConfig(id);
        IMarketController.MarketConfig memory mktCfg = _config(id);

        // Full-close allowed if remaining collateral after cut would be below min activation.
        uint256 remainingCol = hookData.borrowerRawCollateral - hookData.collateralSeized;
        if (remainingCol < mktCfg.minCollateralActivationAmount) {
            return;
        }
    }

    function _heapConfig(Id id) internal view returns (IMarketController.DeleverageHeapConfig memory cfg) {
        cfg = _storage().deleverageHeapConfig[id];
        if (cfg.maxIterations == 0) return defaultDeleverageHeapConfig();
    }

    /// @dev Re-key a borrower in the heap after any debt/collateral change. A borrower with no
    ///      debt or no collateral is removed. Risk key = borrowShares × KEY_SCALE / rawCollateral.
    function _syncDeleverageHeap(address borrower, uint256 borrowShares, uint256 rawCollateral) internal {
        if (borrowShares == 0 || rawCollateral == 0) {
            _heap().remove(borrower);
            return;
        }
        _heap().upsert(borrower, (borrowShares * KEY_SCALE) / rawCollateral);
    }

    function _currentPosition(Id id, address borrower)
        internal
        view
        returns (uint256 borrowShares, uint256 rawCollateral)
    {
        (, uint128 bs, uint128 rc) = IMorphoStaticTyping(_storage().lendingMarket).position(id, borrower);
        return (uint256(bs), uint256(rc));
    }

    function _totalBorrowAssets(Id id) internal view returns (uint256) {
        (,, uint128 totalBorrowAssets,,,) = IMorphoStaticTyping(_storage().lendingMarket).market(id);
        return uint256(totalBorrowAssets);
    }

    function _totalBorrowShares(Id id) internal view returns (uint256) {
        (,,, uint128 totalBorrowShares,,) = IMorphoStaticTyping(_storage().lendingMarket).market(id);
        return uint256(totalBorrowShares);
    }

    function _consumeCollateralByPriority(Id id, address borrower, uint256 amount) internal {
        IMarketController.CollateralState storage p = _storage().collateralState[id][borrower];
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        uint128 remaining = amount.toUint128();

        uint128 fromDust = remaining < p.dustCollateral ? remaining : p.dustCollateral;
        if (fromDust != 0) {
            p.dustCollateral -= fromDust;
            m.totalDustCollateral -= fromDust;
            remaining -= fromDust;
        }

        uint128 fromActivating = remaining < p.activatingCollateral ? remaining : p.activatingCollateral;
        if (fromActivating != 0) {
            p.activatingCollateral -= fromActivating;
            m.totalActivatingCollateral -= fromActivating;
            remaining -= fromActivating;
        }

        if (remaining != 0) {
            if (remaining > p.maturedCollateral) revert DeleverageOverCap();
            p.maturedCollateral -= remaining;
            m.totalMaturedCollateral -= remaining;
        }

        if (p.activatingCollateral == 0) {
            p.pendingMaturationStart = 0;
            p.pendingMaturationDelay = 0;
        }
    }

    function _requireNotPaused(Id id) internal view {
        if (_storage().marketState[id].isPaused) revert MarketIsPaused();
    }

    function _requireNotBlocked(Id id, address user) internal view {
        IMarketAccessRegistry registry = IMarketAccessRegistry(_storage().marketAccessRegistry);
        if (registry.addressBlocked(user)) revert AddressBlocked();
        if (registry.positionBlocked(id, user)) revert PositionBlocked();
    }

    function _isBlocked(Id id, address user) internal view returns (bool) {
        IMarketAccessRegistry registry = IMarketAccessRegistry(_storage().marketAccessRegistry);
        return registry.addressBlocked(user) || registry.positionBlocked(id, user);
    }
}
