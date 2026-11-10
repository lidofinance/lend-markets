// Properties of the config factory over its real bytecode with both config templates compiled beside it:
// dedup, registration, revert conditions and witnesses. Rules that cross the deploy path run with the
// internal function instrumentation off, since the instrumented template no longer matches the creation code
// the factory embeds.

import "IrmConfigFactory_valid_state.spec";

// --- transitions ---

// ICF-VT-01: A registered adaptive config is never replaced and never cleared.
rule vtIcfAdaptiveRegistryIsWriteOnce(env e, method f, calldataarg args, bytes32 h)
    filtered { f -> !EXCLUDED_FUNCTION_ICF(f) } {

    setupIrmConfigFactory(e);
    address configBefore = ghostIcfAdaptiveConfig[h];

    f(e, args);

    address configAfter = ghostIcfAdaptiveConfig[h];

    assert(configBefore != 0 => configAfter == configBefore,
        "a registered adaptive config is never replaced and never cleared");
}

// ICF-VT-02: A registered linear kink config is never replaced and never cleared.
rule vtIcfLinearRegistryIsWriteOnce(env e, method f, calldataarg args, bytes32 h)
    filtered { f -> !EXCLUDED_FUNCTION_ICF(f) } {

    setupIrmConfigFactory(e);
    address configBefore = ghostIcfLinearConfig[h];

    f(e, args);

    address configAfter = ghostIcfLinearConfig[h];

    assert(configBefore != 0 => configAfter == configBefore,
        "a registered linear kink config is never replaced and never cleared");
}

// --- high_level ---

definition SAME_ADAPTIVE_PARAMS_ICF(IrmConfigFactory.AdaptiveCurveParams a,
    IrmConfigFactory.AdaptiveCurveParams b) returns bool =
    a.curveSteepness == b.curveSteepness
    && a.adjustmentSpeed == b.adjustmentSpeed
    && a.targetUtilization == b.targetUtilization
    && a.initialRateAtTarget == b.initialRateAtTarget
    && a.minRateAtTarget == b.minRateAtTarget
    && a.maxRateAtTarget == b.maxRateAtTarget
    && a.maxBorrowRate == b.maxBorrowRate
    ;

// ICF-HL-01: Requesting the same adaptive parameters twice returns the same config and deploys nothing new.
rule hlIcfSameParamsResolveToOneAdaptiveConfig(env e1, env e2,
    IrmConfigFactory.AdaptiveCurveParams params, bytes32 h) {

    setupIrmConfigFactoryValidState(e1);
    setupIrmConfigFactoryValidState(e2);

    address first = getOrDeployAdaptiveCurveConfig(e1, params);
    address registryAfterFirst = ghostIcfAdaptiveConfig[h];

    address second = getOrDeployAdaptiveCurveConfig(e2, params);

    assert(second == first && ghostIcfAdaptiveConfig[h] == registryAfterFirst,
        "a repeat adaptive request is served from the registry, with no second deployment");
}

// ICF-HL-02: Requesting the same linear kink parameters twice returns the same config and deploys nothing new.
rule hlIcfSameParamsResolveToOneLinearConfig(env e1, env e2,
    IrmConfigFactory.LinearKinkParams params, bytes32 h) {

    setupIrmConfigFactoryValidState(e1);
    setupIrmConfigFactoryValidState(e2);

    address first = getOrDeployLinearKinkConfig(e1, params);
    address registryAfterFirst = ghostIcfLinearConfig[h];

    address second = getOrDeployLinearKinkConfig(e2, params);

    assert(second == first && ghostIcfLinearConfig[h] == registryAfterFirst,
        "a repeat linear kink request is served from the registry, with no second deployment");
}

// ICF-HL-03: Adaptive parameter sets that differ in any field always resolve to different configs.
rule hlIcfDistinctParamsResolveToDistinctConfigs(env e,
    IrmConfigFactory.AdaptiveCurveParams params1, IrmConfigFactory.AdaptiveCurveParams params2) {

    setupIrmConfigFactoryValidState(e);
    require(getAdaptiveCurveConfig(params1) == 0 && getAdaptiveCurveConfig(params2) == 0,
        "SCOPE: both param sets start unregistered");

    address config1 = getOrDeployAdaptiveCurveConfig(e, params1);
    address config2 = getOrDeployAdaptiveCurveConfig(e, params2);

    assert(!SAME_ADAPTIVE_PARAMS_ICF(params1, params2) => config1 != config2,
        "curves that differ in any field are held by different config contracts");
}

// --- unit_tests ---

// ICF-UT-01: Requesting an adaptive config returns a real address that the registry then holds for those parameters.
rule utIcfGetOrDeployAdaptiveRegistersTheReturnedConfig(env e, IrmConfigFactory.AdaptiveCurveParams params) {

    setupIrmConfigFactoryValidState(e);

    address config = getOrDeployAdaptiveCurveConfig(e, params);

    assert(config != 0 && getAdaptiveCurveConfig(params) == config,
        "the adaptive config handed back is live and is the one the registry now holds for those params");
}

