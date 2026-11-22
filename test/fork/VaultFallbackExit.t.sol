// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Market as MarketState} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice Mainnet-fork scenarios for the vault's two settle-backed exits, `fallbackExit` and `settle`, run
///         against the bound market (see {ForkStack}).
///         Each shows the redeem-first design: the exit first pays out whatever ordinary liquidity
///         (idle + Morpho-withdrawable) covers, then settles the remainder against an unhealthy-but-
///         solvent borrower for collateral. This also removes the front-run griefing vector — a
///         top-up of idle before the call just flows to the owner instead of reverting the settle.
///
///         State-robustness contract (a shared deployed market may already carry supply/borrow):
///         idle is MEASURED (`_freeLiquidity`) after pinning it to a known target, never assumed from the
///         deposits; the price fall is derived from the live position so the borrower lands strictly
///         inside `(LLTV, 1)` whatever the live price is; and each settle path loudly requires the test
///         borrower to be the settlement-queue root, so a pre-existing riskier borrower cannot hijack the cut.
contract VaultFallbackExitTest is ForkStack {
    // Fresh, market-clean actors (start at zero position and zero vault shares), so per-actor balance
    // assertions double as deltas.

    /// @dev The mocked post-fall collateral price (scaled by `ORACLE_PRICE_SCALE`), computed in
    ///      `_setupExitWithIdle` from the live position. Collateral-seizure expectations recompute from THIS,
    ///      never from a stale constant.
    uint256 internal mockedPrice;

    /// @dev The borrower's collateral, as a multiple of the LIVE activation threshold.
    uint256 internal constant COLLATERAL_MULTIPLE = 3;
    /// @dev The borrow, as a percentage of what the staked collateral can carry at the LIVE LLTV. High enough
    ///      that a modest price fall pushes the position into `(LLTV, 1)`, low enough to open healthy.
    uint256 internal constant BORROW_PCT_OF_CAPACITY = 76;

    /// @dev Post-rebase target LTV for the test borrower: strictly inside `(LLTV, 1)`, so the position is
    ///      unhealthy but solvent — settle-eligible with no bad debt. Only known post-bind (it depends on the
    ///      live market's LLTV), so it is set in `setUp` rather than a compile-time constant.
    uint256 internal targetPostRebaseLtv;

    function setUp() public {
        _setUpTarget();
        _accrueInterest(); // fold in pending interest up front so the exact idle/liquidity math below holds
        _repayExistingBorrowers(); // a live borrower must not outrank or outlast the test's borrowers

        // Midpoint of (LLTV, 1e18): strictly inside the unhealthy-but-solvent band regardless of the live LLTV.
        targetPostRebaseLtv = (market.params.lltv + WAD) / 2;

        LENDER = _freshActor(market, "vaultFallbackExit.lender");
        BORROWER = _freshActor(market, "vaultFallbackExit.borrower");
    }

    /// @dev Lender funds the vault, a borrower draws most of it, then a price fall makes the borrower
    ///      unhealthy but solvent — settle-eligible, no bad debt. Returns the idle loan token left in the market
    ///      (what the redeem leg can pay out), MEASURED after pinning, not inferred from the deposits.
    function _setupExitWithIdle() internal returns (uint256 idle) {
        // Size the debt and the lender's deposit off what the collateral carries at the live LLTV and price.
        // Fixed amounts would break the moment governance moved `minActivationAmount` past the collateral, or the
        // LLTV past the borrow.
        uint256 collateral = COLLATERAL_MULTIPLE * uint256(_activationConfig(market).minActivationAmount);
        collateralIssuer.dealCollateral(BORROWER, collateral);
        _approve(address(market.collateralToken), BORROWER, address(market.core), collateral);
        uint256 borrowAssets = _maxBorrow(market, collateral, market.oracle.price()) * BORROW_PCT_OF_CAPACITY / 100;
        uint256 idleTarget = borrowAssets / 9;
        uint256 lenderDeposit = borrowAssets + idleTarget;

        _requireSupplyHeadroom(market, lenderDeposit);
        deal(address(market.loanToken), LENDER, lenderDeposit);
        _approve(address(market.loanToken), LENDER, address(market.vault), lenderDeposit);
        vm.prank(LENDER);
        market.vault.deposit(lenderDeposit, LENDER);

        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, collateral, BORROWER, "");

        _warpPastActivation();
        vm.prank(BORROWER);
        market.core.borrow(market.params, borrowAssets, 0, BORROWER, BORROWER); // healthy at the live price

        // Pin free liquidity to a known target and MEASURE the result: a shared deployed market may already
        // carry idle, which would break `loanAssets ~= idle` and could let the redeem leg cover the whole exit
        // (collateralSeized == 0). The pin borrower is over-collateralized, so it never outranks BORROWER below.
        _setFreeLiquidity(idleTarget);
        idle = _freeLiquidity();

        // A relative price fall through the oracle's own source, derived from the live position so BORROWER lands
        // at targetPostRebaseLtv — inside (LLTV, 1) — regardless of the live price.
        uint256 livePrice = market.oracle.price();
        mockedPrice = _setPriceForLtv(BORROWER, targetPostRebaseLtv);
        uint256 debtAssets = market.controller.positionOf(BORROWER).debtAssets;
        uint256 rawCollateral = market.core.position(market.id, BORROWER).collateral;

        // Sanity: the fall drops the price, pushes BORROWER above LLTV (unhealthy) yet leaves its
        // collateral worth more than its debt (solvent) — so it is settle-eligible with no bad debt.
        assertLt(mockedPrice, livePrice, "the price falls");
        assertGt(debtAssets, _maxBorrow(market, rawCollateral, mockedPrice), "borrower unhealthy (LTV > LLTV)");
        assertGt(Math.mulDiv(rawCollateral, mockedPrice, ORACLE_PRICE_SCALE), debtAssets, "borrower solvent");
        assertFalse(market.controller.hasBadDebt(), "no bad debt after the fall");

        // Targeted settlement is borrower-opt-in. A near-zero target admits both direct-settle tests below;
        // fallbackExit still selects the same borrower through the risk queue.
        vm.prank(BORROWER);
        market.controller.setSettlementLtv(1);

        // Both settle paths below cut BORROWER (fallbackExit head-first via the queue root; settle by naming it),
        // which needs BORROWER to be the queue root. A near-max debt keeps it the riskiest on a quiet market;
        // assert it so a pre-existing riskier borrower cannot silently hijack the cut.
        (address root,) = market.controller.nextSettlementBorrower(0);
        require(
            root == BORROWER,
            "VaultFallbackExit: a pre-existing riskier borrower outranks the test borrower in the settle queue"
        );
    }

    /// @dev Asserts a vault exit ran both phases: redeemed idle as loan assets AND settled collateral. The
    ///      seized collateral is recomputed from the mocked oracle price (approx: fallbackExit accumulates many
    ///      per-cut floors), never from a hardcoded price.
    function _assertBothPhases(uint256 idle, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
        internal
        view
    {
        assertGt(loanAssets, 0, "redeem leg paid loan assets");
        assertApproxEqAbs(loanAssets, idle, 1e15, "redeem leg drained the available idle");
        assertGt(collateralSeized, 0, "settle leg seized collateral for the remainder");
        assertApproxEqAbs(
            collateralSeized,
            debtCanceled * ORACLE_PRICE_SCALE / mockedPrice,
            1e6,
            "collateral seized at the mocked price"
        );
        assertEq(market.loanToken.balanceOf(LENDER), loanAssets, "receiver got the loan assets");
        assertEq(market.collateralToken.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
    }

    /* fallbackExit: redeem available, then settle the remainder via the risk queue */

    function test_fallbackExit_redeemsAvailableThenSettles() public {
        uint256 idle = _setupExitWithIdle();

        // Request more than idle covers, so the redeem leg pays the idle and the settle leg covers the rest.
        uint256 shares = market.vault.balanceOf(LENDER) / 2;
        vm.prank(LENDER);
        (, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            market.vault.fallbackExit(shares, LENDER, LENDER, 0);

        _assertBothPhases(idle, loanAssets, collateralSeized, debtCanceled);
    }

    /* settle: liquidity-neutral targeted cut — seizes collateral, withdraws NO ordinary liquidity */

    function test_settle_seizesCollateralWithoutWithdrawingLiquidity() public {
        _setupExitWithIdle();

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;

        uint256 loanBefore = market.loanToken.balanceOf(LENDER); // a fresh lender holds no idle loan token (all
        // deposited)
        MarketState memory marketBefore = market.core.market(market.id);
        uint256 borrowerBorrowSharesBefore = market.core.position(market.id, BORROWER).borrowShares;
        uint256 freeBefore = _freeLiquidity();

        uint256 shares = market.vault.balanceOf(LENDER) / 2;
        vm.prank(LENDER);
        (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled) =
            market.vault.settle(shares, borrowers, LENDER, LENDER);

        // Pure settle: the cut seizes collateral to the receiver and burns the matching shares, but the
        // ordinary liquidity is left untouched — no redeem leg, so no loan assets are paid out.
        assertGt(collateralSeized, 0, "settle seized collateral for the cut");
        assertGt(sharesBurned, 0, "shares burned for the settled slice");
        _assertSettlementAccounting(marketBefore, borrowerBorrowSharesBefore, collateralSeized, debtCanceled);
        assertEq(market.loanToken.balanceOf(LENDER), loanBefore, "receiver got no loan assets");
        assertEq(market.collateralToken.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
        // The market's own liquidity, not just the receiver's wallet: settle cancels supply and debt by the same
        // amount, so free liquidity is unmoved. Without this, a path that pulled liquidity out and parked it
        // somewhere other than the receiver would still pass.
        assertEq(_freeLiquidity(), freeBefore, "settle moved no ordinary liquidity");
    }

    /* A targeted cut is still a settle, not a redeem, even when the request would fit inside free liquidity. */

    function test_settle_requestBelowFreeLiquidity_isStillLiquidityNeutral() public {
        _setupExitWithIdle(); // a measured slice of ordinary liquidity sits in the market

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;

        uint256 loanBefore = market.loanToken.balanceOf(LENDER);
        MarketState memory marketBefore = market.core.market(market.id);
        uint256 borrowerBorrowSharesBefore = market.core.position(market.id, BORROWER).borrowShares;
        uint256 freeBefore = _freeLiquidity();

        uint256 shares = market.vault.balanceOf(LENDER) / 40;
        // The premise the name makes: this request could have been served out of free liquidity. Asserted, not
        // asserted-by-comment — the live share price drifts, and a request that quietly outgrew the idle amount
        // would make this the ordinary above-liquidity case with nothing left to distinguish it.
        assertLt(market.vault.previewRedeem(shares), freeBefore, "setup: the request fits inside free liquidity");

        vm.prank(LENDER);
        (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled) =
            market.vault.settle(shares, borrowers, LENDER, LENDER);

        assertGt(collateralSeized, 0, "sub-liquidity settle seized collateral under the new gate");
        assertGt(sharesBurned, 0, "shares burned for the slice");
        _assertSettlementAccounting(marketBefore, borrowerBorrowSharesBefore, collateralSeized, debtCanceled);
        assertEq(market.loanToken.balanceOf(LENDER), loanBefore, "receiver got no loan assets");
        assertEq(market.collateralToken.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
        assertEq(_freeLiquidity(), freeBefore, "settle took the settlement route, not the liquid one");
    }

    function _assertSettlementAccounting(
        MarketState memory marketBefore,
        uint256 borrowerBorrowSharesBefore,
        uint256 collateralSeized,
        uint256 debtCanceled
    ) internal view {
        uint256 borrowSharesCut = borrowerBorrowSharesBefore - market.core.position(market.id, BORROWER).borrowShares;
        uint256 expectedDebt =
            SharesMathLib.toAssetsUp(borrowSharesCut, marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
        uint256 expectedCollateral = Math.mulDiv(
            SharesMathLib.toAssetsDown(borrowSharesCut, marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares),
            ORACLE_PRICE_SCALE,
            mockedPrice
        );
        assertEq(debtCanceled, expectedDebt, "debt uses the up-rounded borrow-share value");
        assertEq(collateralSeized, expectedCollateral, "collateral uses the down-rounded borrow-share value");
    }
}
