// Each rule witnesses that a call can succeed and take real effect

import "LidoLend_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// LL-RC-01: A supplier can deposit assets and be credited freshly minted shares.
rule rcLlSupplyIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {

    setupLidoLendValidState(e);
    mathint sharesBefore = ghostLlSupplyShares256[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = supply(e, mp, assets, 0, onBehalf, data);

    satisfy(retShares > 0 && ghostLlSupplyShares256[onBehalf] > sharesBefore,
        "assets-anchored supply mints positive shares credited to the beneficiary");
}

// LL-RC-02: A supplier can name an exact share amount and be minted exactly that.
rule rcLlSupplySharesAnchoredIsReachable(
    env e, LidoLend.MarketParams mp, uint256 shares, address onBehalf, bytes data
) {

    setupLidoLendValidState(e);

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = supply(e, mp, 0, shares, onBehalf, data);

    satisfy(shares > 0 && retAssets > 0 && to_mathint(retShares) == to_mathint(shares),
        "shares-anchored supply mints exactly the requested shares for positive assets");
}

// LL-RC-03: A first deposit into an empty market can mint its whole share supply to the depositor.
rule rcLlSupplyBootstrapIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {

    setupLidoLendValidState(e);
    require(ghostLlTotalSupplyShares128 == 0, "SCOPE: no existing supply shares (first supplier)");

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = supply(e, mp, assets, 0, onBehalf, data);

    satisfy(retShares > 0 && ghostLlSupplyShares256[onBehalf] == ghostLlTotalSupplyShares128,
        "bootstrap supply mints the market's entire share supply to the first supplier");
}

// LL-RC-04: A deposit into a market governed by the controller can complete and call the depositor back.
rule rcLlSupplyControlledWithCallbackIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {

    setupLidoLendValidState(e);
    require(ghostLlMarketController != 0,
        "SCOPE: a controller-bound market");
    require(data.length > 0, "SCOPE: non-empty data opts into the supply callback");
    mathint sharesBefore = ghostLlSupplyShares256[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = supply(e, mp, assets, 0, onBehalf, data);

    satisfy(retShares > 0 && ghostLlSupplyShares256[onBehalf] > sharesBefore,
        "supply through the controller hook and the supply callback succeeds");
}

// LL-RC-05: A lender can withdraw assets and burn the matching supply shares.
rule rcLlWithdrawIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf == e.msg.sender, "SCOPE: the owner withdraws its own supply");
    mathint sharesBefore = ghostLlSupplyShares256[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, assets, 0, onBehalf, receiver);

    satisfy(retAssets > 0 && ghostLlSupplyShares256[onBehalf] < sharesBefore,
        "assets-anchored withdraw burns supply shares and pays out assets");
}

// LL-RC-06: An authorized delegate can withdraw a lender's supply on their behalf.
rule rcLlWithdrawByDelegateIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf != e.msg.sender, "SCOPE: the caller is a delegate, not the position owner");
    mathint sharesBefore = ghostLlSupplyShares256[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, assets, 0, onBehalf, receiver);

    satisfy(retShares > 0 && ghostLlSupplyShares256[onBehalf] < sharesBefore,
        "an authorized delegate can withdraw on behalf of the owner");
}

// LL-RC-07: The sole lender can burn every share and still leave asset dust in the market.
rule rcLlWithdrawAllLeavesAssetDustIsReachable(
    env e, LidoLend.MarketParams mp, uint256 shares, address onBehalf, address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf == e.msg.sender, "SCOPE: the owner withdraws its own supply");
    require(shares > 0 && to_mathint(shares) == ghostLlTotalSupplyShares128
        && to_mathint(shares) == ghostLlSupplyShares256[onBehalf],
        "SCOPE: the sole supplier withdraws every supply share");

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, 0, shares, onBehalf, receiver);

    satisfy(ghostLlSupplyShares256[onBehalf] == 0 && ghostLlTotalSupplyShares128 == 0
        && ghostLlTotalSupplyAssets128 > 0,
        "the sole supplier's full exit reaches zero shares with asset dust");
}

