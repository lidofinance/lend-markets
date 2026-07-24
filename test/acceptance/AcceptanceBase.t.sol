// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";

import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendMarketBuilder, MarketRoles, GuardianConfig} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
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
    function hasInstantActivation(address caller) external view returns (bool);
    function grantInstantActivation(address caller) external;
    function freeze() external;
    function pauseFor(uint256 duration) external;
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
    function marketStewards(Id marketId) external view returns (address[] memory);
    function addMarketSteward(Id marketId, address steward) external;
}

interface IReadFactory {
    function CONTROLLER_IMPL() external view returns (address);
    function VAULT_IMPL() external view returns (address);
    function GUARDIAN_SIGNALS_IMPL() external view returns (address);
}

interface IReadMorphoBook {
    function isMarketAllowed(bytes32 id) external view returns (bool);
    function MORPHO() external view returns (address);
    function MAX_REQUEST_LIFETIME() external view returns (uint256);
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed) external;
}

interface IReadErc4626Book {
    function isVaultAllowed(address vault) external view returns (bool);
    function MAX_REQUEST_LIFETIME() external view returns (uint256);
    function setVaultAllowed(address vault, bool allowed) external;
}

interface IReadVault {
    function LIDO_LEND() external view returns (address);
    function controller() external view returns (address);
    function marketId() external view returns (bytes32);
    function asset() external view returns (address);
}

interface IReadProxy {
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
}

interface IReadOracle {
    function price() external view returns (uint256);
}

interface IReadWstEthOracle {
    function WSTETH() external view returns (address);
}

interface IReadUsdyOracle {
    function USDY_ORACLE() external view returns (address);
    function stableUsdFeed() external view returns (address);
    function scale() external view returns (uint256);
}

