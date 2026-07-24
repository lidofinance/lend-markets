// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice End-to-end governance flows through one stable owner facade into two real market controllers and
///         guardian registries. Unit tests cover each facade branch; these scenarios prove the downstream
///         AccessControl wiring and market-id resolution against the deployed protocol stack.
contract LidoLendOwnerGovernanceTest is LidoLendSetup {
    address internal constant EXECUTOR = address(0xE7EC);

    LidoLendOwner internal facade;

    function setUp() public {
        MockERC20 loan1 = new MockERC20("Loan 1", "LOAN1", 18);
        MockERC20 collateral1 = new MockERC20("Collateral 1", "COLL1", 18);
        MockERC20 loan2 = new MockERC20("Loan 2", "LOAN2", 18);
        MockERC20 collateral2 = new MockERC20("Collateral 2", "COLL2", 18);

        _deployProtocol(_defaultConfig(address(loan1), address(collateral1), address(collateral1)));
        _addMarket(_defaultConfig(address(loan2), address(collateral2), address(collateral2)));

        facade = new LidoLendOwner(protocol.core, address(this), address(0), address(0));
        protocol.core.setOwner(address(facade));
        facade.grantRole(facade.MARKET_MANAGER_ROLE(), EXECUTOR);
        facade.grantRole(facade.GUARDIAN_MANAGER_ROLE(), EXECUTOR);

        for (uint256 i; i < protocol.markets.length; ++i) {
            Market storage market = protocol.markets[i];
            market.controller.grantRole(market.controller.MANAGER_ROLE(), address(facade));
            market.controller.grantRole(market.controller.UNFREEZER_ROLE(), address(facade));

            GuardianSignals guardians = GuardianSignals(address(market.guardianSignals));
            guardians.grantRole(guardians.MANAGER_ROLE(), address(facade));
            guardians.grantRole(guardians.ACCESS_RESTORER_ROLE(), address(facade));
        }
    }

    function test_governanceFacade_dispatchesControllerActionsAcrossRealMarkets() public {
        Market storage market1 = protocol.markets[0];
        Market storage market2 = protocol.markets[1];

        assertTrue(
            market1.controller.hasRole(market1.controller.MANAGER_ROLE(), address(facade)),
            "market 1 trusts facade manager"
        );
        assertTrue(
            market2.controller.hasRole(market2.controller.MANAGER_ROLE(), address(facade)),
            "market 2 trusts facade manager"
        );
        assertTrue(
            market1.controller.hasRole(market1.controller.UNFREEZER_ROLE(), address(facade)),
            "market 1 trusts facade unfreezer"
        );
        assertTrue(
            market2.controller.hasRole(market2.controller.UNFREEZER_ROLE(), address(facade)),
            "market 2 trusts facade unfreezer"
        );

        market1.controller.grantRole(market1.controller.FREEZER_ROLE(), address(this));
        market2.controller.grantRole(market2.controller.FREEZER_ROLE(), address(this));
        market1.controller.freeze();
        market2.controller.freeze();

        CollateralActivationConfig memory activation1 = market1.controller.collateralActivationConfig();
        CollateralActivationConfig memory activation2 = market2.controller.collateralActivationConfig();
        activation1.minActivationDelay += 1;
        activation2.minActivationDelay += 2;

        SettlementConfig memory settlement1 = market1.controller.settlementConfig();
        SettlementConfig memory settlement2 = market2.controller.settlementConfig();
        settlement1.sliceFloorBps = 111;
        settlement2.sliceFloorBps = 222;

        vm.startPrank(EXECUTOR);
        facade.setMarketSupplyCap(market1.id, 101 ether);
        facade.setMarketSupplyCap(market2.id, 202 ether);
        facade.unfreezeMarket(market1.id);
        facade.unfreezeMarket(market2.id);
        facade.setMarketCollateralActivationConfig(market1.id, activation1);
        facade.setMarketCollateralActivationConfig(market2.id, activation2);
        facade.setMarketSettlementConfig(market1.id, settlement1);
        facade.setMarketSettlementConfig(market2.id, settlement2);
        facade.grantMarketInstantActivation(market1.id, address(0x1111));
        facade.grantMarketInstantActivation(market2.id, address(0x2222));
        vm.stopPrank();

        assertEq(market1.controller.supplyCap(), 101 ether, "market 1 supply cap");
        assertEq(market2.controller.supplyCap(), 202 ether, "market 2 supply cap");
        assertFalse(market1.controller.isFrozen(), "market 1 unfrozen");
        assertFalse(market2.controller.isFrozen(), "market 2 unfrozen");
        assertEq(
            market1.controller.collateralActivationConfig().minActivationDelay,
            activation1.minActivationDelay,
            "market 1 activation config"
        );
        assertEq(
            market2.controller.collateralActivationConfig().minActivationDelay,
            activation2.minActivationDelay,
            "market 2 activation config"
        );
        assertEq(
            market1.controller.settlementConfig().sliceFloorBps, settlement1.sliceFloorBps, "market 1 settlement config"
        );
        assertEq(
            market2.controller.settlementConfig().sliceFloorBps, settlement2.sliceFloorBps, "market 2 settlement config"
        );
        assertTrue(market1.controller.hasInstantActivation(address(0x1111)), "market 1 instant activation");
        assertTrue(market2.controller.hasInstantActivation(address(0x2222)), "market 2 instant activation");
        assertFalse(market1.controller.hasInstantActivation(address(0x2222)), "market 1 excludes market 2 caller");
        assertFalse(market2.controller.hasInstantActivation(address(0x1111)), "market 2 excludes market 1 caller");
    }

    function test_governanceFacade_dispatchesGuardianActionsAcrossRealMarkets() public {
        Market storage market1 = protocol.markets[0];
        Market storage market2 = protocol.markets[1];
        GuardianSignals guardians1 = GuardianSignals(address(market1.guardianSignals));
        GuardianSignals guardians2 = GuardianSignals(address(market2.guardianSignals));

        assertTrue(guardians1.hasRole(guardians1.MANAGER_ROLE(), address(facade)), "market 1 trusts facade manager");
        assertTrue(guardians2.hasRole(guardians2.MANAGER_ROLE(), address(facade)), "market 2 trusts facade manager");
        assertTrue(
            guardians1.hasRole(guardians1.ACCESS_RESTORER_ROLE(), address(facade)), "market 1 trusts facade restorer"
        );
        assertTrue(
            guardians2.hasRole(guardians2.ACCESS_RESTORER_ROLE(), address(facade)), "market 2 trusts facade restorer"
        );

        address guardian1 = address(0xA1);
        address guardian2 = address(0xA2);
        address replacement1 = address(0xA3);
        address replacement2 = address(0xA4);
        address account = address(0xBADD);

        vm.startPrank(EXECUTOR);
        facade.addGuardian(market1.id, guardian1);
        facade.addGuardian(market2.id, guardian2);
        facade.removeGuardian(market1.id, guardian1);
        facade.removeGuardian(market2.id, guardian2);
        facade.addGuardian(market1.id, guardian1);
        facade.addGuardian(market2.id, guardian2);
        facade.setGuardiansQuorum(market1.id, 2);
        facade.setGuardiansQuorum(market2.id, 2);
        facade.replaceGuardian(market1.id, guardian1, replacement1);
        facade.replaceGuardian(market2.id, guardian2, replacement2);
        facade.setGuardiansSuspectWindow(market1.id, 1 days);
        facade.setGuardiansSuspectWindow(market2.id, 2 days);
        vm.stopPrank();

        assertFalse(guardians1.isGuardian(guardian1), "market 1 old guardian removed");
        assertFalse(guardians1.isGuardian(guardian2), "market 1 excludes market 2 guardian");
        assertTrue(guardians1.isGuardian(replacement1), "market 1 replacement added");
        assertFalse(guardians2.isGuardian(guardian2), "market 2 old guardian removed");
        assertFalse(guardians2.isGuardian(guardian1), "market 2 excludes market 1 guardian");
        assertTrue(guardians2.isGuardian(replacement2), "market 2 replacement added");
        assertEq(guardians1.getQuorum(), 2, "market 1 quorum");
        assertEq(guardians2.getQuorum(), 2, "market 2 quorum");
        assertEq(guardians1.getSuspectWindow(), 1 days, "market 1 suspect window");
        assertEq(guardians2.getSuspectWindow(), 2 days, "market 2 suspect window");

        guardians1.grantRole(guardians1.ACCESS_LIMITER_ROLE(), address(this));
        guardians2.grantRole(guardians2.ACCESS_LIMITER_ROLE(), address(this));
        guardians1.ban(market1.id, account);
        guardians2.ban(market2.id, account);
        assertTrue(guardians1.isBanned(market1.id, account), "market 1 account banned");
        assertTrue(guardians2.isBanned(market2.id, account), "market 2 account banned");

        Id[] memory marketIds = new Id[](2);
        marketIds[0] = market1.id;
        marketIds[1] = market2.id;
        vm.prank(EXECUTOR);
        facade.unbanGuardianSignals(marketIds, account);

        assertFalse(guardians1.isBanned(market1.id, account), "market 1 account unbanned");
        assertFalse(guardians2.isBanned(market2.id, account), "market 2 account unbanned");
    }

    function test_governanceFacade_replacesGuardianAtCapAndFullQuorum() public {
        Market storage market = protocol.markets[0];
        GuardianSignals guardians = GuardianSignals(address(market.guardianSignals));
        (address[] memory initialGuardians,) = guardians.getGuardians();
        address oldGuardian = initialGuardians[0];
        address newGuardian = address(0xBEEF);

        vm.startPrank(EXECUTOR);
        for (uint160 i = 1; i < guardians.MAX_GUARDIANS_COUNT(); ++i) {
            facade.addGuardian(market.id, address(0x1000 + i));
        }
        facade.setGuardiansQuorum(market.id, guardians.MAX_GUARDIANS_COUNT());
        facade.replaceGuardian(market.id, oldGuardian, newGuardian);
        vm.stopPrank();

        assertFalse(guardians.isGuardian(oldGuardian), "old guardian removed");
        assertTrue(guardians.isGuardian(newGuardian), "replacement added");
        assertEq(guardians.getGuardianCount(), guardians.MAX_GUARDIANS_COUNT(), "guardian count preserved at cap");
        assertEq(guardians.getQuorum(), guardians.MAX_GUARDIANS_COUNT(), "full quorum restored");
    }
}
