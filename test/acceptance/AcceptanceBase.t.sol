// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendMarketBuilder, MarketRoles, GuardianConfig} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

// --- Minimal read/write surfaces (UDVT `Id` is ABI-identical to bytes32, so bytes32 params match) ---

interface IReadController {
    function collateralActivationConfig() external view returns (CollateralActivationConfig memory);
    function settlementConfig() external view returns (SettlementConfig memory);
    function supplyCap() external view returns (uint256);
    function LIDO_LEND() external view returns (address);
    function marketId() external view returns (bytes32);
    function guardianSignals() external view returns (address);
    function isFrozen() external view returns (bool);
    function isPaused() external view returns (bool);
}

interface IReadFacade {
    function LIDO_LEND() external view returns (address);
    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement) external;
}

interface IReadRouter {
    function marketIrm(bytes32 id) external view returns (address);
    function MORPHO() external view returns (address);
    function owner() external view returns (address);
    function manager() external view returns (address);
    function setMarketIrm(MarketParams calldata marketParams, address irm) external;
}

interface IReadCurve {
    function marketCurveConfig(bytes32 id) external view returns (address);
    function owner() external view returns (address);
    function manager() external view returns (address);
    function setMarketCurveParams(MarketParams calldata marketParams, AdaptiveCurveParams calldata curveParams) external;
}

interface ICurveConfig {
    function getCurveParams() external view returns (AdaptiveCurveParams memory);
}

interface IReadBuilder {
    function FACTORY() external view returns (address);
    function LIDO_LEND_OWNER() external view returns (address);
    function IRM_ROUTER() external view returns (address);
    function CORE() external view returns (address);
    function RISK_STEWARD_DASHBOARD() external view returns (address);
}

interface IReadDashboard {
    function LIDO_LEND() external view returns (address);
}

interface IReadMorphoBook {
    function isMarketAllowed(bytes32 id) external view returns (bool);
    function MORPHO() external view returns (address);
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed) external;
}

interface IReadErc4626Book {
    function isVaultAllowed(address vault) external view returns (bool);
    function setVaultAllowed(address vault, bool allowed) external;
}

interface IReadVault {
    function LIDO_LEND() external view returns (address);
    function controller() external view returns (address);
    function marketId() external view returns (bytes32);
    function asset() external view returns (address);
}

interface IReadCore {
    function marketController(bytes32 id) external view returns (address);
    function isSettlementEnabled(bytes32 id) external view returns (bool);
    function market(bytes32 id)
        external
        view
        returns (
            uint128 tSupplyA,
            uint128 tSupplyS,
            uint128 tBorrowA,
            uint128 tBorrowS,
            uint128 lastUpdate,
            uint128 fee
        );
}

interface IReadCircuitBreaker {
    function getPauser(address pausable) external view returns (address);
    function ADMIN() external view returns (address);
    function registerPauser(address pausable, address newPauser) external;
}

