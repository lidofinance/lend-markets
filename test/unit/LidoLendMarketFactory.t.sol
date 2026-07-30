// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {IIrmRouterView, LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

contract MarketFactoryRouterStub is IIrmRouterView {
    address public immutable MORPHO;

    constructor(address morpho) {
        MORPHO = morpho;
    }
}

contract MarketFactoryCoreBoundStub {
    address public immutable LIDO_LEND;

    constructor(address lidoLend) {
        LIDO_LEND = lidoLend;
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
    address private constant GOVERNANCE = address(0xA11CE);

    LidoLendMarketFactory internal factory;
    LidoLendOwner internal lidoLendOwner;
    address internal riskStewardDashboard;
    address internal controller;
    address internal vault;
    Id internal marketId;
    address internal guardianSignals;
    IIrmRouterView internal router;
    MarketParams internal marketParams;
    LidoLendMarketFactory.MarketSpec internal marketSpec;

    address internal controllerAdmin;
    address internal controllerProxyAdmin;
    address internal manager;
    address internal pauser;
    address internal freezer;
    address internal unfreezer;
    address internal resumer;

    address internal guardianAdmin;
    address internal guardianProxyAdmin;
    address internal guardianManager;
    address internal accessLimiter;
    address internal guardianA;
    address internal guardianB;

    function setUp() external {
        ILidoLend core = ILidoLend(
            address(
                new OssifiableProxy(
                    address(new LidoLend()), GOVERNANCE, abi.encodeWithSignature("initialize(address)", GOVERNANCE)
                )
            )
        );
        lidoLendOwner = new LidoLendOwner(core, GOVERNANCE, address(0), address(0));
        vm.prank(GOVERNANCE);
        core.setOwner(address(lidoLendOwner));

        router = new MarketFactoryRouterStub(address(core));
        address controllerImplementation = address(new LidoLendMarketController(IMorpho(address(core))));
        address vaultImplementation = address(new LidoLendERC4626(address(core)));
        address guardianSignalsImplementation = address(new GuardianSignals());
        riskStewardDashboard = address(new MarketFactoryCoreBoundStub(address(core)));

        LidoLendMarketFactory.Implementations memory implementations = LidoLendMarketFactory.Implementations({
            controller: controllerImplementation,
            vault: vaultImplementation,
            guardianSignals: guardianSignalsImplementation
        });
        factory = new LidoLendMarketFactory(
            implementations,
            ILidoLendOwner(address(lidoLendOwner)),
            IIrmRouterView(address(router)),
            riskStewardDashboard
        );

        controllerAdmin = makeAddr("controllerAdmin");
        controllerProxyAdmin = makeAddr("controllerProxyAdmin");
        manager = makeAddr("manager");
        pauser = makeAddr("pauser");
        freezer = makeAddr("freezer");
        unfreezer = makeAddr("unfreezer");
        resumer = makeAddr("resumer");

        guardianAdmin = makeAddr("guardianAdmin");
        guardianProxyAdmin = makeAddr("guardianProxyAdmin");
        guardianManager = makeAddr("guardianManager");
        accessLimiter = makeAddr("accessLimiter");
        guardianA = makeAddr("guardianA");
        guardianB = makeAddr("guardianB");

        guardianSignals = factory.deployGuardianSignals(_guardianSpec(), _guardianRoles());
        marketSpec = _marketSpec(guardianSignals);
        marketParams = MarketParams({
            loanToken: marketSpec.loanToken,
            collateralToken: marketSpec.collateralToken,
            oracle: marketSpec.oracle,
            irm: address(router),
            lltv: marketSpec.lltv
        });
        (marketId, controller) = factory.deployMarketController(marketSpec, _marketRoles());
        vault = factory.deployVault(LidoLendMarketController(controller), marketParams, _vaultSpec());
    }

    function test_validateMarketController_acceptsExactRoleSets() external view {
        factory.validateMarketController(controller, marketId, guardianSignals, _marketRoles());
    }

    function test_validateMarketController_acceptsEquivalentImplementationCodehash() external {
        address otherImplementation = address(new LidoLendMarketController(IMorpho(address(factory.CORE()))));
        vm.prank(controllerProxyAdmin);
        OssifiableProxy(payable(controller)).proxy__upgradeTo(otherImplementation);

        factory.validateMarketController(controller, marketId, guardianSignals, _marketRoles());
    }

    function testRevert_validateMarketController_rejectsImplementationCodehashMismatch() external {
        address otherCore = address(new LidoLend());
        address wrongImplementation = address(new LidoLendMarketController(IMorpho(otherCore)));
        vm.prank(controllerProxyAdmin);
        OssifiableProxy(payable(controller)).proxy__upgradeTo(wrongImplementation);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.CodehashMismatch.selector,
                controller,
                factory.CONTROLLER_IMPL().codehash,
                wrongImplementation.codehash
            )
        );
        factory.validateMarketController(controller, marketId, guardianSignals, _marketRoles());
    }

    function testRevert_validateMarketController_rejectsProxyAdminMismatch() external {
        address wrongAdmin = makeAddr("wrongControllerProxyAdmin");
        vm.prank(controllerProxyAdmin);
        OssifiableProxy(payable(controller)).proxy__changeAdmin(wrongAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ProxyAdminMismatch.selector, controller, controllerProxyAdmin, wrongAdmin
            )
        );
        factory.validateMarketController(controller, marketId, guardianSignals, _marketRoles());
    }

    function testRevert_validateMarketController_rejectsMarketIdMismatch() external {
        Id wrongMarketId = Id.wrap(bytes32(uint256(1)));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.MarketIdMismatch.selector, Id.unwrap(wrongMarketId), Id.unwrap(marketId)
            )
        );
        factory.validateMarketController(controller, wrongMarketId, guardianSignals, _marketRoles());
    }

    function testRevert_validateMarketController_rejectsGuardianMismatch() external {
        address wrongGuardianSignals = factory.deployGuardianSignals(_guardianSpec(), _guardianRoles());

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ControllerGuardianMismatch.selector, wrongGuardianSignals, guardianSignals
            )
        );
        factory.validateMarketController(controller, marketId, wrongGuardianSignals, _marketRoles());
    }

    function test_validateMarketController_acceptsDuplicateAndMandatoryRoleEntries() external view {
        LidoLendMarketFactory.MarketRoles memory roles = _marketRoles();
        roles.managers = new address[](3);
        roles.managers[0] = manager;
        roles.managers[1] = manager;
        roles.managers[2] = address(lidoLendOwner);

        roles.unfreezers = new address[](2);
        roles.unfreezers[0] = unfreezer;
        roles.unfreezers[1] = address(lidoLendOwner);

        factory.validateMarketController(controller, marketId, guardianSignals, roles);
    }

    function testRevert_validateMarketController_unexpectedHolderOfEveryKnownRole() external {
        LidoLendMarketController c = LidoLendMarketController(controller);
        bytes32[] memory roles = new bytes32[](6);
        uint256[] memory expectedCounts = new uint256[](6);
        roles[0] = c.DEFAULT_ADMIN_ROLE();
        expectedCounts[0] = 1;
        roles[1] = c.MANAGER_ROLE();
        expectedCounts[1] = 3;
        roles[2] = c.PAUSER_ROLE();
        expectedCounts[2] = 1;
        roles[3] = c.FREEZER_ROLE();
        expectedCounts[3] = 1;
        roles[4] = c.UNFREEZER_ROLE();
        expectedCounts[4] = 2;
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
            factory.validateMarketController(controller, marketId, guardianSignals, _marketRoles());

            vm.prank(controllerAdmin);
            c.revokeRole(roles[i], unexpectedHolder);
        }
    }

    function test_validateGuardianSignals_acceptsExactRoleSets() external view {
        factory.validateGuardianSignals(guardianSignals, _guardianSpec(), _guardianRoles());
    }

    function test_validateGuardianSignals_acceptsCompatibleProxyWithDifferentRuntimeCodehash() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        LidoLendMarketFactory.GuardianRoles memory roles = _guardianRoles();
        address registryAddress = address(
            new MarketFactoryCompatibleProxy(
                factory.GUARDIAN_SIGNALS_IMPL(),
                roles.proxyAdmin,
                abi.encodeCall(GuardianSignals.initialize, (roles.admin, spec.guardians, spec.quorum))
            )
        );
        GuardianSignals registry = GuardianSignals(registryAddress);

        vm.startPrank(roles.admin);
        registry.grantRole(registry.MANAGER_ROLE(), roles.admin);
        registry.setSuspectWindow(spec.suspectWindow);
        registry.revokeRole(registry.MANAGER_ROLE(), roles.admin);
        registry.grantRole(registry.MANAGER_ROLE(), guardianManager);
        registry.grantRole(registry.ACCESS_RESTORER_ROLE(), guardianManager);
        registry.grantRole(registry.MANAGER_ROLE(), address(lidoLendOwner));
        registry.grantRole(registry.ACCESS_RESTORER_ROLE(), address(lidoLendOwner));
        registry.grantRole(registry.ACCESS_LIMITER_ROLE(), accessLimiter);
        vm.stopPrank();

        assertTrue(registryAddress.codehash != guardianSignals.codehash, "proxy runtimes must differ");
        factory.validateGuardianSignals(registryAddress, spec, roles);
    }

    function testRevert_validateGuardianSignals_rejectsImplementationMismatch() external {
        address wrongImplementation = factory.CONTROLLER_IMPL();
        vm.prank(guardianProxyAdmin);
        OssifiableProxy(payable(guardianSignals)).proxy__upgradeTo(wrongImplementation);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.CodehashMismatch.selector,
                guardianSignals,
                factory.GUARDIAN_SIGNALS_IMPL().codehash,
                wrongImplementation.codehash
            )
        );
        factory.validateGuardianSignals(guardianSignals, _guardianSpec(), _guardianRoles());
    }

    function testRevert_validateGuardianSignals_rejectsQuorumMismatch() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.quorum = 2;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.GuardianQuorumMismatch.selector, 2, 1));
        factory.validateGuardianSignals(guardianSignals, spec, _guardianRoles());
    }

    function testRevert_validateGuardianSignals_rejectsSuspectWindowMismatch() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.suspectWindow = 1;

        vm.expectRevert(
            abi.encodeWithSelector(LidoLendMarketFactory.GuardianSuspectWindowMismatch.selector, 1, 2 hours)
        );
        factory.validateGuardianSignals(guardianSignals, spec, _guardianRoles());
    }

    function testRevert_validateGuardianSignals_rejectsGuardianCountMismatch() external {
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.guardians = new address[](1);
        spec.guardians[0] = guardianA;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.GuardianCountMismatch.selector, 1, 2));
        factory.validateGuardianSignals(guardianSignals, spec, _guardianRoles());
    }

    function testRevert_validateGuardianSignals_rejectsMissingGuardian() external {
        address missingGuardian = makeAddr("missingGuardian");
        LidoLendMarketFactory.GuardianSpec memory spec = _guardianSpec();
        spec.guardians[1] = missingGuardian;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.MissingGuardian.selector, missingGuardian));
        factory.validateGuardianSignals(guardianSignals, spec, _guardianRoles());
    }

    function testRevert_validateGuardianSignals_unexpectedHolderOfEveryKnownRole() external {
        GuardianSignals registry = GuardianSignals(guardianSignals);
        bytes32[] memory roles = new bytes32[](4);
        uint256[] memory expectedCounts = new uint256[](4);
        roles[0] = registry.DEFAULT_ADMIN_ROLE();
        expectedCounts[0] = 1;
        roles[1] = registry.MANAGER_ROLE();
        expectedCounts[1] = 2;
        roles[2] = registry.ACCESS_RESTORER_ROLE();
        expectedCounts[2] = 2;
        roles[3] = registry.ACCESS_LIMITER_ROLE();
        expectedCounts[3] = 1;

        for (uint256 i; i < roles.length; ++i) {
            address unexpectedHolder = address(uint160(0xBAD1 + i));
            vm.prank(guardianAdmin);
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
            factory.validateGuardianSignals(guardianSignals, _guardianSpec(), _guardianRoles());

            vm.prank(guardianAdmin);
            registry.revokeRole(roles[i], unexpectedHolder);
        }
    }

    function test_validateGuardianSignals_acceptsEmptyAccessLimiterRole() external {
        LidoLendMarketFactory.GuardianRoles memory roles = _guardianRoles();
        roles.accessLimiter = address(0);
        address registry = factory.deployGuardianSignals(_guardianSpec(), roles);

        factory.validateGuardianSignals(registry, _guardianSpec(), roles);
    }

    function testRevert_validateGuardianSignals_unexpectedAccessLimiterWhenExpectedEmpty() external {
        LidoLendMarketFactory.GuardianRoles memory roles = _guardianRoles();
        roles.accessLimiter = address(0);
        address registryAddress = factory.deployGuardianSignals(_guardianSpec(), roles);
        GuardianSignals registry = GuardianSignals(registryAddress);
        address unexpectedHolder = makeAddr("unexpectedAccessLimiter");
        bytes32 limiterRole = registry.ACCESS_LIMITER_ROLE();

        vm.prank(guardianAdmin);
        registry.grantRole(limiterRole, unexpectedHolder);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.RoleMemberCountMismatch.selector, registryAddress, limiterRole, 0, 1
            )
        );
        factory.validateGuardianSignals(registryAddress, _guardianSpec(), roles);
    }

    function test_validateGuardianSignals_acceptsDuplicateAndMandatoryRoleEntries() external view {
        LidoLendMarketFactory.GuardianRoles memory roles = _guardianRoles();
        roles.managers = new address[](3);
        roles.managers[0] = guardianManager;
        roles.managers[1] = guardianManager;
        roles.managers[2] = address(lidoLendOwner);

        factory.validateGuardianSignals(guardianSignals, _guardianSpec(), roles);
    }

    function test_validateVault_acceptsExpectedBinding() external view {
        factory.validateVault(vault, LidoLendMarketController(controller), marketParams, _vaultSpec());
    }

    function testRevert_validateVault_rejectsZeroProxyAdminPolicy() external {
        LidoLendMarketFactory.VaultSpec memory spec = _vaultSpec();
        spec.proxyAdmin = address(0);

        vm.expectRevert(LidoLendMarketFactory.ZeroAddress.selector);
        factory.validateVault(vault, LidoLendMarketController(controller), marketParams, spec);
    }

    function testRevert_validateVault_rejectsProxyAdminMismatch() external {
        address wrongAdmin = makeAddr("wrongVaultProxyAdmin");
        vm.prank(controllerProxyAdmin);
        OssifiableProxy(payable(vault)).proxy__changeAdmin(wrongAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ProxyAdminMismatch.selector, vault, controllerProxyAdmin, wrongAdmin
            )
        );
        factory.validateVault(vault, LidoLendMarketController(controller), marketParams, _vaultSpec());
    }

    function testRevert_validateVault_rejectsControllerMismatch() external {
        (, address otherController) = factory.deployMarketController(marketSpec, _marketRoles());

        vm.expectRevert(
            abi.encodeWithSelector(LidoLendMarketFactory.VaultControllerMismatch.selector, otherController, controller)
        );
        factory.validateVault(vault, LidoLendMarketController(otherController), marketParams, _vaultSpec());
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

    function _marketRoles() private view returns (LidoLendMarketFactory.MarketRoles memory roles) {
        roles.admin = controllerAdmin;
        roles.proxyAdmin = controllerProxyAdmin;
        roles.managers = _single(manager);
        roles.pausers = _single(pauser);
        roles.freezers = _single(freezer);
        roles.unfreezers = _single(unfreezer);
        roles.resumers = _single(resumer);
    }

    function _guardianSpec() private view returns (LidoLendMarketFactory.GuardianSpec memory spec) {
        address[] memory guardians = new address[](2);
        guardians[0] = guardianA;
        guardians[1] = guardianB;
        spec = LidoLendMarketFactory.GuardianSpec({guardians: guardians, quorum: 1, suspectWindow: 2 hours});
    }

    function _guardianRoles() private view returns (LidoLendMarketFactory.GuardianRoles memory roles) {
        roles = LidoLendMarketFactory.GuardianRoles({
            admin: guardianAdmin,
            proxyAdmin: guardianProxyAdmin,
            managers: _single(guardianManager),
            accessLimiter: accessLimiter
        });
    }

    function _vaultSpec() private view returns (LidoLendMarketFactory.VaultSpec memory spec) {
        spec = LidoLendMarketFactory.VaultSpec({
            proxyAdmin: controllerProxyAdmin, name: "Lido Loan Vault", symbol: "lidoLOAN"
        });
    }

    function _single(address holder) private pure returns (address[] memory holders) {
        holders = new address[](1);
        holders[0] = holder;
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
