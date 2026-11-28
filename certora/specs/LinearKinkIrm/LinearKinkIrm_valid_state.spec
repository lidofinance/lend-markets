// Five inductive invariants: the kink below full utilization, the peak rate within the cap, no rate
// parameters on an unset row, live owner and manager seats, and an empty zero id row. The IRM checks no band
// itself; it copies whatever the supplied config reports.

import "../setup/Irm/LinearKinkIrm/LinearKinkIrm.spec";

function requireLinearKinkIrmInvariants(env e) {
    requireInvariant vsLkiKinkBelowFullUtilization(e);
    requireInvariant vsLkiPeakRateWithinCap(e);
    requireInvariant vsLkiUnsetRowCarriesNoParams(e);
    requireInvariant vsLkiRolesAreLive(e);
    requireInvariant vsLkiZeroIdRowStaysEmpty(e);
}

function setupLinearKinkIrmValidState(env e) {
    setupLinearKinkIrm(e);
    requireLinearKinkIrmInvariants(e);
}

function SETUP_LKI(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupLinearKinkIrm(e);
}

function SETUP_FULL_LKI(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupLinearKinkIrmValidState(e);
}

// LKI-VS-01: A market's kink always sits strictly below full utilization.
invariant vsLkiKinkBelowFullUtilization(env e)
    forall LinearKinkIrm.Id id. ghostLkiOptimalUtilization64[id] < WAD_MATH()
filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } { preserved with (env eFunc) { SETUP_LKI(e, eFunc); } }

// LKI-VS-02: A market's peak rate, charged at full utilization, never exceeds 800 percent per year.
invariant vsLkiPeakRateWithinCap(env e)
    forall LinearKinkIrm.Id id.
        ghostLkiBaseRate64[id] + ghostLkiSlope1_64[id] + ghostLkiSlope2_64[id]
            <= MAX_BORROW_RATE_LKI_CVL()
filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } { preserved with (env eFunc) { SETUP_LKI(e, eFunc); } }

// LKI-VS-03: A market with no curve set carries no rate parameters at all.
invariant vsLkiUnsetRowCarriesNoParams(env e)
    forall LinearKinkIrm.Id id. ghostLkiOptimalUtilization64[id] == 0 => (
        ghostLkiBaseRate64[id] == 0
        && ghostLkiSlope1_64[id] == 0
        && ghostLkiSlope2_64[id] == 0)
filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } { preserved with (env eFunc) { SETUP_LKI(e, eFunc); } }

// LKI-VS-04: The rate model always has a live owner and a live manager.
invariant vsLkiRolesAreLive(env e)
    ghostLkiOwner != 0 && ghostLkiManager != 0
filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } { preserved with (env eFunc) { SETUP_LKI(e, eFunc); } }

// LKI-VS-05: The zero market id never carries curve parameters.
invariant vsLkiZeroIdRowStaysEmpty(env e)
    forall LinearKinkIrm.Id id. id == to_bytes32(0) => (
        ghostLkiOptimalUtilization64[id] == 0
        && ghostLkiBaseRate64[id] == 0
        && ghostLkiSlope1_64[id] == 0
        && ghostLkiSlope2_64[id] == 0)
filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } { preserved with (env eFunc) { SETUP_LKI(e, eFunc); } }
