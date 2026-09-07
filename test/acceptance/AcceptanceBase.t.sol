// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/IrmConfigFactory.sol";
import {IIrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/interfaces/IIrmConfigFactory.sol";

import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
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
import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";
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
    function setInstantActivation(address caller, bool enabled) external;
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
    function applyIrmConfig(MarketParams calldata marketParams, address config) external;
}

interface ICurveConfig {
    function getCurveParams() external view returns (AdaptiveCurveParams memory);
}

interface IReadDashboard {
    function LIDO_LEND() external view returns (address);
    function marketStewards(Id marketId) external view returns (address[] memory);
    function addMarketSteward(Id marketId, address steward) external;
}

interface IReadFactory {
    function CONTROLLER_IMPL() external view returns (address);
    function ERC4626_WRAPPER_IMPL() external view returns (address);
    function GUARDIAN_SIGNALS_IMPL() external view returns (address);
    function LIDO_LEND_OWNER() external view returns (address);
    function IRM_ROUTER() external view returns (address);
    function LIDO_LEND() external view returns (address);
    function RISK_STEWARD_DASHBOARD() external view returns (address);
    function CIRCUIT_BREAKER() external view returns (address);
    function RESEAL_MANAGER() external view returns (address);
    function ADMIN() external view returns (address);
}

interface IReadMorphoBook {
    function isMarketAllowed(bytes32 id) external view returns (bool);
    function MORPHO() external view returns (address);
    function MAX_REQUEST_LIFETIME() external view returns (uint256);
    function paused() external view returns (bool);
    function pause() external;
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed) external;
}

interface IReadErc4626Book {
    function isVaultAllowed(address vault) external view returns (bool);
    function MAX_REQUEST_LIFETIME() external view returns (uint256);
    function paused() external view returns (bool);
    function pause() external;
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
    function MIN_PRICE() external view returns (uint256);
    function MAX_PRICE() external view returns (uint256);
}

interface IReadDecimals {
    function decimals() external view returns (uint8);
}

