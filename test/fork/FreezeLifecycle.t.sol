// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice The deployed freeze path on one market: a steward the executor appointed freezes through the risk
///         dashboard, only the owner facade unfreezes, and the two sit on different roles. Frozen, the market
///         refuses new debt but still takes repayments.
contract FreezeLifecycleForkTest is ForkStack {
    using MarketActions for Market;

    IRiskStewardDashboard internal dashboard;
    ILidoLendOwner internal facade;
    address internal STEWARD;
    address internal STRANGER;

    function setUp() public {
        _onlyOnWethWsteth();
        _setUpTarget();
        dashboard = _dashboard();
        facade = _facade();
        STEWARD = _appointSteward("freeze.steward");
        STRANGER = _freshActor(market, "freeze.stranger");
        _seedLenderAndBorrower();
    }

    function test_freeze_viaSteward_thenUnfreeze_viaFacade_borrowWorksAgain() public {
        vm.expectEmit(true, true, true, true, address(market.controller));
        emit ILidoLendMarketController.FrozenSet(true, address(dashboard));
        vm.prank(STEWARD);
        dashboard.freezeMarket(market.id);
        assertTrue(market.controller.isFrozen(), "steward froze the live controller through the dashboard");

        vm.expectEmit(true, true, true, true, address(market.controller));
        emit ILidoLendMarketController.FrozenSet(false, address(facade));
        vm.prank(_executor());
        facade.unfreezeMarket(market.id);
        assertFalse(market.controller.isFrozen(), "executor unfroze it through the facade");

        market.borrow(BORROWER, _oneLoanToken() / 10);
    }

    function testRevert_frozen_borrowBlocked() public {
        _freezeViaSteward(STEWARD);
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.MarketIsFrozen.selector);
        market.core.borrow(market.params, 1, 0, BORROWER, BORROWER);
    }

    /// @dev Freeze is narrow: debt reduction keeps working.
    function test_frozen_repayStillWorks() public {
        _freezeViaSteward(STEWARD);
        deal(address(market.loanToken), BORROWER, market.repayAssets(borrowShares / 2));
        market.repay(BORROWER, borrowShares / 2);
    }

    function testRevert_dashboardFreeze_byStranger() public {
        vm.prank(STRANGER);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.freezeMarket(market.id);
    }

    /// @dev The two directions sit on different roles: the steward that can freeze cannot unfreeze.
    function testRevert_controllerUnfreeze_bySteward() public {
        _freezeViaSteward(STEWARD);
        bytes32 role = market.controller.UNFREEZER_ROLE();
        vm.prank(STEWARD);
        vm.expectRevert(_missingRoleError(STEWARD, role));
        market.controller.unfreeze();
    }
}
