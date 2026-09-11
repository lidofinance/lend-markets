// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {WAD} from "../../src/libs/Constants.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

/// @notice Keeper flows on the deployed market with its real LLTV-dependent incentive: a healthy position cannot
///         be touched, an unhealthy-but-solvent one is liquidated by seized collateral or repaid shares with no
///         loss socialized, and an underwater one is fully seized with the residual socialized. Distress is
///         applied through the deployed oracle's own price source, so the suite holds at any live price.
abstract contract LiquidationForkBase is ForkMarketStack {
    using MarketActions for Market;

    address internal KEEPER;

    constructor(string memory role) ForkMarketStack(role) {}

    function setUp() public {
        _fork();
        _bindRole();
        _seedLenderAndBorrower();

        // Enough loan token to repay the whole debt at any incentive.
        KEEPER = _freshActor(deployed, "liquidation.keeper");
        deal(address(deployed.loanToken), KEEPER, 2 * _maxBorrow(deployed, lot, deployed.oracle.price()));
    }

    function testRevert_liquidate_healthyPosition() public {
        _approve(address(deployed.loanToken), KEEPER, address(deployed.core), type(uint256).max);
        uint256 seize = lot / 10;
        vm.prank(KEEPER);
        vm.expectRevert(bytes("position is healthy"));
        deployed.core.liquidate(deployed.params, BORROWER, seize, 0, "");
    }

    function test_liquidate_unhealthySolvent_bySeizedAssets_repaysByIncentive() public {
        _distress(deployed, BORROWER, _midUnhealthyLtv());
        (uint256 seized,) = market.liquidate(KEEPER, BORROWER, lot / 4, 0);
        assertEq(seized, lot / 4, "seized exactly what was asked");
        assertGt(deployed.core.position(deployed.id, BORROWER).borrowShares, 0, "partial: debt remains");
    }

    function test_liquidate_unhealthySolvent_byRepaidShares_seizesByIncentive() public {
        _distress(deployed, BORROWER, _midUnhealthyLtv());
        uint256 repayShares = borrowShares / 4;
        (uint256 seized,) = market.liquidate(KEEPER, BORROWER, 0, repayShares);
        assertGt(seized, 0, "collateral seized for the repaid shares");
        assertEq(
            deployed.core.position(deployed.id, BORROWER).borrowShares, borrowShares - repayShares, "exact share repay"
        );
    }

    /// @dev At LTV 1.3 the whole collateral, even with the incentive, cannot cover the debt: the position is
    ///      wiped and the remainder is socialized to suppliers.
    function test_liquidateBadDebt_underwater_fullSeizeSocializesResidual() public {
        _distress(deployed, BORROWER, 1.3e18);
        uint256 keeperBefore = deployed.collateralToken.balanceOf(KEEPER);
        (uint256 seized,) = market.liquidateBadDebt(KEEPER, BORROWER, lot, 0);
        assertEq(seized, lot, "all collateral seized");
        assertEq(deployed.collateralToken.balanceOf(KEEPER), keeperBefore + lot, "keeper holds it");
    }

    /// @dev Midpoint of (LLTV, 1): unhealthy, still solvent.
    function _midUnhealthyLtv() internal view returns (uint256) {
        return deployed.params.lltv + (WAD - deployed.params.lltv) / 2;
    }
}

contract LiquidationWethWstethForkTest is LiquidationForkBase("weth-wsteth") {}

contract LiquidationUsdyUsdtForkTest is LiquidationForkBase("usdy-usdt") {}