/// @notice Base for the WETH/wstETH market acceptance tests. Forks the node the protocol is deployed on
///         (`ACCEPTANCE_RPC_URL` or `--fork-url`) and exposes the shared assertion + activation helpers.
///         Expected values come from the committed deploy config (`script/config/markets/<MARKET>.toml` and
///         `guardians/<MARKET>.toml`) — the single source, no hand-maintained duplicate; live addresses from
///         the deploy registry (`ACCEPTANCE_REGISTRY` → `deployed/<name>-<unix-ms>.toml`, `MARKET` selecting
///         the section). Skips cleanly without a registry or a fork.
///
/// @dev This is the repo's only verify tool — nothing parallel to it exists. It splits the checking surface
///      with `LidoLendMarketBuilder` deliberately: anything the builder's own `validateMarketContracts` /
///      `validateGuardianSignals` views can confirm is confirmed by CALLING them (`_assertBuilderValidation`),
///      not by re-implementing the same comparison here. What is left for this file: backbone cross-links the
///      builder has no notion of (`_assertWiring`), activation state (`_assertNotYetActivated` /
///      `_assertActivated`), and — the new piece — exact role-holder completeness via an event scan
///      (`_assertRoleHolderCompleteness`), which is undecidable from a single `hasRole` read and outside what
///      the builder's view functions (scoped to one build's own arguments) can ever check for a
///      previously-deployed contract's FULL role matrix.
abstract contract AcceptanceBase is Test {
    using MarketParamsLib for MarketParams;

    // role ids
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    bytes32 internal constant UNFREEZER_ROLE = keccak256("UNFREEZER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant RESUMER_ROLE = keccak256("RESUMER_ROLE");
    bytes32 internal constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    bytes32 internal constant STEWARD_ADMIN_ROLE = keccak256("STEWARD_ADMIN_ROLE");
    bytes32 internal constant ALLOWLIST_MANAGER_ROLE = keccak256("ALLOWLIST_MANAGER_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant RECOVERER_ROLE = keccak256("RECOVERER_ROLE");
    bytes32 internal constant ACCESS_RESTORER_ROLE = keccak256("ACCESS_RESTORER_ROLE");
    bytes32 internal constant ACCESS_LIMITER_ROLE = keccak256("ACCESS_LIMITER_ROLE");

    bytes32 private constant ROLE_GRANTED_SIG = keccak256("RoleGranted(bytes32,address,address)");
    bytes32 private constant ROLE_REVOKED_SIG = keccak256("RoleRevoked(bytes32,address,address)");

    // governance holders
    address internal agent;
    address internal executor;
    address internal deployer;

    // backbone
    address internal core;
    address internal facade;
    address internal router;
    address internal factory;
    address internal builder;
    address internal dashboard;
    address internal morphoBook;
    address internal erc4626Book;
    address internal circuitBreaker;

    // market
    address internal loanToken;
    address internal collateralToken;
    address internal oracle;
    address internal guardianSignals;
    address internal curve;
    address internal controller;
    address internal vault;
    uint256 internal lltv;
    bytes32 internal marketId;
    address internal pauserCommittee;

    // event-scan starting points (see `ProtocolDeployment.deployedBlock` / `MarketDeployment.deployedBlock`)
    uint256 internal protocolDeployedBlock;
    uint256 internal marketDeployedBlock;

    // expected role holders (controller); the operational roles are arrays — any number of holders each
    address internal rAdmin;
    address internal rProxyAdmin;
    address[] internal rManagers;
    address[] internal rPausers;
    address[] internal rFreezers;
    address[] internal rUnfreezers;
    address[] internal rResumers;

    address[] internal expectedGuardians;
    // `buildGuardianSignals`'s own `managers` argument — kept distinct from `rManagers` (the controller's
    // `MarketRoles.managers`) even though this deploy happens to pass the same value to both.
    address[] internal gManagers;
    address internal gProxyAdmin;
    uint256 internal expectedQuorum;
    uint256 internal expectedSuspectWindow;
    address internal expectedAccessLimiter;

    // Expected values come from the committed deploy config (single source, no hand-maintained duplicate);
    // live addresses from the deploy registry. `toml` holds the market config, whose `[market]` / `[roles]` /
    // `[activation]` / `[settlement]` / `[curve]` keys the assertions read directly.
    string internal toml; // script/config/markets/<MARKET>.toml
    string internal guardiansCfg; // script/config/guardians/<MARKET>.toml
    string internal registry; // deployed/<name>-<unix-ms>.toml via ACCEPTANCE_REGISTRY

    function setUp() public virtual {
        // Live addresses come from the deploy registry (per-run, never committed); without one there is
        // nothing to verify — skip.
        string memory regPath = vm.envOr("ACCEPTANCE_REGISTRY", string(""));
        if (bytes(regPath).length == 0 || !vm.exists(regPath)) {
            vm.skip(true, "acceptance: set ACCEPTANCE_REGISTRY to a deploy registry");
            return;
        }
        registry = vm.readFile(regPath);

        string memory rpc = vm.envOr("ACCEPTANCE_RPC_URL", string(""));
        if (bytes(rpc).length != 0) vm.createSelectFork(rpc);

        // Expected values from the committed config for this market.
        string memory market = vm.envOr("MARKET", string("weth-wsteth"));
        toml = vm.readFile(string.concat("script/config/markets/", market, ".toml"));
        guardiansCfg = vm.readFile(string.concat("script/config/guardians/", market, ".toml"));
        string memory mk = string.concat(".markets.", market, ".");

        // Governance holders + guardian committee: the committed guardians config.
        agent = _grd(".admin");
        executor = _grd(".evm_script_executor");
        deployer = _reg(".protocol.deployer");

        // Deployed addresses: the registry.
        core = _reg(".protocol.core");
        facade = _reg(".protocol.owner_facade");
        router = _reg(".protocol.irm_router");
        curve = _reg(".protocol.adaptive_curve_irm");
        factory = _reg(".protocol.factory");
        builder = _reg(".protocol.builder");
        dashboard = _reg(".protocol.risk_steward_dashboard");
        morphoBook = _reg(".exit_books.morpho");
        erc4626Book = _reg(".exit_books.erc4626");
        oracle = _reg(string.concat(mk, "oracle"));
        guardianSignals = _reg(string.concat(mk, "guardian_signals"));
        controller = _reg(string.concat(mk, "controller"));
        vault = _reg(string.concat(mk, "vault"));
        marketId = vm.parseTomlBytes32(registry, string.concat(mk, "id"));

        // Event-scan starting points: the registry's per-protocol and per-market blocks.
        protocolDeployedBlock = vm.parseTomlUint(registry, ".protocol.deployed_block");
        marketDeployedBlock = vm.parseTomlUint(registry, string.concat(mk, "deployed_block"));

        // Expected market economics + controller roles: the committed market config.
        loanToken = _addr(".market.loan_token");
        collateralToken = _addr(".market.collateral_token");
        lltv = vm.parseTomlUint(toml, ".market.lltv");

        rAdmin = _addr(".roles.admin");
        rProxyAdmin = _addr(".roles.proxy_admin");
        rManagers = vm.parseTomlAddressArray(toml, ".roles.managers");
        rFreezers = vm.parseTomlAddressArray(toml, ".roles.freezers");
        rUnfreezers = vm.parseTomlAddressArray(toml, ".roles.unfreezers");
        rResumers = vm.parseTomlAddressArray(toml, ".roles.resumers");

        // One CircuitBreaker for all markets (registry `[protocol]`); it is the controller's sole PAUSER_ROLE
        // holder. The pauser committee it registers at activation is an env-supplied input.
        circuitBreaker = _reg(".protocol.circuit_breaker");
        rPausers = new address[](1);
        rPausers[0] = circuitBreaker;
        pauserCommittee = vm.envOr("ACCEPTANCE_PAUSER_COMMITTEE", address(0));

        // Expected guardian state: the committed guardians config. The deploy grants the executor the sole
        // registry MANAGER_ROLE (see `ProtocolDeployer._buildGuardianSignals`).
        expectedGuardians = vm.parseTomlAddressArray(guardiansCfg, ".guardians");
        gProxyAdmin = _grd(".proxy_admin");
        expectedQuorum = vm.parseTomlUint(guardiansCfg, ".quorum");
        expectedSuspectWindow = vm.parseTomlUint(guardiansCfg, ".suspect_window");
        expectedAccessLimiter = vm.keyExistsToml(guardiansCfg, ".access_limiter") ? _grd(".access_limiter") : address(0);
        gManagers = new address[](1);
        gManagers[0] = executor;

        if (core.code.length == 0 || controller.code.length == 0) {
            vm.skip(true, "acceptance: run with a fork (ACCEPTANCE_RPC_URL / --fork-url) carrying this deployment");
        }
    }

    // --- shared assertions (state that must hold whether or not the market is activated) ---

    function _assertComponentsDeployed() internal view {
        address[14] memory a = [
            core,
            facade,
            router,
            factory,
            builder,
            dashboard,
            morphoBook,
            erc4626Book,
            circuitBreaker,
            oracle,
            guardianSignals,
            curve,
            controller,
            vault
        ];
        for (uint256 i; i < a.length; ++i) {
            assertGt(a[i].code.length, 0, "component missing code");
        }
    }

    function _assertWiring() internal view {
        // market identity is the hash of the params it was built with
        MarketParams memory p = _params();
        assertEq(Id.unwrap(p.id()), marketId, "marketId != hash(params)");

        // backbone cross-links
        assertEq(IReadFacade(facade).LIDO_LEND(), core, "facade.LIDO_LEND");
        assertEq(IReadRouter(router).MORPHO(), core, "router.MORPHO");
        assertEq(IReadDashboard(dashboard).LIDO_LEND(), core, "dashboard.LIDO_LEND");
        assertEq(IReadMorphoBook(morphoBook).MORPHO(), core, "morphoBook.MORPHO");

        // builder immutables — the builder has no view over its OWN immutables, so this stays here
        assertEq(IReadBuilder(builder).FACTORY(), factory, "builder.FACTORY");
        assertEq(IReadBuilder(builder).LIDO_LEND_OWNER(), facade, "builder.LIDO_LEND_OWNER");
        assertEq(IReadBuilder(builder).IRM_ROUTER(), router, "builder.IRM_ROUTER");
        assertEq(IReadBuilder(builder).CORE(), core, "builder.CORE");
        assertEq(IReadBuilder(builder).RISK_STEWARD_DASHBOARD(), dashboard, "builder.RISK_STEWARD_DASHBOARD");

        // controller/vault <-> core bindings `validateMarketContracts` has no notion of (it knows nothing about "core"
        // or "loan token"); everything else about the pair — impl codehash, proxy admins, marketId/guardian
        // bindings, listed-role-holder presence, builder/factory holding nothing — is `_assertBuilderValidation`.
        assertEq(IReadController(controller).LIDO_LEND(), core, "controller.LIDO_LEND");
        assertEq(IReadVault(vault).LIDO_LEND(), core, "vault.LIDO_LEND");
        assertEq(IReadVault(vault).asset(), loanToken, "vault.asset");
        // The curve singleton's per-market params are activation calldata, so their assert lives in
        // `_assertActivated` / `_assertNotYetActivated`, not here.
    }

    /// @notice Calls `LidoLendMarketBuilder`'s own view checks instead of re-implementing them: impl
    ///         codehashes, proxy admins, marketId/guardian bindings, every listed role holder present, and
    ///         neither the builder nor the factory holding anything. A revert here IS the test failure — no
    ///         separate assertion wraps it.
    function _assertBuilderValidation() internal view {
        LidoLendMarketBuilder b = LidoLendMarketBuilder(builder);
        b.validateMarketContracts(
            controller, vault, Id.wrap(marketId), guardianSignals, builder, _expectedMarketRoles()
        );
        b.validateGuardianSignals(guardianSignals, builder, agent, gProxyAdmin, gManagers, _expectedGuardianConfig());
    }

    function _expectedMarketRoles() internal view returns (MarketRoles memory r) {
        r.admin = rAdmin;
        r.proxyAdmin = rProxyAdmin;
        r.managers = rManagers;
        r.pausers = rPausers;
        r.freezers = rFreezers;
        r.unfreezers = rUnfreezers;
        r.resumers = rResumers;
    }

    function _expectedGuardianConfig() internal view returns (GuardianConfig memory c) {
        c.guardians = expectedGuardians;
        c.quorum = expectedQuorum;
        c.suspectWindow = expectedSuspectWindow;
        c.accessLimiter = expectedAccessLimiter;
    }

    function _assertConfig() internal view {
        CollateralActivationConfig memory c = IReadController(controller).collateralActivationConfig();
        assertEq(uint256(c.minActivationDelay), vm.parseTomlUint(toml, ".activation.min_activation_delay"), "minDelay");
        assertEq(uint256(c.maxActivationDelay), vm.parseTomlUint(toml, ".activation.max_activation_delay"), "maxDelay");
        assertEq(uint256(c.maxDelayInflow), vm.parseTomlUint(toml, ".activation.max_delay_inflow"), "maxDelayInflow");
        assertEq(
            uint256(c.activatingLockAmount), vm.parseTomlUint(toml, ".activation.activating_lock_amount"), "lockAmt"
        );
        assertEq(
            uint256(c.activatingLockDuration), vm.parseTomlUint(toml, ".activation.activating_lock_duration"), "lockDur"
        );
        assertEq(uint256(c.minActivationAmount), vm.parseTomlUint(toml, ".activation.min_activation_amount"), "minAmt");
        assertEq(
            uint256(c.maxGuardiansQuorumDelay),
            vm.parseTomlUint(toml, ".activation.max_guardians_quorum_delay"),
            "qDelay"
        );
        assertEq(uint256(c.delayPerStrike), vm.parseTomlUint(toml, ".activation.delay_per_strike"), "perStrike");
        assertEq(uint256(c.delayPerSuspect), vm.parseTomlUint(toml, ".activation.delay_per_suspect"), "perSuspect");

        SettlementConfig memory s = IReadController(controller).settlementConfig();
        assertEq(uint256(s.sliceFloorBps), vm.parseTomlUint(toml, ".settlement.slice_floor_bps"), "sliceBps");
        assertEq(uint256(s.sliceFloorAssets), vm.parseTomlUint(toml, ".settlement.slice_floor_assets"), "sliceAssets");
        assertEq(
            uint256(s.fullCutBelowCollateral),
            vm.parseTomlUint(toml, ".settlement.full_cut_below_collateral"),
            "fullCut"
        );
        assertEq(uint256(s.ltvStepBps), vm.parseTomlUint(toml, ".settlement.ltv_step_bps"), "ltvStep");
    }

    /// @dev The per-market curve params the activation motion must set on the singleton, from the
    ///      expected-state file.
    function _expectedCurveParams() internal view returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: vm.parseTomlInt(toml, ".curve.curve_steepness"),
            adjustmentSpeed: vm.parseTomlInt(toml, ".curve.adjustment_speed"),
            targetUtilization: vm.parseTomlInt(toml, ".curve.target_utilization"),
            initialRateAtTarget: vm.parseTomlInt(toml, ".curve.initial_rate_at_target"),
            minRateAtTarget: vm.parseTomlInt(toml, ".curve.min_rate_at_target"),
            maxRateAtTarget: vm.parseTomlInt(toml, ".curve.max_rate_at_target"),
            maxBorrowRate: vm.parseTomlUint(toml, ".curve.max_borrow_rate")
        });
    }

    function _assertCurveParams(AdaptiveCurveParams memory cp) internal view {
        AdaptiveCurveParams memory e = _expectedCurveParams();
        assertEq(cp.curveSteepness, e.curveSteepness, "curveSteepness");
        assertEq(cp.adjustmentSpeed, e.adjustmentSpeed, "adjustmentSpeed");
        assertEq(cp.targetUtilization, e.targetUtilization, "targetUtilization");
        assertEq(cp.initialRateAtTarget, e.initialRateAtTarget, "initialRate");
        assertEq(cp.minRateAtTarget, e.minRateAtTarget, "minRate");
        assertEq(cp.maxRateAtTarget, e.maxRateAtTarget, "maxRate");
        assertEq(cp.maxBorrowRate, e.maxBorrowRate, "maxBorrowRate");
    }

    /// @notice Everything left in the role matrix that is NOT a `LidoLendMarketBuilder`-checked
    ///         `AccessControl` role: the router/curve `Ownable`-style owner/manager (no `RoleGranted` events,
    ///         so outside `_assertRoleHolderCompleteness` too).
    function _assertRoles() internal view {
        assertEq(IReadRouter(router).owner(), agent, "router.owner=agent");
        assertEq(IReadRouter(router).manager(), executor, "router.manager=executor");
        assertEq(IReadCurve(curve).owner(), agent, "curve.owner=agent");
        assertEq(IReadCurve(curve).manager(), executor, "curve.manager=executor");
    }

    /// @dev The activation motion is run by the executor, so it must hold the CircuitBreaker admin (registerPauser).
    function _assertCircuitBreakerReadyAsPauser() internal view {
        assertEq(IReadCircuitBreaker(circuitBreaker).ADMIN(), executor, "cb.ADMIN=executor");
    }

    function _assertNotYetActivated() internal view {
        (,,,, uint128 lastUpdate,) = IReadCore(core).market(marketId);
        assertEq(uint256(lastUpdate), 0, "market already created on core");
        assertEq(IReadCore(core).marketController(marketId), address(0), "controller already bound");
        assertEq(IReadRouter(router).marketIrm(marketId), address(0), "curve already routed");
        // Per-market curve params are activation calldata on the singleton — none may exist while inert.
        assertEq(IReadCurve(curve).marketCurveConfig(marketId), address(0), "curve params already set");
        assertEq(IReadCircuitBreaker(circuitBreaker).getPauser(controller), address(0), "pauser already registered");
        assertFalse(IReadMorphoBook(morphoBook).isMarketAllowed(marketId), "market already allow-listed");
        assertFalse(IReadErc4626Book(erc4626Book).isVaultAllowed(vault), "vault already allow-listed");
    }

    function _assertActivated() internal view {
        (,,,, uint128 lastUpdate,) = IReadCore(core).market(marketId);
        assertGt(uint256(lastUpdate), 0, "market not created on core");
        assertEq(IReadCore(core).marketController(marketId), controller, "controller not bound");
        assertTrue(IReadCore(core).isSettlementEnabled(marketId), "settlement not enabled");
        assertEq(IReadRouter(router).marketIrm(marketId), curve, "curve not routed");
        // The motion set this market's curve params on the singleton.
        address cfg = IReadCurve(curve).marketCurveConfig(marketId);
        assertGt(cfg.code.length, 0, "curve config missing for market");
        _assertCurveParams(ICurveConfig(cfg).getCurveParams());
        assertEq(IReadCircuitBreaker(circuitBreaker).getPauser(controller), pauserCommittee, "pauser not registered");
        assertTrue(IReadMorphoBook(morphoBook).isMarketAllowed(marketId), "market not allow-listed");
        assertTrue(IReadErc4626Book(erc4626Book).isVaultAllowed(vault), "vault not allow-listed");
    }

    /// @dev Mirror of the `LidoLendActivateMarket` EasyTrack motion, run by the executor. The curve params
    ///      MUST be set before `createMarket` — its first `borrowRate` ping reverts on an unset config.
    function _activate() internal {
        MarketParams memory p = _params();
        vm.startPrank(executor);
        IReadCurve(curve).setMarketCurveParams(p, _expectedCurveParams());
        IReadRouter(router).setMarketIrm(p, curve);
        IReadFacade(facade).createMarket(p, controller, true);
        IReadCircuitBreaker(circuitBreaker).registerPauser(controller, pauserCommittee);
        IReadMorphoBook(morphoBook).setMarketAllowed(p, true);
        IReadErc4626Book(erc4626Book).setVaultAllowed(vault, true);
        vm.stopPrank();
    }

    function _params() internal view returns (MarketParams memory) {
        return
            MarketParams({
                loanToken: loanToken, collateralToken: collateralToken, oracle: oracle, irm: router, lltv: lltv
            });
    }

    // ---
    // EVENT-BASED ROLE-HOLDER COMPLETENESS
    // ---
    //
    // Inside a `buildMarketContracts` / `buildGuardianSignals` call, the full role-holder set is guaranteed BY
    // CONSTRUCTION: the controller/vault/registry is created in that same transaction, and the only account
    // that could have granted anything on it is the builder itself (the `DEFAULT_ADMIN_ROLE` it holds
    // transiently) — so the set is exactly what that one call granted, nothing more, nothing missing. That
    // guarantee does not survive time: once the build call returns, any `DEFAULT_ADMIN_ROLE` holder can grant
    // or revoke roles, and `AccessControl` carries no member enumeration to catch a stray change from a
    // `hasRole` read alone. This scan closes exactly that window — deploy time to now, before the market is
    // even activated — by replaying every `RoleGranted` / `RoleRevoked` log since the recorded deploy block
    // and asserting the reconstructed holder set matches the expected one exactly.

    /// @notice Applies `_assertExactRoleHolders` to every `AccessControl` contract in the deploy: the
    ///         controller and guardian registry (from the market's own deploy block) and the facade,
    ///         dashboard, and both exit books (from the protocol's deploy block, since `LidoLendMarketBuilder`
    ///         never touches them).
    function _assertRoleHolderCompleteness() internal {
        {
            bytes32[] memory roles = new bytes32[](6);
            roles[0] = DEFAULT_ADMIN_ROLE;
            roles[1] = MANAGER_ROLE;
            roles[2] = PAUSER_ROLE;
            roles[3] = FREEZER_ROLE;
            roles[4] = UNFREEZER_ROLE;
            roles[5] = RESUMER_ROLE;
            address[][] memory holders = new address[][](6);
            holders[0] = _arr1(rAdmin);
            holders[1] = _append(rManagers, dashboard);
            holders[2] = rPausers;
            holders[3] = rFreezers;
            holders[4] = rUnfreezers;
            holders[5] = rResumers;
            _assertExactRoleHolders(controller, marketDeployedBlock, roles, holders);
        }
        {
            bytes32[] memory roles = new bytes32[](4);
            roles[0] = DEFAULT_ADMIN_ROLE;
            roles[1] = MANAGER_ROLE;
            roles[2] = ACCESS_RESTORER_ROLE;
            roles[3] = ACCESS_LIMITER_ROLE;
            address[][] memory holders = new address[][](4);
            holders[0] = _arr1(agent);
            holders[1] = gManagers;
            holders[2] = gManagers;
            holders[3] = _maybeArr1(expectedAccessLimiter);
            _assertExactRoleHolders(guardianSignals, marketDeployedBlock, roles, holders);
        }
        {
            bytes32[] memory roles = new bytes32[](2);
            roles[0] = DEFAULT_ADMIN_ROLE;
            roles[1] = MARKET_CREATOR_ROLE;
            address[][] memory holders = new address[][](2);
            holders[0] = _arr1(agent);
            holders[1] = _arr1(executor);
            _assertExactRoleHolders(facade, protocolDeployedBlock, roles, holders);
        }
        {
            bytes32[] memory roles = new bytes32[](2);
            roles[0] = DEFAULT_ADMIN_ROLE;
            roles[1] = STEWARD_ADMIN_ROLE;
            address[][] memory holders = new address[][](2);
            holders[0] = _arr1(agent);
            holders[1] = _arr1(executor);
            _assertExactRoleHolders(dashboard, protocolDeployedBlock, roles, holders);
        }
        _assertExitBookRoleHolderCompleteness(morphoBook);
        _assertExitBookRoleHolderCompleteness(erc4626Book);
    }

    function _assertExitBookRoleHolderCompleteness(address book) internal {
        bytes32[] memory roles = new bytes32[](4);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = ALLOWLIST_MANAGER_ROLE;
        roles[2] = FEE_MANAGER_ROLE;
        roles[3] = RECOVERER_ROLE;
        address[][] memory holders = new address[][](4);
        holders[0] = _arr1(agent);
        holders[1] = _arr2(executor, agent);
        holders[2] = _arr1(agent);
        holders[3] = _arr1(agent);
        _assertExactRoleHolders(book, protocolDeployedBlock, roles, holders);
    }

    /// @dev For each `roles[i]`, reconstructs `target`'s current holder set from `RoleGranted` / `RoleRevoked`
    ///      logs emitted from `fromBlock` to the current block and asserts it equals `expectedHolders[i]`
    ///      exactly — no extra holder (the deployer included — its absence is a consequence of exact equality,
    ///      not a separate check), no missing one, and an empty expectation means zero holders. Requires a
    ///      real fork: `vm.eth_getLogs` has no in-memory-EVM equivalent.
    function _assertExactRoleHolders(
        address target,
        uint256 fromBlock,
        bytes32[] memory roles,
        address[][] memory expectedHolders
    ) internal {
        for (uint256 i; i < roles.length; ++i) {
            _assertExactHolders(target, fromBlock, roles[i], expectedHolders[i]);
        }
    }

    function _assertExactHolders(address target, uint256 fromBlock, bytes32 role, address[] memory expected) internal {
        address[] memory candidates = _roleTouchedAccounts(target, fromBlock, role);
        address[] memory actual = _currentHolders(target, role, candidates);

        for (uint256 i; i < expected.length; ++i) {
            assertTrue(
                _containsAddr(actual, expected[i]),
                string.concat(
                    "missing role holder on ", vm.toString(target), " ", _roleName(role), ": ", vm.toString(expected[i])
                )
            );
        }
        for (uint256 i; i < actual.length; ++i) {
            assertTrue(
                _containsAddr(expected, actual[i]),
                string.concat(
                    "unexpected role holder on ",
                    vm.toString(target),
                    " ",
                    _roleName(role),
                    ": ",
                    vm.toString(actual[i])
                )
            );
        }
    }

    /// @dev Every address that ever appeared as the `account` topic of a `RoleGranted` or `RoleRevoked` log
    ///      for `role` on `target`, deduplicated. Not the current holder set — `_currentHolders` re-checks
    ///      `hasRole` live, so log ordering never matters.
    function _roleTouchedAccounts(address target, uint256 fromBlock, bytes32 role) internal returns (address[] memory) {
        uint256 toBlock = vm.getBlockNumber();

        bytes32[] memory grantedTopics = new bytes32[](2);
        grantedTopics[0] = ROLE_GRANTED_SIG;
        grantedTopics[1] = role;
        Vm.EthGetLogs[] memory granted = vm.eth_getLogs(fromBlock, toBlock, target, grantedTopics);

        bytes32[] memory revokedTopics = new bytes32[](2);
        revokedTopics[0] = ROLE_REVOKED_SIG;
        revokedTopics[1] = role;
        Vm.EthGetLogs[] memory revoked = vm.eth_getLogs(fromBlock, toBlock, target, revokedTopics);

        address[] memory raw = new address[](granted.length + revoked.length);
        uint256 n;
        for (uint256 i; i < granted.length; ++i) {
            raw[n++] = address(uint160(uint256(granted[i].topics[2])));
        }
        for (uint256 i; i < revoked.length; ++i) {
            raw[n++] = address(uint160(uint256(revoked[i].topics[2])));
        }
        return _dedupAddr(raw);
    }

    function _currentHolders(address target, bytes32 role, address[] memory candidates)
        internal
        view
        returns (address[] memory holders)
    {
        bool[] memory keep = new bool[](candidates.length);
        uint256 n;
        for (uint256 i; i < candidates.length; ++i) {
            keep[i] = IAccessControl(target).hasRole(role, candidates[i]);
            if (keep[i]) ++n;
        }
        holders = new address[](n);
        uint256 j;
        for (uint256 i; i < candidates.length; ++i) {
            if (keep[i]) holders[j++] = candidates[i];
        }
    }

    function _roleName(bytes32 role) internal pure returns (string memory) {
        if (role == DEFAULT_ADMIN_ROLE) return "DEFAULT_ADMIN_ROLE";
        if (role == MANAGER_ROLE) return "MANAGER_ROLE";
        if (role == FREEZER_ROLE) return "FREEZER_ROLE";
        if (role == UNFREEZER_ROLE) return "UNFREEZER_ROLE";
        if (role == PAUSER_ROLE) return "PAUSER_ROLE";
        if (role == RESUMER_ROLE) return "RESUMER_ROLE";
        if (role == MARKET_CREATOR_ROLE) return "MARKET_CREATOR_ROLE";
        if (role == STEWARD_ADMIN_ROLE) return "STEWARD_ADMIN_ROLE";
        if (role == ALLOWLIST_MANAGER_ROLE) return "ALLOWLIST_MANAGER_ROLE";
        if (role == FEE_MANAGER_ROLE) return "FEE_MANAGER_ROLE";
        if (role == RECOVERER_ROLE) return "RECOVERER_ROLE";
        if (role == ACCESS_RESTORER_ROLE) return "ACCESS_RESTORER_ROLE";
        if (role == ACCESS_LIMITER_ROLE) return "ACCESS_LIMITER_ROLE";
        return vm.toString(role);
    }

    function _containsAddr(address[] memory arr, address a) internal pure returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == a) return true;
        }
        return false;
    }

    function _dedupAddr(address[] memory raw) internal pure returns (address[] memory out) {
        address[] memory tmp = new address[](raw.length);
        uint256 n;
        for (uint256 i; i < raw.length; ++i) {
            bool seen;
            for (uint256 j; j < n; ++j) {
                if (tmp[j] == raw[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) tmp[n++] = raw[i];
        }
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = tmp[i];
        }
    }

    function _arr1(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _arr2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    /// @dev Empty when `a` is zero — e.g. `ACCESS_LIMITER_ROLE`, left ungranted when the deploy config names
    ///      no committee.
    function _maybeArr1(address a) internal pure returns (address[] memory r) {
        if (a == address(0)) return r;
        r = _arr1(a);
    }

    function _append(address[] memory a, address b) internal pure returns (address[] memory r) {
        r = new address[](a.length + 1);
        for (uint256 i; i < a.length; ++i) {
            r[i] = a[i];
        }
        r[a.length] = b;
    }

    /// @dev An expected value from the market config (`toml`).
    function _addr(string memory key) internal view returns (address) {
        return vm.parseTomlAddress(toml, key);
    }

    /// @dev An expected value from the guardians config.
    function _grd(string memory key) internal view returns (address) {
        return vm.parseTomlAddress(guardiansCfg, key);
    }

    /// @dev A deployed address from the registry.
    function _reg(string memory key) internal view returns (address) {
        return vm.parseTomlAddress(registry, key);
    }
}
