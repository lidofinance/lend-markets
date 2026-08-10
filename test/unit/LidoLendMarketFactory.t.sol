// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, IMorpho, Market, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
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

    address internal guardianA;
    address internal guardianB;

    function setUp() external {
        controllerAdmin = makeAddr("controllerAdmin");

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
                riskStewardDashboard: riskStewardDashboard
            }),
            controllerAdmin
        );

        guardianA = makeAddr("guardianA");
        guardianB = makeAddr("guardianB");

        guardianSignals = factory.deployGuardianSignals(_guardianSpec());
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
        (, address otherController) = factory.deployMarketController(marketSpec);
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
        address wrongGuardianSignals = factory.deployGuardianSignals(_guardianSpec());

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
        expectedCounts[2] = 1;
        roles[3] = c.FREEZER_ROLE();
        expectedCounts[3] = 1;
        roles[4] = c.UNFREEZER_ROLE();
        expectedCounts[4] = 1;
        roles[5] = c.RESUMER_ROLE();
        expectedCounts[5] = 0;

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
        address registryAddress = factory.deployGuardianSignals(_guardianSpec());
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
        factory.validateGuardianSignals(registryAddress, _guardianSpec());
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
        (, address otherController) = factory.deployMarketController(marketSpec);

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
        (, address otherController) = factory.deployMarketController(marketSpec);
        _createMarket(controller);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.RegisteredControllerMismatch.selector, marketId, controller, otherController
            )
        );
        factory.deployERC4626Wrapper(otherController, marketParams, _erc4626WrapperSpec());
    }

    function test_deployERC4626Wrapper_acceptsCanonicalControllerForCreatedMarket() external {
        _createMarket(controller);

        address secondVault = factory.deployERC4626Wrapper(controller, marketParams, _erc4626WrapperSpec());

        assertEq(address(LidoLendERC4626(secondVault).controller()), controller, "controller");
        assertEq(Id.unwrap(LidoLendERC4626(secondVault).marketId()), Id.unwrap(marketId), "market id");
    }

    function _createMarket(address marketController) private {
        bytes32 marketCreatorRole = lidoLendOwner.MARKET_CREATOR_ROLE();
        vm.prank(GOVERNANCE);
        lidoLendOwner.grantRole(marketCreatorRole, address(this));
        lidoLendOwner.createMarket(marketParams, marketController, true);
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
            activationConfig: _activationConfig(),
            settlementConfig: _settlementConfig()
        });
    }

    function _guardianSpec() private view returns (LidoLendMarketFactory.GuardianSpec memory spec) {
        address[] memory guardians = new address[](2);
        guardians[0] = guardianA;
        guardians[1] = guardianB;
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
            activatingLockAmount: 0,
            activatingLockDuration: 0,
            minActivationAmount: 10 ether,
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