// LL-RC-08: A borrower can draw assets against collateral and take on debt shares.
rule rcLlBorrowIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf == e.msg.sender, "SCOPE: the borrower borrows against its own collateral");
    mathint debtBefore = ghostLlBorrowShares128[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = borrow(e, mp, assets, 0, onBehalf, receiver);

    satisfy(retShares > 0 && ghostLlBorrowShares128[onBehalf] > debtBefore,
        "assets-anchored borrow mints positive debt shares against collateral");
}

// LL-RC-09: A borrower can repay assets and shrink the outstanding debt.
rule rcLlRepayIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {

    setupLidoLendValidState(e);
    mathint debtBefore = ghostLlBorrowShares128[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = repay(e, mp, assets, 0, onBehalf, data);

    satisfy(retShares > 0 && ghostLlBorrowShares128[onBehalf] < debtBefore,
        "assets-anchored repay burns positive debt shares");
}

// LL-RC-10: A full repayment can zero all debt shares and still leave borrowed assets on the books.
rule rcLlRepayAllLeavesAssetResidueIsReachable(
    env e, LidoLend.MarketParams mp, uint256 shares, address onBehalf, bytes data
) {

    setupLidoLendValidState(e);
    require(shares > 0 && to_mathint(shares) == ghostLlTotalBorrowShares128
        && to_mathint(shares) == ghostLlBorrowShares128[onBehalf],
        "SCOPE: the sole borrower repays every borrow share");

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = repay(e, mp, 0, shares, onBehalf, data);

    satisfy(ghostLlBorrowShares128[onBehalf] == 0 && ghostLlTotalBorrowShares128 == 0
        && ghostLlTotalBorrowAssets128 > 0,
        "full repay reaches zero borrow shares with residual borrow assets");
}

// LL-RC-11: A user can post collateral and be credited exactly the amount deposited.
rule rcLlSupplyCollateralIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {

    setupLidoLendValidState(e);
    mathint collBefore = ghostLlCollateral128[onBehalf];

    supplyCollateral(e, mp, assets, onBehalf, data);

    satisfy(assets > 0 && ghostLlCollateral128[onBehalf] == collBefore + assets,
        "the collateral deposit credits exactly the deposited assets to the beneficiary");
}

// LL-RC-12: A borrower with live debt can still pull out surplus collateral.
rule rcLlWithdrawCollateralWithLiveDebtIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf == e.msg.sender, "SCOPE: the owner withdraws its own collateral");
    require(ghostLlBorrowShares128[onBehalf] != 0, "SCOPE: a position with live debt");
    mathint collBefore = ghostLlCollateral128[onBehalf];

    withdrawCollateral(e, mp, assets, onBehalf, receiver);

    satisfy(ghostLlCollateral128[onBehalf] < collBefore,
        "a debtor can withdraw excess collateral past the active health check");
}

// LL-RC-13: A debt free holder can pull its collateral out down to zero.
rule rcLlWithdrawCollateralFullExitIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf == e.msg.sender, "SCOPE: the owner withdraws its own collateral");
    require(ghostLlBorrowShares128[onBehalf] == 0,
        "SCOPE: a debt-free position");
    require(assets > 0 && to_mathint(assets) == ghostLlCollateral128[onBehalf],
        "SCOPE: withdraw the entire collateral balance");

    withdrawCollateral(e, mp, assets, onBehalf, receiver);

    satisfy(ghostLlCollateral128[onBehalf] == 0,
        "a debt-free holder can exit its full collateral down to zero");
}

// LL-RC-14: A settlement can cancel debt shares of the borrower it names.
rule rcLlSettleBorrowAnchoredIsReachable(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf, address borrower,
    address receiver
) {

    setupLidoLendValidState(e);
    mathint debtBefore = ghostLlBorrowShares128[borrower];
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    satisfy(borrowSharesCanceled > 0 && ghostLlBorrowShares128[borrower] < debtBefore,
        "borrow-anchored settle cancels borrower debt shares");
}