interface IReadCore {
    function owner() external view returns (address);
    function feeRecipient() external view returns (address);
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
///         Expected values and deployed addresses come from immutable run artifacts; activation-time choices come
///         from explicit runtime inputs.
///         Skips only when no protocol artifact is provided; a wrong RPC or network fails.
///
/// @dev This is the repo's verify tool. It independently binds deployed runtime code to the local sources,
///      checks backbone wiring and operational state, calls the factory's detailed instance validators, and
///      audits the initial launch privilege sets through enumeration, using logs only for non-enumerable mappings.
///      It deliberately does not model a governance-evolved role topology.
// ============================================================================
// CONTEXT — fork selection and run-artifact loading
// ============================================================================

abstract contract AcceptanceContext is Test {
    using MarketParamsLib for MarketParams;

    error ProtocolDeploymentMismatch(string expected, string actual);
    error RegistryPathMismatch(string expected, string actual);

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

    bytes32 internal constant INSTANT_ACTIVATION_SET_SIG = keccak256("InstantActivationSet(address,bool)");

    // governance holders
    address internal agent;
    address internal executor;

    // backbone
    address internal core;
    address internal facade;
    address internal router;
    address internal factory;
    address internal irmConfigFactory;
    address internal dashboard;
    address internal morphoBook;
    address internal erc4626Book;
    address internal circuitBreaker;
    address internal resealManager;

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
    bool internal forkProvision;

    // Event-scan starting point for the non-enumerable instant-activation mapping.
    uint256 internal marketDeployedBlock;
    uint256 internal expectedExitBookMaxRequestLifetime;
    address internal exitBookPauser;

    // Factory-derived controller and proxy admin.
    address internal rAdmin;
    address internal rProxyAdmin;

    address[] internal expectedGuardians;
    uint256 internal expectedQuorum;
    uint256 internal expectedSuspectWindow;

    string internal toml;
    string internal guardiansCfg;
    string internal oracleCfg;
    string internal circuitBreakerCfg;
    string internal exitBooksArtifact;
    string internal registry;
    string internal artifactsDir;
    ArtifactMetadata internal artifactMetadata;

    function setUp() public virtual {
        string memory regPath = vm.envOr("ACCEPTANCE_REGISTRY", string(""));
        // Unset means "not verifying a deployment". A configured but missing artifact is an error.
        if (bytes(regPath).length == 0) {
            vm.skip(true, "acceptance: set ACCEPTANCE_REGISTRY to protocol.toml");
            return;
        }
        require(vm.exists(regPath), string.concat("acceptance: ACCEPTANCE_REGISTRY not found: ", regPath));
        registry = vm.readFile(regPath);

        string memory deployment = vm.parseTomlString(registry, ".artifact.deployment");
        string memory recordedDeployment = vm.parseTomlString(registry, ".protocol.deployment");
        if (keccak256(bytes(recordedDeployment)) != keccak256(bytes(deployment))) {
            revert ProtocolDeploymentMismatch(deployment, recordedDeployment);
        }
        DeployConfigFile.requireProtocolArtifactCompatibility(registry);

        artifactsDir = string.concat(ArtifactMetadataFile.artifactsDir(deployment), "/");
        string memory expectedRegistryPath = string.concat(artifactsDir, "protocol.toml");
        string memory absoluteRegistryPath = string.concat(vm.projectRoot(), "/", expectedRegistryPath);
        if (
            keccak256(bytes(regPath)) != keccak256(bytes(expectedRegistryPath))
                && keccak256(bytes(regPath)) != keccak256(bytes(absoluteRegistryPath))
        ) revert RegistryPathMismatch(expectedRegistryPath, regPath);

        artifactMetadata = ArtifactMetadata({
            deployment: deployment,
            chainId: vm.parseTomlUint(registry, ".protocol.chain_id"),
            configHash: vm.parseTomlBytes32(registry, ".protocol.config_hash"),
            compatibilityHash: vm.parseTomlBytes32(registry, ".artifact.compatibility_hash")
        });
        registry = ArtifactMetadataFile.requireExact(regPath, artifactMetadata);
        forkProvision = keccak256(bytes(deployment)) == keccak256("fork");

        string memory rpc = vm.envOr("ACCEPTANCE_RPC_URL", string(""));
        if (bytes(rpc).length != 0) vm.createSelectFork(rpc);
        assertEq(block.chainid, artifactMetadata.chainId, "protocol artifact chain ID");
        _loadMarket(vm.envString("MARKET"));
        assertGt(core.code.length, 0, "core missing code on acceptance RPC");
        assertGt(controller.code.length, 0, "controller missing code on acceptance RPC");
    }

    function _loadMarket(string memory market) internal {
        toml = _readSibling(string.concat("markets/", market, ".toml"));
        string memory guardianGroup = vm.parseTomlString(toml, ".market.guardian_group");
        guardiansCfg = _readSibling(string.concat("guardians/", guardianGroup, ".toml"));
        string memory oracleArtifact = vm.parseTomlString(toml, ".market.oracle_artifact");
        oracleCfg = _readSibling(string.concat("oracles/", oracleArtifact, ".toml"));
        string memory circuitBreakerArtifact = vm.parseTomlString(registry, ".protocol.circuit_breaker_artifact");
        circuitBreakerCfg = _readSibling(string.concat("circuit-breakers/", circuitBreakerArtifact, ".toml"));

        agent = _reg(".protocol.agent");
        executor = _reg(".protocol.evm_script_executor");

        core = _reg(".protocol.core");
        facade = _reg(".protocol.owner_facade");
        router = _reg(".protocol.irm_router");
        curve = _reg(".protocol.adaptive_curve_irm");
        factory = _reg(".protocol.factory");
        irmConfigFactory = _reg(".protocol.irm_config_factory");
        dashboard = _reg(".protocol.risk_steward_dashboard");
        string memory exitBooksPath = string.concat(artifactsDir, "exit-books.toml");
        if (vm.exists(exitBooksPath)) {
            exitBooksArtifact = ArtifactMetadataFile.requireCompatible(exitBooksPath, artifactMetadata);
            morphoBook = vm.parseTomlAddress(exitBooksArtifact, ".exit_books.morpho");
            erc4626Book = vm.parseTomlAddress(exitBooksArtifact, ".exit_books.erc4626");
            expectedExitBookMaxRequestLifetime = vm.parseTomlUint(exitBooksArtifact, ".exit_books.max_request_lifetime");
            exitBookPauser = vm.parseTomlAddress(exitBooksArtifact, ".exit_books.pauser");
        }
        oracle = _addr(".market.oracle");
        guardianSignals = _addr(".market.guardian_signals");
        controller = _addr(".market.controller");
        vault = _addr(".market.vault");
        marketId = vm.parseTomlBytes32(toml, ".market.id");
        assertEq(_addr(".market.factory"), factory, "market factory != protocol factory");
        assertEq(_addr(".market.irm"), router, "market IRM != protocol router");
        assertEq(vm.parseTomlAddress(oracleCfg, ".oracle.address"), oracle, "oracle artifact address");
        assertEq(
            vm.parseTomlAddress(guardiansCfg, ".guardian_signals.address"),
            guardianSignals,
            "GuardianSignals artifact address"
        );

        marketDeployedBlock = vm.parseTomlUint(toml, ".market.deployed_block");

        loanToken = _addr(".market.loan_token");
        collateralToken = _addr(".market.collateral_token");
        lltv = vm.parseTomlUint(toml, ".market.lltv");

        rAdmin = IReadFactory(factory).ADMIN();
        rProxyAdmin = rAdmin;
        circuitBreaker = _reg(".protocol.circuit_breaker");
        resealManager = _reg(".protocol.reseal_manager");
        assertEq(
            vm.parseTomlAddress(circuitBreakerCfg, ".circuit_breaker.address"),
            circuitBreaker,
            "CircuitBreaker artifact address"
        );

        expectedGuardians = vm.parseTomlAddressArray(guardiansCfg, ".guardian_signals.guardians");
        expectedQuorum = vm.parseTomlUint(guardiansCfg, ".guardian_signals.quorum");
        expectedSuspectWindow = vm.parseTomlUint(guardiansCfg, ".guardian_signals.suspect_window");
    }

    function _readSibling(string memory relPath) internal view returns (string memory) {
        return ArtifactMetadataFile.requireCompatible(string.concat(artifactsDir, relPath), artifactMetadata);
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

    /// @dev Production acceptance requires the reviewed motion value explicitly. The conventional `fork` run may
    ///      use the local replay's fixed `true` default so provision-fork remains self-contained.
    function _loadExpectedSettlementChoice() internal {
        enableSettlement =
            forkProvision ? vm.envOr("ACCEPTANCE_ENABLE_SETTLEMENT", true) : vm.envBool("ACCEPTANCE_ENABLE_SETTLEMENT");
    }

    /// @dev Production acceptance requires the reviewed committee explicitly instead of trusting the live
    ///      registration. The conventional `fork` run defaults to the Agent used by ActivateMarkets.s.sol.
    function _loadExpectedPauserCommittee() internal {
        pauserCommittee = forkProvision
            ? vm.envOr("ACCEPTANCE_PAUSER_COMMITTEE", agent)
            : vm.envAddress("ACCEPTANCE_PAUSER_COMMITTEE");
        require(pauserCommittee != address(0), "acceptance: CircuitBreaker pauser committee is zero");
    }
}

// ============================================================================
// MARKET — deployment assertions and governance-motion simulation
// ============================================================================

abstract contract AcceptanceMarketAssertions is AcceptanceContext {
    using MarketParamsLib for MarketParams;

    function _assertComponentsDeployed() internal {
        address[11] memory a = [
            core,
            facade,
            router,
            factory,
            irmConfigFactory,
            dashboard,
            oracle,
            guardianSignals,
            curve,
            controller,
            vault
        ];
        for (uint256 i; i < a.length; ++i) {
            assertGt(a[i].code.length, 0, "component missing code");
        }
        assertGt(_expectedIrmConfig().code.length, 0, "IRM config missing code");
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
        assertEq(IReadCore(core).owner(), facade, "core.owner");
        assertEq(IReadCore(core).feeRecipient(), agent, "core.feeRecipient");
        assertEq(IReadRouter(router).MORPHO(), core, "router.MORPHO");
        assertEq(IReadDashboard(dashboard).LIDO_LEND(), core, "dashboard.LIDO_LEND");
        if (morphoBook != address(0)) assertEq(IReadMorphoBook(morphoBook).MORPHO(), core, "morphoBook.MORPHO");

        IReadFactory deployedFactory = IReadFactory(factory);
        assertEq(deployedFactory.LIDO_LEND_OWNER(), facade, "factory.LIDO_LEND_OWNER");
        assertEq(deployedFactory.IRM_ROUTER(), router, "factory.IRM_ROUTER");
        assertEq(deployedFactory.LIDO_LEND(), core, "factory.LIDO_LEND");
        assertEq(deployedFactory.RISK_STEWARD_DASHBOARD(), dashboard, "factory.RISK_STEWARD_DASHBOARD");

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
            assertFalse(IReadMorphoBook(morphoBook).paused(), "morpho exit book is paused");
            assertFalse(IReadErc4626Book(erc4626Book).paused(), "ERC-4626 exit book is paused");
        }

        // Additional direct core, asset, and operational-state checks.
        assertEq(IReadController(controller).LIDO_LEND(), core, "controller.LIDO_LEND");
        assertEq(IReadVault(vault).LIDO_LEND(), core, "vault.LIDO_LEND");
        assertEq(IReadVault(vault).asset(), loanToken, "vault.asset");
        assertFalse(IReadController(controller).isPaused(), "controller is paused");
        assertFalse(IReadController(controller).isFrozen(), "controller is frozen");
        // The curve singleton's per-market config is applied at activation, so its assert lives in
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
            uint256 expectedMinPrice = vm.parseTomlUint(oracleCfg, ".oracle.min_price");
            uint256 expectedMaxPrice = vm.parseTomlUint(oracleCfg, ".oracle.max_price");
            address expectedImplementation =
                address(new UsdyStableOracle(expectedUsdyOracle, expectedMinPrice, expectedMaxPrice));
            assertEq(implementation.codehash, expectedImplementation.codehash, "USDY oracle implementation");
            assertEq(IReadUsdyOracle(oracle).USDY_ORACLE(), expectedUsdyOracle, "oracle.USDY_ORACLE");
            assertEq(IReadUsdyOracle(oracle).stableUsdFeed(), expectedFeed, "oracle.stableUsdFeed");
            uint256 expectedScale =
                10 ** (uint256(IReadDecimals(expectedLoanToken).decimals()) + IReadDecimals(expectedFeed).decimals());
            assertEq(IReadUsdyOracle(oracle).scale(), expectedScale, "oracle.scale");
            assertEq(IReadUsdyOracle(oracle).MIN_PRICE(), expectedMinPrice, "oracle.MIN_PRICE");
            assertEq(IReadUsdyOracle(oracle).MAX_PRICE(), expectedMaxPrice, "oracle.MAX_PRICE");
            // The band must not already be at its edge: `price()` would revert on the next ordinary move.
            uint256 livePrice = IReadOracle(oracle).price();
            assertGt(livePrice, expectedMinPrice, "oracle price at or below MIN_PRICE");
            assertLt(livePrice, expectedMaxPrice, "oracle price at or above MAX_PRICE");
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

    /// @notice Calls `LidoLendMarketFactory`'s own view checks instead of re-implementing them.
    /// @dev A revert is the test failure; no separate assertion wraps these calls.
    function _assertFactoryValidation() internal view {
        LidoLendMarketFactory deployedFactory = LidoLendMarketFactory(factory);
        deployedFactory.validateMarketController(controller, Id.wrap(marketId), guardianSignals);
        deployedFactory.validateERC4626Wrapper(vault, controller, _params());
        deployedFactory.validateGuardianSignals(guardianSignals, _expectedGuardianSpec());
    }

    function _expectedGuardianSpec() internal view returns (LidoLendMarketFactory.GuardianSpec memory spec) {
        spec.guardians = expectedGuardians;
        spec.quorum = expectedQuorum;
        spec.suspectWindow = expectedSuspectWindow;
    }

    function _assertConfig() internal view {
        assertEq(IReadController(controller).supplyCap(), vm.parseTomlUint(toml, ".market.supply_cap"), "supplyCap");

        CollateralActivationConfig memory c = IReadController(controller).collateralActivationConfig();
        assertEq(uint256(c.minActivationDelay), vm.parseTomlUint(toml, ".activation.min_activation_delay"), "minDelay");
        assertEq(uint256(c.maxActivationDelay), vm.parseTomlUint(toml, ".activation.max_activation_delay"), "maxDelay");
        assertEq(uint256(c.maxDelayInflow), vm.parseTomlUint(toml, ".activation.max_delay_inflow"), "maxDelayInflow");
        assertEq(
            uint256(c.activatingLockDuration), vm.parseTomlUint(toml, ".activation.activating_lock_duration"), "lockDur"
        );
        assertEq(uint256(c.minActivationAmount), vm.parseTomlUint(toml, ".activation.min_activation_amount"), "minAmt");
        assertEq(uint256(c.minDepositAmount), vm.parseTomlUint(toml, ".activation.min_deposit_amount"), "minDeposit");
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

        address irmConfig = _expectedIrmConfig();
        _assertCurveParams(ICurveConfig(irmConfig).getCurveParams());
        assertEq(
            IIrmConfigFactory(irmConfigFactory).getAdaptiveCurveConfig(_expectedCurveParams()),
            irmConfig,
            "IRM config factory entry"
        );
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

    /// @notice Everything left in the initial launch role matrix that is NOT a `LidoLendMarketFactory`-checked
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
        assertEq(actualFactory.ERC4626_WRAPPER_IMPL(), vaultImpl, "factory ERC-4626 wrapper implementation");
        assertEq(actualFactory.GUARDIAN_SIGNALS_IMPL(), guardianImpl, "factory guardian implementation");
        assertEq(actualFactory.ADMIN(), rAdmin, "factory controller admin");
        assertEq(rProxyAdmin, rAdmin, "controller proxy admin differs from factory admin");
        assertEq(actualFactory.CIRCUIT_BREAKER(), circuitBreaker, "factory CircuitBreaker");
        assertEq(actualFactory.RESEAL_MANAGER(), resealManager, "factory reseal manager");

        _assertCodehash(
            facade, address(new LidoLendOwner(ILidoLend(core), address(this), address(0), address(0))), "facade"
        );
        _assertCodehash(
            factory,
            address(
                new LidoLendMarketFactory(
                    LidoLendMarketFactory.Implementations({
                        controller: controllerImpl, erc4626Wrapper: vaultImpl, guardianSignals: guardianImpl
                    }),
                    LidoLendMarketFactory.Dependencies({
                        lidoLend: core,
                        irmRouter: router,
                        lidoLendOwner: facade,
                        circuitBreaker: circuitBreaker,
                        resealManager: resealManager,
                        riskStewardDashboard: dashboard
                    }),
                    rAdmin
                )
            ),
            "factory"
        );
        _assertCodehash(dashboard, address(new RiskStewardDashboard(address(this), ILidoLend(core))), "dashboard");
        _assertCodehash(curve, address(new AdaptiveCurveIrm(router, address(this), address(this))), "adaptive curve");
        _assertCodehash(irmConfigFactory, address(new IrmConfigFactory()), "IRM config factory");
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
        // No per-market curve config may be applied to the singleton while the market is inert.
        assertEq(IReadCurve(curve).marketCurveConfig(marketId), address(0), "curve config already applied");
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
        assertEq(IReadRouter(router).marketIrm(marketId), curve, "IRM not routed");
        address cfg = IReadCurve(curve).marketCurveConfig(marketId);
        assertEq(cfg, _expectedIrmConfig(), "unexpected curve config");
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

    function _assertExitBookPausePath() internal {
        if (morphoBook == address(0)) {
            vm.skip(true, "acceptance: exit books are not deployed");
            return;
        }

        vm.startPrank(exitBookPauser);
        IReadMorphoBook(morphoBook).pause();
        IReadErc4626Book(erc4626Book).pause();
        vm.stopPrank();

        assertTrue(IReadMorphoBook(morphoBook).paused(), "configured pauser did not pause morpho exit book");
        assertTrue(IReadErc4626Book(erc4626Book).paused(), "configured pauser did not pause ERC-4626 exit book");
    }

    /// @dev Mirror of the `LidoLendActivateMarket` EasyTrack motion, run by the executor. The curve config
    ///      MUST be applied before `createMarket` — its first `borrowRate` ping reverts on an unset config.
    function _activate(address testPauserCommittee) internal {
        assertNotEq(testPauserCommittee, address(0), "test pauser committee is zero");
        MarketParams memory p = _params();
        address irmConfig = _expectedIrmConfig();
        vm.startPrank(executor);
        IReadCurve(curve).applyIrmConfig(p, irmConfig);
        IReadRouter(router).setMarketIrm(p, curve);
        IReadFacade(facade).createMarket(p, controller, enableSettlement);
        IReadCircuitBreaker(circuitBreaker).registerPauser(controller, testPauserCommittee);
        vm.stopPrank();
    }

    function _expectedIrmConfig() private view returns (address irmConfig) {
        irmConfig = vm.parseTomlAddress(toml, ".market.irm_config");
        assertNotEq(irmConfig, address(0), "IRM config missing from artifact");
    }

    /// @dev Mirror of the exit-book allow-list governance action, when exit books are deployed.
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
// ROLES — exact holder validation
// ============================================================================

abstract contract AcceptanceRoleAudit is AcceptanceMarketAssertions {
    /// @notice Reads every enumerable AccessControl surface directly from the deployed contracts and validates the
    ///         exact initial launch holder set. Only the controller's non-enumerable instant-activation mapping needs
    ///         logs. Deployments changed by later governance actions need a separate expected-role input and are out
    ///         of scope for this launch acceptance suite.
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
            holders[1] = _arr2(facade, dashboard);
            holders[2] = _arr2(circuitBreaker, resealManager);
            holders[3] = _arr1(dashboard);
            holders[4] = _arr1(facade);
            holders[5] = _arr1(resealManager);
            _assertExactEnumerableRoleHolders(controller, roles, holders);
        }
        {
            bytes32[] memory roles = new bytes32[](4);
            roles[0] = DEFAULT_ADMIN_ROLE;
            roles[1] = MANAGER_ROLE;
            roles[2] = ACCESS_RESTORER_ROLE;
            roles[3] = ACCESS_LIMITER_ROLE;
            address[][] memory holders = new address[][](4);
            holders[0] = _arr1(agent);
            holders[1] = _arr1(facade);
            holders[2] = _arr1(facade);
            holders[3] = new address[](0);
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
            holders[2] = _arr1(executor);
            holders[3] = _arr1(executor);
            holders[4] = _arr1(executor);
            _assertExactEnumerableRoleHolders(facade, roles, holders);
        }
        {
            bytes32[] memory roles = new bytes32[](2);
            roles[0] = DEFAULT_ADMIN_ROLE;
            roles[1] = STEWARD_ADMIN_ROLE;
            address[][] memory holders = new address[][](2);
            holders[0] = _arr1(agent);
            holders[1] = _arr1(executor);
            _assertExactEnumerableRoleHolders(dashboard, roles, holders);
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

    function _assertExitBookRoleHolderCompleteness(address book) internal view {
        bytes32[] memory roles = new bytes32[](6);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = ALLOWLIST_MANAGER_ROLE;
        roles[2] = FEE_MANAGER_ROLE;
        roles[3] = RECOVERER_ROLE;
        roles[4] = PAUSER_ROLE;
        roles[5] = RESUMER_ROLE;
        address[][] memory holders = new address[][](6);
        holders[0] = _arr1(agent);
        holders[1] = _arr2(executor, agent);
        holders[2] = _arr1(executor);
        holders[3] = _arr1(agent);
        holders[4] = _arr1(exitBookPauser);
        holders[5] = new address[](0);
        _assertExactEnumerableRoleHolders(book, roles, holders);
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
}

/// @notice Stable import surface for the concrete acceptance scenarios.
abstract contract AcceptanceBase is AcceptanceRoleAudit {}
