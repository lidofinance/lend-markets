// LidoLend unit tests: each rule pins one named call's exact storage effect, or exact non-effect,
// against the mirrored state.

import "LidoLend_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// LL-UT-01: A transfer of ownership installs exactly the named new owner.
rule utLlSetOwnerSetsNewOwner(env e, address newOwner) {
    setupLidoLendValidState(e);

    setOwner(e, newOwner);

    assert(ghostLlOwner == newOwner, "setOwner installs the new owner");
}

// LL-UT-02: The owner installs exactly the named account as the fee recipient.
rule utLlSetFeeRecipientSetsNewRecipient(env e, address newFeeRecipient) {
    setupLidoLendValidState(e);

    setFeeRecipient(e, newFeeRecipient);

    assert(ghostLlFeeRecipient == newFeeRecipient, "setFeeRecipient installs the new recipient");
}

// LL-UT-03: The owner sets a market's fee to exactly the requested value.
rule utLlSetFeeSetsNewFee(env e, LidoLend.MarketParams mp, uint256 newFee) {
    setupLidoLendValidState(e);

    setFee(e, mp, newFee);

    assert(ghostLlFee128 == newFee, "setFee lands the requested fee");
}

// LL-UT-04: The caller's authorization change records exactly the requested permission for the named account.
rule utLlSetAuthorizationSetsFlag(env e, address authorized, bool newIsAuthorized) {
    setupLidoLendValidState(e);

    setAuthorization(e, authorized, newIsAuthorized);

    assert(ghostLlIsAuthorized[e.msg.sender][authorized] == newIsAuthorized,
        "the caller's row carries the requested flag");
}

// LL-UT-05: A collateral deposit credits the beneficiary with exactly the assets supplied.
rule utLlSupplyCollateralCreditsExactCollateral(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    mathint before = ghostLlCollateral128[onBehalf];

    supplyCollateral(e, mp, assets, onBehalf, data);

    assert(ghostLlCollateral128[onBehalf] == before + assets,
        "collateral grows by exactly the deposited assets");
}

// LL-UT-06: A collateral withdrawal debits the position by exactly the assets requested.
rule utLlWithdrawCollateralDebitsExactCollateral(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    mathint before = ghostLlCollateral128[onBehalf];

    withdrawCollateral(e, mp, assets, onBehalf, receiver);

    assert(ghostLlCollateral128[onBehalf] == before - assets,
        "collateral shrinks by exactly the requested assets");
}

// LL-UT-07: Liquidation never increases the borrower's debt, whoever calls it.
rule utLlLiquidateNeverGrowsBorrowerDebt(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares,
    bytes data
) {
    setupLidoLendValidState(e);
    mathint before = ghostLlBorrowShares128[borrower];

    liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    assert(ghostLlBorrowShares128[borrower] <= before, "debt shares never grow under liquidation");
}

// LL-UT-08: A transfer of ownership leaves the fee recipient unchanged.
rule utLlSetOwnerLeavesFeeRecipient(env e, address newOwner) {
    setupLidoLendValidState(e);
    address before = ghostLlFeeRecipient;

    setOwner(e, newOwner);

    assert(ghostLlFeeRecipient == before, "the fee recipient survives an ownership transfer");
}

// LL-UT-09: Changing the fee recipient leaves the owner unchanged.
rule utLlSetFeeRecipientLeavesOwner(env e, address newFeeRecipient) {
    setupLidoLendValidState(e);
    address before = ghostLlOwner;

    setFeeRecipient(e, newFeeRecipient);

    assert(ghostLlOwner == before, "the owner survives a fee-recipient change");
}

// LL-UT-10: An authorization change leaves every other permission unchanged.
rule utLlSetAuthorizationLeavesOtherRows(
    env e, address authorized, bool newIsAuthorized, address otherOwner, address otherAuth
) {
    setupLidoLendValidState(e);
    bool before = ghostLlIsAuthorized[otherOwner][otherAuth];

    setAuthorization(e, authorized, newIsAuthorized);

    assert((otherOwner != e.msg.sender || otherAuth != authorized)
        => ghostLlIsAuthorized[otherOwner][otherAuth] == before,
        "only the caller's row for the grantee may change");
}