interface IReadDecimals {
    function decimals() external view returns (uint8);
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

interface IReadEnumerableAccessControl {
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
}

interface IReadCircuitBreaker {
    function getPauser(address pausable) external view returns (address);
    function isPauserLive(address pauser) external view returns (bool);
    function ADMIN() external view returns (address);
    function MIN_PAUSE_DURATION() external view returns (uint256);
    function MAX_PAUSE_DURATION() external view returns (uint256);
    function MIN_HEARTBEAT_INTERVAL() external view returns (uint256);
    function MAX_HEARTBEAT_INTERVAL() external view returns (uint256);
    function pauseDuration() external view returns (uint256);
    function heartbeatInterval() external view returns (uint256);
    function registerPauser(address pausable, address newPauser) external;
    function pause(address pausable) external;
}

/// @notice Base for market acceptance tests. Forks the node the protocol is deployed on
///         (`ACCEPTANCE_RPC_URL` or `--fork-url`) and exposes the shared assertion + activation helpers.
///         Expected values and deployed addresses come from immutable run artifacts.
///         Skips only when no protocol artifact is provided; a wrong RPC or network fails.
///
/// @dev This is the repo's verify tool. It independently binds deployed runtime code to the local sources,
///      checks backbone wiring and operational state, calls the builder's detailed instance validators, and
///      audits complete privilege sets through enumeration or event scans.
// ============================================================================
// CONTEXT — fork selection and run-artifact loading
// ============================================================================

abstract contract AcceptanceContext is Test {
    using MarketParamsLib for MarketParams;

    // role ids
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant FREEZER_ROLE = keccak256("FREEZER_ROLE");
    bytes32 internal constant UNFREEZER_ROLE = keccak256("UNFREEZER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant RESUMER_ROLE = keccak256("RESUMER_ROLE");
    bytes32 internal constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    bytes32 internal constant MARKET_MANAGER_ROLE = keccak256("MARKET_MANAGER_ROLE");
    bytes32 internal constant GUARDIAN_MANAGER_ROLE = keccak256("GUARDIAN_MANAGER_ROLE");
    bytes32 internal constant STEWARD_ADMIN_ROLE = keccak256("STEWARD_ADMIN_ROLE");
    bytes32 internal constant ALLOWLIST_MANAGER_ROLE = keccak256("ALLOWLIST_MANAGER_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant RECOVERER_ROLE = keccak256("RECOVERER_ROLE");
    bytes32 internal constant ACCESS_RESTORER_ROLE = keccak256("ACCESS_RESTORER_ROLE");
    bytes32 internal constant ACCESS_LIMITER_ROLE = keccak256("ACCESS_LIMITER_ROLE");

    bytes32 internal constant ROLE_GRANTED_SIG = keccak256("RoleGranted(bytes32,address,address)");
    bytes32 internal constant ROLE_REVOKED_SIG = keccak256("RoleRevoked(bytes32,address,address)");
    bytes32 internal constant INSTANT_ACTIVATION_SET_SIG = keccak256("InstantActivationSet(address,bool)");

    // governance holders
    address internal agent;
    address internal executor;

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
    bool internal enableSettlement;

    // event-scan starting points (see `ProtocolDeployment.deployedBlock` / `MarketDeployment.deployedBlock`)
    uint256 internal protocolDeployedBlock;
    uint256 internal marketDeployedBlock;
    uint256 internal exitBooksDeployedBlock;
    uint256 internal expectedExitBookMaxRequestLifetime;

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

    string internal toml;
    string internal guardiansCfg;
    string internal oracleCfg;
    string internal circuitBreakerCfg;
    string internal exitBooksArtifact;
    string internal registry;

    function setUp() public virtual {
        string memory regPath = vm.envOr("ACCEPTANCE_REGISTRY", string(""));
        if (bytes(regPath).length == 0 || !vm.exists(regPath)) {
            vm.skip(true, "acceptance: set ACCEPTANCE_REGISTRY to protocol.toml");
            return;
        }
        registry = vm.readFile(regPath);

        string memory rpc = vm.envOr("ACCEPTANCE_RPC_URL", string(""));
        if (bytes(rpc).length != 0) vm.createSelectFork(rpc);
        assertEq(block.chainid, vm.parseTomlUint(registry, ".protocol.chain_id"), "protocol artifact chain ID");
        _loadMarket(vm.envString("MARKET"));
        assertGt(core.code.length, 0, "core missing code on acceptance RPC");
        assertGt(controller.code.length, 0, "controller missing code on acceptance RPC");
    }

    function _loadMarket(string memory market) internal {
        string memory deployment = vm.parseTomlString(registry, ".artifact.deployment");
        string memory artifactsDir = string.concat("deployed/", deployment, "/");
        toml = vm.readFile(string.concat(artifactsDir, "markets/", market, ".toml"));
        string memory guardianGroup = vm.parseTomlString(toml, ".market.guardian_group");
        guardiansCfg = vm.readFile(string.concat(artifactsDir, "guardians/", guardianGroup, ".toml"));
        string memory oracleArtifact = vm.parseTomlString(toml, ".market.oracle_artifact");
        oracleCfg = vm.readFile(string.concat(artifactsDir, "oracles/", oracleArtifact, ".toml"));
        string memory circuitBreakerArtifact = vm.parseTomlString(toml, ".market.circuit_breaker_artifact");
        circuitBreakerCfg =
            vm.readFile(string.concat(artifactsDir, "circuit-breakers/", circuitBreakerArtifact, ".toml"));

        agent = _reg(".protocol.agent");
        executor = _reg(".protocol.evm_script_executor");

        core = _reg(".protocol.core");
        facade = _reg(".protocol.owner_facade");
        router = _reg(".protocol.irm_router");
        curve = _reg(".protocol.adaptive_curve_irm");
        factory = _reg(".protocol.factory");
        builder = _reg(".protocol.builder");
        dashboard = _reg(".protocol.risk_steward_dashboard");
        string memory exitBooksPath = string.concat(artifactsDir, "exit-books.toml");
        if (vm.exists(exitBooksPath)) {
            exitBooksArtifact = vm.readFile(exitBooksPath);
            morphoBook = vm.parseTomlAddress(exitBooksArtifact, ".exit_books.morpho");
            erc4626Book = vm.parseTomlAddress(exitBooksArtifact, ".exit_books.erc4626");
            expectedExitBookMaxRequestLifetime = vm.parseTomlUint(exitBooksArtifact, ".exit_books.max_request_lifetime");
            exitBooksDeployedBlock = vm.parseTomlUint(exitBooksArtifact, ".exit_books.deployed_block");
        }
        oracle = _addr(".market.oracle");
        guardianSignals = _addr(".market.guardian_signals");
        controller = _addr(".market.controller");
        vault = _addr(".market.vault");
        marketId = vm.parseTomlBytes32(toml, ".market.id");
        assertEq(_addr(".market.builder"), builder, "market builder != protocol builder");
        assertEq(_addr(".market.irm"), router, "market IRM != protocol router");
        assertEq(vm.parseTomlAddress(oracleCfg, ".oracle.address"), oracle, "oracle artifact address");
        assertEq(
            vm.parseTomlAddress(guardiansCfg, ".guardian_signals.address"),
            guardianSignals,
            "GuardianSignals artifact address"
        );

        protocolDeployedBlock = vm.parseTomlUint(registry, ".protocol.deployed_block");
        marketDeployedBlock = vm.parseTomlUint(toml, ".market.deployed_block");

        loanToken = _addr(".market.loan_token");
        collateralToken = _addr(".market.collateral_token");
        lltv = vm.parseTomlUint(toml, ".market.lltv");

        rAdmin = _addr(".roles.admin");
        rProxyAdmin = _addr(".roles.proxy_admin");
        rManagers = vm.parseTomlAddressArray(toml, ".roles.managers");
        rPausers = vm.parseTomlAddressArray(toml, ".roles.pausers");
        rFreezers = vm.parseTomlAddressArray(toml, ".roles.freezers");
        rUnfreezers = vm.parseTomlAddressArray(toml, ".roles.unfreezers");
        rResumers = vm.parseTomlAddressArray(toml, ".roles.resumers");

        assertGt(rPausers.length, 0, "market artifact has no CircuitBreaker");
        circuitBreaker = _addr(".market.circuit_breaker");
        assertEq(circuitBreaker, rPausers[0], "CircuitBreaker must be the first pauser");
        assertEq(
            vm.parseTomlAddress(circuitBreakerCfg, ".circuit_breaker.address"),
            circuitBreaker,
            "CircuitBreaker artifact address"
        );

        // Test-only settlement choice for the simulated activation path.
        // Production motion inputs are maintained manually in EasyTrack.
        enableSettlement = true;

        expectedGuardians = vm.parseTomlAddressArray(guardiansCfg, ".guardian_signals.guardians");
        gProxyAdmin = _grd(".guardian_signals.proxy_admin");
        expectedQuorum = vm.parseTomlUint(guardiansCfg, ".guardian_signals.quorum");
        expectedSuspectWindow = vm.parseTomlUint(guardiansCfg, ".guardian_signals.suspect_window");
        expectedAccessLimiter = _grd(".guardian_signals.access_limiter");
        gManagers = new address[](0);
    }

    function _addr(string memory key) internal view returns (address) {
        return vm.parseTomlAddress(toml, key);
    }

    function _grd(string memory key) internal view returns (address) {
        return vm.parseTomlAddress(guardiansCfg, key);
    }

    function _reg(string memory key) internal view returns (address) {
        return vm.parseTomlAddress(registry, key);
    }
}

// ============================================================================
// MARKET — deployment assertions and governance-motion simulation
// ============================================================================

abstract contract AcceptanceMarketAssertions is AcceptanceContext {
    using MarketParamsLib for MarketParams;

    function _assertComponentsDeployed() internal {
        address[11] memory a =
            [core, facade, router, factory, builder, dashboard, oracle, guardianSignals, curve, controller, vault];
        for (uint256 i; i < a.length; ++i) {
            assertGt(a[i].code.length, 0, "component missing code");
        }
        if (morphoBook != address(0)) {
            assertGt(morphoBook.code.length, 0, "morpho exit book missing code");
            assertGt(erc4626Book.code.length, 0, "ERC-4626 exit book missing code");
        }
        assertGt(circuitBreaker.code.length, 0, "CircuitBreaker missing code");
        _assertLocalBytecode();
    }

    function _assertWiring() internal {
        // market identity is the hash of the params it was built with
        MarketParams memory p = _params();
        assertEq(Id.unwrap(p.id()), marketId, "marketId != hash(params)");

        // backbone cross-links
        assertEq(IReadFacade(facade).LIDO_LEND(), core, "facade.LIDO_LEND");
        assertEq(IReadRouter(router).MORPHO(), core, "router.MORPHO");
        assertEq(IReadDashboard(dashboard).LIDO_LEND(), core, "dashboard.LIDO_LEND");
        if (morphoBook != address(0)) assertEq(IReadMorphoBook(morphoBook).MORPHO(), core, "morphoBook.MORPHO");

        // builder immutables — the builder has no view over its OWN immutables, so this stays here
        assertEq(IReadBuilder(builder).FACTORY(), factory, "builder.FACTORY");
        assertEq(IReadBuilder(builder).LIDO_LEND_OWNER(), facade, "builder.LIDO_LEND_OWNER");
        assertEq(IReadBuilder(builder).IRM_ROUTER(), router, "builder.IRM_ROUTER");
        assertEq(IReadBuilder(builder).CORE(), core, "builder.CORE");
        assertEq(IReadBuilder(builder).RISK_STEWARD_DASHBOARD(), dashboard, "builder.RISK_STEWARD_DASHBOARD");

        assertEq(IReadProxy(core).proxy__getAdmin(), agent, "core proxy admin");
        assertEq(IReadProxy(router).proxy__getAdmin(), agent, "router proxy admin");
        assertEq(IReadProxy(controller).proxy__getAdmin(), agent, "controller proxy admin");
        assertEq(IReadProxy(vault).proxy__getAdmin(), agent, "vault proxy admin");
        assertEq(IReadProxy(guardianSignals).proxy__getAdmin(), agent, "guardian proxy admin");
        assertEq(IReadProxy(oracle).proxy__getAdmin(), agent, "oracle proxy admin");
        _assertCircuitBreakerConfig();
        _assertOracle();
        if (morphoBook != address(0)) {
            assertEq(
                IReadMorphoBook(morphoBook).MAX_REQUEST_LIFETIME(),
                expectedExitBookMaxRequestLifetime,
                "morpho exit-book max lifetime"
            );
            assertEq(
                IReadErc4626Book(erc4626Book).MAX_REQUEST_LIFETIME(),
                expectedExitBookMaxRequestLifetime,
                "ERC-4626 exit-book max lifetime"
            );
        }

        // controller/vault <-> core bindings `validateMarketContracts` has no notion of (it knows nothing about "core"
        // or "loan token"); everything else about the pair — impl codehash, proxy admins, marketId/guardian
        // bindings, listed-role-holder presence, builder/factory holding nothing — is `_assertBuilderValidation`.
        assertEq(IReadController(controller).LIDO_LEND(), core, "controller.LIDO_LEND");
        assertEq(IReadVault(vault).LIDO_LEND(), core, "vault.LIDO_LEND");
        assertEq(IReadVault(vault).asset(), loanToken, "vault.asset");
        assertFalse(IReadController(controller).isPaused(), "controller is paused");
        assertFalse(IReadController(controller).isFrozen(), "controller is frozen");
        // The curve singleton's per-market params are activation calldata, so their assert lives in
        // `_assertActivated` / `_assertNotYetActivated`, not here.
    }

    function _assertOracle() internal {
        address implementation = IReadProxy(oracle).proxy__getImplementation();
        assertGt(implementation.code.length, 0, "oracle implementation missing code");

        bool isWstEth = vm.keyExistsToml(oracleCfg, ".oracle.wsteth");
        bool isUsdy = vm.keyExistsToml(oracleCfg, ".oracle.usdy_oracle");
        assertTrue(isWstEth != isUsdy, "unknown or ambiguous oracle config");

        if (isWstEth) {
            address expectedWstEth = vm.parseTomlAddress(oracleCfg, ".oracle.wsteth");
            assertEq(expectedWstEth, collateralToken, "oracle WstETH != collateral token");
            address expectedImplementation = address(new WstEthRateOracle(expectedWstEth));
            assertEq(implementation.codehash, expectedImplementation.codehash, "WstETH oracle implementation");
            assertEq(IReadWstEthOracle(oracle).WSTETH(), expectedWstEth, "oracle.WSTETH");
        } else {
            address expectedUsdyOracle = vm.parseTomlAddress(oracleCfg, ".oracle.usdy_oracle");
            address expectedFeed = vm.parseTomlAddress(oracleCfg, ".oracle.feed");
            address expectedLoanToken = vm.parseTomlAddress(oracleCfg, ".oracle.loan_token");
            address expectedCollateralToken = vm.parseTomlAddress(oracleCfg, ".oracle.collateral_token");
            assertEq(expectedLoanToken, loanToken, "oracle loan token != market loan token");
            assertEq(expectedCollateralToken, collateralToken, "oracle USDY != collateral token");
            address expectedImplementation = address(new UsdyStableOracle(expectedUsdyOracle));
            assertEq(implementation.codehash, expectedImplementation.codehash, "USDY oracle implementation");
            assertEq(IReadUsdyOracle(oracle).USDY_ORACLE(), expectedUsdyOracle, "oracle.USDY_ORACLE");
            assertEq(IReadUsdyOracle(oracle).stableUsdFeed(), expectedFeed, "oracle.stableUsdFeed");
            uint256 expectedScale =
                10 ** (uint256(IReadDecimals(expectedLoanToken).decimals()) + IReadDecimals(expectedFeed).decimals());
            assertEq(IReadUsdyOracle(oracle).scale(), expectedScale, "oracle.scale");
        }

        assertGt(IReadOracle(oracle).price(), 0, "oracle price is zero");
    }

    function _assertCircuitBreakerConfig() internal view {
        IReadCircuitBreaker cb = IReadCircuitBreaker(circuitBreaker);
        assertEq(cb.ADMIN(), executor, "CircuitBreaker.ADMIN");
        assertEq(
            cb.MIN_PAUSE_DURATION(),
            vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.min_pause_duration"),
            "CircuitBreaker.MIN_PAUSE_DURATION"
        );
        assertEq(
            cb.MAX_PAUSE_DURATION(),
            vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.max_pause_duration"),
            "CircuitBreaker.MAX_PAUSE_DURATION"
        );
        assertEq(
            cb.MIN_HEARTBEAT_INTERVAL(),
            vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.min_heartbeat_interval"),
            "CircuitBreaker.MIN_HEARTBEAT_INTERVAL"
        );
        assertEq(
            cb.MAX_HEARTBEAT_INTERVAL(),
            vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.max_heartbeat_interval"),
            "CircuitBreaker.MAX_HEARTBEAT_INTERVAL"
        );
        assertGe(cb.pauseDuration(), cb.MIN_PAUSE_DURATION(), "CircuitBreaker.pauseDuration below min");
        assertLe(cb.pauseDuration(), cb.MAX_PAUSE_DURATION(), "CircuitBreaker.pauseDuration above max");
        assertGe(cb.heartbeatInterval(), cb.MIN_HEARTBEAT_INTERVAL(), "CircuitBreaker.heartbeatInterval below min");
        assertLe(cb.heartbeatInterval(), cb.MAX_HEARTBEAT_INTERVAL(), "CircuitBreaker.heartbeatInterval above max");
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

    /// @dev The per-market curve params used by the activation simulation.
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
        _assertAddressSetEq(
            IReadDashboard(dashboard).marketStewards(Id.wrap(marketId)), new address[](0), "market steward"
        );
    }

    function _assertLocalBytecode() internal {
        address coreImpl = IReadProxy(core).proxy__getImplementation();
        address routerImpl = IReadProxy(router).proxy__getImplementation();
        address controllerImpl = IReadProxy(controller).proxy__getImplementation();
        address vaultImpl = IReadProxy(vault).proxy__getImplementation();
        address guardianImpl = IReadProxy(guardianSignals).proxy__getImplementation();

        _assertCodehash(coreImpl, address(new LidoLend()), "core implementation");
        _assertCodehash(routerImpl, address(new IrmRouter(core)), "router implementation");
        _assertCodehash(
            controllerImpl, address(new LidoLendMarketController(IMorpho(core))), "controller implementation"
        );
        _assertCodehash(vaultImpl, address(new LidoLendERC4626(core)), "vault implementation");
        _assertCodehash(guardianImpl, address(new GuardianSignals()), "guardian implementation");

        IReadFactory actualFactory = IReadFactory(factory);
        assertEq(actualFactory.CONTROLLER_IMPL(), controllerImpl, "factory controller implementation");
        assertEq(actualFactory.VAULT_IMPL(), vaultImpl, "factory vault implementation");
        assertEq(actualFactory.GUARDIAN_SIGNALS_IMPL(), guardianImpl, "factory guardian implementation");

        _assertCodehash(
            facade, address(new LidoLendOwner(ILidoLend(core), address(this), address(0), address(0))), "facade"
        );
        _assertCodehash(factory, address(new LidoLendMarketFactory(controllerImpl, vaultImpl, guardianImpl)), "factory");
        _assertCodehash(dashboard, address(new RiskStewardDashboard(address(this), ILidoLend(core))), "dashboard");
        _assertCodehash(
            builder,
            address(
                new LidoLendMarketBuilder(
                    LidoLendMarketFactory(factory), LidoLendOwner(facade), IIrmRouter(router), dashboard
                )
            ),
            "builder"
        );
        _assertCodehash(curve, address(new AdaptiveCurveIrm(router, address(this), address(this))), "adaptive curve");
        _assertCodehash(circuitBreaker, _deployExpectedCircuitBreaker(), "CircuitBreaker");

        address proxyShell = address(new OssifiableProxy(address(new GuardianSignals()), address(this), ""));
        _assertCodehash(core, proxyShell, "core proxy");
        _assertCodehash(router, proxyShell, "router proxy");
        _assertCodehash(controller, proxyShell, "controller proxy");
        _assertCodehash(vault, proxyShell, "vault proxy");
        _assertCodehash(guardianSignals, proxyShell, "guardian proxy");
        _assertCodehash(oracle, proxyShell, "oracle proxy");

        if (morphoBook != address(0)) {
            _assertCodehash(
                morphoBook,
                address(new MorphoExitBook(core, address(this), expectedExitBookMaxRequestLifetime)),
                "morpho exit book"
            );
            _assertCodehash(
                erc4626Book,
                address(new Erc4626ExitBook(address(this), expectedExitBookMaxRequestLifetime)),
                "ERC-4626 exit book"
            );
        }
    }

    function _deployExpectedCircuitBreaker() private returns (address expected) {
        bytes memory creationCode = vm.getCode("out/CircuitBreaker.sol/CircuitBreaker.json");
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(
                executor,
                vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.min_pause_duration"),
                vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.max_pause_duration"),
                vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.min_heartbeat_interval"),
                vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.max_heartbeat_interval"),
                vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.initial_pause_duration"),
                vm.parseTomlUint(circuitBreakerCfg, ".circuit_breaker.initial_heartbeat_interval")
            )
        );
        assembly ("memory-safe") {
            expected := create(0, add(initCode, 0x20), mload(initCode))
        }
        assertNotEq(expected, address(0), "expected CircuitBreaker deployment failed");
    }

    function _assertCodehash(address actual, address expected, string memory label) private view {
        assertEq(actual.codehash, expected.codehash, label);
    }

    function _assertAddressSetEq(address[] memory actual, address[] memory expected, string memory label)
        internal
        view
    {
        assertEq(actual.length, expected.length, string.concat("unexpected ", label, " count"));
        for (uint256 i; i < actual.length; ++i) {
            assertTrue(
                _containsAddr(expected, actual[i]), string.concat("unexpected ", label, ": ", vm.toString(actual[i]))
            );
        }
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(
                _containsAddr(actual, expected[i]), string.concat("missing ", label, ": ", vm.toString(expected[i]))
            );
        }
    }

    function _containsAddr(address[] memory arr, address a) internal pure returns (bool) {
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == a) return true;
        }
        return false;
    }

    /// @dev The activation motion is run by the executor, so it must hold the CircuitBreaker admin (registerPauser).
    function _assertCircuitBreakerReadyAsPauser() internal view {
        assertGt(rPausers.length, 0, "market must configure a CircuitBreaker");
        assertEq(IReadCircuitBreaker(circuitBreaker).ADMIN(), executor, "cb.ADMIN=executor");
    }

    function _isMarketActivated() internal view returns (bool) {
        (,,,, uint128 lastUpdate,) = IReadCore(core).market(marketId);
        return lastUpdate != 0;
    }

    function _assertNotYetActivated() internal view {
        (,,,, uint128 lastUpdate,) = IReadCore(core).market(marketId);
        assertEq(uint256(lastUpdate), 0, "market already created on core");
        assertEq(IReadCore(core).marketController(marketId), address(0), "controller already bound");
        assertEq(IReadRouter(router).marketIrm(marketId), address(0), "curve already routed");
        // Per-market curve params are activation calldata on the singleton — none may exist while inert.
        assertEq(IReadCurve(curve).marketCurveConfig(marketId), address(0), "curve params already set");
        assertEq(IReadCircuitBreaker(circuitBreaker).getPauser(controller), address(0), "pauser already registered");
    }

    function _assertExitBooksNotAllowed() internal view {
        if (morphoBook != address(0)) {
            assertFalse(IReadMorphoBook(morphoBook).isMarketAllowed(marketId), "market already allow-listed");
            assertFalse(IReadErc4626Book(erc4626Book).isVaultAllowed(vault), "vault already allow-listed");
        }
    }

    function _assertActivated() internal view {
        (,,,, uint128 lastUpdate,) = IReadCore(core).market(marketId);
        assertGt(uint256(lastUpdate), 0, "market not created on core");
        assertEq(IReadCore(core).marketController(marketId), controller, "controller not bound");
        assertEq(IReadCore(core).isSettlementEnabled(marketId), enableSettlement, "settlement flag");
        assertEq(IReadRouter(router).marketIrm(marketId), curve, "curve not routed");
        // The motion set this market's curve params on the singleton.
        address cfg = IReadCurve(curve).marketCurveConfig(marketId);
        assertGt(cfg.code.length, 0, "curve config missing for market");
        _assertCurveParams(ICurveConfig(cfg).getCurveParams());
        assertNotEq(pauserCommittee, address(0), "CircuitBreaker pauser is not registered");
        assertEq(IReadCircuitBreaker(circuitBreaker).getPauser(controller), pauserCommittee, "pauser not registered");
    }

    function _assertCircuitBreakerPausePath() internal {
        IReadCircuitBreaker cb = IReadCircuitBreaker(circuitBreaker);
        assertTrue(cb.isPauserLive(pauserCommittee), "pauser heartbeat is not live");
        vm.prank(pauserCommittee);
        cb.pause(controller);
        assertTrue(IReadController(controller).isPaused(), "CircuitBreaker did not pause controller");
        assertEq(cb.getPauser(controller), address(0), "single-use pauser registration was not cleared");
    }

    function _assertExitBooksAllowed() internal view {
        if (morphoBook != address(0)) {
            assertTrue(IReadMorphoBook(morphoBook).isMarketAllowed(marketId), "market not allow-listed");
            assertTrue(IReadErc4626Book(erc4626Book).isVaultAllowed(vault), "vault not allow-listed");
        }
    }

    /// @dev Mirror of the `LidoLendActivateMarket` EasyTrack motion, run by the executor. The curve params
    ///      MUST be set before `createMarket` — its first `borrowRate` ping reverts on an unset config.
    function _activate(address testPauserCommittee) internal {
        assertNotEq(testPauserCommittee, address(0), "test pauser committee is zero");
        MarketParams memory p = _params();
        vm.startPrank(executor);
        IReadCurve(curve).setMarketCurveParams(p, _expectedCurveParams());
        IReadRouter(router).setMarketIrm(p, curve);
        IReadFacade(facade).createMarket(p, controller, enableSettlement);
        IReadCircuitBreaker(circuitBreaker).registerPauser(controller, testPauserCommittee);
        vm.stopPrank();
    }

    /// @dev Mirror of the separate exit-book allow-list EasyTrack motion, when exit books are deployed.
    function _allowlistExitBooks() internal {
        if (morphoBook != address(0)) {
            MarketParams memory p = _params();
            vm.startPrank(executor);
            IReadMorphoBook(morphoBook).setMarketAllowed(p, true);
            IReadErc4626Book(erc4626Book).setVaultAllowed(vault, true);
            vm.stopPrank();
        }
    }

    function _params() internal view returns (MarketParams memory) {
        return
            MarketParams({
                loanToken: loanToken, collateralToken: collateralToken, oracle: oracle, irm: router, lltv: lltv
            });
    }
}

