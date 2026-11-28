// The one scene where a deployed config is read back through real bytecode: the factory deploys a linear kink
// or adaptive curve config, and the IRM prices from exactly those params. Both rules pin an authorized caller
// and unregistered params, so the deploying branch runs.

import "../setup/env.spec";

using IrmConfigFactory as _Factory;
using AdaptiveCurveIrm as _Aci;
using LinearKinkIrm as _Lki;

methods {
    function _Factory.getAdaptiveCurveConfig(IrmConfigFactory.AdaptiveCurveParams) external returns (address) envfree;
    function _Factory.getLinearKinkConfig(IrmConfigFactory.LinearKinkParams) external returns (address) envfree;

    // The config address travels through CVL, so the dispatcher resolves it by address to the real clone.
    function _.getCurveParams() external => DISPATCHER(true);
    function _.getKinkParams() external => DISPATCHER(true);

    function _Lki.owner() external returns (address) envfree;
    function _Lki.marketKinkParams(MarketParamsLib.Id) external
        returns (uint64, uint64, uint64, uint64) envfree;

    function _Aci.owner() external returns (address) envfree;
    function _Aci.rateAtTarget(MarketParamsLib.Id) external returns (int256) envfree;
    function _Aci.marketCurveConfig(MarketParamsLib.Id) external returns (address) envfree;
}

// Internal finders are off in this conf, so the id each apply writes under is captured from the store.
persistent ghost MarketParamsLib.Id ghostIcfAciAppliedId;
persistent ghost MarketParamsLib.Id ghostIcfLkiAppliedId;

hook Sstore _Aci.marketCurveConfig[KEY MarketParamsLib.Id id] address val {
    ghostIcfAciAppliedId = id;
}

hook Sstore _Lki.marketKinkParams[KEY MarketParamsLib.Id id].optimalUtilization uint64 val {
    ghostIcfLkiAppliedId = id;
}

// Mirror of the adaptive rateAtTarget, so the priced branch can be pinned before the id is known.
persistent ghost mapping(MarketParamsLib.Id => int256) ghostIcfAciRate;

hook Sload int256 val _Aci.rateAtTarget[KEY MarketParamsLib.Id id] {
    require(ghostIcfAciRate[id] == val, "SAFE: ghostIcfAciRate sync");
}

hook Sstore _Aci.rateAtTarget[KEY MarketParamsLib.Id id] int256 val {
    ghostIcfAciRate[id] = val;
}

// ICF-UT-07: The linear kink curve a market prices with is exactly the one the factory was asked for.
rule utIcfDeployedLinearConfigCopiesTheRequestedParams(env e,
    MarketParamsLib.MarketParams marketParams, IrmConfigFactory.LinearKinkParams params) {

    setupEnv(e);
    require(e.msg.sender == _Lki.owner(),
        "SCOPE: an authorized applier");

    require(_Factory.getLinearKinkConfig(params) == 0,
        "SCOPE: params not yet registered, so the deploy branch runs");
    address config = _Factory.getOrDeployLinearKinkConfig(e, params);
    _Lki.applyIrmConfig(e, marketParams, config);

    MarketParamsLib.Id id = ghostIcfLkiAppliedId;
    uint64 optimalUtilization;
    uint64 baseRate;
    uint64 slope1;
    uint64 slope2;
    optimalUtilization, baseRate, slope1, slope2 = _Lki.marketKinkParams(id);

    assert(optimalUtilization == params.optimalUtilization
        && baseRate == params.baseRate
        && slope1 == params.slope1
        && slope2 == params.slope2,
        "a deployed linear kink config reports back exactly the params the factory was asked for");
}

// ICF-UT-06: Applying a fresh adaptive config points the market at it and pulls its target rate into the requested band.
rule utIcfDeployedAdaptiveConfigClampsToTheRequestedBand(env e,
    MarketParamsLib.MarketParams marketParams, IrmConfigFactory.AdaptiveCurveParams params) {

    setupEnv(e);
    require(e.msg.sender == _Aci.owner(),
        "SCOPE: an authorized applier");

    require(forall MarketParamsLib.Id id. ghostIcfAciRate[id] != 0,
        "SCOPE: every market already priced, so the clamp branch runs");

    require(_Factory.getAdaptiveCurveConfig(params) == 0,
        "SCOPE: params not yet registered, so the deploy branch runs");
    address config = _Factory.getOrDeployAdaptiveCurveConfig(e, params);
    _Aci.applyIrmConfig(e, marketParams, config);

    MarketParamsLib.Id id = ghostIcfAciAppliedId;
    mathint rateAfter = to_mathint(_Aci.rateAtTarget(id));

    assert(_Aci.marketCurveConfig(id) == config
        && rateAfter >= to_mathint(params.minRateAtTarget)
        && rateAfter <= to_mathint(params.maxRateAtTarget),
        "a deployed adaptive config clamps the market into the band the factory was asked for");
}
