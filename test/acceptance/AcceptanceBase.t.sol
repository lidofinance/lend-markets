// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {
    MarketParameters,
    CircuitBreakerParameters,
    DeploymentSnapshot,
    RecordedMarket,
    PriceFeedRecord
} from "../../script/deployment/DeploymentTypes.sol";
import {RecordedDeployment} from "../../script/deployment/RecordedDeployment.sol";

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

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    function currentInflow() external view returns (uint256);
    function settlementBorrowersCount() external view returns (uint256);
    function hasBadDebt() external view returns (bool);
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
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function managedSupplyShares() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
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

interface IReadGeneralAdapter1 {
    function BUNDLER3() external view returns (address);
    function MORPHO() external view returns (address);
    function WRAPPED_NATIVE() external view returns (address);
    function WST_ETH() external view returns (address);
    function ST_ETH() external view returns (address);
}

interface IReadWstEth {
    function stETH() external view returns (address);
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

    address internal constant PRESEED_RECIPIENT = address(0xdead);

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
    uint256 internal expectedFee;
    uint256 internal minimumCoreSeedShares;
    uint256 internal minimumVaultSeedShares;

    // Event-scan starting point for the non-enumerable instant-activation mapping.
    uint256 internal marketDeployedBlock;
    uint256 internal expectedExitBookMaxRequestLifetime;
    address internal exitBookPauser;

    // Optional run-level artifact: the bundler stack over this core.
    address internal bundler3;
    address internal generalAdapter;
    address internal vaultAdapter;

    // Factory-derived controller and proxy admin.
    address internal rAdmin;
    address internal rProxyAdmin;

    address[] internal expectedGuardians;
    address[] internal expectedMarketStewards;
    uint256 internal expectedQuorum;
    uint256 internal expectedSuspectWindow;

    MarketParameters internal expectedMarketParameters;
    CircuitBreakerParameters internal expectedCircuitBreaker;
    address internal expectedIrmConfigAddress;
    address internal expectedBundlerWeth;
    address internal expectedBundlerWstEth;
    address internal expectedBundlerCore;

    PriceFeedRecord internal expectedPriceFeed;
    bool internal useLocalDeploymentLogs;
    string internal recordedRun;

    struct ActivationCandidate {
        address controller;
        address caller;
    }
    ActivationCandidate[] internal localActivationCandidates;

    function setUp() public virtual {
        recordedRun = vm.envOr("ACCEPTANCE_RUN", string(""));
        if (bytes(recordedRun).length == 0) {
            vm.skip(true, "acceptance: set ACCEPTANCE_RUN");
            return;
        }
        string memory rpc = vm.envOr("ACCEPTANCE_RPC_URL", string(""));
        if (bytes(rpc).length != 0) {
            uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
            if (pin == 0) vm.createSelectFork(rpc);
            else vm.createSelectFork(rpc, pin);
        }
        _loadMarket(vm.envString("MARKET"));
        assertGt(controller.code.length, 0, "controller missing code on acceptance RPC");
    }

    function _loadMarket(string memory market) internal {
        DeploymentSnapshot memory d = RecordedDeployment.load(recordedRun);
        for (uint256 i; i < d.markets.length; ++i) {
            if (keccak256(bytes(d.markets[i].parameters.name)) != keccak256(bytes(market))) continue;
            _bindTypedDeployment(d, i, pauserCommittee, enableSettlement, address(0));
            // Recorded deployments require historical log scans, unlike in-process fresh fixtures.
            useLocalDeploymentLogs = false;
            marketDeployedBlock = d.markets[i].deployedBlock;
            return;
        }
        revert("Acceptance market is absent from deployment");
    }

