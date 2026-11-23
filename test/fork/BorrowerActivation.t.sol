// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice The collateral lifecycle a borrower meets on the deployed market at its live thresholds: inactive
///         collateral is all-or-nothing on withdrawal, a top-up restarts or joins the timer, and borrowing is
///         gated on matured collateral up to `collateralValue * LLTV`. Sizes derive from the live config, price
///         and LLTV.
contract BorrowerActivationForkTest is ForkStack {
    using MarketActions for Market;

    function setUp() public {
        _onlyOnOneMarketPerKind();
        _setUpTarget();
        LENDER = _freshActor(market, "activation.lender");
        BORROWER = _freshActor(market, "activation.borrower");

        // Liquidity for the capacity test, sized to what the lot can carry.
        uint256 deposit = _maxBorrow(market, lot, market.oracle.price()) + _oneLoanToken();
        _requireSupplyHeadroom(market, deposit);
        deal(address(market.loanToken), LENDER, deposit);
        market.vaultDeposit(LENDER, deposit);

        collateralIssuer.dealCollateral(BORROWER, 3 * lot);
    }

    // ---
    // INACTIVE COLLATERAL IS ALL-OR-NOTHING
    // ---

    function testRevert_withdrawCollateral_partOfInactiveLot_InactiveCollateralNotCleared() public {
        market.supplyCollateral(BORROWER, lot);
        vm.prank(BORROWER);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralActivationLib.InactiveCollateralNotCleared.selector, lot / 3, lot)
        );
        market.core.withdrawCollateral(market.params, lot / 3, BORROWER, BORROWER);
    }

    function test_withdrawCollateral_wholeInactiveLot_clearsBucketsAndTimer() public {
        market.supplyCollateral(BORROWER, lot);
        market.withdrawCollateral(BORROWER, lot, BORROWER);
        ILidoLendMarketController.BorrowerPosition memory position = market.controller.positionOf(BORROWER);
        assertEq(position.activating, 0, "lot cleared");
        assertEq(position.unlockTime, 0, "timer cleared");
        assertEq(market.core.position(market.id, BORROWER).collateral, 0, "position empty");
    }

    // ---
    // TOP-UPS AND THE TIMER
    // ---

    /// @dev All activating collateral shares one timer: a top-up before maturity restarts it at the delay the
    ///      controller quotes for the enlarged lot, read before the write. Same block on purpose: inflow is
    ///      accumulated per transaction, so a warp inside this single test transaction would leave the quote
    ///      (decayed) and the write (undecayed) reading different inflows.
    function test_topUp_beforeMaturity_movesDeadlineToTheNewQuote() public {
        market.supplyCollateral(BORROWER, lot);
        uint256 firstUnlock = market.controller.positionOf(BORROWER).unlockTime;

        uint256 quotedDelay = market.controller.currentActivationDelay(lot);
        market.supplyCollateral(BORROWER, lot);

        ILidoLendMarketController.BorrowerPosition memory position = market.controller.positionOf(BORROWER);
        assertEq(position.activating, 2 * lot, "both lots share the timer");
        assertEq(position.unlockTime, block.timestamp + quotedDelay, "deadline restarted at the quoted delay");
        assertGt(position.unlockTime, firstUnlock, "and it moved later");
    }

    /// @dev The second supply is the touch that matures the first lot, so it goes through the core directly:
    ///      the `MarketActions` helper's bucket model assumes nothing matures inside the call.
    function test_topUp_afterMaturity_startsFreshLotOverActive() public {
        market.supplyCollateral(BORROWER, lot);
        market.activateCollateral();

        _approve(address(market.collateralToken), BORROWER, address(market.core), lot);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, lot, BORROWER, "");

        ILidoLendMarketController.BorrowerPosition memory position = market.controller.positionOf(BORROWER);
        assertEq(position.active, lot, "the first lot matured on the touch");
        assertEq(position.activating, lot, "the second lot starts its own timer");
    }

    // ---
    // BORROW CAPACITY
    // ---

    function testRevert_borrow_beforeMaturity_InsufficientActiveCollateral() public {
        market.supplyCollateral(BORROWER, lot);
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        market.core.borrow(market.params, 1, 0, BORROWER, BORROWER);
    }

    /// @dev Capacity is `collateralValue * LLTV`, both floored, at the live price. One unit over it is refused;
    ///      one unit under it passes. Exactly the capacity is not promised: the core rounds the debt up by a unit
    ///      whenever borrow shares and assets are not in exact ratio.
    function test_borrow_oneUnitOverCapacityReverts_oneUnitUnderPasses() public {
        market.supplyCollateral(BORROWER, lot);
        market.activateCollateral();
        _accrueInterest();

        uint256 capacity = _maxBorrow(market, lot, market.oracle.price());
        require(capacity < _freeLiquidity(), "BorrowerActivation: fixture liquidity must cover the capacity");

        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        market.core.borrow(market.params, capacity + 1, 0, BORROWER, BORROWER);

        market.borrow(BORROWER, capacity - 1);
    }
}