// LL-UT-11: A supply grows both supply totals by exactly the shares and assets it reports.
rule utLlSupplyGrowsTotalsExactly(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    require(e.block.timestamp == ghostLlLastUpdate128,
        "SCOPE: interest already up to date");
    mathint tssBefore = ghostLlTotalSupplyShares128;
    mathint tsaBefore = ghostLlTotalSupplyAssets128;

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = supply(e, mp, assets, shares, onBehalf, data);

    assert(ghostLlTotalSupplyShares128 == tssBefore + retShares,
        "supply shares total grows by exactly the returned shares");
    assert(ghostLlTotalSupplyAssets128 == tsaBefore + retAssets,
        "supply assets total grows by exactly the credited assets");
}

// LL-UT-12: A withdrawal shrinks both supply totals by exactly the shares and assets it reports.
rule utLlWithdrawShrinksTotalsExactly(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(e.block.timestamp == ghostLlLastUpdate128,
        "SCOPE: interest already up to date");
    mathint tssBefore = ghostLlTotalSupplyShares128;
    mathint tsaBefore = ghostLlTotalSupplyAssets128;

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostLlTotalSupplyShares128 == tssBefore - retShares,
        "supply shares total shrinks by exactly the returned shares");
    assert(ghostLlTotalSupplyAssets128 == tsaBefore - retAssets,
        "supply assets total shrinks by exactly the returned assets");
}

// LL-UT-13: A borrow grows both debt totals by exactly the shares and assets it reports.
rule utLlBorrowGrowsDebtTotalsExactly(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(e.block.timestamp == ghostLlLastUpdate128,
        "SCOPE: interest already up to date");
    mathint tbsBefore = ghostLlTotalBorrowShares128;
    mathint tbaBefore = ghostLlTotalBorrowAssets128;

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = borrow(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostLlTotalBorrowShares128 == tbsBefore + retShares,
        "borrow shares total grows by exactly the returned shares");
    assert(ghostLlTotalBorrowAssets128 == tbaBefore + retAssets,
        "borrow assets total grows by exactly the returned assets");
}

// LL-UT-14: Repayment cuts the borrower's and the market's debt by exactly the amounts it reports.
rule utLlRepayShrinksDebtTotalsExactly(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    require(e.block.timestamp == ghostLlLastUpdate128,
        "SCOPE: interest already up to date");
    mathint bsBefore = ghostLlBorrowShares128[onBehalf];
    mathint tbsBefore = ghostLlTotalBorrowShares128;
    mathint tbaBefore = ghostLlTotalBorrowAssets128;

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = repay(e, mp, assets, shares, onBehalf, data);

    assert(ghostLlBorrowShares128[onBehalf] == bsBefore - retShares,
        "borrower debt shares shrink by exactly the returned shares");
    assert(ghostLlTotalBorrowShares128 == tbsBefore - retShares,
        "borrow shares total shrinks by exactly the returned shares");
    assert(ghostLlTotalBorrowAssets128 == (tbaBefore >= retAssets ? tbaBefore - retAssets : 0),
        "borrow assets total shrinks by the returned assets, floored at zero");
}

// The exact-token-delta family: each call moves precisely the amount it reports.

// LL-UT-15: A withdrawal pays the receiver exactly the amount it reports, in full when an amount is requested.
rule utLlWithdrawMovesExactTokens(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(receiver != _Core,
        "SCOPE: the receiver is not the pool");
    mathint poolBefore = ghostERC20Balances128[mp.loanToken][_Core];
    mathint receiverBefore = ghostERC20Balances128[mp.loanToken][receiver];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = withdraw(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostERC20Balances128[mp.loanToken][receiver] == receiverBefore + retAssets,
        "the receiver is paid exactly the withdrawn assets");
    assert(ghostERC20Balances128[mp.loanToken][_Core] == poolBefore - retAssets,
        "the pool pays out exactly the withdrawn assets");
    assert(assets != 0 => retAssets == assets,
        "an assets-denominated withdrawal returns the requested assets");
}

