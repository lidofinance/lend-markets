// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external method call.
// Once proven, other spec files assume them via setupLidoLendERC4626ValidState, which narrows the Prover's arbitrary
// storage havoc down to reachable states and so cuts down on the false counterexamples those files hit.

import "../setup/LidoLendERC4626/LidoLendERC4626.spec";

function requireLidoLendERC4626Invariants(env e) {
    requireInvariant assetIsLoanToken(e);
    requireInvariant marketIdCanonical(e);
    requireInvariant offsetBounded(e);
}

function SETUP_VA(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupLidoLendERC4626(e);
}

// VA-VS-01: The vault's asset is always the loan token of its market.
invariant assetIsLoanToken(env e)
    ghostVaAsset == ghostVaParamsLoanToken
filtered { f -> !EXCLUDED_FUNCTION_VA(f) } { preserved with (env eFunc) { SETUP_VA(e, eFunc); } }

// VA-VS-02: The vault's market id always matches the market parameters it stores.
invariant marketIdCanonical(env e)
    ghostVaController != 0 => ghostVaMarketId == marketParamsIdCVL(
        ghostVaParamsLoanToken, ghostVaParamsCollateralToken, ghostVaParamsOracle,
        ghostVaParamsIrm, require_uint256(ghostVaParamsLltv256))
filtered { f -> !EXCLUDED_FUNCTION_VA(f) } { preserved with (env eFunc) { SETUP_VA(e, eFunc); } }

// VA-VS-03: The vault's virtual share offset never exceeds eighteen decimals.
invariant offsetBounded(env e)
    ghostVaLoanDecimalsOffset8 <= SHARE_DECIMALS_VA_CVL()
filtered { f -> !EXCLUDED_FUNCTION_VA(f) } { preserved with (env eFunc) { SETUP_VA(e, eFunc); } }
