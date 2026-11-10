// IConfigurableIrm leaves parameter validity to the caller, so both IRM scenes model a config as an address
// with (a) code, (b) answers inside the constructor's bands, and (c) the same answer on every call. The
// witness rules here drop leg (b), keep (a) and (c), and document the assumption rather than report a
// finding.

import "../setup/Irm/LinearKinkIrm/LinearKinkIrm.spec";

using AdaptiveCurveIrm as _Aci;

methods {
    function _.getCurveParams() external
        => untrustedCurveParamsCVL(calledContract)
        expect AdaptiveCurveIrm.AdaptiveCurveParams ALL;

    function _Aci.owner() external returns (address) envfree;
    function _Aci.rateAtTarget(MarketParamsLib.Id) external returns (int256) envfree;
}

// The literal of AdaptiveCurveConfig.MAX_RATE_AT_TARGET_LIMIT.
definition MAX_RATE_AT_TARGET_LIMIT_TB_CVL() returns mathint = 317097919837645;

// The adaptive config model without leg (b): keyed by address, so answers are stable but unconstrained.
persistent ghost mapping(address => mathint) ghostTbCfgCurveSteepness;
persistent ghost mapping(address => mathint) ghostTbCfgAdjustmentSpeed;
persistent ghost mapping(address => mathint) ghostTbCfgTargetUtilization;
persistent ghost mapping(address => mathint) ghostTbCfgInitialRateAtTarget;
persistent ghost mapping(address => mathint) ghostTbCfgMinRateAtTarget;
persistent ghost mapping(address => mathint) ghostTbCfgMaxRateAtTarget;
persistent ghost mapping(address => mathint) ghostTbCfgMaxBorrowRate;

function untrustedCurveParamsCVL(address config) returns AdaptiveCurveIrm.AdaptiveCurveParams {
    AdaptiveCurveIrm.AdaptiveCurveParams p;
    require(config != 0,
        "SAFE: leg (a), a codeless callee reverts the decode on chain");
    require(
        to_mathint(p.curveSteepness) == ghostTbCfgCurveSteepness[config]
        && to_mathint(p.adjustmentSpeed) == ghostTbCfgAdjustmentSpeed[config]
        && to_mathint(p.targetUtilization) == ghostTbCfgTargetUtilization[config]
        && to_mathint(p.initialRateAtTarget) == ghostTbCfgInitialRateAtTarget[config]
        && to_mathint(p.minRateAtTarget) == ghostTbCfgMinRateAtTarget[config]
        && to_mathint(p.maxRateAtTarget) == ghostTbCfgMaxRateAtTarget[config]
        && to_mathint(p.maxBorrowRate) == ghostTbCfgMaxBorrowRate[config],
        "SAFE: leg (c) only, leg (b) is dropped on purpose");
    return p;
}

// ICF-TB-01: The owner can apply an unvalidated config that unsets a live market and stops its rate quotes.
rule tbIcfUnvalidatedConfigDeconfiguresALiveKinkMarket(env e,
    MarketParamsLib.MarketParams marketParams, address config, LinearKinkIrm.Market market) {

    setupLinearKinkIrmUntrustedConfig(e);
    require(e.msg.sender == ghostLkiOwner, "SCOPE: an authorized applier");

    MarketParamsLib.Id id = summaryMarketParamsId(marketParams);
    require(ghostLkiOptimalUtilization64[id] != 0, "SCOPE: a market that is configured before the call");

    _Lki.applyIrmConfig(e, marketParams, config);

    _Lki.borrowRateView@withrevert(e, marketParams, market);
    bool reverted = lastReverted;

    satisfy(ghostLkiOptimalUtilization64[id] == 0 && reverted,
        "a config nobody validated can unset a live market and stop its rate query");
}

// ICF-TB-02: The owner can apply an unvalidated config whose peak borrow rate exceeds the cap the rate model once enforced.
rule tbIcfUnvalidatedConfigStoresAPeakRateAboveTheRetiredCap(env e,
    MarketParamsLib.MarketParams marketParams, address config) {

    setupLinearKinkIrmUntrustedConfig(e);
    require(e.msg.sender == ghostLkiOwner, "SCOPE: an authorized applier");

    MarketParamsLib.Id id = summaryMarketParamsId(marketParams);

    _Lki.applyIrmConfig(e, marketParams, config);

    satisfy(ghostLkiBaseRate64[id] + ghostLkiSlope1_64[id] + ghostLkiSlope2_64[id]
        > MAX_BORROW_RATE_LKI_CVL(),
        "a config nobody validated can store a peak rate above the cap the IRM used to enforce");
}

// ICF-TB-03: The owner can apply an unvalidated config that lifts a market's target rate above the protocol wide limit.
rule tbIcfUnvalidatedConfigClampsRateAtTargetOutsideTheProtocolBand(env e,
    MarketParamsLib.MarketParams marketParams, address config) {

    setupEnv(e);
    require(e.msg.sender == _Aci.owner(), "SCOPE: an authorized applier");

    MarketParamsLib.Id id = summaryMarketParamsId(marketParams);
    mathint rateBefore = to_mathint(_Aci.rateAtTarget(id));
    require(rateBefore > 0 && rateBefore <= MAX_RATE_AT_TARGET_LIMIT_TB_CVL(),
        "SCOPE: a market priced inside the protocol wide band before the call");

    _Aci.applyIrmConfig(e, marketParams, config);

    satisfy(to_mathint(_Aci.rateAtTarget(id)) > MAX_RATE_AT_TARGET_LIMIT_TB_CVL(),
        "a config nobody validated can clamp a market's rate at target above the protocol wide limit");
}