// LL-RC-15: A liquidator can name the collateral to seize and cut the borrower's debt with it.
rule rcLlLiquidateSeizeAnchoredIsReachable(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, bytes data
) {

    setupLidoLendValidState(e);
    mathint collBefore = ghostLlCollateral128[borrower];
    mathint debtBefore = ghostLlBorrowShares128[borrower];

    uint256 seized; uint256 repaid;
    seized, repaid = liquidate(e, mp, borrower, seizedAssets, 0, data);

    satisfy(seized > 0 && ghostLlCollateral128[borrower] < collBefore
        && ghostLlBorrowShares128[borrower] < debtBefore,
        "seize-anchored liquidation reduces both collateral and debt of the borrower");
}

// LL-RC-16: A liquidator can name the debt shares to repay and seize collateral for them.
rule rcLlLiquidateRepaidAnchoredIsReachable(
    env e, LidoLend.MarketParams mp, address borrower, uint256 repaidShares, bytes data
) {

    setupLidoLendValidState(e);
    require(ghostLlCollateral128[borrower] > 0, "SCOPE: the borrower has collateral to seize");
    mathint debtBefore = ghostLlBorrowShares128[borrower];

    uint256 seized; uint256 repaid;
    seized, repaid = liquidate(e, mp, borrower, 0, repaidShares, data);

    satisfy(seized > 0 && ghostLlBorrowShares128[borrower] < debtBefore,
        "repaid-shares-anchored liquidation seizes collateral and reduces debt");
}

// LL-RC-17: A liquidation can wipe out a hopeless position and push the loss onto lenders.
rule rcLlLiquidateBadDebtIsReachable(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, bytes data
) {

    setupLidoLendValidState(e);
    mathint tsaBefore = ghostLlTotalSupplyAssets128;

    uint256 seized; uint256 repaid;
    seized, repaid = liquidate(e, mp, borrower, seizedAssets, 0, data);

    satisfy(ghostLlCollateral128[borrower] == 0 && ghostLlBorrowShares128[borrower] == 0
        && ghostLlTotalSupplyAssets128 < tsaBefore,
        "bad-debt liquidation zeroes the position and socializes the loss into supply");
}

// LL-RC-18: Accrued interest can grow the outstanding debt and the lenders' assets together.
rule rcLlAccrueInterestGrowsDebtIsReachable(env e, LidoLend.MarketParams mp) {

    setupLidoLendValidState(e);
    require(mp.irm != 0, "SCOPE: interest-bearing market with a nonzero irm");
    require(ghostLlTotalBorrowAssets128 > 0, "SCOPE: outstanding debt to accrue on");
    require(ghostLlLastUpdate128 < to_mathint(e.block.timestamp),
        "SCOPE: time has elapsed since the last accrual");
    require(ghostLlIrmBorrowRate[mp.irm] > 0, "SCOPE: a positive borrow rate applies");
    mathint tbaBefore = ghostLlTotalBorrowAssets128;
    mathint tsaBefore = ghostLlTotalSupplyAssets128;

    accrueInterest(e, mp);

    satisfy(ghostLlTotalBorrowAssets128 > tbaBefore && ghostLlTotalSupplyAssets128 > tsaBefore,
        "accrual grows borrow and supply assets together");
}

// LL-RC-19: Accrual under a fee can mint new shares to the fee recipient.
rule rcLlAccrueInterestMintsFeeSharesIsReachable(env e, LidoLend.MarketParams mp) {

    setupLidoLendValidState(e);
    require(mp.irm != 0, "SCOPE: interest-bearing market with a nonzero irm");
    require(ghostLlTotalBorrowAssets128 > 0, "SCOPE: outstanding debt to accrue on");
    require(ghostLlLastUpdate128 < to_mathint(e.block.timestamp),
        "SCOPE: time has elapsed since the last accrual");
    require(ghostLlIrmBorrowRate[mp.irm] > 0, "SCOPE: a positive borrow rate applies");
    require(ghostLlFee128 > 0, "SCOPE: the market charges a fee");
    mathint feeSharesBefore = ghostLlSupplyShares256[ghostLlFeeRecipient];

    accrueInterest(e, mp);

    satisfy(ghostLlSupplyShares256[ghostLlFeeRecipient] > feeSharesBefore,
        "accrual mints fee shares to the fee recipient");
}