    /// @notice Bind independently supplied addresses and expected parameters without preparing or changing the
    /// deployment.
    function _bindTypedDeployment(
        DeploymentSnapshot memory d,
        uint256 index,
        address expectedPauser,
        bool settlement,
        address expectedSteward
    ) internal {
        assertEq(block.chainid, d.protocol.chainId, "deployment chain ID");
        RecordedMarket memory entry = d.markets[index];
        agent = d.protocol.agent;
        executor = d.protocol.executor;
        core = d.protocol.core;
        facade = d.protocol.ownerFacade;
        router = d.protocol.irmRouter;
        factory = d.protocol.factory;
        irmConfigFactory = d.protocol.irmConfigFactory;
        dashboard = d.protocol.dashboard;
        curve = d.protocol.adaptiveCurveIrm;
        circuitBreaker = d.protocol.circuitBreaker;
        resealManager = d.protocol.resealManager;
        morphoBook = d.books.morpho;
        erc4626Book = d.books.erc4626;
        exitBookPauser = d.bookPauser;
        expectedExitBookMaxRequestLifetime = d.bookLifetime;
        bundler3 = d.bundler;
        generalAdapter = d.generalAdapter;
        vaultAdapter = d.vaultAdapter;
        expectedBundlerWeth = d.weth;
        expectedBundlerWstEth = d.wstEth;
        expectedBundlerCore = d.protocol.core;
        expectedMarketParameters = entry.parameters;
        expectedCircuitBreaker = d.circuitBreakerParameters;
        expectedIrmConfigAddress = entry.contracts.irmConfig;
        oracle = entry.contracts.params.oracle;
        guardianSignals = entry.contracts.guardianSignals;
        controller = entry.contracts.controller;
        vault = entry.contracts.vault;
        marketId = Id.unwrap(entry.contracts.id);
        loanToken = entry.parameters.market.loanToken;
        collateralToken = entry.parameters.market.collateralToken;
        lltv = entry.parameters.market.lltv;
        rAdmin = d.protocol.agent;
        rProxyAdmin = d.protocol.agent;
        expectedGuardians = entry.parameters.committee.guardians;
        expectedQuorum = entry.parameters.committee.quorum;
        expectedSuspectWindow = entry.parameters.committee.suspectWindow;
        expectedPriceFeed = entry.priceFeed;
        if (
            expectedPriceFeed.wstEth == address(0)
                && (bytes(entry.priceFeedKind).length == 0
                    || keccak256(bytes(entry.priceFeedKind)) == keccak256("wsteth-rate"))
        ) expectedPriceFeed.wstEth = d.wstEth;
        pauserCommittee = expectedPauser;
        enableSettlement = settlement;
        _expectMarketSteward(expectedSteward);
        useLocalDeploymentLogs = true;
    }

    function _loadExpectedSettlementChoice() internal {
        enableSettlement = vm.envBool("ACCEPTANCE_ENABLE_SETTLEMENT");
    }

    function _loadExpectedPauserCommittee() internal {
        pauserCommittee = vm.envAddress("ACCEPTANCE_PAUSER_COMMITTEE");
        require(pauserCommittee != address(0), "acceptance: CircuitBreaker pauser committee is zero");
    }

    function _loadExpectedSteward() internal {
        _expectMarketSteward(vm.envAddress("ACCEPTANCE_STEWARD"));
    }

    function _loadExpectedFunding() internal {
        _expectFunding(
            vm.envUint("ACCEPTANCE_FEE"),
            vm.envUint("ACCEPTANCE_MIN_CORE_SEED_SHARES"),
            vm.envUint("ACCEPTANCE_MIN_VAULT_SEED_SHARES")
        );
    }

    function _expectFunding(uint256 fee, uint256 coreShares, uint256 vaultShares) internal {
        require(coreShares != 0 && vaultShares != 0, "acceptance: seed thresholds must be nonzero");
        expectedFee = fee;
        minimumCoreSeedShares = coreShares;
        minimumVaultSeedShares = vaultShares;
    }

