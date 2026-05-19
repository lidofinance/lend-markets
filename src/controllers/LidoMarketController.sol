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

/// @title LidoMarketController
/// @notice Stateful market policy for Lido Lending markets.
/// @dev Owns Lido-specific policy state: matured collateral, dust, freeze/pause and fallback
///      eligibility. Address and market-position restrictions live in a deployment-scoped registry.
contract LidoMarketController is Initializable, AccessControlUpgradeable, IMarketController {
    using MathLib for uint256;
    using SharesMathLib for uint256;
    using UtilsLib for uint256;

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
    error BelowMinFallback();
    error FallbackIneligible();
    error FallbackOverCap();
    error AddressBlocked();
    error PositionBlocked();
    error InsufficientMaturedCollateral();

    event MarketFrozen(Id indexed id, bool frozen, address indexed by);
    event MarketPaused(Id indexed id, bool paused, address indexed by);
    event MarketConfigSet(Id indexed id);
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
    }

    function _storage() private pure returns (ControllerStorage storage s) {
        bytes32 slot = CONTROLLER_STORAGE_SLOT;
        assembly {
            s.slot := slot
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

    /// @dev Locks the implementation against direct initialization. Only proxies (whose own
    ///      namespaced slot is still untouched) can call `initialize`.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-shot initializer for a proxy. Sets the core, controlled market id, registry, and admin.
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

    /* MARKET CONFIG */

    function defaultMarketConfig() public pure returns (IMarketController.MarketConfig memory cfg) {
        cfg = IMarketController.MarketConfig({
            minMaturationDelay: DEFAULT_MIN_DELAY,
            maxMaturationDelay: DEFAULT_MAX_DELAY,
            minCollateralActivationAmount: DEFAULT_MIN_COLLATERAL_ACTIVATION_AMOUNT,
            maturationRatePerHour: DEFAULT_RATE_PER_HOUR,
            fallbackMinRequest: 0,
            lenderMinDeposit: 0,
            supplyCap: DEFAULT_SUPPLY_CAP,
            borrowCap: DEFAULT_BORROW_CAP,
            inflowDecayPerSecond: DEFAULT_INFLOW_DECAY_PER_SECOND,
            inflowReferenceSize: DEFAULT_INFLOW_REFERENCE_SIZE,
            inflowMaxAccumulator: DEFAULT_INFLOW_MAX_ACCUMULATOR
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
            _handleRepay(id);
        } else if (e == IMarketController.HookEvent.SupplyCollateral) {
            _handleSupplyCollateral(id, abi.decode(data, (IMarketController.SupplyCollateralHookData)));
        } else if (e == IMarketController.HookEvent.WithdrawCollateral) {
            _handleWithdrawCollateral(id, abi.decode(data, (IMarketController.WithdrawCollateralHookData)));
        } else if (e == IMarketController.HookEvent.Liquidate) {
            _handleLiquidate(id, abi.decode(data, (IMarketController.LiquidateHookData)));
        } else if (e == IMarketController.HookEvent.FallbackExit) {
            _handleFallbackExit(id, abi.decode(data, (IMarketController.FallbackExitHookData)));
        } else if (e == IMarketController.HookEvent.AccrueInterest) {
            _handleAccrueInterest(id);
        } else {
            revert ConfigOutOfBounds();
        }
    }

    function _handleSupply(Id id, IMarketController.SupplyHookData memory hookData) internal view {
        _requireNotPaused(id);
        if (_storage().marketState[id].isFrozen) revert MarketIsFrozen();
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
    }

    function _handleRepay(Id id) internal view {
        _requireNotPaused(id);
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
        // `_consumeNonFallback` so the matured projection matches the actual seizure path.
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
        _consumeNonFallback(id, hookData.onBehalf, hookData.assets);
    }

    function _handleLiquidate(Id id, IMarketController.LiquidateHookData memory hookData) internal {
        _requireNotPaused(id);
        // Liquidator's seizure already known here. Debit controller's split (dust → activating →
        // matured) before core decrements raw `position.collateral`. Both decrements are in the
        // same tx, so a revert anywhere rolls them back together.
        if (hookData.seizedAssets > 0) _consumeNonFallback(id, hookData.borrower, hookData.seizedAssets);
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

    function _handleFallbackExit(Id id, IMarketController.FallbackExitHookData memory hookData) internal {
        _requireNotPaused(id);

        IMarketController.MarketConfig memory cfg = _config(id);
        if (hookData.assetsToCancel < cfg.fallbackMinRequest) revert BelowMinFallback();

        // Settle maturity so eligibility/cap math sees up-to-date matured collateral.
        _syncMaturity(id, hookData.borrower);

        uint256 matured = _storage().collateralState[id][hookData.borrower].maturedCollateral;
        _validateDefaultFallback(
            id,
            hookData.borrowerBorrowAssets,
            hookData.borrowerRawCollateral,
            matured,
            hookData.collateralPrice,
            hookData.collateralSeized
        );

        // Debit matured before returning. Core decrements raw `position.collateral` immediately
        // after; both updates land in the same tx, so a later revert rolls back together.
        if (hookData.collateralSeized > 0) {
            _consumeMatured(id, hookData.borrower, hookData.collateralSeized);
        }
    }

    function _handleAccrueInterest(Id id) internal view {
        _requireNotPaused(id);
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
    ///      classification: borrow, withdrawCollateral, fallbackExit, supplyCollateral.
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

    /// @dev Borrower is eligible iff LTV > marketAvgLTV. The collateral amount is computed by the
    ///      core at the oracle rate; this function only applies Lido policy.
    function _validateDefaultFallback(
        Id id,
        uint256 borrowerBorrowAssets,
        uint256 borrowerRawCollateral,
        uint256 borrowerMaturedCollateral,
        uint256 collateralPrice,
        uint256 collateralSeized
    ) internal view {
        if (borrowerBorrowAssets == 0 || borrowerRawCollateral == 0) {
            revert FallbackIneligible();
        }

        uint256 colValue = borrowerRawCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        if (colValue == 0) revert FallbackIneligible();

        uint256 ltvWad = borrowerBorrowAssets.wDivDown(colValue);
        uint256 threshold = _eligibilityThreshold(id, collateralPrice);
        if (ltvWad <= threshold) revert FallbackIneligible();

        if (collateralSeized == 0 || collateralSeized > borrowerMaturedCollateral) {
            revert FallbackOverCap();
        }

        uint256 maxSeize = _maxFallbackSeizable(borrowerBorrowAssets, borrowerRawCollateral, collateralPrice, threshold);
        if (collateralSeized > maxSeize) revert FallbackOverCap();
    }

    /// @dev Computes eligibility threshold = marketAvgLTV.
    ///      marketAvgLTV = totalBorrowAssets / totalCollateralValue.
    ///      Total collateral value sums matured + activating + dust at current price.
    ///      Borrowers with LTV strictly above the average are fallback-eligible. Lender selects
    ///      a specific eligible borrower at execution; cherry-pick within the eligible set is
    ///      accepted by this policy.
    function _eligibilityThreshold(Id id, uint256 collateralPrice) internal view returns (uint256) {
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        uint256 totalCollateral =
            uint256(m.totalMaturedCollateral) + uint256(m.totalActivatingCollateral) + uint256(m.totalDustCollateral);
        uint256 totalCollateralValue = totalCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        if (totalCollateralValue == 0) return WAD; // no collateral → no one eligible
        (,, uint128 totalBorrowAssets,,,) = IMorphoStaticTyping(_storage().lendingMarket).market(id);
        if (totalBorrowAssets == 0) return WAD; // no debt → no one eligible
        uint256 threshold = uint256(totalBorrowAssets).wDivDown(totalCollateralValue);
        // Cap at slightly below WAD so the cap formula (WAD - threshold) in _maxFallbackSeizable
        // stays positive even in catastrophic conditions where market avg LTV reaches/exceeds 1.
        if (threshold >= WAD) threshold = WAD - 1;
        return threshold;
    }

    function _maxFallbackSeizable(uint256 borrowed, uint256 rawCollateral, uint256 price, uint256 threshold)
        internal
        pure
        returns (uint256)
    {
        uint256 colValue = rawCollateral.mulDivDown(price, ORACLE_PRICE_SCALE);
        uint256 thresholdValue = colValue.wMulDown(threshold);
        if (borrowed <= thresholdValue) return 0;
        uint256 deltaValue = (borrowed - thresholdValue).wDivDown(WAD - threshold);
        return deltaValue.mulDivDown(ORACLE_PRICE_SCALE, price);
    }

    function _consumeMatured(Id id, address borrower, uint256 amount) internal {
        IMarketController.CollateralState storage p = _storage().collateralState[id][borrower];
        uint128 amt = amount.toUint128();
        if (amt > p.maturedCollateral) revert FallbackOverCap();
        p.maturedCollateral -= amt;
        _storage().marketState[id].totalMaturedCollateral -= amt;
    }

    function _consumeNonFallback(Id id, address borrower, uint256 amount) internal {
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
            if (remaining > p.maturedCollateral) revert FallbackOverCap();
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