// LL-RC-20: A supplier can enter and fully exit within a single block.
rule rcLlSupplyWithdrawRoundTripIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address account, bytes data
) {

    setupLidoLendValidState(e);
    require(account == e.msg.sender, "SCOPE: self round trip");
    require(!_Core._hookInProgress,
        "SCOPE: a top level call starts with the hook latch clear");

    uint256 a1; uint256 s1;
    a1, s1 = supply(e, mp, assets, 0, account, data);
    uint256 a2; uint256 s2;
    a2, s2 = withdraw(e, mp, 0, s1, account, account);

    satisfy(s1 > 0 && a2 > 0, "a supplier can enter and fully exit within one block");
}

// LL-RC-21: A borrower can name an exact debt share amount and be issued exactly that.
rule rcLlBorrowSharesAnchoredIsReachable(
    env e, LidoLend.MarketParams mp, uint256 shares, address onBehalf, address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf == e.msg.sender, "SCOPE: the borrower borrows against its own collateral");

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = borrow(e, mp, 0, shares, onBehalf, receiver);

    satisfy(shares > 0 && retAssets > 0 && to_mathint(retShares) == to_mathint(shares),
        "shares-anchored borrow mints exactly the requested debt shares");
}

// LL-RC-22: A lender can exit its whole position while debt and other lenders remain in the market.
rule rcLlWithdrawAllWithLiveDebtIsReachable(
    env e, LidoLend.MarketParams mp, address onBehalf, address receiver, address other
) {

    setupLidoLendValidState(e);
    require(onBehalf == e.msg.sender, "SCOPE: the owner withdraws its own supply");
    mathint sharesBefore = ghostLlSupplyShares256[onBehalf];
    require(other != onBehalf && ghostLlSupplyShares256[other] > 0,
        "SCOPE: a second, distinct supplier stays invested");
    require(ghostLlTotalSupplyShares128 > sharesBefore,
        "SCOPE: other suppliers hold the rest of the shares");
    require(ghostLlTotalBorrowAssets128 > 0, "SCOPE: the market carries outstanding debt");
    require(to_mathint(e.block.timestamp) == ghostLlLastUpdate128,
        "SCOPE: no elapsed time since the last accrual");
    require(ghostERC20Balances128[ghostLlLoanToken][_Core] >= ghostLlTotalSupplyAssets128,
        "SCOPE: the pool holds at least its whole supply in tokens");

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, 0, require_uint256(sharesBefore), onBehalf, receiver);

    satisfy(retAssets > 0 && ghostLlSupplyShares256[onBehalf] == 0 && ghostLlTotalBorrowAssets128 > 0
        && ghostLlSupplyShares256[other] > 0,
        "a paying full exit passes the liquidity check: live debt, another supplier");
}

// LL-RC-23: A settlement can cancel debt on a borrower that is still healthy.
rule rcLlSettleOnHealthyBorrowerIsReachable(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf, address borrower,
    address receiver
) {

    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp), "SCOPE: frozen accrual");
    // _isHealthy mirror: debt rounded up against collateral cut by lltv, both scalings floored.
    mathint borrowed = (ghostLlBorrowShares128[borrower] * (ghostLlTotalBorrowAssets128 + 1)
        + ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL() - 1)
        / (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL());
    mathint maxBorrow = ((ghostLlCollateral128[borrower] * ghostOraclePrice256[mp.oracle]
        / ORACLE_PRICE_SCALE_LL_CVL()) * mp.lltv) / WAD_LL_CVL();
    require(maxBorrow >= borrowed, "SCOPE: a healthy borrower");
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    satisfy(borrowSharesCanceled > 0,
        "settle cancels debt on a borrower inside its liquidation threshold");
}

