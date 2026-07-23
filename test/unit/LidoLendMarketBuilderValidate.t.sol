// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {LidoLendMarketBuilder, MarketRoles, GuardianConfig} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice Unit coverage for `LidoLendMarketBuilder.validateMarketContracts` / `validateGuardianSignals`: each
///         check reverts on a broken setup and passes on a correct one. Builds a controller/vault/registry
///         directly through `LidoLendMarketFactory` (this contract as `msg.sender`, so it receives the
///         `DEFAULT_ADMIN_ROLE` the same way `LidoLendMarketBuilder` would) rather than going through
///         `buildMarketContracts` / `buildGuardianSignals`, so each check can be broken in isolation.
contract LidoLendMarketBuilderValidateTest is Test {
    using MarketParamsLib for MarketParams;

    address internal constant GOVERNANCE = address(0xA11CE);
    address internal proxyAdmin;
    address internal admin;
    address internal manager;
    address internal pauser;
    address internal guardianSignals;

    ILidoLend internal core;
    LidoLendOwner internal facade;
    IIrmRouter internal router;
    address internal controllerImpl;
    address internal vaultImpl;
    address internal guardianSignalsImpl;
    LidoLendMarketFactory internal factory;
    LidoLendMarketBuilder internal builder;

    MarketParams internal params;
    Id internal marketId;
    address internal controller;
    address internal vault;

    // guardian-registry fixture
    address internal gRegistry;
    address internal gAdmin;
    address internal gManager;
    address internal gAccessLimiter;
    address[] internal gGuardianSet;

    function setUp() external {
        proxyAdmin = makeAddr("proxyAdmin");
        admin = makeAddr("admin");
        manager = makeAddr("manager");
        pauser = makeAddr("pauser");

        core = ILidoLend(
            address(
                new OssifiableProxy(
                    address(new LidoLend()), GOVERNANCE, abi.encodeWithSignature("initialize(address)", GOVERNANCE)
                )
            )
        );
        facade = new LidoLendOwner(core, GOVERNANCE, address(0), address(0));
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

        address[] memory guardians = new address[](1);
        guardians[0] = GOVERNANCE;
        guardianSignals = address(
            new OssifiableProxy(
                address(new GuardianSignals()),
                GOVERNANCE,
                abi.encodeWithSignature("initialize(address,address[],uint256)", GOVERNANCE, guardians, 1)
            )
        );

        controllerImpl = address(new LidoLendMarketController(IMorpho(address(core))));
        vaultImpl = address(new LidoLendERC4626(address(core)));
        guardianSignalsImpl = address(new GuardianSignals());
        factory = new LidoLendMarketFactory(controllerImpl, vaultImpl, guardianSignalsImpl);
        // The dashboard is irrelevant to validation logic — zero skips the grant, same as a protocol without one.
        builder = new LidoLendMarketBuilder(factory, ILidoLendOwner(address(facade)), router, address(0));

        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        address oracle = address(
            new OssifiableProxy(
                address(new MockPriceOracle()), GOVERNANCE, abi.encodeWithSignature("initialize(uint256)", 1.05e36)
            )
        );
        params = MarketParams({
            loanToken: address(loan),
            collateralToken: address(collateral),
            oracle: oracle,
            irm: address(router),
            lltv: 0.8e18
        });
        marketId = params.id();

        (controller, vault) = factory.deployMarketContracts(
            params, _activationConfig(), _settlementConfig(), guardianSignals, proxyAdmin, "Lido Loan Vault", "lidoLOAN"
        );

        LidoLendMarketController c = LidoLendMarketController(controller);
        c.grantRole(c.MANAGER_ROLE(), manager);
        c.grantRole(c.MANAGER_ROLE(), address(facade));
        c.grantRole(c.UNFREEZER_ROLE(), address(facade));
        c.grantRole(c.PAUSER_ROLE(), pauser);
        c.grantRole(c.DEFAULT_ADMIN_ROLE(), admin);
        c.revokeRole(c.DEFAULT_ADMIN_ROLE(), address(this));

        // guardian-registry fixture, wired the same way `LidoLendMarketBuilder.buildGuardianSignals` would.
        gAdmin = makeAddr("gAdmin");
        gManager = makeAddr("gManager");
        gAccessLimiter = makeAddr("gAccessLimiter");
        gGuardianSet = new address[](1);
        gGuardianSet[0] = GOVERNANCE;

        gRegistry = factory.deployGuardianSignals(proxyAdmin, gGuardianSet, 1);
        GuardianSignals gg = GuardianSignals(gRegistry);
        gg.grantRole(gg.MANAGER_ROLE(), address(this));
        gg.setSuspectWindow(7200);
        gg.revokeRole(gg.MANAGER_ROLE(), address(this));
        gg.grantRole(gg.MANAGER_ROLE(), gManager);
        gg.grantRole(gg.ACCESS_RESTORER_ROLE(), gManager);
        gg.grantRole(gg.MANAGER_ROLE(), address(facade));
        gg.grantRole(gg.ACCESS_RESTORER_ROLE(), address(facade));
        gg.grantRole(gg.ACCESS_LIMITER_ROLE(), gAccessLimiter);
        gg.grantRole(gg.DEFAULT_ADMIN_ROLE(), gAdmin);
        gg.revokeRole(gg.DEFAULT_ADMIN_ROLE(), address(this));
    }

    // ---
    // validateMarketContracts
    // ---

    function test_validateMarketContracts_passesOnCorrectSetup() external view {
        builder.validateMarketContracts(controller, vault, marketId, guardianSignals, address(this), _roles());
    }

    function test_validateMarketContracts_revertsOnCodehashMismatch() external {
        // A different core immutable produces different runtime bytecode (and codehash) at the same slot.
        address otherCore = address(
            new OssifiableProxy(
                address(new LidoLend()), GOVERNANCE, abi.encodeWithSignature("initialize(address)", GOVERNANCE)
            )
        );
        address otherControllerImpl = address(new LidoLendMarketController(IMorpho(otherCore)));
        vm.prank(proxyAdmin);
        IOssifiableProxy(controller).proxy__upgradeTo(otherControllerImpl);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.CodehashMismatch.selector,
                controller,
                controllerImpl.codehash,
                otherControllerImpl.codehash
            )
        );
        builder.validateMarketContracts(controller, vault, marketId, guardianSignals, address(this), _roles());
    }

    function test_validateMarketContracts_revertsOnProxyAdminMismatch() external {
        address wrongAdmin = makeAddr("wrongAdmin");
        vm.prank(proxyAdmin);
        IOssifiableProxy(controller).proxy__changeAdmin(wrongAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.ProxyAdminMismatch.selector, controller, proxyAdmin, wrongAdmin
            )
        );
        builder.validateMarketContracts(controller, vault, marketId, guardianSignals, address(this), _roles());
    }

    function test_validateMarketContracts_revertsOnMarketIdMismatch() external {
        Id wrongId = Id.wrap(bytes32(uint256(1)));
        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.MarketIdMismatch.selector, Id.unwrap(wrongId), Id.unwrap(marketId)
            )
        );
        builder.validateMarketContracts(controller, vault, wrongId, guardianSignals, address(this), _roles());
    }

    function test_validateMarketContracts_revertsOnVaultControllerMismatch() external {
        // A second market's vault, bound to its own (different) controller — swapped in for `vault` here.
        MockERC20 loan2 = new MockERC20("Loan2", "LOAN2", 18);
        MockERC20 collateral2 = new MockERC20("Collateral2", "COLL2", 18);
        address oracle2 = address(
            new OssifiableProxy(
                address(new MockPriceOracle()), GOVERNANCE, abi.encodeWithSignature("initialize(uint256)", 0.92e36)
            )
        );
        MarketParams memory params2 = MarketParams({
            loanToken: address(loan2),
            collateralToken: address(collateral2),
            oracle: oracle2,
            irm: address(router),
            lltv: 0.8e18
        });
        (address otherController, address otherVault) = factory.deployMarketContracts(
            params2, _activationConfig(), _settlementConfig(), guardianSignals, proxyAdmin, "Other Vault", "otherLOAN"
        );

        vm.expectRevert(
            abi.encodeWithSelector(LidoLendMarketBuilder.VaultControllerMismatch.selector, controller, otherController)
        );
        builder.validateMarketContracts(controller, otherVault, marketId, guardianSignals, address(this), _roles());
    }

    function test_validateMarketContracts_revertsOnGuardianSignalsMismatch() external {
        address wrongGuardian = makeAddr("wrongGuardian");
        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.GuardianSignalsMismatch.selector, wrongGuardian, guardianSignals
            )
        );
        builder.validateMarketContracts(controller, vault, marketId, wrongGuardian, address(this), _roles());
    }

    function test_validateMarketContracts_revertsOnMissingRoleHolder() external {
        MarketRoles memory roles = _roles();
        roles.managers = new address[](1);
        roles.managers[0] = makeAddr("neverGranted");

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.MissingRoleHolder.selector,
                controller,
                LidoLendMarketController(controller).MANAGER_ROLE(),
                roles.managers[0]
            )
        );
        builder.validateMarketContracts(controller, vault, marketId, guardianSignals, address(this), roles);
    }

    function test_validateMarketContracts_revertsWhenBuilderStillHoldsAdmin() external {
        LidoLendMarketController c = LidoLendMarketController(controller);
        address fakeBuilder = makeAddr("fakeBuilder");
        bytes32 adminRole = c.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        c.grantRole(adminRole, fakeBuilder);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.UnexpectedRoleHolder.selector, controller, adminRole, fakeBuilder
            )
        );
        builder.validateMarketContracts(controller, vault, marketId, guardianSignals, fakeBuilder, _roles());
    }

    // ---
    // validateGuardianSignals
    // ---

    function test_validateGuardianSignals_passesOnCorrectSetup() external view {
        builder.validateGuardianSignals(
            gRegistry, address(this), gAdmin, proxyAdmin, _guardianManagers(), _guardianCfg()
        );
    }

    function test_validateGuardianSignals_revertsOnCodehashMismatch() external {
        // `controllerImpl` is any contract with a different codehash than `guardianSignalsImpl`; the codehash
        // check reads the proxy's own `proxy__getImplementation()`, never delegates into it, so the mismatched
        // storage layout is irrelevant here.
        vm.prank(proxyAdmin);
        IOssifiableProxy(gRegistry).proxy__upgradeTo(controllerImpl);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.CodehashMismatch.selector,
                gRegistry,
                guardianSignalsImpl.codehash,
                controllerImpl.codehash
            )
        );
        builder.validateGuardianSignals(
            gRegistry, address(this), gAdmin, proxyAdmin, _guardianManagers(), _guardianCfg()
        );
    }

    function test_validateGuardianSignals_revertsOnProxyAdminMismatch() external {
        address wrongAdmin = makeAddr("wrongAdmin");
        vm.prank(proxyAdmin);
        IOssifiableProxy(gRegistry).proxy__changeAdmin(wrongAdmin);

        vm.expectRevert(
            abi.encodeWithSelector(LidoLendMarketBuilder.ProxyAdminMismatch.selector, gRegistry, proxyAdmin, wrongAdmin)
        );
        builder.validateGuardianSignals(
            gRegistry, address(this), gAdmin, proxyAdmin, _guardianManagers(), _guardianCfg()
        );
    }

    function test_validateGuardianSignals_revertsOnQuorumMismatch() external {
        GuardianConfig memory cfg = _guardianCfg();
        cfg.quorum = 2;
        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketBuilder.GuardianQuorumMismatch.selector, 2, 1));
        builder.validateGuardianSignals(gRegistry, address(this), gAdmin, proxyAdmin, _guardianManagers(), cfg);
    }

    function test_validateGuardianSignals_revertsOnSuspectWindowMismatch() external {
        GuardianConfig memory cfg = _guardianCfg();
        cfg.suspectWindow = 1;
        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketBuilder.GuardianSuspectWindowMismatch.selector, 1, 7200));
        builder.validateGuardianSignals(gRegistry, address(this), gAdmin, proxyAdmin, _guardianManagers(), cfg);
    }

    function test_validateGuardianSignals_revertsOnGuardianSetSizeMismatch() external {
        GuardianConfig memory cfg = _guardianCfg();
        cfg.guardians = new address[](2);
        cfg.guardians[0] = gGuardianSet[0];
        cfg.guardians[1] = makeAddr("extraGuardian");

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketBuilder.GuardianSetSizeMismatch.selector, 2, 1));
        builder.validateGuardianSignals(gRegistry, address(this), gAdmin, proxyAdmin, _guardianManagers(), cfg);
    }

    function test_validateGuardianSignals_revertsOnMissingGuardian() external {
        GuardianConfig memory cfg = _guardianCfg();
        address notAGuardian = makeAddr("notAGuardian");
        cfg.guardians = new address[](1);
        cfg.guardians[0] = notAGuardian;

        vm.expectRevert(abi.encodeWithSelector(LidoLendMarketBuilder.MissingGuardian.selector, notAGuardian));
        builder.validateGuardianSignals(gRegistry, address(this), gAdmin, proxyAdmin, _guardianManagers(), cfg);
    }

    function test_validateGuardianSignals_revertsOnMissingRoleHolder() external {
        address[] memory managers = new address[](1);
        managers[0] = makeAddr("neverGranted");

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.MissingRoleHolder.selector,
                gRegistry,
                GuardianSignals(gRegistry).MANAGER_ROLE(),
                managers[0]
            )
        );
        builder.validateGuardianSignals(gRegistry, address(this), gAdmin, proxyAdmin, managers, _guardianCfg());
    }

    function test_validateGuardianSignals_revertsWhenBuilderStillHoldsAdmin() external {
        GuardianSignals g = GuardianSignals(gRegistry);
        address fakeBuilder = makeAddr("fakeBuilder");
        bytes32 adminRole = g.DEFAULT_ADMIN_ROLE();
        vm.prank(gAdmin);
        g.grantRole(adminRole, fakeBuilder);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.UnexpectedRoleHolder.selector, gRegistry, adminRole, fakeBuilder
            )
        );
        builder.validateGuardianSignals(gRegistry, fakeBuilder, gAdmin, proxyAdmin, _guardianManagers(), _guardianCfg());
    }

    /// @dev Fix 2: a forgotten revoke of the MANAGER_ROLE the builder holds transiently (to call
    ///      `setSuspectWindow`) must be caught too, not just a lingering DEFAULT_ADMIN_ROLE.
    function test_validateGuardianSignals_revertsWhenBuilderStillHoldsManager() external {
        GuardianSignals g = GuardianSignals(gRegistry);
        address fakeBuilder = makeAddr("fakeBuilder");
        bytes32 managerRole = g.MANAGER_ROLE();
        vm.prank(gAdmin);
        g.grantRole(managerRole, fakeBuilder);

        vm.expectRevert(
            abi.encodeWithSelector(
                LidoLendMarketBuilder.UnexpectedRoleHolder.selector, gRegistry, managerRole, fakeBuilder
            )
        );
        builder.validateGuardianSignals(gRegistry, fakeBuilder, gAdmin, proxyAdmin, _guardianManagers(), _guardianCfg());
    }

    // ---
    // HELPERS
    // ---

    function _guardianCfg() internal view returns (GuardianConfig memory cfg) {
        cfg = GuardianConfig({guardians: gGuardianSet, quorum: 1, suspectWindow: 7200, accessLimiter: gAccessLimiter});
    }

    function _guardianManagers() internal view returns (address[] memory m) {
        m = new address[](1);
        m[0] = gManager;
    }

    function _roles() internal view returns (MarketRoles memory r) {
        r.admin = admin;
        r.proxyAdmin = proxyAdmin;
        r.managers = new address[](1);
        r.managers[0] = manager;
        r.pausers = new address[](1);
        r.pausers[0] = pauser;
    }

    function _activationConfig() internal pure returns (CollateralActivationConfig memory) {
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

    function _settlementConfig() internal pure returns (SettlementConfig memory) {
        return
            SettlementConfig({
                sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
            });
    }
}
