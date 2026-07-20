// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
// The router's `Id` is a distinct UDVT (the IRM submodule's nested core copy); same underlying bytes32.
import {Id as IrmId} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {LidoLendMarketBuilder, MarketRoles, GuardianConfig} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice Scenario for `LidoLendMarketBuilder.buildMarketContracts` in isolation: it produces the per-market
///         components (controller, vault) via `LidoLendMarketFactory`, fully role-wired but INERT — not
///         created on the core, not routed, not registered anywhere — and self-checks the result with its own
///         `validateMarketContracts` before returning. Binding them is the separate activation step, covered
///         end-to-end elsewhere. Here we prove the deploy is correct, that neither the builder nor the factory
///         retains anything, and that every pre-check / role-array edge reverts correctly.
contract MarketBuilderScenarioTest is Test {
    using MarketParamsLib for MarketParams;

    address internal constant GOVERNANCE = address(0xA11CE);
    address internal deployer; // arbitrary caller — `buildMarketContracts` is permissionless
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
    address internal guardianSignals;
    address internal riskStewardDashboard;
    IIrmRouter internal router;
    address internal controllerImpl;
    address internal vaultImpl;
    LidoLendMarketFactory internal factory;
    LidoLendMarketBuilder internal builder;

    function setUp() external {
        deployer = makeAddr("deployer");
        marketAdmin = makeAddr("marketAdmin");
        marketProxyAdmin = makeAddr("marketProxyAdmin");
        manager1 = makeAddr("manager1");
        manager2 = makeAddr("manager2");
        pauser1 = makeAddr("pauser1"); // stand-in for a CircuitBreaker instance
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

        address[] memory guardians = new address[](1);
        guardians[0] = GOVERNANCE;
        guardianSignals = address(
            new OssifiableProxy(
                address(new GuardianSignals()),
                GOVERNANCE,
                abi.encodeWithSignature("initialize(address,address[],uint256)", GOVERNANCE, guardians, 1)
            )
        );
        router = IIrmRouter(
            address(
                new OssifiableProxy(
                    address(new IrmRouter(address(core))),
                    GOVERNANCE,
                    abi.encodeWithSignature("initialize(address,address)", GOVERNANCE, GOVERNANCE)
                )
            )
        );

        // Protocol risk-steward dashboard: the builder grants it each controller's MANAGER_ROLE at deploy.
        riskStewardDashboard = address(new RiskStewardDashboard(GOVERNANCE, core));

        // Shared impls are deployed separately and injected (the factory cannot `new` them without overflowing
        // its EIP-3860 initcode limit).
        controllerImpl = address(new LidoLendMarketController(IMorpho(address(core))));
        vaultImpl = address(new LidoLendERC4626(address(core)));

        factory = new LidoLendMarketFactory(controllerImpl, vaultImpl, address(new GuardianSignals()));
        builder = new LidoLendMarketBuilder(factory, ILidoLendOwner(address(facade)), router, riskStewardDashboard);
    }

    function test_buildMarketContracts_producesInertWiredComponents() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketBuilder.MarketSpec memory market = _marketSpec(loan, collateral, oracle, "A");
        MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);
        LidoLendMarketBuilder.MarketContracts memory built = _buildMarketContracts(market, roles);

        // Components deployed at the shared, immutable implementations.
        assertEq(IOssifiableProxy(built.controller).proxy__getImplementation(), factory.CONTROLLER_IMPL());
        assertEq(IOssifiableProxy(built.vault).proxy__getImplementation(), factory.VAULT_IMPL());

        // Controller: bound to the right market id and guardian registry, roles on final holders, neither the
        // builder nor the factory keeps anything.
        LidoLendMarketController controller = LidoLendMarketController(built.controller);
        assertEq(bytes32(abi.encode(controller.marketId())), bytes32(abi.encode(built.marketId)), "controller marketId");
        assertEq(controller.guardianSignals(), guardianSignals, "controller guardianSignals");
        assertTrue(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), marketAdmin), "admin");
        assertFalse(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(builder)), "builder keeps no admin");
        assertFalse(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(factory)), "factory keeps no admin");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), manager1), "manager1");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), manager2), "manager2");
        assertTrue(controller.hasRole(controller.MANAGER_ROLE(), riskStewardDashboard), "dashboard manager");
        assertTrue(controller.hasRole(controller.PAUSER_ROLE(), pauser1), "pauser1");
        assertTrue(controller.hasRole(controller.PAUSER_ROLE(), pauser2), "pauser2");
        assertTrue(controller.hasRole(controller.FREEZER_ROLE(), freezer), "freezer");
        assertTrue(controller.hasRole(controller.UNFREEZER_ROLE(), unfreezer), "unfreezer");
        assertTrue(controller.hasRole(controller.RESUMER_ROLE(), resumer), "resumer");

        // Proxy admins on final holders.
        assertEq(IOssifiableProxy(built.controller).proxy__getAdmin(), marketProxyAdmin, "controller proxy admin");
        assertEq(IOssifiableProxy(built.vault).proxy__getAdmin(), marketProxyAdmin, "vault proxy admin");
        assertEq(address(LidoLendERC4626(built.vault).controller()), built.controller, "vault controller binding");

        // The whole point: it is INERT. Not created on the core, not routed on the shared router.
        assertEq(core.market(built.marketId).lastUpdate, 0, "market must NOT be created yet");
        assertEq(core.marketController(built.marketId), address(0), "market must have no controller on the core yet");
        assertEq(address(router.marketIrm(_toIrmId(built.marketId))), address(0), "market must NOT be routed yet");
    }

    function test_buildMarketContracts_emitsMarketContractsDeployed() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketBuilder.MarketSpec memory market = _marketSpec(loan, collateral, oracle, "A");
        MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);

        MarketParams memory params = MarketParams({
            loanToken: address(loan),
            collateralToken: address(collateral),
            oracle: oracle,
            irm: address(router),
            lltv: 0.8e18
        });
        Id expectedId = params.id();

        vm.expectEmit(true, false, false, false, address(builder));
        emit LidoLendMarketBuilder.MarketContractsDeployed(
            expectedId, address(0), address(0), address(0), address(0), roles
        );
        _buildMarketContracts(market, roles);
    }

    function test_buildMarketContracts_secondMarketReusesSharedImpls() external {
        (MockERC20 lA, MockERC20 cA, address oA) = _deployTokensAndOracle("A", 1.05e36);
        (MockERC20 lB, MockERC20 cB, address oB) = _deployTokensAndOracle("B", 0.92e36);
        LidoLendMarketBuilder.MarketContracts memory builtA =
            _buildMarketContracts(_marketSpec(lA, cA, oA, "A"), _roles(marketAdmin, marketProxyAdmin));
        LidoLendMarketBuilder.MarketContracts memory builtB =
            _buildMarketContracts(_marketSpec(lB, cB, oB, "B"), _roles(marketAdmin, marketProxyAdmin));

        assertTrue(builtA.controller != builtB.controller, "distinct controllers");
        assertEq(
            IOssifiableProxy(builtA.controller).proxy__getImplementation(),
            IOssifiableProxy(builtB.controller).proxy__getImplementation(),
            "controller impl shared"
        );
        assertEq(
            IOssifiableProxy(builtA.vault).proxy__getImplementation(),
            IOssifiableProxy(builtB.vault).proxy__getImplementation(),
            "vault impl shared"
        );
    }

    function testRevert_buildMarketContracts_marketAlreadyExists() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketBuilder.MarketSpec memory market = _marketSpec(loan, collateral, oracle, "A");
        MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);

        MarketParams memory params = MarketParams({
            loanToken: address(loan),
            collateralToken: address(collateral),
            oracle: oracle,
            irm: address(router),
            lltv: 0.8e18
        });
        Id id = params.id();

        // Simulate an already-created market by stubbing the core's read rather than going through the real
        // facade/IRM registration dance — irrelevant machinery for this pre-check.
        vm.mockCall(
            address(core),
            abi.encodeWithSelector(IMorpho.market.selector, id),
            abi.encode(uint128(0), uint128(0), uint128(0), uint128(0), uint128(1), uint128(0))
        );

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketBuilder.MarketAlreadyExists.selector, id));
        vm.prank(deployer);
        builder.buildMarketContracts(market, roles);
    }

    /// @dev The external dependency must at least be a contract (covers zero and typo'd addresses), so a
    ///      codeless reference fails the deploy up front. Interface compatibility is deliberately NOT probed
    ///      (see the builder), so a wrong-but-live contract passes here and reverts at first real use instead.
    function testRevert_buildMarketContracts_codelessGuardianSignals() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketBuilder.MarketSpec memory market = _marketSpec(loan, collateral, oracle, "A");
        MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);

        market.guardianSignals = address(0);
        vm.expectRevert(LidoLendMarketBuilder.GuardianSignalsNotContract.selector);
        vm.prank(deployer);
        builder.buildMarketContracts(market, roles);

        market.guardianSignals = makeAddr("not a registry"); // EOA — no code
        vm.expectRevert(LidoLendMarketBuilder.GuardianSignalsNotContract.selector);
        vm.prank(deployer);
        builder.buildMarketContracts(market, roles);
    }

    function testRevert_buildMarketContracts_codelessOracle() external {
        (MockERC20 loan, MockERC20 collateral,) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketBuilder.MarketSpec memory market = _marketSpec(loan, collateral, address(0), "A");
        MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);

        vm.expectRevert(LidoLendMarketBuilder.OracleNotContract.selector);
        vm.prank(deployer);
        builder.buildMarketContracts(market, roles);

        market.oracle = makeAddr("not an oracle"); // EOA — no code
        vm.expectRevert(LidoLendMarketBuilder.OracleNotContract.selector);
        vm.prank(deployer);
        builder.buildMarketContracts(market, roles);
    }

    function testRevert_buildMarketContracts_zeroRoleHolder() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketBuilder.MarketSpec memory market = _marketSpec(loan, collateral, oracle, "A");
        MarketRoles memory roles = _roles(marketAdmin, marketProxyAdmin);
        roles.managers = new address[](2);
        roles.managers[0] = manager1;
        roles.managers[1] = address(0);

        vm.expectRevert(LidoLendMarketBuilder.ZeroRoleHolder.selector);
        vm.prank(deployer);
        builder.buildMarketContracts(market, roles);
    }

    function test_constructor_revertsOnCoreMismatch() external {
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
        vm.expectRevert(LidoLendMarketBuilder.CoreMismatch.selector);
        new LidoLendMarketBuilder(factory, ILidoLendOwner(address(facade)), mismatchedRouter, riskStewardDashboard);
    }

    function testRevert_buildMarketContracts_zeroAdmin() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketBuilder.MarketSpec memory market = _marketSpec(loan, collateral, oracle, "A");
        MarketRoles memory roles = _roles(address(0), marketProxyAdmin);

        vm.expectRevert(LidoLendMarketBuilder.ZeroAdmin.selector);
        vm.prank(deployer);
        builder.buildMarketContracts(market, roles);
    }

    function testRevert_buildMarketContracts_zeroProxyAdmin() external {
        (MockERC20 loan, MockERC20 collateral, address oracle) = _deployTokensAndOracle("A", 1.05e36);
        LidoLendMarketBuilder.MarketSpec memory market = _marketSpec(loan, collateral, oracle, "A");
        MarketRoles memory roles = _roles(marketAdmin, address(0));

        vm.expectRevert(LidoLendMarketBuilder.ZeroProxyAdmin.selector);
        vm.prank(deployer);
        builder.buildMarketContracts(market, roles);
    }

    // ---
    // buildGuardianSignals
    // ---

    function test_buildGuardianSignals_producesWiredRegistry() external {
        address gAdmin = makeAddr("gAdmin");
        address gProxyAdmin = makeAddr("gProxyAdmin");
        address gManager1 = makeAddr("gManager1");
        address gManager2 = makeAddr("gManager2");
        address accessLimiter = makeAddr("accessLimiter");
        address[] memory guardianSet = new address[](2);
        guardianSet[0] = makeAddr("guardian1");
        guardianSet[1] = makeAddr("guardian2");
        address[] memory managers = new address[](2);
        managers[0] = gManager1;
        managers[1] = gManager2;

        GuardianConfig memory cfg =
            GuardianConfig({guardians: guardianSet, quorum: 2, suspectWindow: 3600, accessLimiter: accessLimiter});

        vm.prank(deployer);
        address guardianSignals = builder.buildGuardianSignals(cfg, gAdmin, managers, gProxyAdmin);

        assertEq(IOssifiableProxy(guardianSignals).proxy__getImplementation(), factory.GUARDIAN_SIGNALS_IMPL(), "impl");
        assertEq(IOssifiableProxy(guardianSignals).proxy__getAdmin(), gProxyAdmin, "proxy admin");

        GuardianSignals g = GuardianSignals(guardianSignals);
        assertEq(g.getQuorum(), 2, "quorum");
        assertEq(g.getSuspectWindow(), 3600, "suspect window");
        assertTrue(g.isGuardian(guardianSet[0]), "guardian1");
        assertTrue(g.isGuardian(guardianSet[1]), "guardian2");

        assertTrue(g.hasRole(g.DEFAULT_ADMIN_ROLE(), gAdmin), "admin");
        assertTrue(g.hasRole(g.MANAGER_ROLE(), gManager1), "manager1");
        assertTrue(g.hasRole(g.MANAGER_ROLE(), gManager2), "manager2");
        assertTrue(g.hasRole(g.ACCESS_RESTORER_ROLE(), gManager1), "restorer1");
        assertTrue(g.hasRole(g.ACCESS_RESTORER_ROLE(), gManager2), "restorer2");
        assertTrue(g.hasRole(g.ACCESS_LIMITER_ROLE(), accessLimiter), "limiter");

        assertFalse(g.hasRole(g.DEFAULT_ADMIN_ROLE(), address(builder)), "builder keeps no admin");
        assertFalse(g.hasRole(g.DEFAULT_ADMIN_ROLE(), address(factory)), "factory keeps no admin");
        assertFalse(g.hasRole(g.MANAGER_ROLE(), address(builder)), "builder keeps no manager");
    }

    function testRevert_buildGuardianSignals_zeroAdmin() external {
        vm.expectRevert(LidoLendMarketBuilder.ZeroAdmin.selector);
        vm.prank(deployer);
        builder.buildGuardianSignals(_guardianConfig(), address(0), _guardianManagers(), marketProxyAdmin);
    }

    function testRevert_buildGuardianSignals_zeroProxyAdmin() external {
        vm.expectRevert(LidoLendMarketBuilder.ZeroProxyAdmin.selector);
        vm.prank(deployer);
        builder.buildGuardianSignals(_guardianConfig(), marketAdmin, _guardianManagers(), address(0));
    }

    function testRevert_buildGuardianSignals_zeroRoleHolder() external {
        address[] memory managers = new address[](2);
        managers[0] = manager1;
        managers[1] = address(0);

        vm.expectRevert(LidoLendMarketBuilder.ZeroRoleHolder.selector);
        vm.prank(deployer);
        builder.buildGuardianSignals(_guardianConfig(), marketAdmin, managers, marketProxyAdmin);
    }

    // ---
    // HELPERS
    // ---

    function _guardianConfig() internal view returns (GuardianConfig memory cfg) {
        address[] memory set = new address[](1);
        set[0] = GOVERNANCE;
        cfg = GuardianConfig({guardians: set, quorum: 1, suspectWindow: 0, accessLimiter: address(0)});
    }

    function _guardianManagers() internal view returns (address[] memory m) {
        m = new address[](1);
        m[0] = manager1;
    }

    function _buildMarketContracts(LidoLendMarketBuilder.MarketSpec memory market, MarketRoles memory roles)
        internal
        returns (LidoLendMarketBuilder.MarketContracts memory built)
    {
        vm.prank(deployer);
        built = builder.buildMarketContracts(market, roles);
    }

    /// @dev The router's `Id` is a distinct UDVT (nested core copy); it is the same bytes32.
    function _toIrmId(Id id) internal pure returns (IrmId) {
        return IrmId.wrap(Id.unwrap(id));
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

    function _marketSpec(MockERC20 loan, MockERC20 collateral, address oracle, string memory salt)
        internal
        view
        returns (LidoLendMarketBuilder.MarketSpec memory)
    {
        return LidoLendMarketBuilder.MarketSpec({
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
            }),
            vaultName: string.concat("Lido Loan Vault ", salt),
            vaultSymbol: string.concat("lidoLOAN", salt)
        });
    }

    function _roles(address admin, address proxyAdmin) internal view returns (MarketRoles memory r) {
        r.admin = admin;
        r.proxyAdmin = proxyAdmin;
        r.managers = new address[](2);
        r.managers[0] = manager1;
        r.managers[1] = manager2;
        r.pausers = new address[](2);
        r.pausers[0] = pauser1;
        r.pausers[1] = pauser2;
        r.freezers = new address[](1);
        r.freezers[0] = freezer;
        r.unfreezers = new address[](1);
        r.unfreezers[0] = unfreezer;
        r.resumers = new address[](1);
        r.resumers[0] = resumer;
    }
}