// LL-RC-24: A settlement can cancel debt on a borrower that is under water.
rule rcLlSettleOnUnhealthyBorrowerIsReachable(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf, address borrower,
    address receiver
) {

    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp), "SCOPE: frozen accrual");
    mathint borrowed = (ghostLlBorrowShares128[borrower] * (ghostLlTotalBorrowAssets128 + 1)
        + ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL() - 1)
        / (ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL());
    mathint maxBorrow = ((ghostLlCollateral128[borrower] * ghostOraclePrice256[mp.oracle]
        / ORACLE_PRICE_SCALE_LL_CVL()) * mp.lltv) / WAD_LL_CVL();
    require(maxBorrow < borrowed, "SCOPE: a borrower under water");
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    satisfy(borrowSharesCanceled > 0,
        "settle cancels debt on an under-water borrower: the core carries no health gate");
}

// LL-RC-25: An account with no authorization can repay another account's debt.
rule rcLlRepayByUnauthorizedThirdPartyIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {

    setupLidoLendValidState(e);
    require(onBehalf != e.msg.sender, "SCOPE: the payer is not the position owner");
    require(!ghostLlIsAuthorized[onBehalf][e.msg.sender],
        "SCOPE: the payer holds no authorization over the position");
    mathint debtBefore = ghostLlBorrowShares128[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = repay(e, mp, assets, 0, onBehalf, data);

    satisfy(retShares > 0 && ghostLlBorrowShares128[onBehalf] < debtBefore,
        "an unauthorized third party can repay a position's debt");
}

// LL-RC-26: A withdrawal can take a market's free liquidity down to exactly zero while debt remains.
rule rcLlWithdrawToExactZeroLiquidityIsReachable(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf == e.msg.sender, "SCOPE: the owner withdraws its own supply");
    require(to_mathint(e.block.timestamp) == ghostLlLastUpdate128,
        "SCOPE: no elapsed time since the last accrual");
    require(ghostLlTotalBorrowAssets128 > 0, "SCOPE: the market carries outstanding debt");
    require(to_mathint(assets) == ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128,
        "SCOPE: the withdrawal takes exactly the market's free liquidity");

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, assets, 0, onBehalf, receiver);

    satisfy(retAssets > 0 && ghostLlTotalBorrowAssets128 > 0
        && ghostLlTotalSupplyAssets128 == ghostLlTotalBorrowAssets128,
        "a withdraw may take the market's free liquidity down to exactly zero");
}

// LL-RC-27: A settlement can burn the entire supply position it is charged against.
rule rcLlSettleBurnsWholeSupplyPositionIsReachable(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf, address borrower,
    address receiver
) {

    setupLidoLendValidState(e);
    require(onBehalf != ghostLlFeeRecipient,
        "SCOPE: a plain lender, not the fee sink");
    mathint supplyBefore = ghostLlSupplyShares256[onBehalf];
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    satisfy(supplyBefore > 0 && to_mathint(supplySharesBurned) == supplyBefore
        && ghostLlSupplyShares256[onBehalf] == 0,
        "a settlement may take the lender's whole supply position");
}

// LL-RC-28: A settlement can cancel one unit more debt than the market's books record.
rule rcLlSettleDebtFloorAbsorbsAWeiIsReachable(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf, address borrower,
    address receiver
) {

    setupLidoLendValidState(e);
    require(to_mathint(e.block.timestamp) == ghostLlLastUpdate128,
        "SCOPE: no elapsed time since the last accrual");
    mathint borrowAssetsBefore = ghostLlTotalBorrowAssets128;
    uint256 seizedAssets;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 supplySharesBurned;

    (seizedAssets, borrowAssetsCanceled, borrowSharesCanceled, supplySharesBurned)
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    satisfy(to_mathint(borrowAssetsCanceled) == borrowAssetsBefore + 1
        && ghostLlTotalBorrowAssets128 == 0,
        "the cancellation may outrun the debt total by the wei the floor absorbs");
}

// LL-RE-04: A flash loan can still complete while one of the controller hooks is running.
rule reLlFlashLoanRunsWhileHookInProgress(
    env e, address token, uint256 assets, bytes data
) {

    setupLidoLendValidState(e);
    require(_Core._hookInProgress,
        "SCOPE: a controller hook is in flight");

    flashLoan(e, token, assets, data);

    satisfy(assets != 0, "flashLoan dispatches no hook and completes while a hook is in flight");
}
