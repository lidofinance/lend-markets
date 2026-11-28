// Adaptive curve math models: the intractable ExpLib.wExp and the generic UtilsLib.bound. Both are bound
// exactly, so a missing target fails the build instead of leaving the summary silently unattached.

import "irmWadMath.spec";

methods {
    function ExpLib.wExp(int256 x) internal returns (int256) => wExpCVL(x);
    function UtilsLib.bound(int256 x, int256 low, int256 high) internal returns (int256)
        => boundCVL(x, low, high);
}

// Byte exact ExpLib clip constants.
definition LN_WEI_INT_CVL() returns mathint = -41446531673892822312;
definition WEXP_UPPER_BOUND_CVL() returns mathint = 93859467695000404319;
definition WEXP_UPPER_VALUE_CVL() returns mathint =
    57716089161558943949701069502944508345128422502756744429568;

// wExp is pure, so a ghost keyed on x is faithful; monotonicity is a grounding hazard, pinned per rule instead.
persistent ghost wExpGhostFn(mathint) returns mathint {
    // SAFE: ExpLib clips wExp into [0, WEXP_UPPER_VALUE].
    axiom forall mathint x.
        wExpGhostFn(x) >= 0 && wExpGhostFn(x) <= WEXP_UPPER_VALUE_CVL();
    // PROVED: ExpLib returns WAD at x = 0.
    axiom wExpGhostFn(0) == WAD_MATH();
}

function wExpCVL(int256 x) returns int256 {
    mathint xm = to_mathint(x);
    if (xm < LN_WEI_INT_CVL()) {
        return 0;
    }
    if (xm >= WEXP_UPPER_BOUND_CVL()) {
        return require_int256(WEXP_UPPER_VALUE_CVL());
    }
    return require_int256(wExpGhostFn(xm));
}

// The assembly clamp max(min(x, high), low), including the low > high case the library returns low for.
function boundCVL(int256 x, int256 low, int256 high) returns int256 {
    mathint xm = to_mathint(x);
    mathint lowm = to_mathint(low);
    mathint highm = to_mathint(high);
    mathint capped = xm < highm ? xm : highm;
    mathint bounded = capped > lowm ? capped : lowm;
    return require_int256(bounded);
}