// ICF-UT-02: Requesting a linear kink config returns a real address that the registry then holds for those parameters.
rule utIcfGetOrDeployLinearRegistersTheReturnedConfig(env e, IrmConfigFactory.LinearKinkParams params) {

    setupIrmConfigFactoryValidState(e);

    address config = getOrDeployLinearKinkConfig(e, params);

    assert(config != 0 && getLinearKinkConfig(params) == config,
        "the linear kink config handed back is live and is the one the registry now holds for those params");
}

// ICF-UT-03: Looking up a registered adaptive config reports the same address a new request would return.
rule utIcfGetAdaptiveConfigMatchesTheRegistry(env e, IrmConfigFactory.AdaptiveCurveParams params) {

    setupIrmConfigFactoryValidState(e);
    address viewed = getAdaptiveCurveConfig(params);

    address served = getOrDeployAdaptiveCurveConfig(e, params);

    assert(viewed != 0 => served == viewed,
        "the adaptive view getter reports exactly the address the deploy path re-serves");
}

// ICF-UT-04: Looking up a registered linear kink config reports the same address a new request would return.
rule utIcfGetLinearConfigMatchesTheRegistry(env e, IrmConfigFactory.LinearKinkParams params) {

    setupIrmConfigFactoryValidState(e);
    address viewed = getLinearKinkConfig(params);

    address served = getOrDeployLinearKinkConfig(e, params);

    assert(viewed != 0 => served == viewed,
        "the linear kink view getter reports exactly the address the deploy path re-serves");
}

// ICF-UT-05: Deploying an adaptive config changes nothing in the linear kink registry.
rule utIcfAdaptiveDeployLeavesTheLinearRegistryUntouched(env e,
    IrmConfigFactory.AdaptiveCurveParams params, bytes32 h) {

    setupIrmConfigFactoryValidState(e);
    address linearBefore = ghostIcfLinearConfig[h];

    getOrDeployAdaptiveCurveConfig(e, params);

    assert(ghostIcfLinearConfig[h] == linearBefore,
        "an adaptive deployment never touches a linear kink registry row");
}

// ICF-UT-10: Deploying a linear kink config changes nothing in the adaptive registry.
rule utIcfLinearDeployLeavesTheAdaptiveRegistryUntouched(env e,
    IrmConfigFactory.LinearKinkParams params, bytes32 h) {

    setupIrmConfigFactoryValidState(e);
    address adaptiveBefore = ghostIcfAdaptiveConfig[h];

    getOrDeployLinearKinkConfig(e, params);

    assert(ghostIcfAdaptiveConfig[h] == adaptiveBefore,
        "a linear kink deployment never touches an adaptive registry row");
}

// ICF-UT-08: The adaptive config reports every curve parameter in the field it belongs to.
rule utIcfAdaptiveConfigGetterMirrorsItsImmutables() {

    AdaptiveCurveConfig.AdaptiveCurveParams p = _AciConfig.getCurveParams();

    assert(p.curveSteepness == _AciConfig.CURVE_STEEPNESS()
        && p.adjustmentSpeed == _AciConfig.ADJUSTMENT_SPEED()
        && p.targetUtilization == _AciConfig.TARGET_UTILIZATION()
        && p.initialRateAtTarget == _AciConfig.INITIAL_RATE_AT_TARGET()
        && p.minRateAtTarget == _AciConfig.MIN_RATE_AT_TARGET()
        && p.maxRateAtTarget == _AciConfig.MAX_RATE_AT_TARGET()
        && p.maxBorrowRate == _AciConfig.MAX_BORROW_RATE(),
        "getCurveParams places every immutable in the field it belongs to");
}

// ICF-UT-09: The linear kink config reports every parameter in the field it belongs to.
rule utIcfLinearConfigGetterMirrorsItsImmutables() {

    LinearKinkConfig.LinearKinkParams p = _LkiConfig.getKinkParams();

    assert(p.optimalUtilization == _LkiConfig.OPTIMAL_UTILIZATION()
        && p.baseRate == _LkiConfig.BASE_RATE()
        && p.slope1 == _LkiConfig.SLOPE1()
        && p.slope2 == _LkiConfig.SLOPE2(),
        "getKinkParams places every immutable in the field it belongs to");
}

// --- reachability ---

// ICF-RC-01: A caller can deploy and register a config for an adaptive curve nobody has requested yet.
rule rcIcfFreshAdaptiveDeploymentIsReachable(env e, IrmConfigFactory.AdaptiveCurveParams params) {

    setupIrmConfigFactoryValidState(e);
    require(getAdaptiveCurveConfig(params) == 0, "SCOPE: a params set nobody registered yet");
    require(VALID_ADAPTIVE_PARAMS_ICF(params),
        "SCOPE: a curve the config constructor accepts");

    address config = getOrDeployAdaptiveCurveConfig(e, params);

    satisfy(config != 0 && getAdaptiveCurveConfig(params) == config,
        "a fresh adaptive params set can be deployed and registered by any caller");
}

