// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

// The router's `Id` is a distinct UDVT (the IRM submodule's nested core copy); same underlying bytes32.
import {Id as IrmId} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";
import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";

import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignalsView} from "../../src/interfaces/IGuardianSignalsView.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

contract CircuitBreakerStub {}

/// @notice Scenario for the permissionless factory. It deploys fully wired controller and vault proxies but
///         leaves core market creation and IRM routing to a separate activation transaction.
contract MarketFactoryScenarioTest is Test {
    using MarketParamsLib for MarketParams;

    address internal constant GOVERNANCE = address(0xA11CE);

    address internal caller;
    address internal marketAdmin;

    ILidoLend internal core;
    LidoLendOwner internal facade;
    IIrmRouter internal router;
    address internal riskStewardDashboard;
    address internal circuitBreaker;
    address internal controllerImpl;
    address internal erc4626WrapperImpl;
    address internal guardianSignalsImpl;
    address internal guardianSignals;
    LidoLendMarketFactory internal factory;

    function setUp() external {
        caller = makeAddr("caller");
        marketAdmin = makeAddr("marketAdmin");

        core = ILidoLend(
            address(
                new OssifiableProxy(
                    address(new LidoLend()), GOVERNANCE, abi.encodeWithSignature("initialize(address)", GOVERNANCE)
                )
            )
        );
        facade = new LidoLendOwner(core, GOVERNANCE, GOVERNANCE, address(0));
        vm.prank(GOVERNANCE);
        core.setOwner(address(facade));

        router = IIrmRouter(
            address(
                new OssifiableProxy(
                    address(new IrmRouter(address(core))),
                    GOVERNANCE,
                    abi.encodeWithSignature("initialize(address,address)", GOVERNANCE, GOVERNANCE)
                )
            )
        );
        riskStewardDashboard = address(new RiskStewardDashboard(GOVERNANCE, core));
        circuitBreaker = address(new CircuitBreakerStub());

        controllerImpl = address(new LidoLendMarketController(IMorpho(address(core))));
        erc4626WrapperImpl = address(new LidoLendERC4626(address(core)));
        guardianSignalsImpl = address(new GuardianSignals());
        factory = new LidoLendMarketFactory(
            LidoLendMarketFactory.Implementations({
                controller: controllerImpl, erc4626Wrapper: erc4626WrapperImpl, guardianSignals: guardianSignalsImpl
            }),
            _dependencies(router, riskStewardDashboard, circuitBreaker),
            marketAdmin
        );

        vm.prank(caller);
        guardianSignals = factory.deployGuardianSignals(_guardianSpec(), keccak256("primary"));
    }

    function test_deployMarketComponents_producesInertWiredComponents() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec = _erc4626WrapperSpec("A");
        (Id marketId, address controllerAddress, address erc4626Wrapper) =
            _deployMarketComponents(market, erc4626WrapperSpec);

        assertEq(
            IOssifiableProxy(controllerAddress).proxy__getImplementation(), factory.CONTROLLER_IMPL(), "controller impl"
        );
        assertEq(
            IOssifiableProxy(erc4626Wrapper).proxy__getImplementation(),
            factory.ERC4626_WRAPPER_IMPL(),
            "ERC-4626 wrapper impl"
        );

        LidoLendMarketController controller = LidoLendMarketController(controllerAddress);
        assertEq(Id.unwrap(controller.marketId()), Id.unwrap(marketId), "controller market id");
        assertEq(controller.guardianSignals(), guardianSignals, "controller guardian signals");
        assertEq(controller.supplyCap(), market.supplyCap, "controller supply cap");
        _assertActivationConfigEq(controller.collateralActivationConfig(), market.activationConfig);
        _assertSettlementConfigEq(controller.settlementConfig(), market.settlementConfig);
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), marketAdmin), "admin");
        assertFalse(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(factory)), "factory keeps no admin");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), address(facade)), "facade manager");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), riskStewardDashboard), "dashboard manager");
        assertTrue(controller.hasRole(controller.PAUSER_ROLE(), circuitBreaker), "circuit breaker pauser");
        assertTrue(controller.hasRole(controller.FREEZER_ROLE(), riskStewardDashboard), "dashboard freezer");
        assertTrue(controller.hasRole(controller.UNFREEZER_ROLE(), address(facade)), "facade unfreezer");
        assertEq(controller.getRoleMemberCount(controller.RESUMER_ROLE()), 0, "no initial resumer");

        assertEq(IOssifiableProxy(controllerAddress).proxy__getAdmin(), marketAdmin, "controller proxy admin");
        assertEq(IOssifiableProxy(erc4626Wrapper).proxy__getAdmin(), marketAdmin, "wrapper proxy admin");

        LidoLendERC4626 wrapper = LidoLendERC4626(erc4626Wrapper);
        assertEq(address(wrapper.controller()), controllerAddress, "wrapper controller");
        assertEq(wrapper.name(), erc4626WrapperSpec.name, "wrapper name");
        assertEq(wrapper.symbol(), erc4626WrapperSpec.symbol, "wrapper symbol");

        assertEq(core.market(marketId).lastUpdate, 0, "market remains uncreated");
        assertEq(core.marketController(marketId), address(0), "core controller remains unset");
        assertEq(address(router.marketIrm(_toIrmId(marketId))), address(0), "IRM route remains unset");
    }

    function test_deployMarketComponents_emitsDeploymentEvents() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec = _erc4626WrapperSpec("A");
        Id expectedId = _marketParams(market).id();
        address expectedController = _predictController(market, caller);
        address expectedWrapper = _predictWrapper(market, erc4626WrapperSpec, expectedController, caller);

        vm.expectEmit(true, true, true, true, address(factory));
        emit LidoLendMarketFactory.MarketControllerDeployed(expectedId, expectedController, guardianSignals);
        vm.expectEmit(true, true, true, true, address(factory));
        emit LidoLendMarketFactory.ERC4626WrapperDeployed(expectedId, expectedController, expectedWrapper);
        vm.expectEmit(true, true, true, true, address(factory));
        emit LidoLendMarketFactory.MarketComponentsDeployed(
            expectedId, expectedController, expectedWrapper, guardianSignals
        );

        _deployMarketComponents(market, erc4626WrapperSpec);
    }

    /// @dev The audit trail for a deployment: every proxy the factory creates logs its implementation and the exact
    ///      constructor arguments it was created with, so a log reader can check a component against them without
    ///      decoding the transaction that created it.
    function test_deployMarketComponents_emitsProxyDeployedPerComponent() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec = _erc4626WrapperSpec("A");
        address expectedController = _predictController(market, caller);
        address expectedWrapper = _predictWrapper(market, erc4626WrapperSpec, expectedController, caller);

        vm.expectEmit(true, true, true, true, address(factory));
        emit LidoLendMarketFactory.ProxyDeployed(
            expectedController, controllerImpl, marketAdmin, _controllerInitData(market), _proxySalt(caller, bytes32(0))
        );
        vm.expectEmit(true, true, true, true, address(factory));
        emit LidoLendMarketFactory.ProxyDeployed(
            expectedWrapper,
            erc4626WrapperImpl,
            marketAdmin,
            _wrapperInitData(market, erc4626WrapperSpec, expectedController),
            _proxySalt(caller, bytes32(0))
        );

        _deployMarketComponents(market, erc4626WrapperSpec);
    }

    /// @dev A deploy script records the addresses its simulation returned, so those addresses must not depend on
    ///      anything a third party controls. Here another caller advances the factory's transaction count and also
    ///      deploys the very same reviewed specification first, and the components still land where they were
    ///      predicted, at addresses that caller could not reach.
    function test_deployMarketComponents_addressesSurviveAnotherCallerDeployingFirst() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec = _erc4626WrapperSpec("A");
        address predictedController = _predictController(market, caller);
        address predictedWrapper = _predictWrapper(market, erc4626WrapperSpec, predictedController, caller);

        vm.prank(makeAddr("frontRunner"));
        (, address theirController, address theirWrapper) = factory.deployMarketComponents(market, erc4626WrapperSpec);

        (, address controllerAddress, address erc4626Wrapper) = _deployMarketComponents(market, erc4626WrapperSpec);

        assertEq(controllerAddress, predictedController, "controller as predicted");
        assertEq(erc4626Wrapper, predictedWrapper, "wrapper as predicted");
        assertTrue(theirController != predictedController, "another caller cannot take the controller address");
        assertTrue(theirWrapper != predictedWrapper, "another caller cannot take the wrapper address");
    }

    /// @dev The narrowing that comes with deterministic addresses: an exact duplicate of something the same deployer
    ///      already created has nowhere to go. Anything that tells two components apart also moves their addresses
    ///      apart, so only a true duplicate is refused. The address collision carries no revert data of its own.
    function testRevert_deployMarketComponents_rejectsAnIdenticalRedeploy() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        _deployMarketComponents(market, _erc4626WrapperSpec("A"));

        vm.prank(caller);
        vm.expectRevert();
        factory.deployMarketComponents(market, _erc4626WrapperSpec("A"));
    }

    function test_deployMarketComponents_secondMarketReusesImplementations() external {
        (MockERC20 loanA, MockERC20 collateralA, address oracleA) = _deployTokensAndOracle("A", 1.05e36);
        (MockERC20 loanB, MockERC20 collateralB, address oracleB) = _deployTokensAndOracle("B", 0.92e36);

        (, address firstControllerAddress, address firstWrapper) =
            _deployMarketComponents(_marketSpec(loanA, collateralA, oracleA), _erc4626WrapperSpec("A"));
        (, address secondControllerAddress, address secondWrapper) =
            _deployMarketComponents(_marketSpec(loanB, collateralB, oracleB), _erc4626WrapperSpec("B"));

        assertTrue(firstControllerAddress != secondControllerAddress, "distinct controllers");
        assertTrue(firstWrapper != secondWrapper, "distinct wrappers");
        assertEq(
            IOssifiableProxy(firstControllerAddress).proxy__getImplementation(),
            IOssifiableProxy(secondControllerAddress).proxy__getImplementation(),
            "shared controller implementation"
        );
        assertEq(
            IOssifiableProxy(firstWrapper).proxy__getImplementation(),
            IOssifiableProxy(secondWrapper).proxy__getImplementation(),
            "shared ERC-4626 wrapper implementation"
        );

        LidoLendMarketController firstController = LidoLendMarketController(firstControllerAddress);
        LidoLendMarketController secondController = LidoLendMarketController(secondControllerAddress);
        assertEq(firstController.getRoleMemberCount(firstController.PAUSER_ROLE()), 1, "first pauser count");
        assertEq(secondController.getRoleMemberCount(secondController.PAUSER_ROLE()), 1, "second pauser count");
        assertTrue(firstController.hasRole(firstController.PAUSER_ROLE(), circuitBreaker), "first shared pauser");
        assertTrue(secondController.hasRole(secondController.PAUSER_ROLE(), circuitBreaker), "second shared pauser");
        assertEq(firstController.getRoleMemberCount(firstController.RESUMER_ROLE()), 0, "first resumer count");
        assertEq(secondController.getRoleMemberCount(secondController.RESUMER_ROLE()), 0, "second resumer count");
    }

    function testRevert_deployMarketComponents_marketAlreadyExists() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        Id marketId = _marketParams(market).id();

        vm.mockCall(
            address(core),
            abi.encodeWithSelector(IMorpho.market.selector, marketId),
            abi.encode(uint128(0), uint128(0), uint128(0), uint128(0), uint128(1), uint128(0))
        );

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.MarketAlreadyExists.selector, marketId));
        factory.deployMarketComponents(market, _erc4626WrapperSpec("A"));
    }

    function testRevert_deployMarketComponents_nonContractOracle() external {
        (MockERC20 loan, MockERC20 collateral,) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, address(0));

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.NotContract.selector, address(0)));
        factory.deployMarketComponents(market, _erc4626WrapperSpec("A"));

        market.oracle = makeAddr("not an oracle");
        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.NotContract.selector, market.oracle));
        factory.deployMarketComponents(market, _erc4626WrapperSpec("A"));
    }

    function testRevert_deployMarketComponents_invalidGuardianProxy() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        market.guardianSignals = makeAddr("not a guardian proxy");

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.NotContract.selector, market.guardianSignals));
        factory.deployMarketComponents(market, _erc4626WrapperSpec("A"));
    }

    function testRevert_deployMarketComponents_invalidLltv() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        market.lltv = 1e18;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.InvalidLltv.selector, 1e18));
        factory.deployMarketComponents(market, _erc4626WrapperSpec("A"));
    }

    function testRevert_constructor_routerUsesAnotherCore() external {
        ILidoLend otherCore = ILidoLend(
            address(
                new OssifiableProxy(
                    address(new LidoLend()), GOVERNANCE, abi.encodeWithSignature("initialize(address)", GOVERNANCE)
                )
            )
        );
        IIrmRouter mismatchedRouter = IIrmRouter(
            address(
                new OssifiableProxy(
                    address(new IrmRouter(address(otherCore))),
                    GOVERNANCE,
                    abi.encodeWithSignature("initialize(address,address)", GOVERNANCE, GOVERNANCE)
                )
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.LidoLendMismatch.selector,
                address(mismatchedRouter),
                address(core),
                address(otherCore)
            )
        );
        new LidoLendMarketFactory(
            _implementations(controllerImpl, erc4626WrapperImpl),
            _dependencies(mismatchedRouter, riskStewardDashboard, circuitBreaker),
            marketAdmin
        );
    }

    function testRevert_constructor_controllerImplementationUsesAnotherCore() external {
        ILidoLend otherCore = _deployCore(GOVERNANCE);
        address otherControllerImpl = address(new LidoLendMarketController(IMorpho(address(otherCore))));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.LidoLendMismatch.selector, otherControllerImpl, address(core), address(otherCore)
            )
        );
        new LidoLendMarketFactory(
            _implementations(otherControllerImpl, erc4626WrapperImpl),
            _dependencies(router, riskStewardDashboard, circuitBreaker),
            marketAdmin
        );
    }

    function testRevert_constructor_erc4626WrapperImplementationUsesAnotherCore() external {
        ILidoLend otherCore = _deployCore(GOVERNANCE);
        address otherVaultImpl = address(new LidoLendERC4626(address(otherCore)));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.LidoLendMismatch.selector, otherVaultImpl, address(core), address(otherCore)
            )
        );
        new LidoLendMarketFactory(
            _implementations(controllerImpl, otherVaultImpl),
            _dependencies(router, riskStewardDashboard, circuitBreaker),
            marketAdmin
        );
    }

    function testRevert_constructor_riskStewardDashboardUsesAnotherCore() external {
        ILidoLend otherCore = _deployCore(GOVERNANCE);
        address otherDashboard = address(new RiskStewardDashboard(GOVERNANCE, otherCore));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.LidoLendMismatch.selector, otherDashboard, address(core), address(otherCore)
            )
        );
        _newFactory(otherDashboard, circuitBreaker, marketAdmin);
    }

    function testRevert_constructor_lidoLendOwnerUsesAnotherCore() external {
        ILidoLend otherCore = _deployCore(GOVERNANCE);
        LidoLendOwner otherFacade = new LidoLendOwner(otherCore, GOVERNANCE, address(0), address(0));
        LidoLendMarketFactory.Dependencies memory dependencies =
            _dependencies(router, riskStewardDashboard, circuitBreaker);
        dependencies.lidoLendOwner = address(otherFacade);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.LidoLendMismatch.selector, address(otherFacade), address(core), address(otherCore)
            )
        );
        new LidoLendMarketFactory(_implementations(controllerImpl, erc4626WrapperImpl), dependencies, marketAdmin);
    }

    function testRevert_constructor_zeroAdmin() external {
        vm.expectRevert(LidoLendMarketFactory.AdminZeroAddress.selector);
        _newFactory(riskStewardDashboard, circuitBreaker, address(0));
    }

    function test_constructor_doesNotValidateCircuitBreakerCode() external {
        address invalidCircuitBreaker = makeAddr("invalidCircuitBreaker");
        LidoLendMarketFactory deployed = _newFactory(riskStewardDashboard, invalidCircuitBreaker, marketAdmin);
        assertEq(deployed.CIRCUIT_BREAKER(), invalidCircuitBreaker, "circuit breaker");
    }

    function test_deployMarketComponents_afterCoreOwnershipMoves_succeeds() external {
        address newOwner = makeAddr("newCoreOwner");
        vm.prank(GOVERNANCE);
        facade.transferLidoLendOwnership(newOwner);

        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        (Id marketId, address controllerAddress, address erc4626Wrapper) =
            _deployMarketComponents(_marketSpec(loan, collateral, oracle), _erc4626WrapperSpec("A"));

        assertEq(Id.unwrap(LidoLendMarketController(controllerAddress).marketId()), Id.unwrap(marketId), "market id");
        assertEq(address(LidoLendERC4626(erc4626Wrapper).controller()), controllerAddress, "controller");
    }

    /// @dev Two committees can be configured identically and still want registries of their own. Nothing in the
    ///      specification separates them — the suspect window is applied after initialization, so it does not reach
    ///      the address either — which is what the caller-chosen salt is for.
    function test_deployGuardianSignals_identicalSpecsSeparatedBySalt() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();

        vm.prank(caller);
        address first = factory.deployGuardianSignals(spec, keccak256("group-a"));
        vm.prank(caller);
        address second = factory.deployGuardianSignals(spec, keccak256("group-b"));

        assertTrue(first != second, "one registry per salt");
        assertEq(first, _predictGuardianSignals(spec, caller, keccak256("group-a")), "first as predicted");
        assertEq(second, _predictGuardianSignals(spec, caller, keccak256("group-b")), "second as predicted");
        factory.validateGuardianSignals(first, spec);
        factory.validateGuardianSignals(second, spec);
    }

    /// @dev Reusing a salt for the same committee resolves to the registry that already exists. The address
    ///      collision carries no revert data of its own.
    function testRevert_deployGuardianSignals_rejectsAReusedSalt() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        vm.prank(caller);
        factory.deployGuardianSignals(spec, keccak256("group-a"));

        vm.prank(caller);
        vm.expectRevert();
        factory.deployGuardianSignals(spec, keccak256("group-a"));
    }

    function test_deployGuardianSignals_emitsProxyDeployed() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        bytes32 callerSalt = keccak256("logged-registry");
        address expectedRegistry = _predictGuardianSignals(spec, caller, callerSalt);

        vm.expectEmit(true, true, true, true, address(factory));
        emit LidoLendMarketFactory.ProxyDeployed(
            expectedRegistry,
            guardianSignalsImpl,
            marketAdmin,
            _guardianSignalsInitData(spec),
            _proxySalt(caller, callerSalt)
        );
        vm.prank(caller);
        factory.deployGuardianSignals(spec, callerSalt);
    }

    function test_deployGuardianSignals_producesWiredRegistry() external {
        address[] memory guardianSet = new address[](2);
        guardianSet[0] = makeAddr("guardian1");
        guardianSet[1] = makeAddr("guardian2");
        LidoLendMarketFactory.GuardianSpec memory spec =
            LidoLendMarketFactory.GuardianSpec({guardians: guardianSet, quorum: 2, suspectWindow: 3600});
        address expectedRegistry = _predictGuardianSignals(spec, caller, keccak256("wired-registry"));

        vm.expectEmit(true, true, true, true, address(factory));
        emit LidoLendMarketFactory.GuardianSignalsDeployed(expectedRegistry);
        vm.prank(caller);
        address deployed = factory.deployGuardianSignals(spec, keccak256("wired-registry"));

        assertEq(IOssifiableProxy(deployed).proxy__getImplementation(), guardianSignalsImpl, "implementation");
        assertEq(IOssifiableProxy(deployed).proxy__getAdmin(), marketAdmin, "proxy admin");

        GuardianSignals signals = GuardianSignals(deployed);
        assertEq(signals.getQuorum(), 2, "quorum");
        assertEq(signals.getSuspectWindow(), 3600, "suspect window");
        assertTrue(signals.isGuardian(guardianSet[0]), "guardian1");
        assertTrue(signals.isGuardian(guardianSet[1]), "guardian2");
        assertTrue(signals.hasRole(signals.DEFAULT_ADMIN_ROLE(), marketAdmin), "admin");
        assertTrue(signals.hasRole(signals.MANAGER_ROLE(), address(facade)), "facade manager");
        assertTrue(signals.hasRole(signals.ACCESS_RESTORER_ROLE(), address(facade)), "facade restorer");
        assertEq(signals.getRoleMemberCount(signals.ACCESS_LIMITER_ROLE()), 0, "access limiter count");
        assertFalse(signals.hasRole(signals.DEFAULT_ADMIN_ROLE(), address(factory)), "factory keeps no admin");
        assertFalse(signals.hasRole(signals.MANAGER_ROLE(), address(factory)), "factory keeps no manager");
    }

    function _deployMarketComponents(
        LidoLendMarketFactory.MarketSpec memory market,
        LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec
    ) internal returns (Id marketId, address controller, address erc4626Wrapper) {
        vm.prank(caller);
        return factory.deployMarketComponents(market, erc4626WrapperSpec);
    }

    function _deployCore(address owner) internal returns (ILidoLend deployedCore) {
        deployedCore = ILidoLend(
            address(
                new OssifiableProxy(
                    address(new LidoLend()), owner, abi.encodeWithSignature("initialize(address)", owner)
                )
            )
        );
    }

    function _newFactory(address dashboard, address breaker, address admin)
        internal
        returns (LidoLendMarketFactory deployed)
    {
        deployed = new LidoLendMarketFactory(
            _implementations(controllerImpl, erc4626WrapperImpl), _dependencies(router, dashboard, breaker), admin
        );
    }

    function _implementations(address controller, address erc4626Wrapper)
        internal
        view
        returns (LidoLendMarketFactory.Implementations memory)
    {
        return LidoLendMarketFactory.Implementations({
            controller: controller, erc4626Wrapper: erc4626Wrapper, guardianSignals: guardianSignalsImpl
        });
    }

    function _dependencies(IIrmRouter router_, address dashboard, address breaker)
        internal
        view
        returns (LidoLendMarketFactory.Dependencies memory)
    {
        return LidoLendMarketFactory.Dependencies({
            lidoLend: address(core),
            irmRouter: address(router_),
            lidoLendOwner: address(facade),
            circuitBreaker: breaker,
            riskStewardDashboard: dashboard
        });
    }

    /// @dev The proxy constructor arguments the factory must have used, recomposed from the same public inputs the
    ///      deployment address is derived from.
    function _proxyConstructorArgs(address implementation, bytes memory initData) private view returns (bytes memory) {
        return abi.encode(implementation, marketAdmin, initData);
    }

    /// @dev The `CREATE2` salt a deployment must have used: the caller, narrowed by the salt that caller passed.
    function _proxySalt(address deployer, bytes32 callerSalt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, callerSalt));
    }

    /// @dev Derives a deployment address from public inputs alone: the factory, the deployer, and the data the
    ///      component is initialized with. Predicting from outside the factory is the property being exercised.
    function _predictProxy(address implementation, bytes memory initData, address deployer, bytes32 callerSalt)
        private
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(OssifiableProxy).creationCode, _proxyConstructorArgs(implementation, initData))
        );
        return vm.computeCreate2Address(_proxySalt(deployer, callerSalt), initCodeHash, address(factory));
    }

    function _controllerInitData(LidoLendMarketFactory.MarketSpec memory market) private view returns (bytes memory) {
        return abi.encodeCall(
            LidoLendMarketController.initialize,
            (
                _marketParams(market).id(),
                address(factory),
                market.supplyCap,
                IGuardianSignalsView(market.guardianSignals),
                market.activationConfig,
                market.settlementConfig
            )
        );
    }

    function _wrapperInitData(
        LidoLendMarketFactory.MarketSpec memory market,
        LidoLendMarketFactory.ERC4626WrapperSpec memory wrapperSpec,
        address controllerAddress
    ) private view returns (bytes memory) {
        return abi.encodeCall(
            LidoLendERC4626.initialize, (_marketParams(market), controllerAddress, wrapperSpec.name, wrapperSpec.symbol)
        );
    }

    function _guardianSignalsInitData(LidoLendMarketFactory.GuardianSpec memory spec)
        private
        view
        returns (bytes memory)
    {
        return abi.encodeCall(GuardianSignals.initialize, (address(factory), spec.guardians, spec.quorum));
    }

    function _predictController(LidoLendMarketFactory.MarketSpec memory market, address deployer)
        private
        view
        returns (address)
    {
        return _predictProxy(controllerImpl, _controllerInitData(market), deployer, bytes32(0));
    }

    function _predictWrapper(
        LidoLendMarketFactory.MarketSpec memory market,
        LidoLendMarketFactory.ERC4626WrapperSpec memory wrapperSpec,
        address controllerAddress,
        address deployer
    ) private view returns (address) {
        return _predictProxy(
            erc4626WrapperImpl, _wrapperInitData(market, wrapperSpec, controllerAddress), deployer, bytes32(0)
        );
    }

    function _predictGuardianSignals(
        LidoLendMarketFactory.GuardianSpec memory spec,
        address deployer,
        bytes32 callerSalt
    ) private view returns (address) {
        return _predictProxy(guardianSignalsImpl, _guardianSignalsInitData(spec), deployer, callerSalt);
    }

    function _marketParams(LidoLendMarketFactory.MarketSpec memory market) internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: market.loanToken,
            collateralToken: market.collateralToken,
            oracle: market.oracle,
            irm: address(router),
            lltv: market.lltv
        });
    }

    /// @dev The router's `Id` is a distinct UDVT (nested core copy); it is the same bytes32.
    function _toIrmId(Id marketId) internal pure returns (IrmId) {
        return IrmId.wrap(Id.unwrap(marketId));
    }

    function _deployTokensAndOracle(string memory salt, uint256 price)
        internal
        returns (MockERC20 loan, MockERC20 collateral, address oracle)
    {
        loan = new MockERC20(string.concat("Loan ", salt), string.concat("LOAN", salt), 18);
        collateral = new MockERC20(string.concat("Collateral ", salt), string.concat("COLL", salt), 18);
        oracle = address(
            new OssifiableProxy(
                address(new MockPriceOracle()), GOVERNANCE, abi.encodeWithSignature("initialize(uint256)", price)
            )
        );
    }

    function _marketSpec(MockERC20 loan, MockERC20 collateral, address oracle)
        internal
        view
        returns (LidoLendMarketFactory.MarketSpec memory)
    {
        return LidoLendMarketFactory.MarketSpec({
            loanToken: address(loan),
            collateralToken: address(collateral),
            oracle: oracle,
            lltv: 0.8e18,
            guardianSignals: guardianSignals,
            supplyCap: 1_000 ether,
            activationConfig: CollateralActivationConfig({
                minActivationDelay: 11 minutes,
                maxActivationDelay: 123 minutes,
                maxDelayInflow: 10_003 ether,
                activatingLockDuration: 19 minutes,
                minActivationAmount: 23 ether,
                minDepositAmount: 0,
                maxGuardiansQuorumDelay: 3 hours,
                delayPerStrike: 29 minutes,
                delayPerSuspect: 31 minutes
            }),
            settlementConfig: SettlementConfig({
                sliceFloorBps: 137, sliceFloorAssets: 41 ether, fullCutBelowCollateral: 43 ether, ltvStepBps: 149
            })
        });
    }

    function _erc4626WrapperSpec(string memory salt)
        internal
        pure
        returns (LidoLendMarketFactory.ERC4626WrapperSpec memory)
    {
        return LidoLendMarketFactory.ERC4626WrapperSpec({
            name: string.concat("Lido Loan Vault ", salt), symbol: string.concat("lidoLOAN", salt)
        });
    }

    function _guardianSpec() internal pure returns (LidoLendMarketFactory.GuardianSpec memory spec) {
        spec.guardians = new address[](1);
        spec.guardians[0] = GOVERNANCE;
        spec.quorum = 1;
        spec.suspectWindow = 0;
    }

    function _assertActivationConfigEq(
        CollateralActivationConfig memory actual,
        CollateralActivationConfig memory expected
    ) internal pure {
        assertEq(actual.minActivationDelay, expected.minActivationDelay, "min activation delay");
        assertEq(actual.maxActivationDelay, expected.maxActivationDelay, "max activation delay");
        assertEq(actual.maxDelayInflow, expected.maxDelayInflow, "max delay inflow");
        assertEq(actual.activatingLockDuration, expected.activatingLockDuration, "activating lock duration");
        assertEq(actual.minActivationAmount, expected.minActivationAmount, "min activation amount");
        assertEq(actual.maxGuardiansQuorumDelay, expected.maxGuardiansQuorumDelay, "max guardians quorum delay");
        assertEq(actual.delayPerStrike, expected.delayPerStrike, "delay per strike");
        assertEq(actual.delayPerSuspect, expected.delayPerSuspect, "delay per suspect");
    }

    function _assertSettlementConfigEq(SettlementConfig memory actual, SettlementConfig memory expected) internal pure {
        assertEq(actual.sliceFloorBps, expected.sliceFloorBps, "slice floor bps");
        assertEq(actual.sliceFloorAssets, expected.sliceFloorAssets, "slice floor assets");
        assertEq(actual.fullCutBelowCollateral, expected.fullCutBelowCollateral, "full cut below collateral");
        assertEq(actual.ltvStepBps, expected.ltvStepBps, "LTV step bps");
    }
}
