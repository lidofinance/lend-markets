// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

/// @notice The deployed freeze path on one market: a steward the executor appointed freezes through the risk
///         dashboard, only the owner facade unfreezes, and the two sit on different roles. Frozen, the market
///         refuses new debt but still takes repayments.
abstract contract FreezeLifecycleForkBase is ForkMarketStack {
    using MarketActions for Market;

    IRiskStewardDashboard internal dashboard;
    ILidoLendOwner internal facade;
    address internal STEWARD;
    address internal STRANGER;

    constructor(string memory role) ForkMarketStack(role) {}

    function setUp() public {
        _fork();
        _bindRole();
        dashboard = _dashboard();
        facade = _facade();
        STEWARD = _appointSteward(deployed, "freeze.steward");
        STRANGER = _freshActor(deployed, "freeze.stranger");
        _seedLenderAndBorrower();
    }

    function test_freeze_viaSteward_thenUnfreeze_viaFacade_borrowWorksAgain() public {
        vm.expectEmit(true, true, true, true, address(deployed.controller));
        emit ILidoLendMarketController.FrozenSet(true, address(dashboard));
        vm.prank(STEWARD);
        dashboard.freezeMarket(deployed.id);
        assertTrue(deployed.controller.isFrozen(), "steward froze the live controller through the dashboard");

        vm.expectEmit(true, true, true, true, address(deployed.controller));
        emit ILidoLendMarketController.FrozenSet(false, address(facade));
        vm.prank(_executor());
        facade.unfreezeMarket(deployed.id);
        assertFalse(deployed.controller.isFrozen(), "executor unfroze it through the facade");

        market.borrow(BORROWER, _loanUnit(deployed) / 10);
    }

    function testRevert_frozen_borrowBlocked() public {
        _freezeViaSteward(deployed, STEWARD);
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.MarketIsFrozen.selector);
        deployed.core.borrow(deployed.params, 1, 0, BORROWER, BORROWER);
    }

    /// @dev Freeze is narrow: debt reduction keeps working.
    function test_frozen_repayStillWorks() public {
        _freezeViaSteward(deployed, STEWARD);
        deal(address(deployed.loanToken), BORROWER, market.repayAssets(borrowShares / 2));
        market.repay(BORROWER, borrowShares / 2);
    }

    function testRevert_dashboardFreeze_byStranger() public {
        vm.prank(STRANGER);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.freezeMarket(deployed.id);
    }

    /// @dev The two directions sit on different roles: the steward that can freeze cannot unfreeze.
    function testRevert_controllerUnfreeze_bySteward() public {
        _freezeViaSteward(deployed, STEWARD);
        bytes32 role = deployed.controller.UNFREEZER_ROLE();
        vm.prank(STEWARD);
        vm.expectRevert(_unauthorized(STEWARD, role));
        deployed.controller.unfreeze();
    }
}

contract FreezeLifecycleWethWstethForkTest is FreezeLifecycleForkBase("weth-wsteth") {}

contract FreezeLifecycleUsdyUsdtForkTest is FreezeLifecycleForkBase("usdy-usdt") {}
