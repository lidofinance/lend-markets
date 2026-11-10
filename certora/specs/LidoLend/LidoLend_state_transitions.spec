// Each rule ties the storage variables that move together in any single call: snapshot them, invoke any
// external method, assert the co-change law (paired writes, latch coupling, lifecycle steps).

import "LidoLend_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// LL-ST-01: Total debt grows only in a call that leaves interest up to date.
rule stLlBorrowGrowthIsFresh(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);
    mathint tbaBefore = ghostLlTotalBorrowAssets128;

    f(e, args);

    assert(ghostLlTotalBorrowAssets128 > tbaBefore
        => ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "borrow assets grow only with fresh accrual");
}

// LL-ST-02: A borrower's debt grows only while that same position holds collateral.
rule stLlNewDebtNeedsCollateral(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);
    mathint bsBefore = ghostLlBorrowShares128[u];

    f(e, args);

    assert(ghostLlBorrowShares128[u] > bsBefore => ghostLlCollateral128[u] != 0,
        "borrow shares grow only against collateral");
}

// LL-ST-03: A market's fee changes only in a call that leaves interest up to date.
rule stLlFeeChangeIsFresh(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);
    mathint feeBefore = ghostLlFee128;

    f(e, args);

    assert(ghostLlFee128 != feeBefore
        => ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "setFee accrues before changing the fee");
}

// LL-ST-04: The supply pool shrinks only when supply shares are burned or debt is written off.
rule stLlSupplyShrinkIsAccounted(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);
    mathint tsaBefore = ghostLlTotalSupplyAssets128;
    mathint tssBefore = ghostLlTotalSupplyShares128;
    mathint tbaBefore = ghostLlTotalBorrowAssets128;

    f(e, args);

    assert(ghostLlTotalSupplyAssets128 < tsaBefore
        => (ghostLlTotalSupplyShares128 < tssBefore
            || ghostLlTotalBorrowAssets128 < tbaBefore),
        "a supply drain burns shares or cancels debt");
}

// LL-ST-05: Minting supply shares always adds assets to the supply pool.
rule stLlSupplyShareMintAddsAssets(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);
    mathint luBefore = ghostLlLastUpdate128;

    require(to_mathint(e.block.timestamp) == luBefore,
        "SCOPE: interest already up to date");

    mathint tssBefore = ghostLlTotalSupplyShares128;
    mathint tsaBefore = ghostLlTotalSupplyAssets128;

    f(e, args);

    assert(ghostLlTotalSupplyShares128 > tssBefore => ghostLlTotalSupplyAssets128 > tsaBefore,
        "a supply share mint deposits assets");
}

// LL-ST-06: Burning supply shares never adds assets to the supply pool.
rule stLlSupplyShareBurnRemovesAssets(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);
    mathint luBefore = ghostLlLastUpdate128;

    require(to_mathint(e.block.timestamp) == luBefore,
        "SCOPE: interest already up to date");

    mathint tssBefore = ghostLlTotalSupplyShares128;
    mathint tsaBefore = ghostLlTotalSupplyAssets128;

    f(e, args);

    assert(ghostLlTotalSupplyShares128 < tssBefore => ghostLlTotalSupplyAssets128 <= tsaBefore,
        "a supply share burn never adds assets");
}

// LL-ST-07: Minting debt shares never cancels part of the market's outstanding debt.
rule stLlBorrowShareMintAddsDebt(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);
    mathint luBefore = ghostLlLastUpdate128;

    require(to_mathint(e.block.timestamp) == luBefore,
        "SCOPE: interest already up to date");

    mathint tbsBefore = ghostLlTotalBorrowShares128;
    mathint tbaBefore = ghostLlTotalBorrowAssets128;

    f(e, args);

    assert(ghostLlTotalBorrowShares128 > tbsBefore => ghostLlTotalBorrowAssets128 >= tbaBefore,
        "a borrow share mint never cancels debt");
}

// LL-ST-08: Accruing interest credits suppliers at least as much as the outstanding debt grows.
rule stLlAccrualFavorsSuppliers(env e, method f, calldataarg args)
    filtered {
        f -> !EXCLUDED_FUNCTION_LL(f)
            && f.selector == sig:accrueInterest(LidoLend.MarketParams).selector
    } {

    setupLidoLendValidState(e);

    mathint luBefore = ghostLlLastUpdate128;
    mathint tbaBefore = ghostLlTotalBorrowAssets128;
    mathint tbsBefore = ghostLlTotalBorrowShares128;
    mathint tsaBefore = ghostLlTotalSupplyAssets128;

    f(e, args);

    // Only accrueInterest runs here: other entrypoints add accounting deltas of their own.
    bool pureInterest = ghostLlTotalBorrowAssets128 > tbaBefore
        && ghostLlTotalBorrowShares128 == tbsBefore
        && luBefore != 0;

    assert(pureInterest
        => ghostLlTotalSupplyAssets128 - tsaBefore >= ghostLlTotalBorrowAssets128 - tbaBefore,
        "accrued interest credits suppliers at least the debt growth");
}

