// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

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
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {IIrmRouterView, LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice Scenario for the permissionless factory. It deploys fully wired controller and vault proxies but
///         leaves core market creation and IRM routing to a separate activation transaction.
contract MarketFactoryScenarioTest is Test {
    using MarketParamsLib for MarketParams;

    address internal constant GOVERNANCE = address(0xA11CE);

    address internal caller;
    address internal marketAdmin;
    address internal marketProxyAdmin;
    address internal manager1;
    address internal manager2;
    address internal pauser1;
    address internal pauser2;
    address internal freezer;
    address internal unfreezer;
    address internal resumer;

    ILidoLend internal core;
    LidoLendOwner internal facade;
    IIrmRouter internal router;
    address internal riskStewardDashboard;
    address internal controllerImpl;
    address internal vaultImpl;
    address internal guardianSignalsImpl;
    address internal guardianSignals;
    LidoLendMarketFactory internal factory;

    function setUp() external {
        caller = makeAddr("caller");
        marketAdmin = makeAddr("marketAdmin");
        marketProxyAdmin = makeAddr("marketProxyAdmin");
        manager1 = makeAddr("manager1");
        manager2 = makeAddr("manager2");
        pauser1 = makeAddr("pauser1");
        pauser2 = makeAddr("pauser2");
        freezer = makeAddr("freezer");
        unfreezer = makeAddr("unfreezer");
        resumer = makeAddr("resumer");

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

        controllerImpl = address(new LidoLendMarketController(IMorpho(address(core))));
        vaultImpl = address(new LidoLendERC4626(address(core)));
        guardianSignalsImpl = address(new GuardianSignals());
        factory = new LidoLendMarketFactory(
            LidoLendMarketFactory.Implementations({
                controller: controllerImpl, vault: vaultImpl, guardianSignals: guardianSignalsImpl
            }),
            ILidoLendOwner(address(facade)),
            IIrmRouterView(address(router)),
            riskStewardDashboard
        );

        vm.prank(caller);
        guardianSignals = factory.deployGuardianSignals(_guardianSpec(), _guardianRoles(GOVERNANCE, GOVERNANCE));
    }

    function test_deployMarketComponents_producesInertWiredComponents() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        LidoLendMarketFactory.MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);
        LidoLendMarketFactory.VaultSpec memory vaultSpec = _vaultSpec(marketProxyAdmin, "A");
        LidoLendMarketFactory.MarketComponents memory components = _deployMarketComponents(market, roles, vaultSpec);

        assertEq(
            IOssifiableProxy(components.controller).proxy__getImplementation(),
            factory.CONTROLLER_IMPL(),
            "controller impl"
        );
        assertEq(IOssifiableProxy(components.vault).proxy__getImplementation(), factory.VAULT_IMPL(), "vault impl");

        LidoLendMarketController controller = LidoLendMarketController(components.controller);
        assertEq(Id.unwrap(controller.marketId()), Id.unwrap(components.marketId), "controller market id");
        assertEq(controller.guardianSignals(), guardianSignals, "controller guardian signals");
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), marketAdmin), "admin");
        assertFalse(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(factory)), "factory keeps no admin");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), manager1), "manager1");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), manager2), "manager2");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), address(facade)), "facade manager");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), riskStewardDashboard), "dashboard manager");
        assertTrue(controller.hasRole(controller.PAUSER_ROLE(), pauser1), "pauser1");
        assertTrue(controller.hasRole(controller.PAUSER_ROLE(), pauser2), "pauser2");
        assertTrue(controller.hasRole(controller.FREEZER_ROLE(), freezer), "freezer");
        assertTrue(controller.hasRole(controller.UNFREEZER_ROLE(), unfreezer), "unfreezer");
        assertTrue(controller.hasRole(controller.UNFREEZER_ROLE(), address(facade)), "facade unfreezer");
        assertTrue(controller.hasRole(controller.RESUMER_ROLE(), resumer), "resumer");

        assertEq(IOssifiableProxy(components.controller).proxy__getAdmin(), marketProxyAdmin, "controller proxy admin");
        assertEq(IOssifiableProxy(components.vault).proxy__getAdmin(), marketProxyAdmin, "vault proxy admin");

        LidoLendERC4626 vault = LidoLendERC4626(components.vault);
        assertEq(address(vault.controller()), components.controller, "vault controller");
        assertEq(vault.name(), vaultSpec.name, "vault name");
        assertEq(vault.symbol(), vaultSpec.symbol, "vault symbol");

        assertEq(core.market(components.marketId).lastUpdate, 0, "market remains uncreated");
        assertEq(core.marketController(components.marketId), address(0), "core controller remains unset");
        assertEq(address(router.marketIrm(_toIrmId(components.marketId))), address(0), "IRM route remains unset");
    }

    function test_deployMarketComponents_emitsAggregateEvent() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        LidoLendMarketFactory.MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);
        LidoLendMarketFactory.VaultSpec memory vaultSpec = _vaultSpec(marketProxyAdmin, "A");
        Id expectedId = _marketParams(market).id();

        vm.expectEmit(true, false, false, false, address(factory));
        emit LidoLendMarketFactory.MarketComponentsDeployed(expectedId, address(0), address(0), guardianSignals);

        _deployMarketComponents(market, roles, vaultSpec);
    }

    function test_deployMarketComponents_secondMarketReusesImplementations() external {
        (MockERC20 loanA, MockERC20 collateralA, address oracleA) = _deployTokensAndOracle("A", 1.05e36);
        (MockERC20 loanB, MockERC20 collateralB, address oracleB) = _deployTokensAndOracle("B", 0.92e36);

        LidoLendMarketFactory.MarketComponents memory first = _deployMarketComponents(
            _marketSpec(loanA, collateralA, oracleA),
            _roles(marketAdmin, marketProxyAdmin),
            _vaultSpec(marketProxyAdmin, "A")
        );
        LidoLendMarketFactory.MarketComponents memory second = _deployMarketComponents(
            _marketSpec(loanB, collateralB, oracleB),
            _roles(marketAdmin, marketProxyAdmin),
            _vaultSpec(marketProxyAdmin, "B")
        );

        assertTrue(first.controller != second.controller, "distinct controllers");
        assertTrue(first.vault != second.vault, "distinct vaults");
        assertEq(
            IOssifiableProxy(first.controller).proxy__getImplementation(),
            IOssifiableProxy(second.controller).proxy__getImplementation(),
            "shared controller implementation"
        );
        assertEq(
            IOssifiableProxy(first.vault).proxy__getImplementation(),
            IOssifiableProxy(second.vault).proxy__getImplementation(),
            "shared vault implementation"
        );
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
        factory.deployMarketComponents(market, _roles(marketAdmin, marketProxyAdmin), _vaultSpec(marketProxyAdmin, "A"));
    }

    function testRevert_deployMarketComponents_nonContractOracle() external {
        (MockERC20 loan, MockERC20 collateral,) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, address(0));

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.NotContract.selector, address(0)));
        factory.deployMarketComponents(market, _roles(marketAdmin, marketProxyAdmin), _vaultSpec(marketProxyAdmin, "A"));

        market.oracle = makeAddr("not an oracle");
        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.NotContract.selector, market.oracle));
        factory.deployMarketComponents(market, _roles(marketAdmin, marketProxyAdmin), _vaultSpec(marketProxyAdmin, "A"));
    }

    function testRevert_deployMarketComponents_invalidGuardianProxy() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        market.guardianSignals = makeAddr("not a guardian proxy");

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.NotContract.selector, market.guardianSignals));
        factory.deployMarketComponents(market, _roles(marketAdmin, marketProxyAdmin), _vaultSpec(marketProxyAdmin, "A"));
    }

    function testRevert_deployMarketComponents_wrongGuardianImplementation() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        address wrongGuardian = address(new OssifiableProxy(controllerImpl, marketProxyAdmin, ""));
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        market.guardianSignals = wrongGuardian;

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.CodehashMismatch.selector,
                wrongGuardian,
                guardianSignalsImpl.codehash,
                controllerImpl.codehash
            )
        );
        factory.deployMarketComponents(market, _roles(marketAdmin, marketProxyAdmin), _vaultSpec(marketProxyAdmin, "A"));
    }

    function testRevert_deployMarketComponents_invalidLltv() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketSpec memory market = _marketSpec(loan, collateral, oracle);
        market.lltv = 1e18;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketFactory.InvalidLltv.selector, 1e18));
        factory.deployMarketComponents(market, _roles(marketAdmin, marketProxyAdmin), _vaultSpec(marketProxyAdmin, "A"));
    }

    function testRevert_deployMarketComponents_zeroRoleHolder() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketFactory.MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);
        roles.managers[1] = address(0);

        vm.expectRevert(LidoLendMarketFactory.ZeroRoleHolder.selector);
        factory.deployMarketComponents(_marketSpec(loan, collateral, oracle), roles, _vaultSpec(marketProxyAdmin, "A"));
    }

    function testRevert_deployMarketComponents_zeroAdmin() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);

        vm.expectRevert(LidoLendMarketFactory.ZeroAddress.selector);
        factory.deployMarketComponents(
            _marketSpec(loan, collateral, oracle),
            _roles(address(0), marketProxyAdmin),
            _vaultSpec(marketProxyAdmin, "A")
        );
    }

    function testRevert_deployMarketComponents_zeroProxyAdmin() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);

        vm.expectRevert(LidoLendMarketFactory.ZeroAddress.selector);
        factory.deployMarketComponents(
            _marketSpec(loan, collateral, oracle), _roles(marketAdmin, address(0)), _vaultSpec(marketProxyAdmin, "A")
        );
    }

    function test_constructor_revertsOnRouterCoreMismatch() external {
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
            abi.encodeWithSelector(LidoLendMarketFactory.CoreMismatch.selector, address(core), address(otherCore))
        );
        new LidoLendMarketFactory(
            _implementations(controllerImpl, vaultImpl),
            ILidoLendOwner(address(facade)),
            IIrmRouterView(address(mismatchedRouter)),
            riskStewardDashboard
        );
    }

    function testRevert_constructor_controllerImplementationUsesAnotherCore() external {
        ILidoLend otherCore = _deployCore(GOVERNANCE);
        address otherControllerImpl = address(new LidoLendMarketController(IMorpho(address(otherCore))));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ImplementationCoreMismatch.selector,
                otherControllerImpl,
                address(core),
                address(otherCore)
            )
        );
        new LidoLendMarketFactory(
            _implementations(otherControllerImpl, vaultImpl),
            ILidoLendOwner(address(facade)),
            IIrmRouterView(address(router)),
            riskStewardDashboard
        );
    }

    function testRevert_constructor_vaultImplementationUsesAnotherCore() external {
        ILidoLend otherCore = _deployCore(GOVERNANCE);
        address otherVaultImpl = address(new LidoLendERC4626(address(otherCore)));

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketFactory.ImplementationCoreMismatch.selector,
                otherVaultImpl,
                address(core),
                address(otherCore)
            )
        );
        new LidoLendMarketFactory(
            _implementations(controllerImpl, otherVaultImpl),
            ILidoLendOwner(address(facade)),
            IIrmRouterView(address(router)),
            riskStewardDashboard
        );
    }

    function test_deployAfterCoreOwnershipMoves_succeeds() external {
        address newOwner = makeAddr("newCoreOwner");
        vm.prank(GOVERNANCE);
        facade.transferLidoLendOwnership(newOwner);

        address deployed = factory.deployGuardianSignals(_guardianSpec(), _guardianRoles(GOVERNANCE, GOVERNANCE));

        assertEq(IOssifiableProxy(deployed).proxy__getImplementation(), guardianSignalsImpl, "implementation");
    }

    function test_deployGuardianSignals_producesWiredRegistry() external {
        address guardianAdmin = makeAddr("guardianAdmin");
        address guardianProxyAdmin = makeAddr("guardianProxyAdmin");
        address guardianManager1 = makeAddr("guardianManager1");
        address guardianManager2 = makeAddr("guardianManager2");
        address accessLimiter = makeAddr("accessLimiter");

        address[] memory guardianSet = new address[](2);
        guardianSet[0] = makeAddr("guardian1");
        guardianSet[1] = makeAddr("guardian2");
        address[] memory managers = new address[](2);
        managers[0] = guardianManager1;
        managers[1] = guardianManager2;
        LidoLendMarketFactory.GuardianSpec memory spec =
            LidoLendMarketFactory.GuardianSpec({guardians: guardianSet, quorum: 2, suspectWindow: 3600});
        LidoLendMarketFactory.GuardianRoles memory roles = LidoLendMarketFactory.GuardianRoles({
            admin: guardianAdmin, proxyAdmin: guardianProxyAdmin, managers: managers, accessLimiter: accessLimiter
        });

        vm.prank(caller);
        address deployed = factory.deployGuardianSignals(spec, roles);

        assertEq(IOssifiableProxy(deployed).proxy__getImplementation(), guardianSignalsImpl, "implementation");
        assertEq(IOssifiableProxy(deployed).proxy__getAdmin(), guardianProxyAdmin, "proxy admin");

        GuardianSignals signals = GuardianSignals(deployed);
        assertEq(signals.getQuorum(), 2, "quorum");
        assertEq(signals.getSuspectWindow(), 3600, "suspect window");
        assertTrue(signals.isGuardian(guardianSet[0]), "guardian1");
        assertTrue(signals.isGuardian(guardianSet[1]), "guardian2");
        assertTrue(signals.hasRole(signals.DEFAULT_ADMIN_ROLE(), guardianAdmin), "admin");
        assertTrue(signals.hasRole(signals.MANAGER_ROLE(), guardianManager1), "manager1");
        assertTrue(signals.hasRole(signals.MANAGER_ROLE(), guardianManager2), "manager2");
        assertTrue(signals.hasRole(signals.MANAGER_ROLE(), address(facade)), "facade manager");
        assertTrue(signals.hasRole(signals.ACCESS_RESTORER_ROLE(), guardianManager1), "restorer1");
        assertTrue(signals.hasRole(signals.ACCESS_RESTORER_ROLE(), guardianManager2), "restorer2");
        assertTrue(signals.hasRole(signals.ACCESS_RESTORER_ROLE(), address(facade)), "facade restorer");
        assertTrue(signals.hasRole(signals.ACCESS_LIMITER_ROLE(), accessLimiter), "access limiter");
        assertFalse(signals.hasRole(signals.DEFAULT_ADMIN_ROLE(), address(factory)), "factory keeps no admin");
        assertFalse(signals.hasRole(signals.MANAGER_ROLE(), address(factory)), "factory keeps no manager");
    }

    function testRevert_deployGuardianSignals_zeroAdmin() external {
        LidoLendMarketFactory.GuardianRoles memory roles = _guardianRoles(address(0), marketProxyAdmin);

        vm.expectRevert(LidoLendMarketFactory.ZeroAddress.selector);
        factory.deployGuardianSignals(_guardianSpec(), roles);
    }

    function testRevert_deployGuardianSignals_zeroProxyAdmin() external {
        LidoLendMarketFactory.GuardianRoles memory roles = _guardianRoles(marketAdmin, address(0));

        vm.expectRevert(LidoLendMarketFactory.ZeroAddress.selector);
        factory.deployGuardianSignals(_guardianSpec(), roles);
    }

    function testRevert_deployGuardianSignals_zeroRoleHolder() external {
        LidoLendMarketFactory.GuardianRoles memory roles = _guardianRoles(marketAdmin, marketProxyAdmin);
        roles.managers = new address[](2);
        roles.managers[0] = manager1;

        vm.expectRevert(LidoLendMarketFactory.ZeroRoleHolder.selector);
        factory.deployGuardianSignals(_guardianSpec(), roles);
    }

    function _deployMarketComponents(
        LidoLendMarketFactory.MarketSpec memory market,
        LidoLendMarketFactory.MarketRoles memory roles,
        LidoLendMarketFactory.VaultSpec memory vaultSpec
    ) internal returns (LidoLendMarketFactory.MarketComponents memory components) {
        vm.prank(caller);
        components = factory.deployMarketComponents(market, roles, vaultSpec);
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

    function _implementations(address controller, address vault)
        internal
        view
        returns (LidoLendMarketFactory.Implementations memory)
    {
        return LidoLendMarketFactory.Implementations({
            controller: controller, vault: vault, guardianSignals: guardianSignalsImpl
        });
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
            activationConfig: CollateralActivationConfig({
                minActivationDelay: 10 minutes,
                maxActivationDelay: 2 hours,
                maxDelayInflow: 10_000 ether,
                activatingLockAmount: 0,
                activatingLockDuration: 0,
                minActivationAmount: 10 ether,
                maxGuardiansQuorumDelay: 0,
                delayPerStrike: 2 hours,
                delayPerSuspect: 0
            }),
            settlementConfig: SettlementConfig({
                sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
            })
        });
    }

    function _roles(address admin, address proxyAdmin)
        internal
        view
        returns (LidoLendMarketFactory.MarketRoles memory roles)
    {
        roles.admin = admin;
        roles.proxyAdmin = proxyAdmin;
        roles.managers = new address[](2);
        roles.managers[0] = manager1;
        roles.managers[1] = manager2;
        roles.pausers = new address[](2);
        roles.pausers[0] = pauser1;
        roles.pausers[1] = pauser2;
        roles.freezers = new address[](1);
        roles.freezers[0] = freezer;
        roles.unfreezers = new address[](1);
        roles.unfreezers[0] = unfreezer;
        roles.resumers = new address[](1);
        roles.resumers[0] = resumer;
    }

    function _vaultSpec(address proxyAdmin, string memory salt)
        internal
        pure
        returns (LidoLendMarketFactory.VaultSpec memory)
    {
        return LidoLendMarketFactory.VaultSpec({
            proxyAdmin: proxyAdmin,
            name: string.concat("Lido Loan Vault ", salt),
            symbol: string.concat("lidoLOAN", salt)
        });
    }

    function _guardianSpec() internal pure returns (LidoLendMarketFactory.GuardianSpec memory spec) {
        spec.guardians = new address[](1);
        spec.guardians[0] = GOVERNANCE;
        spec.quorum = 1;
        spec.suspectWindow = 0;
    }

    function _guardianRoles(address admin, address proxyAdmin)
        internal
        pure
        returns (LidoLendMarketFactory.GuardianRoles memory roles)
    {
        roles.admin = admin;
        roles.proxyAdmin = proxyAdmin;
        roles.managers = new address[](0);
        roles.accessLimiter = address(0);
    }
}