// LL-UT-16: A borrow hands the receiver exactly the amount it reports, in full when an amount is requested.
rule utLlBorrowMovesExactTokens(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(receiver != _Core,
        "SCOPE: the receiver is not the pool");
    mathint poolBefore = ghostERC20Balances128[mp.loanToken][_Core];
    mathint receiverBefore = ghostERC20Balances128[mp.loanToken][receiver];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = borrow(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostERC20Balances128[mp.loanToken][receiver] == receiverBefore + retAssets,
        "the receiver gets exactly the borrowed assets");
    assert(ghostERC20Balances128[mp.loanToken][_Core] == poolBefore - retAssets,
        "the pool lends out exactly the borrowed assets");
    assert(assets != 0 => retAssets == assets,
        "an assets-denominated borrow returns the requested assets");
}

// LL-UT-17: Repayment pulls exactly the amount it reports from the caller, in full when an amount is requested.
rule utLlRepayMovesExactTokens(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    mathint poolBefore = ghostERC20Balances128[mp.loanToken][_Core];
    mathint payerBefore = ghostERC20Balances128[mp.loanToken][e.msg.sender];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = repay(e, mp, assets, shares, onBehalf, data);

    assert(ghostERC20Balances128[mp.loanToken][_Core] == poolBefore + retAssets,
        "the pool receives exactly the repaid assets");
    assert(ghostERC20Balances128[mp.loanToken][e.msg.sender] == payerBefore - retAssets,
        "the payer parts with exactly the repaid assets");
    assert(assets != 0 => retAssets == assets,
        "an assets-denominated repayment charges the requested assets");
}

// LL-UT-18: A collateral deposit pulls exactly the deposited collateral from the caller into the pool.
rule utLlSupplyCollateralMovesExactTokens(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    mathint poolBefore = ghostERC20Balances128[mp.collateralToken][_Core];
    mathint payerBefore = ghostERC20Balances128[mp.collateralToken][e.msg.sender];

    supplyCollateral(e, mp, assets, onBehalf, data);

    assert(ghostERC20Balances128[mp.collateralToken][_Core] == poolBefore + assets,
        "the pool receives exactly the deposited collateral");
    assert(ghostERC20Balances128[mp.collateralToken][e.msg.sender] == payerBefore - assets,
        "the payer parts with exactly the deposited collateral");
}

// LL-UT-19: A collateral withdrawal pays the receiver exactly the requested collateral out of the pool.
rule utLlWithdrawCollateralMovesExactTokens(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    require(receiver != _Core,
        "SCOPE: the receiver is not the pool");
    mathint poolBefore = ghostERC20Balances128[mp.collateralToken][_Core];
    mathint receiverBefore = ghostERC20Balances128[mp.collateralToken][receiver];

    withdrawCollateral(e, mp, assets, onBehalf, receiver);

    assert(ghostERC20Balances128[mp.collateralToken][receiver] == receiverBefore + assets,
        "the receiver is paid exactly the requested collateral");
    assert(ghostERC20Balances128[mp.collateralToken][_Core] == poolBefore - assets,
        "the pool pays out exactly the requested collateral");
}

// LL-UT-20: Liquidation takes in exactly the repaid loan tokens and hands out exactly the seized collateral.
rule utLlLiquidateMovesExactTokens(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares,
    bytes data
) {
    setupLidoLendValidState(e);
    require(mp.loanToken != mp.collateralToken,
        "SCOPE: the loan and collateral tokens differ");
    mathint poolLoanBefore = ghostERC20Balances128[mp.loanToken][_Core];
    mathint poolCollateralBefore = ghostERC20Balances128[mp.collateralToken][_Core];
    mathint liquidatorLoanBefore = ghostERC20Balances128[mp.loanToken][e.msg.sender];
    mathint liquidatorCollateralBefore = ghostERC20Balances128[mp.collateralToken][e.msg.sender];

    uint256 retSeized; uint256 retRepaid;
    retSeized, retRepaid = liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    assert(ghostERC20Balances128[mp.loanToken][_Core] == poolLoanBefore + retRepaid
        && ghostERC20Balances128[mp.loanToken][e.msg.sender] == liquidatorLoanBefore - retRepaid,
        "the liquidator pays exactly the repaid assets into the pool");
    assert(ghostERC20Balances128[mp.collateralToken][_Core] == poolCollateralBefore - retSeized
        && ghostERC20Balances128[mp.collateralToken][e.msg.sender]
            == liquidatorCollateralBefore + retSeized,
        "the liquidator takes exactly the seized collateral out of the pool");
    assert(seizedAssets != 0 => retSeized == seizedAssets,
        "a seizure-denominated liquidation seizes the requested collateral");
}