    function _expectMarketSteward(address steward) internal {
        delete expectedMarketStewards;
        if (steward != address(0)) expectedMarketStewards.push(steward);
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
        if (vaultAdapter != address(0)) {
            assertGt(bundler3.code.length, 0, "Bundler3 missing code");
            assertGt(generalAdapter.code.length, 0, "general adapter missing code");
            assertGt(vaultAdapter.code.length, 0, "vault adapter missing code");
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
        if (vaultAdapter != address(0)) _assertBundlerWiring();

        // Additional direct core, asset, and operational-state checks.
        assertEq(IReadController(controller).LIDO_LEND(), core, "controller.LIDO_LEND");
        assertEq(IReadVault(vault).LIDO_LEND(), core, "vault.LIDO_LEND");
        assertEq(IReadVault(vault).asset(), loanToken, "vault.asset");
        assertFalse(IReadController(controller).isPaused(), "controller is paused");
        assertFalse(IReadController(controller).isFrozen(), "controller is frozen");
        // The curve singleton's per-market config is applied at activation, so its assert lives in
        // `_assertActivated` / `_assertNotYetActivated`, not here.
    }

    /// @dev The adapters' immutables are the dispatcher and token inputs the artifact recorded and the core this
    ///      run owns. The role audits and the instant-activation log scan already prove they hold no privilege.
    function _assertBundlerWiring() internal view {
        IReadGeneralAdapter1 general = IReadGeneralAdapter1(generalAdapter);
        address weth = expectedBundlerWeth;
        address wsteth = expectedBundlerWstEth;
        assertEq(general.BUNDLER3(), bundler3, "generalAdapter.BUNDLER3");
        assertEq(general.MORPHO(), core, "generalAdapter.MORPHO");
        assertEq(general.WRAPPED_NATIVE(), weth, "generalAdapter.WRAPPED_NATIVE");
        assertEq(general.WST_ETH(), wsteth, "generalAdapter.WST_ETH");
        assertEq(general.ST_ETH(), IReadWstEth(wsteth).stETH(), "generalAdapter.ST_ETH");
        assertEq(IReadGeneralAdapter1(vaultAdapter).BUNDLER3(), bundler3, "vaultAdapter.BUNDLER3");
        assertEq(expectedBundlerCore, core, "bundler.toml morpho");
    }

    function _assertOracle() internal {
        address implementation = IReadProxy(oracle).proxy__getImplementation();
        assertGt(implementation.code.length, 0, "oracle implementation missing code");

        bool isWstEth = expectedPriceFeed.wstEth != address(0);
        bool isUsdy = expectedPriceFeed.usdySource != address(0);
        assertTrue(isWstEth != isUsdy, "unknown or ambiguous oracle config");

        if (isWstEth) {
            address expectedWstEth = expectedPriceFeed.wstEth;
            assertEq(expectedWstEth, collateralToken, "oracle WstETH != collateral token");
            address expectedImplementation = address(new WstEthRateOracle(expectedWstEth));
            assertEq(implementation.codehash, expectedImplementation.codehash, "WstETH oracle implementation");
            assertEq(IReadWstEthOracle(oracle).WSTETH(), expectedWstEth, "oracle.WSTETH");
        } else {
            address expectedUsdyOracle = expectedPriceFeed.usdySource;
            address expectedFeed = expectedPriceFeed.feed;
            address expectedLoanToken = expectedPriceFeed.loanToken;
            address expectedCollateralToken = expectedPriceFeed.collateralToken;
            assertEq(expectedLoanToken, loanToken, "oracle loan token != market loan token");
            assertEq(expectedCollateralToken, collateralToken, "oracle USDY != collateral token");
            uint256 expectedMinPrice = expectedPriceFeed.minPrice;
            uint256 expectedMaxPrice = expectedPriceFeed.maxPrice;
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
        assertEq(cb.MIN_PAUSE_DURATION(), expectedCircuitBreaker.minPauseDuration, "CircuitBreaker.MIN_PAUSE_DURATION");
        assertEq(cb.MAX_PAUSE_DURATION(), expectedCircuitBreaker.maxPauseDuration, "CircuitBreaker.MAX_PAUSE_DURATION");
        assertEq(
            cb.MIN_HEARTBEAT_INTERVAL(),
            expectedCircuitBreaker.minHeartbeatInterval,
            "CircuitBreaker.MIN_HEARTBEAT_INTERVAL"
        );
        assertEq(
            cb.MAX_HEARTBEAT_INTERVAL(),
            expectedCircuitBreaker.maxHeartbeatInterval,
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
        assertEq(IReadController(controller).supplyCap(), expectedMarketParameters.market.supplyCap, "supplyCap");

        CollateralActivationConfig memory c = IReadController(controller).collateralActivationConfig();
        assertEq(
            uint256(c.minActivationDelay),
            uint256(expectedMarketParameters.market.activationConfig.minActivationDelay),
            "minDelay"
        );
        assertEq(
            uint256(c.maxActivationDelay),
            uint256(expectedMarketParameters.market.activationConfig.maxActivationDelay),
            "maxDelay"
        );
        assertEq(
            uint256(c.maxDelayInflow),
            uint256(expectedMarketParameters.market.activationConfig.maxDelayInflow),
            "maxDelayInflow"
        );
        assertEq(
            uint256(c.activatingLockDuration),
            uint256(expectedMarketParameters.market.activationConfig.activatingLockDuration),
            "lockDur"
        );
        assertEq(
            uint256(c.minActivationAmount),
            uint256(expectedMarketParameters.market.activationConfig.minActivationAmount),
            "minAmt"
        );
        assertEq(
            uint256(c.minDepositAmount),
            uint256(expectedMarketParameters.market.activationConfig.minDepositAmount),
            "minDeposit"
        );
        assertEq(
            uint256(c.maxGuardiansQuorumDelay),
            uint256(expectedMarketParameters.market.activationConfig.maxGuardiansQuorumDelay),
            "qDelay"
        );
        assertEq(
            uint256(c.delayPerStrike),
            uint256(expectedMarketParameters.market.activationConfig.delayPerStrike),
            "perStrike"
        );
        assertEq(
            uint256(c.delayPerSuspect),
            uint256(expectedMarketParameters.market.activationConfig.delayPerSuspect),
            "perSuspect"
        );

        SettlementConfig memory s = IReadController(controller).settlementConfig();
        assertEq(
            uint256(s.sliceFloorBps),
            uint256(expectedMarketParameters.market.settlementConfig.sliceFloorBps),
            "sliceBps"
        );
        assertEq(
            uint256(s.sliceFloorAssets),
            uint256(expectedMarketParameters.market.settlementConfig.sliceFloorAssets),
            "sliceAssets"
        );
        assertEq(
            uint256(s.fullCutBelowCollateral),
            uint256(expectedMarketParameters.market.settlementConfig.fullCutBelowCollateral),
            "fullCut"
        );
        assertEq(uint256(s.ltvStepBps), uint256(expectedMarketParameters.market.settlementConfig.ltvStepBps), "ltvStep");

        address irmConfig = _expectedIrmConfig();
        _assertCurveParams(ICurveConfig(irmConfig).getCurveParams());
        assertEq(
            IIrmConfigFactory(irmConfigFactory).getAdaptiveCurveConfig(_expectedCurveParams()),
            irmConfig,
            "IRM config factory entry"
        );

        _assertVaultIdentity();
    }

    /// @notice The vault's ERC-20 identity, fixed by `initialize` and unreachable afterwards.
    /// @dev Shares carry the loan token's decimals plus the virtual-share offset the vault freezes at init.
    ///      The offset closes the gap up to 18, and is zero for a loan token already at or above it.
    function _assertVaultIdentity() internal view {
        IReadVault deployedVault = IReadVault(vault);
        assertEq(deployedVault.name(), expectedMarketParameters.wrapper.name, "vault.name");
        assertEq(deployedVault.symbol(), expectedMarketParameters.wrapper.symbol, "vault.symbol");

        uint256 loanDecimals = uint256(IReadDecimals(loanToken).decimals());
        assertEq(uint256(deployedVault.decimals()), Math.max(18, loanDecimals), "vault.decimals");
    }

    /// @dev The per-market curve params used by the activation simulation.
    function _expectedCurveParams() internal view returns (AdaptiveCurveParams memory) {
        return expectedMarketParameters.curve;
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
            IReadDashboard(dashboard).marketStewards(Id.wrap(marketId)), expectedMarketStewards, "market steward"
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
        bytes memory creationCode = vm.getCode("CircuitBreaker.sol:CircuitBreaker");
        bytes memory initCode = abi.encodePacked(
            creationCode,
            abi.encode(
                executor,
                expectedCircuitBreaker.minPauseDuration,
                expectedCircuitBreaker.maxPauseDuration,
                expectedCircuitBreaker.minHeartbeatInterval,
                expectedCircuitBreaker.maxHeartbeatInterval,
                expectedCircuitBreaker.initialPauseDuration,
                expectedCircuitBreaker.initialHeartbeatInterval
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

    /// @notice Every accounting variable on the market, the vault, and the controller is still zero, and no
    ///         protocol fee is set.
    /// @dev Readiness only: before the motion the core has no market under this id. The motion itself preseeds
    ///      the market and the vault, and sets any non-zero initial fee.
    function _assertZeroState() internal view {
        (uint128 tSupplyA, uint128 tSupplyS, uint128 tBorrowA, uint128 tBorrowS,, uint128 fee) =
            IReadCore(core).market(marketId);
        assertEq(uint256(tSupplyA), 0, "core totalSupplyAssets");
        assertEq(uint256(tSupplyS), 0, "core totalSupplyShares");
        assertEq(uint256(tBorrowA), 0, "core totalBorrowAssets");
        assertEq(uint256(tBorrowS), 0, "core totalBorrowShares");
        assertEq(uint256(fee), 0, "core market fee");

        IReadVault deployedVault = IReadVault(vault);
        assertEq(deployedVault.totalSupply(), 0, "vault.totalSupply");
        assertEq(deployedVault.totalAssets(), 0, "vault.totalAssets");
        assertEq(deployedVault.managedSupplyShares(), 0, "vault.managedSupplyShares");

        IReadController deployedController = IReadController(controller);
        assertEq(deployedController.currentInflow(), 0, "controller.currentInflow");
        assertEq(deployedController.settlementBorrowersCount(), 0, "controller.settlementBorrowersCount");
        assertFalse(deployedController.hasBadDebt(), "controller.hasBadDebt");
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

    function _assertActivationFunding() internal view {
        require(minimumCoreSeedShares != 0 && minimumVaultSeedShares != 0, "acceptance: seed expectations missing");
        (,,,,, uint128 fee) = IReadCore(core).market(marketId);
        assertEq(uint256(fee), expectedFee, "activation fee");
        assertGe(
            ILidoLend(core).position(Id.wrap(marketId), PRESEED_RECIPIENT).supplyShares,
            minimumCoreSeedShares,
            "core preseed shares"
        );
        assertGe(IReadVault(vault).balanceOf(PRESEED_RECIPIENT), minimumVaultSeedShares, "vault preseed shares");
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
        irmConfig = expectedIrmConfigAddress;
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
        if (useLocalDeploymentLogs) {
            Vm.Log[] memory localLogs = vm.getRecordedLogs();
            for (uint256 i; i < localLogs.length; ++i) {
                if (localLogs[i].topics.length >= 2 && localLogs[i].topics[0] == INSTANT_ACTIVATION_SET_SIG) {
                    localActivationCandidates.push(
                        ActivationCandidate({
                            controller: localLogs[i].emitter, caller: address(uint160(uint256(localLogs[i].topics[1])))
                        })
                    );
                }
            }
            address[] memory candidates = new address[](localActivationCandidates.length);
            uint256 count;
            for (uint256 i; i < localActivationCandidates.length; ++i) {
                if (localActivationCandidates[i].controller == controller) {
                    candidates[count++] = localActivationCandidates[i].caller;
                }
            }
            assembly ("memory-safe") { mstore(candidates, count) }
            _assertInstantActivationCallers(_dedupAddr(candidates), new address[](0));
            return;
        }
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
        holders[1] = _arr1(executor);
        holders[2] = new address[](0);
        holders[3] = new address[](0);
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
