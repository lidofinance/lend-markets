// Each rule walks a concrete scenario: one named external call, or a sequence of them, then asserts the end-to-end
// law (conservation, isolation, monotonicity, a round trip).

import "LidoLend_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// LL-HL-01: A supplier's position grows by exactly the shares the deposit reports.
rule hlLlSupplyCreditsExactShares(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    require(onBehalf != ghostLlFeeRecipient,
        "SCOPE: a plain supplier, not the fee sink");
    mathint before = ghostLlSupplyShares256[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = supply(e, mp, assets, shares, onBehalf, data);

    assert(ghostLlSupplyShares256[onBehalf] == before + retShares);
}

// LL-HL-02: A supplier's position shrinks by exactly the shares the withdrawal reports.
rule hlLlWithdrawDebitsExactShares(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(onBehalf != ghostLlFeeRecipient,
        "SCOPE: a plain supplier, not the fee sink");
    mathint before = ghostLlSupplyShares256[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostLlSupplyShares256[onBehalf] == before - retShares);
}

// LL-HL-03: A borrower's debt grows by exactly the debt shares the borrow reports.
rule hlLlBorrowCreditsExactDebt(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    mathint before = ghostLlBorrowShares128[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = borrow(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostLlBorrowShares128[onBehalf] == before + retShares);
}

// LL-HL-04: A borrower's debt shrinks by exactly the debt shares the repayment reports.
rule hlLlRepayDebitsExactDebt(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    mathint before = ghostLlBorrowShares128[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = repay(e, mp, assets, shares, onBehalf, data);

    assert(ghostLlBorrowShares128[onBehalf] == before - retShares);
}

// LL-HL-05: Posting collateral leaves the market's supply and borrow totals unchanged.
rule hlLlSupplyCollateralLeavesLoanTotals(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    mathint supplyAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint supplySharesBefore = ghostLlTotalSupplyShares128;
    mathint borrowAssetsBefore = ghostLlTotalBorrowAssets128;
    mathint borrowSharesBefore = ghostLlTotalBorrowShares128;

    supplyCollateral(e, mp, assets, onBehalf, data);

    assert(ghostLlTotalSupplyAssets128 == supplyAssetsBefore
        && ghostLlTotalSupplyShares128 == supplySharesBefore
        && ghostLlTotalBorrowAssets128 == borrowAssetsBefore
        && ghostLlTotalBorrowShares128 == borrowSharesBefore);
}

// LL-HL-06: Taking collateral back leaves the market's total debt shares unchanged.
rule hlLlWithdrawCollateralLeavesBorrowShares(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    mathint before = ghostLlTotalBorrowShares128;

    withdrawCollateral(e, mp, assets, onBehalf, receiver);

    assert(ghostLlTotalBorrowShares128 == before);
}

// LL-HL-07: A flash loan returns every borrowed token and leaves the pool's supply total unchanged.
rule hlLlFlashLoanLeavesMarkets(env e, address token, uint256 amount, bytes data) {
    setupLidoLendValidState(e);
    mathint before = ghostLlTotalSupplyAssets128;
    mathint poolBefore = ghostERC20Balances128[token][_Core];
    mathint callerBefore = ghostERC20Balances128[token][e.msg.sender];

    flashLoan(e, token, amount, data);

    assert(ghostLlTotalSupplyAssets128 == before
        && ghostERC20Balances128[token][_Core] == poolBefore
        && ghostERC20Balances128[token][e.msg.sender] == callerBefore);
}

// LL-HL-08: Accruing interest never mints or burns debt shares.
rule hlLlAccrueKeepsBorrowShares(env e, LidoLend.MarketParams mp) {
    setupLidoLendValidState(e);
    mathint before = ghostLlTotalBorrowShares128;

    accrueInterest(e, mp);

    assert(ghostLlTotalBorrowShares128 == before);
}

// LL-HL-09: A deposit leaves every other user's shares, debt and collateral untouched.
rule hlLlSupplyLeavesOtherPositions(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data,
    address other
) {
    setupLidoLendValidState(e);
    require(other != onBehalf && other != ghostLlFeeRecipient,
        "SCOPE: a bystander that is not the fee sink");
    mathint supplyBefore = ghostLlSupplyShares256[other];
    mathint borrowBefore = ghostLlBorrowShares128[other];
    mathint collateralBefore = ghostLlCollateral128[other];

    supply(e, mp, assets, shares, onBehalf, data);

    assert(ghostLlSupplyShares256[other] == supplyBefore
        && ghostLlBorrowShares128[other] == borrowBefore
        && ghostLlCollateral128[other] == collateralBefore);
}

// LL-HL-10: Settlement reports exactly the amounts it removes from the books, with the market's debt floored at zero.
rule hlLlSettleReturnsExactDeltas(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    mathint supplySharesBefore = ghostLlSupplyShares256[onBehalf];
    mathint totalSupplySharesBefore = ghostLlTotalSupplyShares128;
    mathint totalSupplyAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint borrowSharesBefore = ghostLlBorrowShares128[borrower];
    mathint totalBorrowSharesBefore = ghostLlTotalBorrowShares128;
    mathint totalBorrowAssetsBefore = ghostLlTotalBorrowAssets128;
    mathint collateralBefore = ghostLlCollateral128[borrower];
    require(e.block.timestamp == ghostLlLastUpdate128,
        "SCOPE: frozen accrual");
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    assert(ghostLlSupplyShares256[onBehalf] == supplySharesBefore - supplySharesBurned
        && ghostLlTotalSupplyShares128 == totalSupplySharesBefore - supplySharesBurned
        && ghostLlTotalSupplyAssets128 == totalSupplyAssetsBefore - borrowAssetsCanceled
        && ghostLlBorrowShares128[borrower] == borrowSharesBefore - borrowSharesCanceled
        && ghostLlTotalBorrowShares128 == totalBorrowSharesBefore - borrowSharesCanceled
        && (totalBorrowAssetsBefore >= to_mathint(borrowAssetsCanceled)
            => ghostLlTotalBorrowAssets128 == totalBorrowAssetsBefore - borrowAssetsCanceled)
        && (totalBorrowAssetsBefore < to_mathint(borrowAssetsCanceled)
            => ghostLlTotalBorrowAssets128 == 0)
        && to_mathint(borrowAssetsCanceled) <= totalBorrowAssetsBefore + 1
        && ghostLlCollateral128[borrower] == collateralBefore - seizedAssets
        && seizedAssets > 0);
}

// LL-HL-11: Settlement seizes collateral at par with the debt it cancels, to within one unit.
rule hlLlSettleSeizesAtPar(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    mathint price = ghostOraclePrice256[mp.oracle];
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    assert(seizedAssets * price <= borrowAssetsCanceled * ORACLE_PRICE_SCALE_LL_CVL()
        && (seizedAssets + 1) * price
            > (to_mathint(borrowAssetsCanceled) - 1) * ORACLE_PRICE_SCALE_LL_CVL());
}

// LL-HL-53: A settlement rounds the collateral it seizes down and the debt it cancels up.
rule hlLlSettleSeizurePricedDownAgainstCancelUp(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    require(e.block.timestamp == ghostLlLastUpdate128,
        "SCOPE: frozen accrual");
    mathint price = ghostOraclePrice256[mp.oracle];
    mathint sliceDown = borrowShares * (ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL())
        / (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL());
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    assert(seizedAssets * price <= sliceDown * ORACLE_PRICE_SCALE_LL_CVL(),
        "the seizure is quoted off the slice rounded down");
    assert(sliceDown <= to_mathint(borrowAssetsCanceled)
            && to_mathint(borrowAssetsCanceled) <= sliceDown + 1,
        "the cancellation books the same slice rounded up");
}

// LL-HL-12: A borrow leaves the borrower's position healthy at the current oracle price.
rule hlLlBorrowLeavesPositionHealthy(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    mathint price = ghostOraclePrice256[mp.oracle];

    borrow(e, mp, assets, shares, onBehalf, receiver);

    assert((ghostLlBorrowShares128[onBehalf] * (ghostLlTotalBorrowAssets128 + 1)
            + ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL() - 1)
            / (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL())
        <= ((ghostLlCollateral128[onBehalf] * price / ORACLE_PRICE_SCALE_LL_CVL()) * mp.lltv)
            / WAD_LL_CVL());
}

// LL-HL-13: Pulling collateral out never leaves the borrower's own position under water.
rule hlLlWithdrawCollateralLeavesPositionHealthy(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    mathint price = ghostOraclePrice256[mp.oracle];

    withdrawCollateral(e, mp, assets, onBehalf, receiver);

    assert((ghostLlBorrowShares128[onBehalf] * (ghostLlTotalBorrowAssets128 + 1)
            + ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL() - 1)
            / (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL())
        <= ((ghostLlCollateral128[onBehalf] * price / ORACLE_PRICE_SCALE_LL_CVL()) * mp.lltv)
            / WAD_LL_CVL());
}

// LL-HL-14: Liquidating a borrower whose collateral still covers their debt always fails.
rule hlLlLiquidateRevertsOnHealthyBorrower(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets,
    uint256 repaidShares, bytes data
) {
    setupLidoLendValidState(e);
    require(e.block.timestamp == ghostLlLastUpdate128, "SCOPE: frozen accrual");
    // _isHealthy mirror: debt rounded up against collateral cut by lltv, both scalings floored.
    mathint borrowed = (ghostLlBorrowShares128[borrower] * (ghostLlTotalBorrowAssets128 + 1)
        + ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL() - 1)
        / (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL());
    mathint maxBorrow = ((ghostLlCollateral128[borrower] * ghostOraclePrice256[mp.oracle]
        / ORACLE_PRICE_SCALE_LL_CVL()) * mp.lltv) / WAD_LL_CVL();
    require(maxBorrow >= borrowed, "SCOPE: a healthy borrower");

    liquidate@withrevert(e, mp, borrower, seizedAssets, repaidShares, data);

    assert(lastReverted);
}

// LL-HL-15: A liquidation burns the borrower's debt shares and the market's total in lockstep and seizes what it reports.
rule hlLlLiquidateDebitsSharesLockstep(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares,
    bytes data
) {
    setupLidoLendValidState(e);
    mathint bsBefore = ghostLlBorrowShares128[borrower];
    mathint tbsBefore = ghostLlTotalBorrowShares128;
    mathint colBefore = ghostLlCollateral128[borrower];

    uint256 retSeized; uint256 retRepaid;
    retSeized, retRepaid = liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    assert(tbsBefore - ghostLlTotalBorrowShares128
            == bsBefore - ghostLlBorrowShares128[borrower]
        && ghostLlCollateral128[borrower] == colBefore - retSeized);
}

// LL-HL-16: A liquidation leaves every position other than the borrower's untouched.
rule hlLlLiquidateLeavesOtherPositions(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets,
    uint256 repaidShares, bytes data, address other
) {
    setupLidoLendValidState(e);
    require(other != borrower, "SCOPE: a bystander, not the liquidated account");
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint supplyBefore = ghostLlSupplyShares256[other];
    mathint borrowBefore = ghostLlBorrowShares128[other];
    mathint collateralBefore = ghostLlCollateral128[other];

    liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    assert(ghostLlSupplyShares256[other] == supplyBefore
        && ghostLlBorrowShares128[other] == borrowBefore
        && ghostLlCollateral128[other] == collateralBefore);
}

// LL-HL-17: Accruing interest never shrinks the pot the suppliers own.
rule hlLlAccrueGrowsSupplyAssets(env e, LidoLend.MarketParams mp) {
    setupLidoLendValidState(e);
    mathint before = ghostLlTotalSupplyAssets128;

    accrueInterest(e, mp);

    assert(ghostLlTotalSupplyAssets128 >= before);
}

// LL-HL-18: Accrued interest credits suppliers exactly what it charges borrowers.
rule hlLlAccrueAddsEqualValue(env e, LidoLend.MarketParams mp) {
    setupLidoLendValidState(e);
    mathint supplyAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint borrowAssetsBefore = ghostLlTotalBorrowAssets128;

    accrueInterest(e, mp);

    assert(ghostLlTotalSupplyAssets128 - supplyAssetsBefore
        == ghostLlTotalBorrowAssets128 - borrowAssetsBefore);
}

// LL-HL-19: Depositing and immediately withdrawing the same shares never returns more tokens than went in.
rule hlLlSupplyWithdrawNoProfit(
    env e, LidoLend.MarketParams mp, uint256 supplyAssets, address onBehalf, address receiver, bytes data
) {
    setupLidoLendValidState(e);
    require(e.msg.sender == onBehalf, "SCOPE: a self-service round trip");
    require(onBehalf == receiver, "SCOPE: one address on both legs");
    mathint balanceBefore = ghostERC20Balances128[mp.loanToken][onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = supply(e, mp, supplyAssets, 0, onBehalf, data);
    withdraw(e, mp, 0, retShares, onBehalf, receiver);

    assert(ghostERC20Balances128[mp.loanToken][onBehalf] <= balanceBefore);
}

// LL-HL-20: Borrowing and immediately repaying the same debt shares never leaves the borrower ahead.
rule hlLlBorrowRepayNoProfit(
    env e, LidoLend.MarketParams mp, uint256 borrowAssets, address onBehalf, address receiver, bytes data
) {
    setupLidoLendValidState(e);
    require(e.msg.sender == onBehalf, "SCOPE: a self-service round trip");
    require(receiver == onBehalf, "SCOPE: one address on both legs");
    mathint balanceBefore = ghostERC20Balances128[mp.loanToken][onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = borrow(e, mp, borrowAssets, 0, onBehalf, receiver);
    repay(e, mp, 0, retShares, onBehalf, data);

    assert(ghostERC20Balances128[mp.loanToken][onBehalf] <= balanceBefore);
}

// LL-HL-21: A deposit moves exactly the assets it reports from the payer into the pool.
rule hlLlSupplyPullsExactAssets(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    mathint poolBefore = ghostERC20Balances128[mp.loanToken][_Core];
    mathint payerBefore = ghostERC20Balances128[mp.loanToken][e.msg.sender];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = supply(e, mp, assets, shares, onBehalf, data);

    assert(ghostERC20Balances128[mp.loanToken][_Core] == poolBefore + retAssets
        && ghostERC20Balances128[mp.loanToken][e.msg.sender] == payerBefore - retAssets);
    assert(assets != 0 => retAssets == assets,
        "an assets-denominated supply pulls the requested assets");
}

// LL-HL-22: A withdrawal leaves every other user's shares, debt and collateral untouched.
rule hlLlWithdrawLeavesOtherPositions(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver,
    address other
) {
    setupLidoLendValidState(e);
    require(other != onBehalf && other != ghostLlFeeRecipient,
        "SCOPE: a bystander that is not the fee sink");
    mathint supplyBefore = ghostLlSupplyShares256[other];
    mathint borrowBefore = ghostLlBorrowShares128[other];
    mathint collateralBefore = ghostLlCollateral128[other];

    withdraw(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostLlSupplyShares256[other] == supplyBefore
        && ghostLlBorrowShares128[other] == borrowBefore
        && ghostLlCollateral128[other] == collateralBefore);
}

// LL-HL-23: A borrow leaves every other user's shares, debt and collateral untouched.
rule hlLlBorrowLeavesOtherPositions(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver,
    address other
) {
    setupLidoLendValidState(e);
    require(other != onBehalf && other != ghostLlFeeRecipient,
        "SCOPE: a bystander that is not the fee sink");
    mathint supplyBefore = ghostLlSupplyShares256[other];
    mathint borrowBefore = ghostLlBorrowShares128[other];
    mathint collateralBefore = ghostLlCollateral128[other];

    borrow(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostLlSupplyShares256[other] == supplyBefore
        && ghostLlBorrowShares128[other] == borrowBefore
        && ghostLlCollateral128[other] == collateralBefore);
}

// LL-HL-24: A repayment leaves every other user's shares, debt and collateral untouched.
rule hlLlRepayLeavesOtherPositions(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data,
    address other
) {
    setupLidoLendValidState(e);
    require(other != onBehalf && other != ghostLlFeeRecipient,
        "SCOPE: a bystander that is not the fee sink");
    mathint supplyBefore = ghostLlSupplyShares256[other];
    mathint borrowBefore = ghostLlBorrowShares128[other];
    mathint collateralBefore = ghostLlCollateral128[other];

    repay(e, mp, assets, shares, onBehalf, data);

    assert(ghostLlSupplyShares256[other] == supplyBefore
        && ghostLlBorrowShares128[other] == borrowBefore
        && ghostLlCollateral128[other] == collateralBefore);
}

// LL-HL-25: Posting collateral leaves every other user's shares, debt and collateral untouched, the fee recipient included.
rule hlLlSupplyCollateralLeavesOtherPositions(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data, address other
) {
    setupLidoLendValidState(e);
    require(other != onBehalf, "SCOPE: a bystander other than the credited position");
    mathint supplyBefore = ghostLlSupplyShares256[other];
    mathint borrowBefore = ghostLlBorrowShares128[other];
    mathint collateralBefore = ghostLlCollateral128[other];

    supplyCollateral(e, mp, assets, onBehalf, data);

    assert(ghostLlSupplyShares256[other] == supplyBefore
        && ghostLlBorrowShares128[other] == borrowBefore
        && ghostLlCollateral128[other] == collateralBefore);
}

// LL-HL-26: Taking collateral back leaves every other user's shares, debt and collateral untouched.
rule hlLlWithdrawCollateralLeavesOtherPositions(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver, address other
) {
    setupLidoLendValidState(e);
    require(other != onBehalf && other != ghostLlFeeRecipient,
        "SCOPE: a bystander that is not the fee sink");
    mathint supplyBefore = ghostLlSupplyShares256[other];
    mathint borrowBefore = ghostLlBorrowShares128[other];
    mathint collateralBefore = ghostLlCollateral128[other];

    withdrawCollateral(e, mp, assets, onBehalf, receiver);

    assert(ghostLlSupplyShares256[other] == supplyBefore
        && ghostLlBorrowShares128[other] == borrowBefore
        && ghostLlCollateral128[other] == collateralBefore);
}

// LL-HL-27: Accruing interest never makes a supply share cheaper.
rule hlLlAccrueRaisesSupplySharePrice(env e, LidoLend.MarketParams mp) {
    setupLidoLendValidState(e);
    mathint assetsBefore = ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesBefore = ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL();

    accrueInterest(e, mp);

    mathint assetsAfter = ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesAfter = ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL();

    assert(assetsBefore * sharesAfter <= assetsAfter * sharesBefore);
}

// LL-HL-28: With interest already up to date, only a liquidation can make a supply share cheaper.
rule hlLlSupplySharePriceOnlyFallsOnSeizure(env e, method f, calldataarg args)
    filtered {
        f -> !EXCLUDED_FUNCTION_LL(f)
            && f.selector != sig:liquidate(LidoLend.MarketParams,address,uint256,uint256,bytes).selector
    } {

    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint assetsBefore = ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesBefore = ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL();

    f(e, args);

    mathint assetsAfter = ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesAfter = ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL();

    assert(assetsBefore * sharesAfter <= assetsAfter * sharesBefore);
}

// LL-HL-29: A liquidation that leaves the borrower some collateral never makes a supply share cheaper.
rule hlLlLiquidateNoBadDebtRaisesSupplySharePrice(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares,
    bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint assetsBefore = ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesBefore = ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL();

    liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    mathint assetsAfter = ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesAfter = ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL();
    require(ghostLlCollateral128[borrower] != 0,
        "SCOPE: the liquidation leaves collateral behind");

    assert(assetsBefore * sharesAfter <= assetsAfter * sharesBefore);
}

// LL-HL-30: With interest already up to date, only repayment, liquidation and settlement can make a debt share costlier.
rule hlLlBorrowSharePriceOnlyRisesOnAccrual(env e, method f, calldataarg args)
    filtered {
        f -> !EXCLUDED_FUNCTION_LL(f)
            && f.selector != sig:repay(LidoLend.MarketParams,uint256,uint256,address,bytes).selector
            && f.selector != sig:liquidate(LidoLend.MarketParams,address,uint256,uint256,bytes).selector
            && f.selector != sig:settle(LidoLend.MarketParams,uint256,address,address,address).selector
    } {

    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint assetsBefore = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesBefore = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();

    f(e, args);

    mathint assetsAfter = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesAfter = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();

    assert(assetsBefore * sharesAfter >= assetsAfter * sharesBefore);
}

// LL-HL-31: A repayment never makes the remaining debt shares more expensive.
rule hlLlRepayNeverRaisesDebtSharePrice(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint assetsBefore = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesBefore = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = repay(e, mp, assets, shares, onBehalf, data);

    require(to_mathint(retAssets) < assetsBefore,
        "SCOPE: the repayment does not outrun the debt book");
    mathint assetsAfter = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesAfter = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();

    assert(assetsBefore * sharesAfter >= assetsAfter * sharesBefore);
}

// LL-HL-32: A liquidation that leaves the market carrying debt never raises what a debt share owes.
rule hlLlLiquidateNeverRaisesDebtSharePrice(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares,
    bytes data
) {
    setupLidoLendValidState(e);
    require(data.length == 0, "SCOPE: no liquidator callback");
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint assetsBefore = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesBefore = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();

    liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    mathint assetsAfter = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesAfter = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();
    require(ghostLlTotalBorrowAssets128 != 0,
        "SCOPE: the market still carries debt");

    assert(assetsBefore * sharesAfter >= assetsAfter * sharesBefore);
}

// Mirror of the contract's liquidation incentive factor, both divisions floored.
function llLiquidationIncentiveCvl(mathint lltv) returns mathint {
    mathint denominator = WAD_LL_CVL() - (LIQUIDATION_CURSOR_LL_CVL() * (WAD_LL_CVL() - lltv)) / WAD_LL_CVL();
    mathint uncapped = (WAD_LL_CVL() * WAD_LL_CVL()) / denominator;
    return uncapped < MAX_LIF_LL_CVL() ? uncapped : MAX_LIF_LL_CVL();
}

// LL-HL-33: Liquidating a comfortably collateralized borrower leaves them collateral and takes at most the same fraction of it as of their debt.
rule hlLlLiquidateSeizureBoundedByIncentive(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssetsInput,
    uint256 repaidSharesInput, bytes data
) {
    setupLidoLendValidState(e);
    require(data.length == 0, "SCOPE: no liquidator callback");
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint price = ghostOraclePrice256[mp.oracle];
    mathint sharesBefore = ghostLlBorrowShares128[borrower];
    mathint collateralBefore = ghostLlCollateral128[borrower];
    mathint virtualAssetsBefore = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint virtualSharesBefore = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();
    require(collateralBefore * price * virtualSharesBefore * WAD_LL_CVL()
            > sharesBefore * ORACLE_PRICE_SCALE_LL_CVL() * virtualAssetsBefore
                * llLiquidationIncentiveCvl(to_mathint(mp.lltv)),
        "SCOPE: debt below the incentive-discounted collateral value");

    uint256 retSeized; uint256 retRepaid;
    retSeized, retRepaid = liquidate(e, mp, borrower, seizedAssetsInput, repaidSharesInput, data);

    mathint sharesAfter = ghostLlBorrowShares128[borrower];
    mathint collateralAfter = ghostLlCollateral128[borrower];
    mathint repaidShares = sharesBefore - sharesAfter;

    assert(collateralAfter != 0, "the borrower keeps collateral: no bad debt is realized");
    assert(repaidShares * collateralBefore >= retSeized * sharesBefore,
        "the seized share of collateral does not exceed the repaid share of debt");
    assert(sharesBefore * collateralAfter >= sharesAfter * collateralBefore,
        "debt shares per unit of collateral do not grow");
    assert(ghostLlTotalBorrowAssets128 > 0
        => (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL()) * virtualAssetsBefore
            >= (ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL()) * virtualSharesBefore,
        "what a debt share owes does not grow while the market still carries debt");
}

// What a borrower owes: debt shares priced at the market rate and rounded up.
function llDebtAssetsUpCvl(address user) returns mathint {
    return (ghostLlBorrowShares128[user] * (ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL())
            + ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL() - 1)
        / (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL());
}

// The health test: collateral quoted at the price and cut by lltv covers the debt, both floored.
function llIsHealthyCvl(address user, mathint price, mathint lltv) returns bool {
    return ((ghostLlCollateral128[user] * price / ORACLE_PRICE_SCALE_LL_CVL()) * lltv) / WAD_LL_CVL()
        >= llDebtAssetsUpCvl(user);
}

// LL-HL-34: No operation other than liquidation or settlement pushes an untouched, healthy borrower under water.
rule hlLlOthersStayHealthy(env e, method f, calldataarg args, LidoLend.MarketParams mp, address user)
    filtered {
        f -> !EXCLUDED_FUNCTION_LL(f)
            && f.selector != sig:liquidate(LidoLend.MarketParams,address,uint256,uint256,bytes).selector
            && f.selector != sig:settle(LidoLend.MarketParams,uint256,address,address,address).selector
    } {

    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint price = ghostOraclePrice256[mp.oracle];
    mathint borrowSharesBefore = ghostLlBorrowShares128[user];
    mathint collateralBefore = ghostLlCollateral128[user];
    require(llIsHealthyCvl(user, price, to_mathint(mp.lltv)),
        "SCOPE: a position that starts out healthy");

    f(e, args);

    require(ghostLlBorrowShares128[user] == borrowSharesBefore
            && ghostLlCollateral128[user] == collateralBefore,
        "SCOPE: a bystander the call left alone");
    require(ghostLlBorrowShares128[user] <= ghostLlTotalBorrowShares128,
        "SAFE: a position never exceeds the market total");

    assert(llIsHealthyCvl(user, price, to_mathint(mp.lltv)));
}

// LL-HL-35: A liquidation that leaves the borrower collateral cannot push a healthy bystander under water.
rule hlLlLiquidateLeavesOthersHealthy(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, bytes data, address user
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint price = ghostOraclePrice256[mp.oracle];
    require(llIsHealthyCvl(user, price, to_mathint(mp.lltv)),
        "SCOPE: a position that starts out healthy");
    mathint sharesBefore = ghostLlBorrowShares128[user];
    mathint debtBefore = llDebtAssetsUpCvl(user);

    liquidate(e, mp, borrower, seizedAssets, 0, data);

    require(ghostLlBorrowShares128[user] <= ghostLlTotalBorrowShares128,
        "SAFE: a position never exceeds the market total");
    require(ghostLlTotalBorrowAssets128 > 0,
        "SCOPE: the market still carries debt");
    require(ghostLlCollateral128[borrower] > 0,
        "SCOPE: the liquidation leaves collateral behind");

    assert(user != borrower, "a healthy position is never the one being liquidated");
    assert(ghostLlBorrowShares128[user] == sharesBefore, "the bystander's debt shares stay put");
    assert(debtBefore >= llDebtAssetsUpCvl(user), "what those shares owe does not grow");
    assert(llIsHealthyCvl(user, price, to_mathint(mp.lltv)));
}

// LL-HL-36: A liquidation clearing the market's last debt still leaves a healthy bystander healthy.
rule hlLlLastBorrowLiquidationLeavesOthersHealthy(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, bytes data, address user
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint price = ghostOraclePrice256[mp.oracle];
    require(llIsHealthyCvl(user, price, to_mathint(mp.lltv)),
        "SCOPE: a position that starts out healthy");

    liquidate(e, mp, borrower, seizedAssets, 0, data);

    require(ghostLlBorrowShares128[user] <= ghostLlTotalBorrowShares128,
        "SAFE: a position never exceeds the market total");
    require(ghostLlTotalBorrowAssets128 == 0,
        "SCOPE: the market is left with no debt assets");

    assert(llIsHealthyCvl(user, price, to_mathint(mp.lltv)));
}

// What a supplier's shares are worth: priced at the market rate and rounded down.
function llSupplyAssetsDownCvl(address user) returns mathint {
    return ghostLlSupplyShares256[user] * (ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL())
        / (ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL());
}

// LL-HL-37: A deposit never buys more book value than the assets it pays in.
rule hlLlSupplyBookValueBounded(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint ownedBefore = llSupplyAssetsDownCvl(onBehalf);

    uint256 suppliedAssets; uint256 suppliedShares;
    suppliedAssets, suppliedShares = supply(e, mp, assets, shares, onBehalf, data);

    assert(ownedBefore + suppliedAssets >= llSupplyAssetsDownCvl(onBehalf));
}

// LL-HL-38: A withdrawal never pays out more than the position was worth beforehand.
rule hlLlWithdrawBookValueBounded(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint owned = llSupplyAssetsDownCvl(onBehalf);

    uint256 withdrawnAssets; uint256 withdrawnShares;
    withdrawnAssets, withdrawnShares = withdraw(e, mp, assets, shares, onBehalf, receiver);

    assert(to_mathint(withdrawnAssets) <= owned);
}

// LL-HL-39: A borrow always books at least as much debt as the assets it hands out.
rule hlLlBorrowDebtValueBounded(
    env e, LidoLend.MarketParams mp, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint owedBefore = llDebtAssetsUpCvl(onBehalf);

    // SCOPE: the shares-mode leg only.
    uint256 borrowedAssets; uint256 borrowedShares;
    borrowedAssets, borrowedShares = borrow(e, mp, 0, shares, onBehalf, receiver);

    assert(owedBefore + borrowedAssets <= llDebtAssetsUpCvl(onBehalf));
}

// LL-HL-40: Clearing a debt costs at least what the position's debt shares were worth.
rule hlLlRepayCostBounded(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint owed = llDebtAssetsUpCvl(onBehalf);

    uint256 repaidAssets; uint256 repaidShares;
    repaidAssets, repaidShares = repay(e, mp, assets, shares, onBehalf, data);

    require(ghostLlBorrowShares128[onBehalf] == 0,
        "SCOPE: a repayment that clears the position");

    assert(to_mathint(repaidAssets) >= owed);
}

// LL-HL-41: Depositing and immediately withdrawing never turns a profit, whether the amount is set in assets or in shares.
rule hlLlSupplyWithdrawAnyModeNoProfit(
    env e, LidoLend.MarketParams mp, uint256 supplyAssetsIn, uint256 supplySharesIn,
    uint256 withdrawAssetsIn, uint256 withdrawSharesIn, address onBehalf, address receiver, bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlSupplyShares256[onBehalf] == 0,
        "SCOPE: a position opened by this round trip");
    require(onBehalf != ghostLlFeeRecipient,
        "SCOPE: a plain supplier, not the fee sink");

    uint256 suppliedAssets; uint256 suppliedShares;
    suppliedAssets, suppliedShares = supply(e, mp, supplyAssetsIn, supplySharesIn, onBehalf, data);

    // The mint is priced at no better than the market rate, read either before or after the mint itself.
    assert(suppliedAssets * (ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL() - suppliedShares)
        >= suppliedShares * (ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL() - suppliedAssets));
    assert(suppliedAssets * (ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL())
        >= suppliedShares * (ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL()));

    uint256 withdrawnAssets;
    uint256 withdrawnShares;

    (withdrawnAssets, withdrawnShares) =
        withdraw(e, mp, withdrawAssetsIn, withdrawSharesIn, onBehalf, receiver);

    assert(withdrawnAssets <= suppliedAssets);
}

// LL-HL-42: Borrowing and immediately repaying the same debt never leaves the borrower ahead.
rule hlLlBorrowRepayAnyModeNoProfit(
    env e, LidoLend.MarketParams mp, uint256 borrowAssetsIn, uint256 borrowSharesIn, address onBehalf,
    address receiver, bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlBorrowShares128[onBehalf] == 0,
        "SCOPE: a debt opened by this round trip");

    uint256 borrowedAssets; uint256 borrowedShares;
    borrowedAssets, borrowedShares = borrow(e, mp, borrowAssetsIn, borrowSharesIn, onBehalf, receiver);

    // The debt booked is priced at no better than the market rate, read either before or after the draw.
    assert(borrowedAssets * (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL() - borrowedShares)
        <= borrowedShares * (ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL() - borrowedAssets));
    assert(borrowedAssets * (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL())
        <= borrowedShares * (ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL()));

    uint256 repaidAssets; uint256 repaidShares;
    repaidAssets, repaidShares = repay(e, mp, 0, borrowedShares, onBehalf, data);

    assert(borrowedAssets <= repaidAssets);
}

// LL-HL-43: A settlement cancels at most one unit of debt beyond the book and otherwise never makes remaining debt shares costlier.
rule hlLlSettleBorrowAnchoredNeverRaisesDebtSharePrice(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf, address borrower,
    address receiver
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint assetsBefore = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesBefore = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();

    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    mathint assetsAfter = ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint sharesAfter = ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL();

    assert(to_mathint(borrowAssetsCanceled) <= assetsBefore,
        "the cancellation overshoots the book by at most the wei zeroFloorSub absorbs");
    assert(to_mathint(borrowAssetsCanceled) < assetsBefore
            => assetsBefore * sharesAfter >= assetsAfter * sharesBefore,
        "and off that overshoot a remaining debt share never gets more expensive");
}

// LL-HL-44: A settlement cannot push a healthy borrower it never touched into liquidation.
rule hlLlSettleBorrowAnchoredLeavesOthersHealthy(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf, address borrower,
    address receiver, address user
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint price = ghostOraclePrice256[mp.oracle];
    require(llIsHealthyCvl(user, price, to_mathint(mp.lltv)),
        "SCOPE: a position that starts out healthy");
    mathint borrowSharesBefore = ghostLlBorrowShares128[user];
    mathint collateralBefore = ghostLlCollateral128[user];

    settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    require(ghostLlBorrowShares128[user] == borrowSharesBefore
            && ghostLlCollateral128[user] == collateralBefore,
        "SCOPE: a bystander the call left alone");
    require(ghostLlBorrowShares128[user] <= ghostLlTotalBorrowShares128,
        "SAFE: a position never exceeds the market total");

    assert(llIsHealthyCvl(user, price, to_mathint(mp.lltv)));
}

// LL-HL-45: A borrow for a named amount hands over exactly that amount and books at least as much new debt.
rule hlLlBorrowDebtValueBoundedAssetsMode(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint owedBefore = llDebtAssetsUpCvl(onBehalf);

    uint256 borrowedAssets; uint256 borrowedShares;
    borrowedAssets, borrowedShares = borrow(e, mp, assets, 0, onBehalf, receiver);

    assert(to_mathint(borrowedAssets) == to_mathint(assets),
        "the assets-mode leg draws the requested assets verbatim");
    assert(owedBefore + borrowedAssets <= llDebtAssetsUpCvl(onBehalf));
}

// LL-HL-46: Only a lender withdrawal, a borrow or a settlement can reduce the cash a market has free.
rule hlLlFreeLiquidityFallsOnlyOnExitOrDraw(env e, method f, calldataarg args)
    filtered {
        f -> !EXCLUDED_FUNCTION_LL(f)
            && f.selector != sig:withdraw(LidoLend.MarketParams,uint256,uint256,address,address).selector
            && f.selector != sig:borrow(LidoLend.MarketParams,uint256,uint256,address,address).selector
            && f.selector != sig:settle(LidoLend.MarketParams,uint256,address,address,address).selector
    } {

    setupLidoLendValidState(e);
    mathint freeBefore = ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128;

    f(e, args);

    assert(ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128 >= freeBefore,
        "only a lender exit or a borrower draw takes cash out of the pool");
}

// LL-HL-52: A settlement gives up at most one unit of free cash, and none when the book covers the cancellation.
rule hlLlSettleFreeLiquidityFallsByAtMostTheClampWei(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf, address borrower,
    address receiver
) {
    setupLidoLendValidState(e);
    mathint freeBefore = ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128;
    mathint borrowAssetsBefore = ghostLlTotalBorrowAssets128;

    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    assert(ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128 >= freeBefore - 1,
        "a settle gives up at most the one wei the zero floor absorbs");
    assert(to_mathint(borrowAssetsCanceled) <= borrowAssetsBefore
            => ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128 == freeBefore,
        "and nothing at all when the book covers the cancellation");
}

// LL-HL-47: A withdrawal pays out at most the market's free cash and reduces it by exactly the amount paid.
rule hlLlWithdrawPaysAtMostFreeLiquidity(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    mathint freeBefore = ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128;

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, assets, shares, onBehalf, receiver);

    assert(to_mathint(retAssets) <= freeBefore,
        "a lender is never paid out of money the market has lent away");
    assert(ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128 == freeBefore - retAssets,
        "the payout is exactly what leaves the free pot");
}

// LL-HL-48: A borrow draws at most the market's free cash and reduces it by exactly the amount drawn.
rule hlLlBorrowDrawsAtMostFreeLiquidity(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    mathint freeBefore = ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128;

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = borrow(e, mp, assets, shares, onBehalf, receiver);

    assert(to_mathint(retAssets) <= freeBefore,
        "a borrower never draws more than the market has free");
    assert(ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128 == freeBefore - retAssets,
        "the draw is exactly what leaves the free pot");
}

// LL-HL-49: A liquidation that seizes all of a borrower's collateral leaves no debt standing against them.
rule hlLlLiquidateBadDebtTailClearsDebt(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares, bytes data
) {
    setupLidoLendValidState(e);
    require(data.length == 0, "SCOPE: no liquidate callback");

    liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    assert(ghostLlCollateral128[borrower] == 0 => ghostLlBorrowShares128[borrower] == 0,
        "a fully seized position keeps no residual debt shares");
}

// LL-HL-50: A liquidation never charges lenders more than the liquidated borrower owed.
rule hlLlLiquidateSocializesAtMostBorrowerDebt(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares,
    bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint debtBefore = llDebtAssetsUpCvl(borrower);
    mathint supplyAssetsBefore = ghostLlTotalSupplyAssets128;

    liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    assert(supplyAssetsBefore - ghostLlTotalSupplyAssets128 <= debtBefore,
        "the supply pool never eats more than the liquidated borrower's whole debt");
}

// LL-HL-51: When the fee recipient changes, the next interest accrual pays the whole pending fee to the new recipient.
rule hlLlFeeWindowSettlesToRecipientOfRecord(
    env e, LidoLend.MarketParams mp, address newFeeRecipient
) {
    setupLidoLendValidState(e);
    require(mp.irm != 0, "SCOPE: interest-bearing market with a nonzero irm");
    require(ghostLlTotalBorrowAssets128 > 0, "SCOPE: outstanding debt to accrue on");
    require(ghostLlIrmBorrowRate[mp.irm] > 0, "SCOPE: a positive borrow rate applies");
    require(ghostLlFee128 > 0, "SCOPE: the market charges a fee");
    require(ghostLlLastUpdate128 < to_mathint(e.block.timestamp),
        "SCOPE: a window standing open since the last accrual");
    // setFeeRecipient refuses an unchanged recipient, so the two addresses always differ.
    address outgoing = ghostLlFeeRecipient;
    require(ERC20_ACCOUNT_BOUNDS(ghostLlLoanToken, newFeeRecipient)
            && ERC20_ACCOUNT_BOUNDS(ghostLlLoanToken, outgoing),
        "SCOPE: both recipients are modelled loan token holders");
    mathint incomingBefore = ghostLlSupplyShares256[newFeeRecipient];
    mathint outgoingBefore = ghostLlSupplyShares256[outgoing];
    mathint totalSharesBefore = ghostLlTotalSupplyShares128;

    setFeeRecipient(e, newFeeRecipient);
    accrueInterest(e, mp);

    assert(ghostLlSupplyShares256[newFeeRecipient] - incomingBefore
            == ghostLlTotalSupplyShares128 - totalSharesBefore,
        "the recipient on record at the accrual takes every share that accrual mints");
    assert(ghostLlSupplyShares256[outgoing] == outgoingBefore,
        "and the outgoing recipient keeps the shares it already held");
}

// LL-HL-54: A settlement burns the supply shares its canceled debt is worth, rounded up.
rule hlLlSettleBurnsSupplySharesAtSupplyRate(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    require(e.block.timestamp == ghostLlLastUpdate128,
        "SCOPE: frozen accrual");
    mathint virtualAssets = ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL();
    mathint virtualShares = ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL();
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    assert(supplySharesBurned * virtualAssets >= borrowAssetsCanceled * virtualShares,
        "the lenders' charge covers the debt the settlement cancels");
    assert(supplySharesBurned * virtualAssets
            < borrowAssetsCanceled * virtualShares + virtualAssets,
        "and never exceeds it by a whole share of the supply pool");
}

// LL-HL-55: A settlement never raises the risk key of a borrower whose collateral covers the debt.
rule hlLlSettleDoesNotRaiseCoveredBorrowerRiskKey(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");
    mathint price = ghostOraclePrice256[mp.oracle];
    mathint debtSharesBefore = ghostLlBorrowShares128[borrower];
    mathint collateralBefore = ghostLlCollateral128[borrower];
    require(debtSharesBefore * (ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL())
                * ORACLE_PRICE_SCALE_LL_CVL()
            <= collateralBefore * price * (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL()),
        "SCOPE: collateral value covers the debt at the pre-cut rate");

    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    assert(debtSharesBefore * seizedAssets <= borrowSharesCanceled * collateralBefore,
        "the risk key (debt shares over collateral) does not rise");
}