// LL-UT-21: Settlement pays the receiver exactly the seized collateral and moves no loan tokens.
rule utLlSettleMovesExactTokens(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf,
    address borrower, address receiver
) {
    setupLidoLendValidState(e);
    require(receiver != _Core,
        "SCOPE: the receiver is not the pool");
    require(mp.loanToken != mp.collateralToken,
        "SCOPE: the loan and collateral tokens differ");
    mathint poolCollateralBefore = ghostERC20Balances128[mp.collateralToken][_Core];
    mathint receiverBefore = ghostERC20Balances128[mp.collateralToken][receiver];
    mathint poolLoanBefore = ghostERC20Balances128[mp.loanToken][_Core];

    uint256 retSeized; uint256 retAssetsCanceled; uint256 retSharesCanceled; uint256 retBurned;
    retSeized, retAssetsCanceled, retSharesCanceled, retBurned
        = settle(e, mp, borrowShares, onBehalf, borrower, receiver);

    assert(ghostERC20Balances128[mp.collateralToken][receiver] == receiverBefore + retSeized,
        "the receiver is paid exactly the seized collateral");
    assert(ghostERC20Balances128[mp.collateralToken][_Core] == poolCollateralBefore - retSeized,
        "the pool pays out exactly the seized collateral");
    assert(ghostERC20Balances128[mp.loanToken][_Core] == poolLoanBefore,
        "settle moves no loan token");
}

// LL-UT-22: A market with no rate model earns no interest, though accruing still updates its clock.
rule utLlAccrueIdleMarketMovesOnlyClock(env e, LidoLend.MarketParams mp) {
    setupLidoLendValidState(e);
    require(ghostLlIrm == 0, "SCOPE: a market created without an interest model");
    mathint supplyAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint supplySharesBefore = ghostLlTotalSupplyShares128;
    mathint borrowAssetsBefore = ghostLlTotalBorrowAssets128;
    mathint borrowSharesBefore = ghostLlTotalBorrowShares128;
    mathint feeSinkBefore = ghostLlSupplyShares256[ghostLlFeeRecipient];

    accrueInterest(e, mp);

    assert(ghostLlTotalSupplyAssets128 == supplyAssetsBefore
        && ghostLlTotalSupplyShares128 == supplySharesBefore
        && ghostLlTotalBorrowAssets128 == borrowAssetsBefore
        && ghostLlTotalBorrowShares128 == borrowSharesBefore
        && ghostLlSupplyShares256[ghostLlFeeRecipient] == feeSinkBefore,
        "a market without an interest model accrues nothing");
    assert(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "the accrual clock lands on the current block");
}

// LL-UT-23: With nothing borrowed, accruing interest changes no total and mints no fee shares.
rule utLlAccrueZeroDebtLeavesTotals(env e, LidoLend.MarketParams mp) {
    setupLidoLendValidState(e);
    require(ghostLlTotalBorrowAssets128 == 0, "SCOPE: no outstanding debt to charge interest on");
    mathint supplyAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint supplySharesBefore = ghostLlTotalSupplyShares128;
    mathint borrowSharesBefore = ghostLlTotalBorrowShares128;
    mathint feeSinkBefore = ghostLlSupplyShares256[ghostLlFeeRecipient];

    accrueInterest(e, mp);

    assert(ghostLlTotalSupplyAssets128 == supplyAssetsBefore
        && ghostLlTotalSupplyShares128 == supplySharesBefore
        && ghostLlTotalBorrowAssets128 == 0
        && ghostLlTotalBorrowShares128 == borrowSharesBefore
        && ghostLlSupplyShares256[ghostLlFeeRecipient] == feeSinkBefore,
        "an idle loan book earns nothing to distribute");
}
