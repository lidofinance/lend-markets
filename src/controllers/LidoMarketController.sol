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
    uint128 internal constant DEFAULT_MIN_MATURATION_AMOUNT = 10e18;
    uint128 internal constant DEFAULT_MATURATION_LOAD_DECAY_PER_SECOND = 0;
    uint128 internal constant DEFAULT_MAX_DELAY_MATURATION_LOAD = 0;
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
            minMaturationAmount: DEFAULT_MIN_MATURATION_AMOUNT,
            fallbackMinRequest: 0,
            lenderMinDeposit: 0,
            supplyCap: DEFAULT_SUPPLY_CAP,
            borrowCap: DEFAULT_BORROW_CAP,
            maturationLoadDecayPerSecond: DEFAULT_MATURATION_LOAD_DECAY_PER_SECOND,
            maxDelayMaturationLoad: DEFAULT_MAX_DELAY_MATURATION_LOAD
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

    function increaseMaturationParams(Id id, uint64 newMinMaturationDelay, uint128 newMinMaturationAmount)
        external
        onlyRole(RISK_STEWARD_ROLE)
        onlyControlledId(id)
    {
        IMarketController.MarketConfig memory cfg = _config(id);
        if (newMinMaturationDelay < cfg.minMaturationDelay) revert ConfigOutOfBounds();
        if (newMinMaturationAmount < cfg.minMaturationAmount) revert ConfigOutOfBounds();
        cfg.minMaturationDelay = newMinMaturationDelay;
        cfg.minMaturationAmount = newMinMaturationAmount;
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
        // Load-scaled delay is all-or-nothing: both knobs zero (disabled, fixed maxDelay) or both
        // non-zero (enabled). The accumulator caps itself at maxDelayMaturationLoad, so there is no
        // separate cap to validate.
        bool loadScalingDisabled = cfg.maturationLoadDecayPerSecond == 0 && cfg.maxDelayMaturationLoad == 0;
        bool loadScalingEnabled = cfg.maturationLoadDecayPerSecond != 0 && cfg.maxDelayMaturationLoad != 0;
        if (!loadScalingDisabled && !loadScalingEnabled) revert ConfigOutOfBounds();
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
        _syncMaturation(id, hookData.onBehalf);

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
        _syncMaturation(id, hookData.onBehalf);

        IMarketController.CollateralState storage p = _storage().collateralState[id][hookData.onBehalf];
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        IMarketController.MarketConfig memory cfg = _config(id);

        // Auto-promotion: once accumulated dust + the new deposit reaches the minimum maturation
        // amount, fold dust into maturing. This is intentionally caller-agnostic so vaults,
        // wrappers, and delegated flows can batch dust into borrowable collateral once the
        // economic threshold is crossed.
        uint128 dustPromoted = 0;
        if (p.dustCollateral > 0 && uint256(p.dustCollateral) + hookData.assets >= uint256(cfg.minMaturationAmount)) {
            dustPromoted = p.dustCollateral;
            m.totalDustCollateral -= dustPromoted;
            p.dustCollateral = 0;
        }

        uint256 maturingAmount = uint256(dustPromoted) + hookData.assets;

        if (maturingAmount >= uint256(cfg.minMaturationAmount)) {
            uint128 added = maturingAmount.toUint128();
            p.maturingCollateral += added;
            m.totalMaturingCollateral += added;

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

            // Add maturation load for the full lot entering maturation (new deposit + any promoted
            // dust). Earlier dust deposits were not booked against the load because they were not
            // yet borrowable; entering maturation is the moment they begin contributing to risk
            // capacity, so they must be charged here. Otherwise split-deposit sequences would
            // bypass the load-scaled delay.
            _increaseMaturationLoad(id, maturingAmount);
        } else {
            // Sub-minimum: deposited and withdrawable, but does not enter the maturation pipeline.
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
        _syncMaturation(id, hookData.onBehalf);

        // If borrower carries debt, enforce the matured-only ceiling against the post-withdraw
        // state. We simulate the consume order (dust → maturing → matured) used by
        // `_consumeNonFallback` so the matured projection matches the actual seizure path.
        if (hookData.borrowerBorrowShares != 0) {
            IMarketController.CollateralState storage p = _storage().collateralState[id][hookData.onBehalf];
            uint256 remaining = hookData.assets;
            uint256 fromDust = remaining < p.dustCollateral ? remaining : p.dustCollateral;
            remaining -= fromDust;
            uint256 fromMaturing = remaining < p.maturingCollateral ? remaining : p.maturingCollateral;
            remaining -= fromMaturing;
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
        // Liquidator's seizure already known here. Debit controller's split (dust → maturing →
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
        _syncMaturation(id, hookData.borrower);

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

    /// @notice Off-chain preview of borrower's maturation state without mutating storage.
    ///         Useful for UI / monitoring. `readyToSettle` reflects whether the next mutating action
    ///         will mature the maturing lot in full (timer elapsed and borrower not blocked).
    function previewMaturation(Id id, address borrower)
        external
        view
        returns (uint256 storedMatured, uint256 maturing, uint256 dust, bool readyToSettle)
    {
        IMarketController.CollateralState storage p = _storage().collateralState[id][borrower];
        storedMatured = uint256(p.maturedCollateral);
        maturing = uint256(p.maturingCollateral);
        dust = uint256(p.dustCollateral);
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        readyToSettle = p.pendingMaturationStart != 0
            && block.timestamp >= uint256(p.pendingMaturationStart) + p.pendingMaturationDelay
            && !_isBlocked(id, borrower) && !m.isFrozen && !m.isPaused;
    }

    /// @dev Internal invariant sync. Settles eligible maturing collateral to matured state,
    ///      respecting the per-position timer, address/maturation blocks, and market freeze/pause.
    ///      Blocks and freeze/pause can delay maturation, but cannot accelerate it beyond the timer.
    ///      Called from every action whose accounting depends on up-to-date matured/maturing
    ///      classification: borrow, withdrawCollateral, fallbackExit, supplyCollateral.
    function _syncMaturation(Id id, address borrower) internal {
        IMarketController.CollateralState storage p = _storage().collateralState[id][borrower];
        if (p.pendingMaturationStart == 0) return;
        if (block.timestamp < uint256(p.pendingMaturationStart) + p.pendingMaturationDelay) return;

        // Blocked addresses or market positions stay pending; blocks can delay maturation but do
        // not seize or withdraw collateral.
        if (_isBlocked(id, borrower)) return;

        // Freeze and pause suspend maturation: an elapsed lot stays maturing until the market
        // resumes. The timer keeps running (deferral, not extension), so it matures on the next
        // sync after resume. This halts new borrow capacity without seizing collateral.
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        if (m.isFrozen || m.isPaused) return;

        uint128 toMature = p.maturingCollateral;
        if (toMature == 0) {
            p.pendingMaturationStart = 0;
            p.pendingMaturationDelay = 0;
            return;
        }

        // The maturation delay is the only throttle: once it has elapsed the whole lot matures at
        // once. There is no separate maturation rate cap to fragment or starve the transition.
        p.maturingCollateral = 0;
        p.maturedCollateral += toMature;
        m.totalMaturingCollateral -= toMature;
        m.totalMaturedCollateral += toMature;

        p.pendingMaturationStart = 0;
        p.pendingMaturationDelay = 0;

        emit Matured(id, borrower, toMature);
    }

    function _computeMaturationDelay(Id id, uint256 depositSize) internal view returns (uint64) {
        IMarketController.MarketConfig memory cfg = _config(id);

        // Leaky-bucket disabled (unconfigured market): conservative fixed maxDelay. The delay never
        // depends on live market state, so it cannot be scaled down by a large matured base.
        if (cfg.maxDelayMaturationLoad == 0) return cfg.maxMaturationDelay;

        // Load-scaled adaptive formula (Spark ALM-style leaky bucket).
        uint256 span = uint256(cfg.maxMaturationDelay - cfg.minMaturationDelay);
        uint256 effectiveLoad = _currentMaturationLoad(id) + depositSize;
        uint256 ratioWad = effectiveLoad.wDivDown(uint256(cfg.maxDelayMaturationLoad));
        if (ratioWad >= WAD) return cfg.maxMaturationDelay;
        return uint64(uint256(cfg.minMaturationDelay) + (span * ratioWad) / WAD);
    }

    function _currentMaturationLoad(Id id) internal view returns (uint256) {
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        if (m.maturationLoad == 0) return 0;
        IMarketController.MarketConfig memory cfg = _config(id);

        uint256 elapsed = block.timestamp - uint256(m.maturationLoadUpdatedAt);
        uint256 decay;
        unchecked {
            decay = uint256(cfg.maturationLoadDecayPerSecond) * elapsed;
        }
        if (decay >= m.maturationLoad) return 0;
        return uint256(m.maturationLoad) - decay;
    }

    function _increaseMaturationLoad(Id id, uint256 added) internal {
        IMarketController.MarketConfig memory cfg = _config(id);
        if (cfg.maxDelayMaturationLoad == 0) return;

        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        // Cap the accumulator at maxDelayMaturationLoad: load beyond that point already saturates
        // the delay at maxDelay, so retaining more would only make a single oversized deposit pin
        // later deposits at maxDelay for longer than the load takes to decay from this cap.
        uint256 newValue = _currentMaturationLoad(id) + added;
        uint256 cap = uint256(cfg.maxDelayMaturationLoad);
        if (newValue > cap) newValue = cap;

        m.maturationLoad = uint128(newValue);
        m.maturationLoadUpdatedAt = uint64(block.timestamp);
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
    ///      Total collateral value sums matured + maturing + dust at current price.
    ///      Borrowers with LTV strictly above the average are fallback-eligible. Lender selects
    ///      a specific eligible borrower at execution; cherry-pick within the eligible set is
    ///      accepted by this policy.
    function _eligibilityThreshold(Id id, uint256 collateralPrice) internal view returns (uint256) {
        IMarketController.ControllerMarketState storage m = _storage().marketState[id];
        uint256 totalCollateral =
            uint256(m.totalMaturedCollateral) + uint256(m.totalMaturingCollateral) + uint256(m.totalDustCollateral);
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

    /// @dev Non-fallback debit path (user withdrawal and liquidation): consumes dust then maturing
    ///      then matured. Immature collateral is withdrawable, so user withdrawals and seizures share
    ///      the same consume order.
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

        uint128 fromMaturing = remaining < p.maturingCollateral ? remaining : p.maturingCollateral;
        if (fromMaturing != 0) {
            p.maturingCollateral -= fromMaturing;
            m.totalMaturingCollateral -= fromMaturing;
            remaining -= fromMaturing;
        }

        if (remaining != 0) {
            if (remaining > p.maturedCollateral) revert FallbackOverCap();
            p.maturedCollateral -= remaining;
            m.totalMaturedCollateral -= remaining;
        }

        if (p.maturingCollateral == 0) {
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
