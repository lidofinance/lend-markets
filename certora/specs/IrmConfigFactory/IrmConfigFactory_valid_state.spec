// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external method call.
// Once proven, the other spec files of this scene assume them via setupIrmConfigFactoryValidState.

import "../setup/Irm/IrmConfigFactory/IrmConfigFactory.spec";

function requireIrmConfigFactoryInvariants(env e) {
    requireInvariant vsIcfZeroHashNeverResolvesToAnAdaptiveConfig(e);
    requireInvariant vsIcfZeroHashNeverResolvesToALinearConfig(e);
}

function setupIrmConfigFactoryValidState(env e) {
    setupIrmConfigFactory(e);
    requireIrmConfigFactoryInvariants(e);
}

function SETUP_FULL_ICF(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupIrmConfigFactory(e);
    requireIrmConfigFactoryInvariants(e);
}

// ICF-VS-01: The empty parameter key never maps to an adaptive config.
invariant vsIcfZeroHashNeverResolvesToAnAdaptiveConfig(env e)
    ghostIcfAdaptiveConfig[to_bytes32(0)] == 0
filtered { f -> !EXCLUDED_FUNCTION_ICF(f) } { preserved with (env eFunc) { SETUP_ICF(e, eFunc); } }

// ICF-VS-02: The empty parameter key never maps to a linear kink config.
invariant vsIcfZeroHashNeverResolvesToALinearConfig(env e)
    ghostIcfLinearConfig[to_bytes32(0)] == 0
filtered { f -> !EXCLUDED_FUNCTION_ICF(f) } { preserved with (env eFunc) { SETUP_ICF(e, eFunc); } }