// LL-ST-09: Once time has passed, any move in the market totals restamps the interest clock.
rule stLlAccountingRefreshesClock(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);

    mathint luBefore = ghostLlLastUpdate128;
    mathint tsaBefore = ghostLlTotalSupplyAssets128;
    mathint tssBefore = ghostLlTotalSupplyShares128;
    mathint tbaBefore = ghostLlTotalBorrowAssets128;
    mathint tbsBefore = ghostLlTotalBorrowShares128;

    f(e, args);

    bool accountingChanged = ghostLlTotalSupplyAssets128 != tsaBefore
        || ghostLlTotalSupplyShares128 != tssBefore
        || ghostLlTotalBorrowAssets128 != tbaBefore
        || ghostLlTotalBorrowShares128 != tbsBefore;

    assert(accountingChanged && to_mathint(e.block.timestamp) > luBefore
        => ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "totals move only once the clock is restamped to now");
}

// LL-ST-10: A supply that mints shares always brings loan tokens into the pool.
rule stLlSupplyShareMintIsFunded(
    env e, LidoLend.MarketParams marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);

    require(to_mathint(e.block.timestamp) == ghostLlLastUpdate128,
        "SCOPE: interest already up to date");

    address loanToken = ghostLlLoanToken;

    mathint tssBefore = ghostLlTotalSupplyShares128;
    mathint balanceBefore = ghostERC20Balances128[loanToken][currentContract];

    supply(e, marketParams, assets, shares, onBehalf, data);

    assert(ghostLlTotalSupplyShares128 > tssBefore
        => ghostERC20Balances128[loanToken][currentContract] > balanceBefore,
        "a supply share mint pulls loan tokens into the pool");
}

// LL-ST-11: Crediting shares to a supplier always grows the market's total supply shares.
rule stLlUserSupplyMintGrowsTotal(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);

    mathint luBefore = ghostLlLastUpdate128;
    require(to_mathint(e.block.timestamp) == luBefore,
        "SCOPE: interest already up to date");

    mathint userBefore = ghostLlSupplyShares256[u];
    mathint totalBefore = ghostLlTotalSupplyShares128;

    f(e, args);

    assert(ghostLlSupplyShares256[u] > userBefore => ghostLlTotalSupplyShares128 > totalBefore,
        "a position's supply-share credit grows the total");
}

// LL-ST-12: Burning a supplier's shares always shrinks the market's total supply shares.
rule stLlUserSupplyBurnShrinksTotal(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);

    mathint luBefore = ghostLlLastUpdate128;
    require(to_mathint(e.block.timestamp) == luBefore,
        "SCOPE: interest already up to date");

    mathint userBefore = ghostLlSupplyShares256[u];
    mathint totalBefore = ghostLlTotalSupplyShares128;

    f(e, args);

    assert(ghostLlSupplyShares256[u] < userBefore => ghostLlTotalSupplyShares128 < totalBefore,
        "a position's supply-share burn shrinks the total");
}

// LL-ST-13: Crediting debt shares to a borrower always grows the market's total debt shares.
rule stLlUserDebtMintGrowsTotal(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);

    mathint userBefore = ghostLlBorrowShares128[u];
    mathint totalBefore = ghostLlTotalBorrowShares128;

    f(e, args);

    assert(ghostLlBorrowShares128[u] > userBefore => ghostLlTotalBorrowShares128 > totalBefore,
        "a position's debt-share credit grows the total");
}

// LL-ST-14: Burning a borrower's debt shares always shrinks the market's total debt shares.
rule stLlUserDebtBurnShrinksTotal(env e, method f, calldataarg args, address u)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);

    mathint userBefore = ghostLlBorrowShares128[u];
    mathint totalBefore = ghostLlTotalBorrowShares128;

    f(e, args);

    assert(ghostLlBorrowShares128[u] < userBefore => ghostLlTotalBorrowShares128 < totalBefore,
        "a position's debt-share burn shrinks the total");
}
