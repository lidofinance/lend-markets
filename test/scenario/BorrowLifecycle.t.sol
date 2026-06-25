// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice L2 end-to-end borrow lifecycle on a freshly deployed stack: lender supplies -> borrower supplies
///         and matures collateral -> borrows -> interest accrues -> repays in full -> withdraws collateral ->
///         lender redeems with the earned interest. Each step is asserted by the self-checking
///         `MarketActions` helpers; this scenario adds the cross-step conservation properties.
contract BorrowLifecycleTest is LidoLendSetup {
    using MarketActions for Market;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Safe borrow = half of LLTV-max at the seeded price, well clear of the health gate.
    function _safeBorrow(uint256 collat) internal view returns (uint256) {
        uint256 maxBorrow = collat * oraclePrice / 1e36 * 80 / 100; // LLTV default 0.8
        return maxBorrow / 2;
    }

    function test_fullBorrowLifecycle_roundTrips() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        uint256 collat = 100 ether;

        // 1. Lender supplies liquidity into the vault (-> core supply).
        _fund(m.loanToken, lender, 1000 ether);
        uint256 lenderShares = m.vaultDeposit(lender, 1000 ether);

        // 2. Borrower supplies collateral and matures it through the activation timer.
        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();

        // 3. Borrow against the now-active collateral.
        uint256 borrowAmt = _safeBorrow(collat);
        m.borrow(borrower, borrowAmt);
        assertEq(m.loanToken.balanceOf(borrower), borrowAmt, "borrower received the loan");

        // 4. Interest accrues over a month; `owed` is the exact debt the borrower now repays.
        m.warpAndAccrue(30 days);
        uint256 debtShares = m.core.position(m.id, borrower).borrowShares;
        uint256 owed = m.repayAssets(debtShares);

        // 5. Borrower repays the full debt. `_fund` (deal) SETS the balance, so fund the full `owed`
        //    (the borrowed principal it overwrites is irrelevant — we only need `owed` on hand to repay).
        _fund(m.loanToken, borrower, owed);
        m.repay(borrower, debtShares);
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "debt cleared");

        // 6. Debt-free, the borrower withdraws all collateral back.
        m.withdrawCollateral(borrower, collat, borrower);
        assertEq(m.core.position(m.id, borrower).collateral, 0, "collateral fully returned");
        assertEq(m.collateralToken.balanceOf(borrower), collat, "borrower whole on collateral");

        // 7. Lender redeems: principal + exactly the interest the borrower paid (fee 0 → supply-side
        //    interest == borrow-side interest). Equality is exact up to share-conversion dust (vault +
        //    core share rounding; observed 2 wei).
        uint256 redeemed = m.vaultRedeem(lender, lenderShares);
        assertApproxEqAbs(redeemed - 1000 ether, owed - borrowAmt, 10, "lender's gain == the interest paid");
    }

    function test_openDebt_locksCollateral_thenRepayUnlocks() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        uint256 collat = 100 ether;

        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();

        // Borrow near the LLTV ceiling so the position has little health headroom.
        uint256 maxBorrow = collat * oraclePrice / 1e36 * 80 / 100;
        m.borrow(borrower, maxBorrow * 95 / 100);

        // Withdrawing a large slice of collateral under that debt trips the health gate (the open debt
        // genuinely LOCKS the collateral) — this is the blocked branch the previous version never exercised.
        vm.prank(borrower);
        vm.expectRevert(); // InsufficientActiveCollateral: would leave the position unhealthy
        m.core.withdrawCollateral(m.params, 50 ether, borrower, borrower);

        // Repay the whole debt, then the same withdrawal is allowed.
        uint256 shares = m.core.position(m.id, borrower).borrowShares;
        uint256 owed = m.repayAssets(shares);
        _fund(m.loanToken, borrower, owed);
        m.repay(borrower, shares);
        m.withdrawCollateral(borrower, 50 ether, borrower); // now debt-free/healthy → unblocked
        assertEq(m.core.position(m.id, borrower).collateral, collat - 50 ether, "collateral unlocked after repay");
    }
}