// ============================================================================
// ROLES — exact holder reconstruction from AccessControl events
// ============================================================================

abstract contract AcceptanceRoleAudit is AcceptanceMarketAssertions {
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

    /// @notice Applies `_assertExactRoleHolders` to every `AccessControl` contract from its own recorded
    ///         deployment block.
    function _assertRoleHolderCompleteness() internal {
        _assertNoInstantActivationCallers();
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
            holders[1] = rManagers;
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
            holders[1] = _append(gManagers, facade);
            holders[2] = _append(gManagers, facade);
            holders[3] = _maybeArr1(expectedAccessLimiter);
            _assertExactEnumerableRoleHolders(guardianSignals, roles, holders);
        }
        {
            bytes32[] memory roles = new bytes32[](5);
            roles[0] = DEFAULT_ADMIN_ROLE;
            roles[1] = MARKET_CREATOR_ROLE;
            roles[2] = FEE_MANAGER_ROLE;
            roles[3] = MARKET_MANAGER_ROLE;
            roles[4] = GUARDIAN_MANAGER_ROLE;
            address[][] memory holders = new address[][](5);
            holders[0] = _arr1(agent);
            holders[1] = _arr1(executor);
            holders[2] = _arr1(agent);
            holders[3] = _arr1(executor);
            holders[4] = _arr1(executor);
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
        if (morphoBook != address(0)) {
            _assertExitBookRoleHolderCompleteness(morphoBook);
            _assertExitBookRoleHolderCompleteness(erc4626Book);
        }
    }

    function _assertNoInstantActivationCallers() private {
        uint256 toBlock = vm.getBlockNumber();
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = INSTANT_ACTIVATION_SET_SIG;
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(marketDeployedBlock, toBlock, controller, topics);

        address[] memory raw = new address[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            raw[i] = address(uint160(uint256(logs[i].topics[1])));
        }
        _assertInstantActivationCallers(_dedupAddr(raw), new address[](0));
    }

    function _assertInstantActivationCallers(address[] memory candidates, address[] memory expected) internal view {
        address[] memory actual = new address[](candidates.length);
        uint256 count;
        for (uint256 i; i < candidates.length; ++i) {
            if (IReadController(controller).hasInstantActivation(candidates[i])) actual[count++] = candidates[i];
        }
        assembly ("memory-safe") {
            mstore(actual, count)
        }
        _assertAddressSetEq(actual, expected, "instant-activation caller");
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
        _assertExactRoleHolders(book, exitBooksDeployedBlock, roles, holders);
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

    function _assertExactEnumerableRoleHolders(
        address target,
        bytes32[] memory roles,
        address[][] memory expectedHolders
    ) internal view {
        IReadEnumerableAccessControl access = IReadEnumerableAccessControl(target);
        for (uint256 i; i < roles.length; ++i) {
            uint256 count = access.getRoleMemberCount(roles[i]);
            assertEq(count, expectedHolders[i].length, "unexpected enumerable role-holder count");
            for (uint256 j; j < count; ++j) {
                assertTrue(
                    _containsAddr(expectedHolders[i], access.getRoleMember(roles[i], j)),
                    "unexpected enumerable role holder"
                );
            }
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
        if (role == MARKET_MANAGER_ROLE) return "MARKET_MANAGER_ROLE";
        if (role == GUARDIAN_MANAGER_ROLE) return "GUARDIAN_MANAGER_ROLE";
        if (role == STEWARD_ADMIN_ROLE) return "STEWARD_ADMIN_ROLE";
        if (role == ALLOWLIST_MANAGER_ROLE) return "ALLOWLIST_MANAGER_ROLE";
        if (role == FEE_MANAGER_ROLE) return "FEE_MANAGER_ROLE";
        if (role == RECOVERER_ROLE) return "RECOVERER_ROLE";
        if (role == ACCESS_RESTORER_ROLE) return "ACCESS_RESTORER_ROLE";
        if (role == ACCESS_LIMITER_ROLE) return "ACCESS_LIMITER_ROLE";
        return vm.toString(role);
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
}

/// @notice Stable import surface for the concrete acceptance scenarios.
abstract contract AcceptanceBase is AcceptanceRoleAudit {}
