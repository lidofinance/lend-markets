// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Market as MarketState} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice The illustrative happy path over the bound market — the simplest end-to-end proof that a provisioned
///         stack and the fork-test binding work together. One story, one step per helper: a lender deposits the
///         loan token into the live vault; a borrower posts collateral, waits out the live activation timer, draws
///         the loan token, repays in full and reclaims the collateral; the lender exits with the principal.
///
///         Everything is sized off the LIVE controller config and oracle price (never deploy-time constants),
///         all actors are fresh, and every assertion is a delta or an independently recomputed value — so the
///         test passes against a freshly provisioned fork AND a market that already carries positions.
contract HappyPathRoundTripTest is ForkStack {
    using SharesMathLib for uint256;

    function setUp() public {
        _setUpTarget();
        _accrueInterest(); // fold pending interest so same-block delta assertions below are exact

        LENDER = _freshActor(market, "happyPath.lender");
        BORROWER = _freshActor(market, "happyPath.borrower");
    }

    function test_happyPath_lendBorrowRepayExit() public {
        // The script's config and the live market agree on the token wiring.
        assertEq(address(market.loanToken), parameters.market.loanToken, "market loan token is the configured one");
        assertEq(
            address(market.collateralToken),
            parameters.market.collateralToken,
            "market collateral is the configured one"
        );

        uint256 collateral = 3 * uint256(_activationConfig(market).minActivationAmount);
        (uint256 depositAssets, uint256 shares) = _lenderDeposits(collateral);
        _borrowerPostsCollateralAndItMatures(collateral);
        uint256 borrowAssets = _borrowerDraws(collateral);
        _borrowerRepaysInFullAndReclaims(collateral, borrowAssets);
        _lenderExits(depositAssets, shares);
    }

    // ---
    // STEPS
    // ---

    /// @dev 1. The lender deposits into the deployed vault half the value of the borrower's `collateral` at the live
    ///      price, which comfortably covers the quarter-value borrow in step 3.
    function _lenderDeposits(uint256 collateral) internal returns (uint256 depositAssets, uint256 shares) {
        depositAssets = (collateral * market.oracle.price()) / ORACLE_PRICE_SCALE / 2;
        _requireSupplyHeadroom(market, depositAssets);

        uint256 vaultAssetsBefore = market.vault.totalAssets();
        uint256 expectedShares = Erc4626Math.toShares(market.vault, depositAssets, Math.Rounding.Floor);

        deal(address(market.loanToken), LENDER, depositAssets);
        _approve(address(market.loanToken), LENDER, address(market.vault), depositAssets);
        vm.prank(LENDER);
        shares = market.vault.deposit(depositAssets, LENDER);

        assertEq(shares, expectedShares, "minted shares match the ERC-4626 conversion, recomputed from the totals");
        assertEq(market.vault.balanceOf(LENDER), shares, "lender holds the minted shares");
        assertEq(market.vault.totalAssets() - vaultAssetsBefore, depositAssets, "vault assets grew by the deposit");
    }

    /// @dev 2. The borrower posts `collateral`, three times the live dust threshold. The fresh lot sits in the
    ///      controller's activation timer, then matures once the live maximum delay has passed.
    function _borrowerPostsCollateralAndItMatures(uint256 collateral) internal {
        collateralIssuer.dealCollateral(BORROWER, collateral);
        _approve(address(market.collateralToken), BORROWER, address(market.core), collateral);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, collateral, BORROWER, "");

        ILidoLendMarketController.BorrowerPosition memory pos = market.controller.positionOf(BORROWER);
        assertEq(pos.activating, collateral, "fresh collateral enters the activation timer");
        assertEq(pos.active, 0, "nothing is active before the delay elapses");

        // The activation gate resolves LAZILY: after the warp the lot is mature, but the buckets fold over on
        // the next position touch — the borrow in step 3 both consumes and proves the maturation.
        _warpPastActivation();
        _accrueInterest(); // fold the interest the warp accrued, so the borrow-shares math in step 3 is exact
    }

    /// @dev 3. The borrower draws a quarter of the collateral's loan-token value — comfortably inside the
    ///      market LLTV. The expected debt shares are recomputed independently from the live totals.
    function _borrowerDraws(uint256 collateral) internal returns (uint256 borrowAssets) {
        borrowAssets = (collateral * market.oracle.price()) / ORACLE_PRICE_SCALE / 4;
        require(borrowAssets != 0, "HappyPath: borrow rounds to zero");
        require(borrowAssets <= _freeLiquidity(), "HappyPath: market lacks liquidity for the borrow");

        MarketState memory mkt = market.core.market(market.id);
        uint256 expectedDebtShares =
            borrowAssets.toSharesUp(uint256(mkt.totalBorrowAssets), uint256(mkt.totalBorrowShares));

        vm.prank(BORROWER);
        market.core.borrow(market.params, borrowAssets, 0, BORROWER, BORROWER);

        assertEq(market.loanToken.balanceOf(BORROWER), borrowAssets, "borrower received the drawn loan token");
        assertEq(
            market.core.position(market.id, BORROWER).borrowShares,
            expectedDebtShares,
            "recorded debt shares match the independent recomputation"
        );
        assertEq(
            market.controller.positionOf(BORROWER).active, collateral, "the borrow resolved the matured lot to active"
        );
    }

    /// @dev 4. The borrower repays in full and reclaims the collateral. Same block as the borrow, so no
    ///      further interest: repaying by SHARES closes the position exactly; the assets owed for those
    ///      shares round up, so the borrower holds the owed amount.
    function _borrowerRepaysInFullAndReclaims(uint256 collateral, uint256 borrowAssets) internal {
        uint256 debtShares = market.core.position(market.id, BORROWER).borrowShares;
        MarketState memory mkt = market.core.market(market.id);
        uint256 owed = debtShares.toAssetsUp(uint256(mkt.totalBorrowAssets), uint256(mkt.totalBorrowShares));
        assertGe(owed, borrowAssets, "the debt covers at least the drawn amount");

        deal(address(market.loanToken), BORROWER, owed); // covers the share-rounding dust over the draw
        _approve(address(market.loanToken), BORROWER, address(market.core), owed);
        vm.startPrank(BORROWER);
        (uint256 repaidAssets,) = market.core.repay(market.params, 0, debtShares, BORROWER, "");
        market.core.withdrawCollateral(market.params, collateral, BORROWER, BORROWER);
        vm.stopPrank();

        assertEq(repaidAssets, owed, "repaid exactly the recomputed debt");
        assertEq(market.core.position(market.id, BORROWER).borrowShares, 0, "debt fully closed");
        assertEq(market.core.position(market.id, BORROWER).collateral, 0, "no collateral left in the market");
        assertEq(market.collateralToken.balanceOf(BORROWER), collateral, "collateral back in the borrower's wallet");
    }

    /// @dev 5. The lender redeems every share. Principal comes back (minus at most 1 wei of share rounding),
    ///      plus whatever interest pre-existing market debt accrued over the activation warp.
    function _lenderExits(uint256 depositAssets, uint256 shares) internal {
        uint256 expectedAssets = Erc4626Math.toAssets(market.vault, shares, Math.Rounding.Floor);
        require(_freeLiquidity() >= expectedAssets, "HappyPath: market lacks liquidity for the lender's exit");

        vm.prank(LENDER);
        uint256 redeemed = market.vault.redeem(shares, LENDER, LENDER);

        assertEq(redeemed, expectedAssets, "redeemed assets match the ERC-4626 conversion, recomputed from the totals");
        assertGe(redeemed, depositAssets - 1, "principal back (1 wei share rounding), plus any accrued interest");
        assertEq(market.vault.balanceOf(LENDER), 0, "no shares left behind");
    }
}
