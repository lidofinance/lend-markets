// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice L2 liquidation scenarios on a freshly deployed stack. A borrower takes a near-max loan, the
///         collateral price drops, and a keeper liquidates. Two regimes: a moderate drop leaves the
///         position solvent-but-unhealthy (clean liquidation, no bad debt) while a severe drop pushes it
///         underwater (bad debt is realized and socialized). The `MarketActions.liquidate` /
///         `liquidateBadDebt` helpers assert the no-bad-debt vs bad-debt invariants respectively.
contract LiquidationTest is LidoLendSetup {
    using MarketActions for Market;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _crashTo(uint256 numerator, uint256 denominator) internal {
        MockPriceOracle(address(_m().oracle)).setPrice(oraclePrice * numerator / denominator);
    }

    /// @dev Lender liquidity + a borrower at ~99% of LLTV-max, ready to be tipped unhealthy by a price drop.
    function _seedNearMax(uint256 collat) internal returns (address borrower) {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();
        uint256 maxBorrow = collat * oraclePrice / 1e36 * 80 / 100;
        m.borrow(borrower, maxBorrow * 99 / 100);
    }

    /// @dev A -10% drop makes the position unhealthy but solvent; a partial seize clears cleanly with no bad debt.
    function test_liquidate_moderateDrop_noBadDebt() public {
        Market storage m = _m();
        address borrower = _seedNearMax(100 ether);

        _crashTo(9, 10); // -10%: unhealthy (borrowed at ~99% of max) but collateral value still > debt

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether); // ample loan tokens to repay (deal sets the balance)
        // Seize a slice of the collateral; the helper asserts totalSupplyAssets does NOT drop (no bad debt).
        (uint256 seized,) = m.liquidate(keeper, borrower, 10 ether, 0);

        assertEq(seized, 10 ether, "seized exactly the requested collateral");
        assertEq(m.core.position(m.id, borrower).collateral, 100 ether - seized, "collateral debited by exactly seized");
    }

    /// @dev A -50% drop pushes the position underwater; a full seize wipes it and socializes the residual bad debt.
    function test_liquidateBadDebt_severeDrop_socialized() public {
        Market storage m = _m();
        address borrower = _seedNearMax(100 ether);

        _crashTo(5, 10); // -50%: collateral value now below the debt -> underwater

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        // Seize ALL collateral; the residual debt is bad debt. The helper asserts the position is wiped
        // (collateral & debt to 0) and totalSupplyAssets drops (loss socialized to lenders).
        m.liquidateBadDebt(keeper, borrower, 100 ether, 0);
    }

    /// @dev A position driven underwater by interest alone (no price move): a partial seize stays loss-neutral and
    ///      leaves the bad debt unrealized.
    function test_partialLiquidate_underwaterByInterest_doesNotSocialize() public {
        Market storage m = _m();
        uint256 borrowAmt = 100 ether * oraclePrice / 1e36 * 80 / 100 * 99 / 100; // ~99% of LLTV-max

        // Supply just above the borrow so utilization is ~95% — well past the IRM target, so the adaptive
        // rate pins near its max and a year of interest drives the debt far past the collateral value.
        address lender = _actor("lender");
        _fund(m.loanToken, lender, borrowAmt * 105 / 100);
        m.vaultDeposit(lender, borrowAmt * 105 / 100);
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, borrowAmt);

        m.warpAndAccrue(365 days);
        // Interest alone drove the position underwater (no price move) — the root carries bad debt.
        assertTrue(m.controller.hasBadDebt(), "a year of high-rate interest pushed the root underwater");

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, type(uint128).max);
        // A PARTIAL seize (10 of 100) leaves collateral > 0, so the core never realizes/socializes the bad
        // debt (that fires only on a full seize, collateral==0). The helper asserts totalSupplyAssets does
        // NOT drop — proving a partial liquidation of even a deeply-underwater position is loss-neutral.
        (uint256 seized,) = m.liquidate(keeper, borrower, 10 ether, 0);

        assertEq(seized, 10 ether, "seized exactly the requested collateral");
        assertEq(m.core.position(m.id, borrower).collateral, 100 ether - seized, "collateral debited by exactly seized");
        assertTrue(m.controller.hasBadDebt(), "bad debt remains (partial seize did not clear the underwater root)");
    }

    /// @dev With no price drop the position stays healthy and the core rejects any liquidation attempt.
    function test_healthyPosition_cannotBeLiquidated() public {
        Market storage m = _m();
        address borrower = _seedNearMax(100 ether);
        // No price drop -> still healthy -> core rejects the liquidation.
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        vm.prank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(bytes("position is healthy")); // Morpho require-string on a healthy position
        m.core.liquidate(m.params, borrower, 10 ether, 0, "");
    }
}
