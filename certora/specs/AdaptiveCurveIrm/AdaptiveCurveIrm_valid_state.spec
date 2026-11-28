// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external method call.
// Once proven, other spec files assume them via setupAdaptiveCurveIrmValidState, which narrows the Prover's
// arbitrary storage havoc down to reachable states.

import "../setup/Irm/AdaptiveCurveIrm/AdaptiveCurveIrm.spec";

function requireAdaptiveCurveIrmInvariants(env e) {
    require(forall AdaptiveCurveIrm.Id id.
        ghostAciRateAtTarget[id] >= 0
        && ghostAciRateAtTarget[id] <= MAX_RATE_AT_TARGET_LIMIT_CVL(),
        "PROVED: every rate at target sits between zero and the shared ceiling");
    requireInvariant vsAciRateWithinItsConfigBand(e);
    requireInvariant vsAciPricedMarketHasConfig(e);
    requireInvariant vsAciRolesNeverZero(e);
    requireInvariant vsAciZeroIdNeverConfigured(e);
}

function setupAdaptiveCurveIrmValidState(env e) {
    setupAdaptiveCurveIrm(e);
    requireAdaptiveCurveIrmInvariants(e);
}

function SETUP_ACI(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupAdaptiveCurveIrm(e);
}

function SETUP_FULL_ACI(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupAdaptiveCurveIrm(e);
    requireAdaptiveCurveIrmInvariants(e);
}

// ACI-VS-01: A priced market's rate always sits inside the bounds of the config it points at.
invariant vsAciRateWithinItsConfigBand(env e)
    forall AdaptiveCurveIrm.Id id.
        ghostAciRateAtTarget[id] == 0
        || (ghostAciRateAtTarget[id] >= ghostAciCfgMinRateAtTarget[ghostAciMarketCurveConfig[id]]
            && ghostAciRateAtTarget[id] <= ghostAciCfgMaxRateAtTarget[ghostAciMarketCurveConfig[id]])
filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } { preserved with (env eFunc) { SETUP_ACI(e, eFunc); } }

// ACI-VS-02: A market that carries a rate always has a config attached.
invariant vsAciPricedMarketHasConfig(env e)
    forall AdaptiveCurveIrm.Id id.
        ghostAciRateAtTarget[id] != 0 => ghostAciMarketCurveConfig[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } { preserved with (env eFunc) { SETUP_ACI(e, eFunc); } }

// ACI-VS-03: The rate model always has a live owner and a live manager.
invariant vsAciRolesNeverZero(env e)
    ghostAciOwner != 0 && ghostAciManager != 0
filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } { preserved with (env eFunc) { SETUP_ACI(e, eFunc); } }

// ACI-VS-04: The zero market id never carries a rate or a config.
invariant vsAciZeroIdNeverConfigured(env e)
    forall AdaptiveCurveIrm.Id id. id == to_bytes32(0) =>
        (ghostAciRateAtTarget[id] == 0 && ghostAciMarketCurveConfig[id] == 0)
filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } { preserved with (env eFunc) { SETUP_ACI(e, eFunc); } }