// ICF-RC-02: A caller can deploy and register a config for a linear kink curve nobody has requested yet.
rule rcIcfFreshLinearDeploymentIsReachable(env e, IrmConfigFactory.LinearKinkParams params) {

    setupIrmConfigFactoryValidState(e);
    require(getLinearKinkConfig(params) == 0, "SCOPE: a params set nobody registered yet");

    address config = getOrDeployLinearKinkConfig(e, params);

    satisfy(config != 0 && getLinearKinkConfig(params) == config,
        "a fresh linear kink params set can be deployed and registered by any caller");
}

// ICF-RC-03: A repeat adaptive request can be served from the registry without writing to it again.
rule rcIcfAdaptiveDedupHitIsReachable(env e1, env e2, IrmConfigFactory.AdaptiveCurveParams params) {

    setupIrmConfigFactoryValidState(e1);
    setupIrmConfigFactoryValidState(e2);
    require(getAdaptiveCurveConfig(params) == 0, "SCOPE: start from a params set nobody registered yet");

    address first = getOrDeployAdaptiveCurveConfig(e1, params);
    mathint writesAfterFirst = ghostIcfAdaptiveWrites;
    address second = getOrDeployAdaptiveCurveConfig(e2, params);

    satisfy(first != 0 && second == first && ghostIcfAdaptiveWrites == writesAfterFirst,
        "the adaptive cache hit is reachable and writes no registry row");
}

// ICF-RC-04: A repeat linear kink request can be served from the registry without writing to it again.
rule rcIcfLinearDedupHitIsReachable(env e1, env e2, IrmConfigFactory.LinearKinkParams params) {

    setupIrmConfigFactoryValidState(e1);
    setupIrmConfigFactoryValidState(e2);
    require(getLinearKinkConfig(params) == 0, "SCOPE: start from a params set nobody registered yet");

    address first = getOrDeployLinearKinkConfig(e1, params);
    mathint writesAfterFirst = ghostIcfLinearWrites;
    address second = getOrDeployLinearKinkConfig(e2, params);

    satisfy(first != 0 && second == first && ghostIcfLinearWrites == writesAfterFirst,
        "the linear kink cache hit is reachable and writes no registry row");
}

// --- reverts ---

// ICF-RV-01: Deploying an adaptive config fails exactly when the requested curve is outside the allowed bands.
rule rvIcfGetOrDeployAdaptiveRevertsIffParamsInvalid(env e, IrmConfigFactory.AdaptiveCurveParams params) {

    setupIrmConfigFactoryValidState(e);
    require(getAdaptiveCurveConfig(params) == 0,
        "SCOPE: the deploying path");

    getOrDeployAdaptiveCurveConfig@withrevert(e, params);
    bool reverted = lastReverted;

    assert(reverted <=> !VALID_ADAPTIVE_PARAMS_ICF(params),
        "the adaptive deploy path rejects exactly the params its constructor rejects");
}

// ICF-RV-02: Deploying a linear kink config fails exactly when the kink or the peak rate is out of bounds.
rule rvIcfGetOrDeployLinearRevertsIffParamsInvalid(env e, IrmConfigFactory.LinearKinkParams params) {

    setupIrmConfigFactoryValidState(e);
    require(getLinearKinkConfig(params) == 0,
        "SCOPE: the deploying path");

    getOrDeployLinearKinkConfig@withrevert(e, params);
    bool reverted = lastReverted;

    assert(reverted <=> !VALID_LINEAR_PARAMS_ICF(params),
        "the linear kink deploy path rejects exactly the params its constructor rejects");
}

// ICF-RV-03: A request for adaptive parameters that already have a config never fails.
rule rvIcfGetOrDeployAdaptiveNeverRevertsOnRegisteredParams(env e,
    IrmConfigFactory.AdaptiveCurveParams params) {

    setupIrmConfigFactoryValidState(e);
    bool registered = getAdaptiveCurveConfig(params) != 0;

    getOrDeployAdaptiveCurveConfig@withrevert(e, params);
    bool reverted = lastReverted;

    assert(registered => !reverted,
        "an adaptive cache hit never reverts");
}

// ICF-RV-04: A request for linear kink parameters that already have a config never fails.
rule rvIcfGetOrDeployLinearNeverRevertsOnRegisteredParams(env e, IrmConfigFactory.LinearKinkParams params) {

    setupIrmConfigFactoryValidState(e);
    bool registered = getLinearKinkConfig(params) != 0;

    getOrDeployLinearKinkConfig@withrevert(e, params);
    bool reverted = lastReverted;

    assert(registered => !reverted,
        "a linear kink cache hit never reverts");
}
