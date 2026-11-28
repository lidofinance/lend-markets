// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external method call.
// Once proven, other spec files assume them via setupLidoLendValidState, which narrows the Prover's arbitrary
// storage havoc down to reachable states and so cuts down on the false counterexamples those files hit.

import "../setup/LidoLend/LidoLend.spec";

function requireLidoLendInvariants(env e) {
    requireInvariant feeCapped(e);
    requireInvariant lastUpdateNotInFuture(e);
    requireInvariant lastUpdateMinBound(e);
    requireInvariant borrowLeSupplyAssets(e);
    requireInvariant supplySharesSumCorrect(e);
    requireInvariant borrowSharesSumCorrect(e);
    requireInvariant borrowerCollateralizedUnlessSettlement(e);
    requireInvariant zeroAddressNeverAuthorizes(e);
    requireInvariant tokenBackingSolvency(e);
}

function setupLidoLendValidState(env e) {
    setupLidoLend(e);
    requireLidoLendInvariants(e);
}

function SETUP_LL(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupLidoLend(e);
}

// LL-VS-01: A market's fee on accrued interest can never exceed the protocol's 25 percent cap.
invariant feeCapped(env e)
    ghostLlFee128 <= MAX_FEE_LL_CVL()
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) { SETUP_LL(e, eFunc); } }

// LL-VS-02: A market's interest clock never runs ahead of the current block time.
invariant lastUpdateNotInFuture(env e)
    ghostLlLastUpdate128 <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) { SETUP_LL(e, eFunc); } }

// LL-VS-03: A live market's interest clock always holds a plausible block time, never a near zero value.
invariant lastUpdateMinBound(env e)
    ghostLlLastUpdate128 != 0 => ghostLlLastUpdate128 >= MIN_BLOCK_TIMESTAMP()
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) { SETUP_LL(e, eFunc); } }

// LL-VS-04: A market never has more assets borrowed than supplied, so utilization stays at or below 100 percent.
invariant borrowLeSupplyAssets(env e)
    ghostLlTotalBorrowAssets128 <= ghostLlTotalSupplyAssets128
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) { SETUP_LL(e, eFunc); } }

// LL-VS-05: A market's total supply shares always equal the sum of the lenders' shares.
invariant supplySharesSumCorrect(env e)
    ghostLlTotalSupplyShares128 == LL_SUPPLY_SHARES_SUM()
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) {
    SETUP_LL(e, eFunc);
} }

// LL-VS-06: A market's total borrow shares always equal the sum of the borrowers' shares.
invariant borrowSharesSumCorrect(env e)
    ghostLlTotalBorrowShares128 == LL_BORROW_SHARES_SUM()
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) {
    SETUP_LL(e, eFunc);
} }

// LL-VS-07: In a market without settlement, any borrower carrying debt still holds collateral.
invariant borrowerCollateralizedUnlessSettlement(env e)
    forall address u.
        (!ghostLlIsSettlementEnabled && ghostLlBorrowShares128[u] != 0)
            => ghostLlCollateral128[u] != 0
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) {
    SETUP_LL(e, eFunc);
} }

// LL-VS-08: Nobody is ever authorized to act on behalf of the zero address.
invariant zeroAddressNeverAuthorizes(env e)
    forall address a. !ghostLlIsAuthorized[0][a]
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) { SETUP_LL(e, eFunc); } }

// LL-VS-09: The pool always holds enough loan and collateral tokens to cover idle liquidity and the collateral entrusted to it.
invariant tokenBackingSolvency(env e)
    ghostERC20Balances128[ghostLlLoanToken][_Core] >= LL_TOKEN_BACKING(ghostLlLoanToken)
    && ghostERC20Balances128[ghostLlCollateralToken][_Core]
        >= LL_TOKEN_BACKING(ghostLlCollateralToken)
filtered { f -> !EXCLUDED_FUNCTION_LL(f) } { preserved with (env eFunc) { SETUP_LL(e, eFunc); } }
