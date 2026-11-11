// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, IMorpho, Market, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

contract MarketFactoryRouterStub {
    address public immutable MORPHO;

    constructor(address morpho) {
        MORPHO = morpho;
    }

    function borrowRate(MarketParams memory, Market memory) external pure returns (uint256) {
        return 0;
    }
}

contract MarketFactoryCoreBoundStub {
    address public immutable LIDO_LEND;

    constructor(address lidoLend) {
        LIDO_LEND = lidoLend;
    }
}

contract MarketFactoryControllerBindingStub {
    address public immutable LIDO_LEND;
    Id public immutable marketId;

    constructor(address lidoLend, Id marketId_) {
        LIDO_LEND = lidoLend;
        marketId = marketId_;
    }
}

contract MarketFactoryCompatibleProxy is OssifiableProxy {
    constructor(address implementation, address admin, bytes memory data)
        OssifiableProxy(implementation, admin, data)
    {}

    function proxyKind() external pure returns (bytes32) {
        return keccak256("compatible-test-proxy");
    }
}

contract LidoLendMarketFactoryRoleValidationTest is Test {
    using MarketParamsLib for MarketParams;

    address private constant GOVERNANCE = address(0xA11CE);

    ILidoLend internal core;
    LidoLendMarketFactory internal factory;
    LidoLendOwner internal lidoLendOwner;
    address internal riskStewardDashboard;
    address internal circuitBreaker;
    address internal controller;
    address internal vault;
    Id internal marketId;
    address internal guardianSignals;
    IIrmRouter internal router;
    MarketParams internal marketParams;
    LidoLendMarketFactory.MarketSpec internal marketSpec;

    address internal controllerAdmin;
    address internal resealManager;

    address internal guardianA;
    address internal guardianB;

    function setUp() external {
        controllerAdmin = makeAddr("controllerAdmin");
        resealManager = makeAddr("resealManager");

        core = ILidoLend(
            address(
                new OssifiableProxy(
                    address(new LidoLend()), GOVERNANCE, abi.encodeWithSignature("initialize(address)", GOVERNANCE)
                )
            )
        );
        lidoLendOwner = new LidoLendOwner(core, GOVERNANCE, address(0), address(0));
        vm.prank(GOVERNANCE);
        core.setOwner(address(lidoLendOwner));

        router = IIrmRouter(address(new MarketFactoryRouterStub(address(core))));
        address controllerImplementation = address(new LidoLendMarketController(IMorpho(address(core))));
        address erc4626WrapperImplementation = address(new LidoLendERC4626(address(core)));
        address guardianSignalsImplementation = address(new GuardianSignals());
        riskStewardDashboard = address(new MarketFactoryCoreBoundStub(address(core)));
        circuitBreaker = address(new MarketFactoryCoreBoundStub(address(core)));

        LidoLendMarketFactory.Implementations memory implementations = LidoLendMarketFactory.Implementations({
            controller: controllerImplementation,
            erc4626Wrapper: erc4626WrapperImplementation,
            guardianSignals: guardianSignalsImplementation
        });
        factory = new LidoLendMarketFactory(
            implementations,
            LidoLendMarketFactory.Dependencies({
                lidoLend: address(core),
                irmRouter: address(router),
                lidoLendOwner: address(lidoLendOwner),
                circuitBreaker: circuitBreaker,
                resealManager: resealManager,
                riskStewardDashboard: riskStewardDashboard
            }),
            controllerAdmin
        );

        guardianA = makeAddr("guardianA");
        guardianB = makeAddr("guardianB");

        guardianSignals = factory.deployGuardianSignals(_guardianSpec(), keccak256("primary"));
        marketSpec = _marketSpec(guardianSignals);
        marketParams = MarketParams({
            loanToken: marketSpec.loanToken,
            collateralToken: marketSpec.collateralToken,
            oracle: marketSpec.oracle,
            irm: address(router),
            lltv: marketSpec.lltv
        });
        (marketId, controller) = factory.deployMarketController(marketSpec);
        vault = factory.deployERC4626Wrapper(controller, marketParams, _erc4626WrapperSpec());
    }

    function testRevert_constructor_rejectsZeroAdmin() external {
        LidoLendMarketFactory.Implementations memory implementations = _implementations();
        LidoLendMarketFactory.Dependencies memory dependencies = _dependencies(circuitBreaker);

        vm.expectRevert(LidoLendMarketFactory.AdminZeroAddress.selector);
        new LidoLendMarketFactory(implementations, dependencies, address(0));
    }

    function testRevert_constructor_rejectsZeroCircuitBreaker() external {
        LidoLendMarketFactory.Implementations memory implementations = _implementations();
        LidoLendMarketFactory.Dependencies memory dependencies = _dependencies(address(0));

        vm.expectRevert(LidoLendMarketFactory.CircuitBreakerZeroAddress.selector);
        new LidoLendMarketFactory(implementations, dependencies, controllerAdmin);
    }

    function testRevert_constructor_rejectsZeroResealManager() external {
        LidoLendMarketFactory.Implementations memory implementations = _implementations();
        LidoLendMarketFactory.Dependencies memory dependencies = _dependencies(circuitBreaker);
        dependencies.resealManager = address(0);

        vm.expectRevert(LidoLendMarketFactory.ResealManagerZeroAddress.selector);
        new LidoLendMarketFactory(implementations, dependencies, controllerAdmin);
    }

    function testRevert_constructor_rejectsDuplicateEmergencyRoleRecipient() external {
        LidoLendMarketFactory.Implementations memory implementations = _implementations();
        LidoLendMarketFactory.Dependencies memory dependencies = _dependencies(circuitBreaker);
        dependencies.resealManager = circuitBreaker;

        vm.expectRevert(LidoLendMarketFactory.DuplicateEmergencyRoleRecipient.selector);
        new LidoLendMarketFactory(implementations, dependencies, controllerAdmin);
    }

    function testRevert_deployMarketController_rejectsCodelessLoanToken() external {
        LidoLendMarketFactory.MarketSpec memory spec = marketSpec;
        spec.loanToken = makeAddr("codelessLoanToken");

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.NotContract.selector, spec.loanToken));
        factory.deployMarketController(spec);
    }

    function test_deployMarketController_assignsResealManagerEmergencyRoles() external view {
        LidoLendMarketController c = LidoLendMarketController(controller);

        assertEq(c.getRoleMemberCount(c.PAUSER_ROLE()), 2);
        assertTrue(c.hasRole(c.PAUSER_ROLE(), circuitBreaker));
        assertTrue(c.hasRole(c.PAUSER_ROLE(), resealManager));
        assertEq(c.getRoleMemberCount(c.RESUMER_ROLE()), 1);
        assertTrue(c.hasRole(c.RESUMER_ROLE(), resealManager));
    }

    function testRevert_deployMarketController_rejectsCodelessCollateralToken() external {
        LidoLendMarketFactory.MarketSpec memory spec = marketSpec;
        spec.collateralToken = makeAddr("codelessCollateralToken");

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.NotContract.selector, spec.collateralToken));
        factory.deployMarketController(spec);
    }

    function test_validateMarketController_acceptsExactRoleSets() external view {
        factory.validateMarketController(controller, marketId, guardianSignals);
    }

    function test_validateMarketController_acceptsCanonicalControllerForCreatedMarket() external {
        _createMarket(controller);

        factory.validateMarketController(controller, marketId, guardianSignals);
    }

    function testRevert_validateMarketController_rejectsControllerBoundToAnotherCore() external {
        address otherCore = makeAddr("otherCore");
        address otherController = address(new MarketFactoryControllerBindingStub(otherCore, marketId));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.LidoLendMismatch.selector, otherController, address(core), otherCore
            )
        );
        factory.validateMarketController(otherController, marketId, guardianSignals);
    }

    function testRevert_validateMarketController_rejectsNonCanonicalControllerForCreatedMarket() external {
        address otherController = _otherControllerForSameMarket();
        _createMarket(controller);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.RegisteredControllerMismatch.selector, marketId, controller, otherController
            )
        );
        factory.validateMarketController(otherController, marketId, guardianSignals);
    }

    function testRevert_validateMarketController_rejectsProxyAdminMismatch() external {
        address wrongAdmin = makeAddr("wrongControllerProxyAdmin");
        vm.prank(controllerAdmin);
        OssifiableProxy(payable(controller)).proxy__changeAdmin(wrongAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ProxyAdminMismatch.selector, controller, controllerAdmin, wrongAdmin
            )
        );
        factory.validateMarketController(controller, marketId, guardianSignals);
    }

    function testRevert_validateMarketController_rejectsMarketIdMismatch() external {
        Id wrongMarketId = Id.wrap(bytes32(uint256(1)));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.MarketIdMismatch.selector, Id.unwrap(wrongMarketId), Id.unwrap(marketId)
            )
        );
        factory.validateMarketController(controller, wrongMarketId, guardianSignals);
    }

    function testRevert_validateMarketController_rejectsGuardianMismatch() external {
        address wrongGuardianSignals = factory.deployGuardianSignals(_otherGuardianSpec(), keccak256("other"));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ControllerGuardianMismatch.selector, wrongGuardianSignals, guardianSignals
            )
        );
        factory.validateMarketController(controller, marketId, wrongGuardianSignals);
    }

    function testRevert_validateMarketController_unexpectedHolderOfEveryKnownRole() external {
        LidoLendMarketController c = LidoLendMarketController(controller);
        bytes32[] memory roles = new bytes32[](6);
        uint256[] memory expectedCounts = new uint256[](6);
        roles[0] = c.DEFAULT_ADMIN_ROLE();
        expectedCounts[0] = 1;
        roles[1] = c.MANAGER_ROLE();
        expectedCounts[1] = 2;
        roles[2] = c.PAUSER_ROLE();
        expectedCounts[2] = 2;
        roles[3] = c.FREEZER_ROLE();
        expectedCounts[3] = 1;
        roles[4] = c.UNFREEZER_ROLE();
        expectedCounts[4] = 1;
        roles[5] = c.RESUMER_ROLE();
        expectedCounts[5] = 1;

        for (uint256 i; i < roles.length; ++i) {
            address unexpectedHolder = address(uint160(0xBAD0 + i));
            vm.prank(controllerAdmin);
            c.grantRole(roles[i], unexpectedHolder);

            vm.expectRevert(
                abi.encodeWithSelector(
                    LidoLendMarketFactory.RoleMemberCountMismatch.selector,
                    controller,
                    roles[i],
                    expectedCounts[i],
                    expectedCounts[i] + 1
                )
            );
            factory.validateMarketController(controller, marketId, guardianSignals);

            vm.prank(controllerAdmin);
            c.revokeRole(roles[i], unexpectedHolder);
        }
    }

    function testRevert_validateMarketController_rejectsManagerSubstitution() external {
        LidoLendMarketController c = LidoLendMarketController(controller);
        address unexpectedManager = makeAddr("unexpectedManager");

        vm.startPrank(controllerAdmin);
        c.grantRole(c.MANAGER_ROLE(), unexpectedManager);
        c.revokeRole(c.MANAGER_ROLE(), riskStewardDashboard);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.MissingRole.selector, controller, c.MANAGER_ROLE(), riskStewardDashboard
            )
        );
        factory.validateMarketController(controller, marketId, guardianSignals);
    }

    function testRevert_validateMarketController_rejectsPauserSubstitution() external {
        LidoLendMarketController c = LidoLendMarketController(controller);
        address unexpectedPauser = makeAddr("unexpectedPauser");

        vm.startPrank(controllerAdmin);
        c.grantRole(c.PAUSER_ROLE(), unexpectedPauser);
        c.revokeRole(c.PAUSER_ROLE(), circuitBreaker);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.MissingRole.selector, controller, c.PAUSER_ROLE(), circuitBreaker
            )
        );
        factory.validateMarketController(controller, marketId, guardianSignals);
    }

    function testRevert_validateMarketController_rejectsAdminFreezerAndUnfreezerSubstitution() external {
        LidoLendMarketController c = LidoLendMarketController(controller);
        bytes32[] memory roles = new bytes32[](3);
        address[] memory expectedHolders = new address[](3);
        roles[0] = c.DEFAULT_ADMIN_ROLE();
        expectedHolders[0] = controllerAdmin;
        roles[1] = c.FREEZER_ROLE();
        expectedHolders[1] = riskStewardDashboard;
        roles[2] = c.UNFREEZER_ROLE();
        expectedHolders[2] = address(lidoLendOwner);

        for (uint256 i; i < roles.length; ++i) {
            address unexpectedHolder = address(uint160(0xBAD8 + i));
            vm.startPrank(controllerAdmin);
            c.grantRole(roles[i], unexpectedHolder);
            c.revokeRole(roles[i], expectedHolders[i]);
            vm.stopPrank();

            vm.expectRevert(
                abi.encodeWithSelector(
                    LidoLendMarketFactory.MissingRole.selector, controller, roles[i], expectedHolders[i]
                )
            );
            factory.validateMarketController(controller, marketId, guardianSignals);

            address restoringAdmin = roles[i] == c.DEFAULT_ADMIN_ROLE() ? unexpectedHolder : controllerAdmin;
            vm.startPrank(restoringAdmin);
            c.grantRole(roles[i], expectedHolders[i]);
            vm.stopPrank();
            vm.prank(controllerAdmin);
            c.revokeRole(roles[i], unexpectedHolder);
        }
    }

    function testRevert_validateMarketController_unexpectedAdminOfEveryKnownRole() external {
        LidoLendMarketController c = LidoLendMarketController(controller);
        bytes32 defaultAdminRole = c.DEFAULT_ADMIN_ROLE();
        bytes32 unexpectedAdminRole = keccak256("UNEXPECTED_ADMIN_ROLE");
        bytes32[] memory roles = new bytes32[](6);
        roles[0] = defaultAdminRole;
        roles[1] = c.MANAGER_ROLE();
        roles[2] = c.PAUSER_ROLE();
        roles[3] = c.FREEZER_ROLE();
        roles[4] = c.UNFREEZER_ROLE();
        roles[5] = c.RESUMER_ROLE();

        for (uint256 i; i < roles.length; ++i) {
            vm.mockCall(
                controller,
                abi.encodeWithSelector(IAccessControl.getRoleAdmin.selector, roles[i]),
                abi.encode(unexpectedAdminRole)
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    LidoLendMarketFactory.RoleAdminMismatch.selector,
                    controller,
                    roles[i],
                    defaultAdminRole,
                    unexpectedAdminRole
                )
            );
            factory.validateMarketController(controller, marketId, guardianSignals);
            vm.clearMockedCalls();
        }
    }

    /// @dev The factory must not still administer a controller it validates. Only a factory whose admin is its own
    ///      address passes the sole-admin check while holding that role, so this is the setup that reaches the check.
    function testRevert_validateMarketController_factoryStillAdministers() external {
        address selfAdmin = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        LidoLendMarketFactory selfAdministered = new LidoLendMarketFactory(
            LidoLendMarketFactory.Implementations({
                controller: factory.CONTROLLER_IMPL(),
                erc4626Wrapper: factory.ERC4626_WRAPPER_IMPL(),
                guardianSignals: factory.GUARDIAN_SIGNALS_IMPL()
            }),
            LidoLendMarketFactory.Dependencies({
                lidoLend: factory.LIDO_LEND(),
                irmRouter: factory.IRM_ROUTER(),
                lidoLendOwner: factory.LIDO_LEND_OWNER(),
                circuitBreaker: factory.CIRCUIT_BREAKER(),
                resealManager: factory.RESEAL_MANAGER(),
                riskStewardDashboard: factory.RISK_STEWARD_DASHBOARD()
            }),
            selfAdmin
        );
        assertEq(address(selfAdministered), selfAdmin, "setup: the factory is its own admin");

        LidoLendMarketController c = LidoLendMarketController(controller);
        bytes32 defaultAdminRole = c.DEFAULT_ADMIN_ROLE();
        vm.startPrank(controllerAdmin);
        OssifiableProxy(payable(controller)).proxy__changeAdmin(selfAdmin);
        c.grantRole(defaultAdminRole, selfAdmin);
        c.renounceRole(defaultAdminRole, controllerAdmin);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.UnexpectedRole.selector, controller, defaultAdminRole, selfAdmin
            )
        );
        selfAdministered.validateMarketController(controller, marketId, guardianSignals);
    }

    function test_validateGuardianSignals_acceptsExactRoleSets() external view {
        factory.validateGuardianSignals(guardianSignals, _guardianSpec());
    }

    function test_validateGuardianSignals_acceptsCompatibleProxyWithDifferentRuntimeCodehash() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        address registryAddress = address(
            new MarketFactoryCompatibleProxy(
                factory.GUARDIAN_SIGNALS_IMPL(),
                controllerAdmin,
                abi.encodeCall(GuardianSignals.initialize, (controllerAdmin, spec.guardians, spec.quorum))
            )
        );
        GuardianSignals registry = GuardianSignals(registryAddress);

        vm.startPrank(controllerAdmin);
        registry.grantRole(registry.MANAGER_ROLE(), controllerAdmin);
        registry.setSuspectWindow(spec.suspectWindow);
        registry.revokeRole(registry.MANAGER_ROLE(), controllerAdmin);
        registry.grantRole(registry.MANAGER_ROLE(), address(lidoLendOwner));
        registry.grantRole(registry.ACCESS_RESTORER_ROLE(), address(lidoLendOwner));
        vm.stopPrank();

        assertTrue(registryAddress.codehash != guardianSignals.codehash, "proxy runtimes must differ");
        factory.validateGuardianSignals(registryAddress, spec);
    }

    function testRevert_validateGuardianSignals_rejectsProxyAdminMismatch() external {
        address wrongAdmin = makeAddr("wrongGuardianProxyAdmin");
        vm.prank(controllerAdmin);
        OssifiableProxy(payable(guardianSignals)).proxy__changeAdmin(wrongAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ProxyAdminMismatch.selector, guardianSignals, controllerAdmin, wrongAdmin
            )
        );
        factory.validateGuardianSignals(guardianSignals, _guardianSpec());
    }

    function testRevert_validateGuardianSignals_rejectsQuorumMismatch() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.quorum = 2;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.GuardianQuorumMismatch.selector, 2, 1));
        factory.validateGuardianSignals(guardianSignals, spec);
    }

    function testRevert_validateGuardianSignals_rejectsSuspectWindowMismatch() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.suspectWindow = 1;

        vm.expectRevert(
            abi.encodeWithSelector(LidoLendMarketFactory.GuardianSuspectWindowMismatch.selector, 1, 2 hours)
        );
        factory.validateGuardianSignals(guardianSignals, spec);
    }

    function testRevert_validateGuardianSignals_rejectsGuardianCountMismatch() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.guardians = new address[](1);
        spec.guardians[0] = guardianA;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.GuardianCountMismatch.selector, 1, 2));
        factory.validateGuardianSignals(guardianSignals, spec);
    }

    function testRevert_validateGuardianSignals_rejectsMissingGuardian() external {
        address missingGuardian = makeAddr("missingGuardian");
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.guardians[1] = missingGuardian;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.MissingGuardian.selector, missingGuardian));
        factory.validateGuardianSignals(guardianSignals, spec);
    }

    function testRevert_validateGuardianSignals_rejectsDuplicateExpectedGuardian() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.guardians[1] = guardianA;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.DuplicateGuardian.selector, guardianA));
        factory.validateGuardianSignals(guardianSignals, spec);
    }

    function testRevert_validateGuardianSignals_unexpectedHolderOfEveryKnownRole() external {
        GuardianSignals registry = GuardianSignals(guardianSignals);
        bytes32[] memory roles = new bytes32[](4);
        uint256[] memory expectedCounts = new uint256[](4);
        roles[0] = registry.DEFAULT_ADMIN_ROLE();
        expectedCounts[0] = 1;
        roles[1] = registry.MANAGER_ROLE();
        expectedCounts[1] = 1;
        roles[2] = registry.ACCESS_RESTORER_ROLE();
        expectedCounts[2] = 1;
        roles[3] = registry.ACCESS_LIMITER_ROLE();
        expectedCounts[3] = 0;

        for (uint256 i; i < roles.length; ++i) {
            address unexpectedHolder = address(uint160(0xBAD1 + i));
            vm.prank(controllerAdmin);
            registry.grantRole(roles[i], unexpectedHolder);

            vm.expectRevert(
                abi.encodeWithSelector(
                    LidoLendMarketFactory.RoleMemberCountMismatch.selector,
                    guardianSignals,
                    roles[i],
                    expectedCounts[i],
                    expectedCounts[i] + 1
                )
            );
            factory.validateGuardianSignals(guardianSignals, _guardianSpec());

            vm.prank(controllerAdmin);
            registry.revokeRole(roles[i], unexpectedHolder);
        }
    }

    function testRevert_validateGuardianSignals_rejectsGovernanceRoleSubstitution() external {
        GuardianSignals registry = GuardianSignals(guardianSignals);
        bytes32[] memory roles = new bytes32[](2);
        roles[0] = registry.MANAGER_ROLE();
        roles[1] = registry.ACCESS_RESTORER_ROLE();

        for (uint256 i; i < roles.length; ++i) {
            address unexpectedHolder = address(uint160(0xBAD5 + i));
            vm.startPrank(controllerAdmin);
            registry.grantRole(roles[i], unexpectedHolder);
            registry.revokeRole(roles[i], address(lidoLendOwner));
            vm.stopPrank();

            vm.expectRevert(
                abi.encodeWithSelector(
                    LidoLendMarketFactory.MissingRole.selector, guardianSignals, roles[i], address(lidoLendOwner)
                )
            );
            factory.validateGuardianSignals(guardianSignals, _guardianSpec());

            vm.startPrank(controllerAdmin);
            registry.grantRole(roles[i], address(lidoLendOwner));
            registry.revokeRole(roles[i], unexpectedHolder);
            vm.stopPrank();
        }
    }

    function testRevert_validateGuardianSignals_rejectsDefaultAdminSubstitution() external {
        GuardianSignals registry = GuardianSignals(guardianSignals);
        bytes32 defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();
        address unexpectedAdmin = makeAddr("unexpectedGuardianAdmin");

        vm.startPrank(controllerAdmin);
        registry.grantRole(defaultAdminRole, unexpectedAdmin);
        registry.revokeRole(defaultAdminRole, controllerAdmin);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.MissingRole.selector, guardianSignals, defaultAdminRole, controllerAdmin
            )
        );
        factory.validateGuardianSignals(guardianSignals, _guardianSpec());
    }

    function testRevert_validateGuardianSignals_unexpectedAccessLimiter() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _otherGuardianSpec();
        address registryAddress = factory.deployGuardianSignals(spec, keccak256("other"));
        GuardianSignals registry = GuardianSignals(registryAddress);
        address unexpectedHolder = makeAddr("unexpectedAccessLimiter");
        bytes32 limiterRole = registry.ACCESS_LIMITER_ROLE();

        vm.prank(controllerAdmin);
        registry.grantRole(limiterRole, unexpectedHolder);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.RoleMemberCountMismatch.selector, registryAddress, limiterRole, 0, 1
            )
        );
        factory.validateGuardianSignals(registryAddress, spec);
    }

    function testRevert_validateGuardianSignals_unexpectedAdminOfEveryKnownRole() external {
        GuardianSignals registry = GuardianSignals(guardianSignals);
        bytes32 defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();
        bytes32 unexpectedAdminRole = keccak256("UNEXPECTED_ADMIN_ROLE");
        bytes32[] memory roles = new bytes32[](4);
        roles[0] = defaultAdminRole;
        roles[1] = registry.MANAGER_ROLE();
        roles[2] = registry.ACCESS_RESTORER_ROLE();
        roles[3] = registry.ACCESS_LIMITER_ROLE();

        for (uint256 i; i < roles.length; ++i) {
            vm.mockCall(
                guardianSignals,
                abi.encodeWithSelector(IAccessControl.getRoleAdmin.selector, roles[i]),
                abi.encode(unexpectedAdminRole)
            );
            vm.expectRevert(
                abi.encodeWithSelector(
                    LidoLendMarketFactory.RoleAdminMismatch.selector,
                    guardianSignals,
                    roles[i],
                    defaultAdminRole,
                    unexpectedAdminRole
                )
            );
            factory.validateGuardianSignals(guardianSignals, _guardianSpec());
            vm.clearMockedCalls();
        }
    }

    function test_validateERC4626Wrapper_acceptsExpectedBinding() external view {
        factory.validateERC4626Wrapper(vault, controller, marketParams);
    }

    function testRevert_validateERC4626Wrapper_rejectsWrapperBoundToAnotherCore() external {
        address otherCore = makeAddr("otherCore");
        vm.mockCall(
            vault, abi.encodeWithSelector(ILidoLendERC4626.LIDO_LEND.selector), abi.encode(ILidoLend(otherCore))
        );

        vm.expectRevert(
            abi.encodeWithSelector(LidoLendMarketFactory.LidoLendMismatch.selector, vault, address(core), otherCore)
        );
        factory.validateERC4626Wrapper(vault, controller, marketParams);
    }

    function testRevert_validateERC4626Wrapper_rejectsCachedMarketParamsMismatch() external {
        MarketParams memory wrongMarketParams = marketParams;
        wrongMarketParams.oracle = makeAddr("wrongOracle");
        vm.mockCall(
            vault, abi.encodeWithSelector(ILidoLendERC4626.marketParams.selector), abi.encode(wrongMarketParams)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.MarketIdMismatch.selector, Id.unwrap(marketId), Id.unwrap(wrongMarketParams.id())
            )
        );
        factory.validateERC4626Wrapper(vault, controller, marketParams);
    }

    function testRevert_validateERC4626Wrapper_rejectsCachedMarketIdMismatch() external {
        Id wrongMarketId = Id.wrap(bytes32(uint256(1)));
        vm.mockCall(vault, abi.encodeWithSelector(ILidoLendERC4626.marketId.selector), abi.encode(wrongMarketId));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.MarketIdMismatch.selector, Id.unwrap(marketId), Id.unwrap(wrongMarketId)
            )
        );
        factory.validateERC4626Wrapper(vault, controller, marketParams);
    }

    function testRevert_validateERC4626Wrapper_rejectsAssetMismatch() external {
        vm.mockCall(vault, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(marketParams.collateralToken));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ERC4626WrapperAssetMismatch.selector,
                marketParams.loanToken,
                marketParams.collateralToken
            )
        );
        factory.validateERC4626Wrapper(vault, controller, marketParams);
    }

    function testRevert_validateERC4626Wrapper_rejectsProxyAdminMismatch() external {
        address wrongAdmin = makeAddr("wrongVaultProxyAdmin");
        vm.prank(controllerAdmin);
        OssifiableProxy(payable(vault)).proxy__changeAdmin(wrongAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ProxyAdminMismatch.selector, vault, controllerAdmin, wrongAdmin
            )
        );
        factory.validateERC4626Wrapper(vault, controller, marketParams);
    }

    function testRevert_validateERC4626Wrapper_rejectsControllerMismatch() external {
        address otherController = _otherControllerForSameMarket();

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ERC4626WrapperControllerMismatch.selector, otherController, controller
            )
        );
        factory.validateERC4626Wrapper(vault, otherController, marketParams);
    }

    function testRevert_deployERC4626Wrapper_rejectsControllerBoundToAnotherCore() external {
        address otherCore = makeAddr("otherCore");
        address otherController = address(new MarketFactoryControllerBindingStub(otherCore, marketId));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.LidoLendMismatch.selector, otherController, address(core), otherCore
            )
        );
        factory.deployERC4626Wrapper(otherController, marketParams, _erc4626WrapperSpec());
    }

    function testRevert_deployERC4626Wrapper_rejectsNonCanonicalControllerForCreatedMarket() external {
        address otherController = _otherControllerForSameMarket();
        _createMarket(controller);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.RegisteredControllerMismatch.selector, marketId, controller, otherController
            )
        );
        factory.deployERC4626Wrapper(otherController, marketParams, _erc4626WrapperSpec());
    }

    /// @dev A second wrapper over a live market is allowed, and carries its own share metadata: the metadata is
    ///      part of the deployment address, so an exact duplicate of an existing wrapper has nowhere to go.
    function test_deployERC4626Wrapper_acceptsCanonicalControllerForCreatedMarket() external {
        _createMarket(controller);

        address secondVault = factory.deployERC4626Wrapper(
            controller,
            marketParams,
            LidoLendMarketFactory.ERC4626WrapperSpec({name: "Second Loan Vault", symbol: "lidoLOAN2"})
        );

        assertEq(address(LidoLendERC4626(secondVault).controller()), controller, "controller");
        assertEq(Id.unwrap(LidoLendERC4626(secondVault).marketId()), Id.unwrap(marketId), "market id");
    }

    function test_deployMarketComponents_lltvJustBelowWad_accepted() external {
        LidoLendMarketFactory.MarketSpec memory spec = _marketSpec(guardianSignals);
        spec.lltv = 1e18 - 1;
        Id expectedId = MarketParams({
            loanToken: spec.loanToken,
            collateralToken: spec.collateralToken,
            oracle: spec.oracle,
            irm: address(router),
            lltv: spec.lltv
        }).id();

        (Id deployedId, address deployedController,) = factory.deployMarketComponents(spec, _erc4626WrapperSpec());

        assertEq(Id.unwrap(deployedId), Id.unwrap(expectedId), "market id over lltv WAD - 1");
        factory.validateMarketController(deployedController, expectedId, guardianSignals);
    }

    function test_deployMarketController_standalone_emitsOnlyControllerDeployed() external {
        vm.recordLogs();
        (Id deployedId, address deployedController) = factory.deployMarketController(_marketSpec(guardianSignals));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 controllerEvents;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            assertTrue(topic != LidoLendMarketFactory.ERC4626WrapperDeployed.selector, "no wrapper event");
            assertTrue(topic != LidoLendMarketFactory.MarketComponentsDeployed.selector, "no components event");
            if (topic == LidoLendMarketFactory.MarketControllerDeployed.selector) {
                assertEq(logs[i].topics[1], Id.unwrap(deployedId), "market id");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(deployedController))), "controller");
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(guardianSignals))), "registry");
                controllerEvents++;
            }
        }
        assertEq(controllerEvents, 1, "one MarketControllerDeployed");
    }

    /// @dev The wrapper's metadata and caller fix its address, so the same wrapper twice has nowhere to go. A
    ///      `CREATE2` collision reverts with no return data, so there is no selector to match.
    function testRevert_deployERC4626Wrapper_identicalWrapperCollides() external {
        vm.expectRevert();
        factory.deployERC4626Wrapper(controller, marketParams, _erc4626WrapperSpec());
    }

    function test_deployERC4626Wrapper_standalone_emitsWrapperDeployed() external {
        LidoLendMarketFactory.ERC4626WrapperSpec memory spec =
            LidoLendMarketFactory.ERC4626WrapperSpec({name: "Second Loan Vault", symbol: "lidoLOAN2"});

        vm.recordLogs();
        address secondVault = factory.deployERC4626Wrapper(controller, marketParams, spec);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 wrapperEvents;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 topic = logs[i].topics[0];
            assertTrue(topic != LidoLendMarketFactory.MarketComponentsDeployed.selector, "no components event");
            if (topic == LidoLendMarketFactory.ERC4626WrapperDeployed.selector) {
                assertEq(logs[i].topics[1], Id.unwrap(marketId), "market id");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(controller))), "controller");
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(secondVault))), "wrapper");
                wrapperEvents++;
            }
        }
        assertEq(wrapperEvents, 1, "one ERC4626WrapperDeployed");
    }

    /// @dev The registry's own `initialize` and `setSuspectWindow` reject a bad spec inside the deployment.
    function testRevert_deployGuardianSignals_invalidSpec() external {
        LidoLendMarketFactory.GuardianSpec memory duplicate = _guardianSpec();
        duplicate.guardians[1] = guardianA;
        vm.expectRevert(IGuardianSignals.AlreadyGuardian.selector);
        factory.deployGuardianSignals(duplicate, keccak256("invalid"));

        LidoLendMarketFactory.GuardianSpec memory badQuorum = _guardianSpec();
        badQuorum.quorum = 3;
        vm.expectRevert(IGuardianSignals.BadQuorum.selector);
        factory.deployGuardianSignals(badQuorum, keccak256("invalid"));

        LidoLendMarketFactory.GuardianSpec memory oversizedWindow = _guardianSpec();
        oversizedWindow.suspectWindow = GuardianSignals(guardianSignals).MAX_SUSPECT_WINDOW() + 1;
        vm.expectRevert(IGuardianSignals.SuspectWindowTooHigh.selector);
        factory.deployGuardianSignals(oversizedWindow, keccak256("invalid"));
    }

    function test_deployGuardianSignals_sameSaltOtherCaller_landsElsewhere() external {
        address otherCaller = makeAddr("otherCaller");
        vm.prank(otherCaller);
        address otherRegistry = factory.deployGuardianSignals(_guardianSpec(), keccak256("primary"));

        assertTrue(otherRegistry != guardianSignals, "a caller-scoped salt gives another address");
        factory.validateGuardianSignals(otherRegistry, _guardianSpec());
    }

    function testRevert_validateMarketController_rejectsResumerSubstitution() external {
        LidoLendMarketController c = LidoLendMarketController(controller);
        address unexpectedResumer = makeAddr("unexpectedResumer");
        bytes32 resumerRole = c.RESUMER_ROLE();

        vm.startPrank(controllerAdmin);
        c.grantRole(resumerRole, unexpectedResumer);
        c.revokeRole(resumerRole, resealManager);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(LidoLendMarketFactory.MissingRole.selector, controller, resumerRole, resealManager)
        );
        factory.validateMarketController(controller, marketId, guardianSignals);
    }

    function testRevert_validateERC4626Wrapper_suppliedControllerFailsBinding() external {
        address otherCore = makeAddr("otherCore");
        address foreignController = address(new MarketFactoryControllerBindingStub(otherCore, marketId));
        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.LidoLendMismatch.selector, foreignController, address(core), otherCore
            )
        );
        factory.validateERC4626Wrapper(vault, foreignController, marketParams);

        address otherController = _otherControllerForSameMarket();
        _createMarket(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.RegisteredControllerMismatch.selector, marketId, controller, otherController
            )
        );
        factory.validateERC4626Wrapper(vault, otherController, marketParams);
    }

    /// @dev A factory whose admin is its own address passes every other check on a registry it administers, then
    ///      fails the last one.
    function testRevert_validateGuardianSignals_factoryStillAdministers() external {
        address selfAdmin = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        LidoLendMarketFactory selfAdministered =
            new LidoLendMarketFactory(_implementations(), _dependencies(circuitBreaker), selfAdmin);
        assertEq(address(selfAdministered), selfAdmin, "setup: the factory is its own admin");

        GuardianSignals registry = GuardianSignals(guardianSignals);
        bytes32 defaultAdminRole = registry.DEFAULT_ADMIN_ROLE();
        vm.startPrank(controllerAdmin);
        OssifiableProxy(payable(guardianSignals)).proxy__changeAdmin(selfAdmin);
        registry.grantRole(defaultAdminRole, selfAdmin);
        registry.renounceRole(defaultAdminRole, controllerAdmin);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.UnexpectedRole.selector, guardianSignals, defaultAdminRole, selfAdmin
            )
        );
        selfAdministered.validateGuardianSignals(guardianSignals, _guardianSpec());
    }

    function test_views_readBackConstructorArguments() external {
        LidoLendMarketFactory.Implementations memory implementations = LidoLendMarketFactory.Implementations({
            controller: address(new LidoLendMarketController(IMorpho(address(core)))),
            erc4626Wrapper: address(new LidoLendERC4626(address(core))),
            guardianSignals: address(new GuardianSignals())
        });
        LidoLendMarketFactory.Dependencies memory dependencies = _dependencies(circuitBreaker);
        address admin = makeAddr("factoryAdmin");

        LidoLendMarketFactory fresh = new LidoLendMarketFactory(implementations, dependencies, admin);

        assertEq(fresh.CONTROLLER_IMPL(), implementations.controller, "CONTROLLER_IMPL");
        assertEq(fresh.ERC4626_WRAPPER_IMPL(), implementations.erc4626Wrapper, "ERC4626_WRAPPER_IMPL");
        assertEq(fresh.GUARDIAN_SIGNALS_IMPL(), implementations.guardianSignals, "GUARDIAN_SIGNALS_IMPL");
        assertEq(fresh.LIDO_LEND(), dependencies.lidoLend, "LIDO_LEND");
        assertEq(fresh.IRM_ROUTER(), dependencies.irmRouter, "IRM_ROUTER");
        assertEq(fresh.CIRCUIT_BREAKER(), dependencies.circuitBreaker, "CIRCUIT_BREAKER");
        assertEq(fresh.RESEAL_MANAGER(), dependencies.resealManager, "RESEAL_MANAGER");
        assertEq(fresh.LIDO_LEND_OWNER(), dependencies.lidoLendOwner, "LIDO_LEND_OWNER");
        assertEq(fresh.RISK_STEWARD_DASHBOARD(), dependencies.riskStewardDashboard, "RISK_STEWARD_DASHBOARD");
        assertEq(fresh.ADMIN(), admin, "ADMIN");
    }

    function _createMarket(address marketController) private {
        bytes32 marketCreatorRole = lidoLendOwner.MARKET_CREATOR_ROLE();
        vm.prank(GOVERNANCE);
        lidoLendOwner.grantRole(marketCreatorRole, address(this));
        lidoLendOwner.createMarket(marketParams, marketController, true);
    }

    /// @dev Another controller for the same market. The activation config sits outside the market id, so varying it
    ///      leaves the id alone while giving the controller a deployment address of its own.
    function _otherControllerForSameMarket() private returns (address otherController) {
        LidoLendMarketFactory.MarketSpec memory spec = marketSpec;
        spec.activationConfig.minActivationDelay += 1;
        Id otherMarketId;
        (otherMarketId, otherController) = factory.deployMarketController(spec);
        assertEq(Id.unwrap(otherMarketId), Id.unwrap(marketId), "same market");
    }

    function _marketSpec(address registry) private returns (LidoLendMarketFactory.MarketSpec memory spec) {
        MockERC20 loanToken = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateralToken = new MockERC20("Collateral", "COLL", 18);
        MockPriceOracle oracle = new MockPriceOracle();
        oracle.initialize(1.05e36);

        spec = LidoLendMarketFactory.MarketSpec({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(oracle),
            lltv: 0.8e18,
            guardianSignals: registry,
            supplyCap: 1_000 ether,
            activationConfig: _activationConfig(),
            settlementConfig: _settlementConfig()
        });
    }

    function _implementations() private view returns (LidoLendMarketFactory.Implementations memory) {
        return LidoLendMarketFactory.Implementations({
            controller: factory.CONTROLLER_IMPL(),
            erc4626Wrapper: factory.ERC4626_WRAPPER_IMPL(),
            guardianSignals: factory.GUARDIAN_SIGNALS_IMPL()
        });
    }

    function _dependencies(address circuitBreaker_) private view returns (LidoLendMarketFactory.Dependencies memory) {
        return LidoLendMarketFactory.Dependencies({
            lidoLend: address(core),
            irmRouter: address(router),
            lidoLendOwner: address(lidoLendOwner),
            circuitBreaker: circuitBreaker_,
            resealManager: resealManager,
            riskStewardDashboard: riskStewardDashboard
        });
    }

    function _guardianSpec() private view returns (LidoLendMarketFactory.GuardianSpec memory spec) {
        address[] memory guardians = new address[](2);
        guardians[0] = guardianA;
        guardians[1] = guardianB;
        spec = LidoLendMarketFactory.GuardianSpec({guardians: guardians, quorum: 1, suspectWindow: 2 hours});
    }

    /// @dev A registry that is its own instance rather than a second copy of `guardianSignals`.
    function _otherGuardianSpec() private returns (LidoLendMarketFactory.GuardianSpec memory spec) {
        address[] memory guardians = new address[](2);
        guardians[0] = guardianA;
        guardians[1] = makeAddr("guardianC");
        spec = LidoLendMarketFactory.GuardianSpec({guardians: guardians, quorum: 1, suspectWindow: 2 hours});
    }

    function _erc4626WrapperSpec() private pure returns (LidoLendMarketFactory.ERC4626WrapperSpec memory spec) {
        spec = LidoLendMarketFactory.ERC4626WrapperSpec({name: "Lido Loan Vault", symbol: "lidoLOAN"});
    }

    function _activationConfig() private pure returns (CollateralActivationConfig memory) {
        return CollateralActivationConfig({
            minActivationDelay: 10 minutes,
            maxActivationDelay: 2 hours,
            maxDelayInflow: 10_000 ether,
            activatingLockDuration: 0,
            minActivationAmount: 10 ether,
            minDepositAmount: 0,
            maxGuardiansQuorumDelay: 0,
            delayPerStrike: 2 hours,
            delayPerSuspect: 0
        });
    }

    function _settlementConfig() private pure returns (SettlementConfig memory) {
        return
            SettlementConfig({
                sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
            });
    }
}
