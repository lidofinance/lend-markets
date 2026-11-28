// Mirrors and write counters for the two config registries, plus the parameter bands the config constructors
// enforce and the IRM scenes assume. A conf reaching the deploy path must set dynamic_bound and
// disable_internal_function_instrumentation, or the constructor is skipped and the deployment never reverts.

import "../../env.spec";

using IrmConfigFactory as _Factory;
using AdaptiveCurveConfig as _AciConfig;
using LinearKinkConfig as _LkiConfig;

methods {
    function _Factory.getAdaptiveCurveConfig(IrmConfigFactory.AdaptiveCurveParams) external returns (address) envfree;
    function _Factory.getLinearKinkConfig(IrmConfigFactory.LinearKinkParams) external returns (address) envfree;

    function _AciConfig.getCurveParams() external returns (AdaptiveCurveConfig.AdaptiveCurveParams) envfree;
    function _AciConfig.CURVE_STEEPNESS() external returns (int256) envfree;
    function _AciConfig.ADJUSTMENT_SPEED() external returns (int256) envfree;
    function _AciConfig.TARGET_UTILIZATION() external returns (int256) envfree;
    function _AciConfig.INITIAL_RATE_AT_TARGET() external returns (int256) envfree;
    function _AciConfig.MIN_RATE_AT_TARGET() external returns (int256) envfree;
    function _AciConfig.MAX_RATE_AT_TARGET() external returns (int256) envfree;
    function _AciConfig.MAX_BORROW_RATE() external returns (uint256) envfree;

    function _LkiConfig.getKinkParams() external returns (LinearKinkConfig.LinearKinkParams) envfree;
    function _LkiConfig.OPTIMAL_UTILIZATION() external returns (uint64) envfree;
    function _LkiConfig.BASE_RATE() external returns (uint64) envfree;
    function _LkiConfig.SLOPE1() external returns (uint64) envfree;
    function _LkiConfig.SLOPE2() external returns (uint64) envfree;
}

definition EXCLUDED_FUNCTION_ICF(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

function setupIrmConfigFactory(env e) {
    setupEnv(e);
}

function SETUP_ICF(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupIrmConfigFactory(e);
}

// Both mappings are private; hooks address them by name, so the scene needs no harness.

persistent ghost mapping(bytes32 => address) ghostIcfAdaptiveConfig {
    init_state axiom forall bytes32 h. ghostIcfAdaptiveConfig[h] == 0;
}

persistent ghost mapping(bytes32 => address) ghostIcfLinearConfig {
    init_state axiom forall bytes32 h. ghostIcfLinearConfig[h] == 0;
}

// Bumped by the mirror hooks, so a rule can pin that a call wrote no registry row at all.

persistent ghost mathint ghostIcfAdaptiveWrites {
    init_state axiom ghostIcfAdaptiveWrites == 0;
}

persistent ghost mathint ghostIcfLinearWrites {
    init_state axiom ghostIcfLinearWrites == 0;
}

hook Sload address val _Factory._adaptiveCurveConfigByParamsHash[KEY bytes32 h] {
    require(ghostIcfAdaptiveConfig[h] == val, "SAFE: ghostIcfAdaptiveConfig sync");
}

hook Sstore _Factory._adaptiveCurveConfigByParamsHash[KEY bytes32 h] address val {
    ghostIcfAdaptiveConfig[h] = val;
    ghostIcfAdaptiveWrites = ghostIcfAdaptiveWrites + 1;
}

hook Sload address val _Factory._linearKinkConfigByParamsHash[KEY bytes32 h] {
    require(ghostIcfLinearConfig[h] == val, "SAFE: ghostIcfLinearConfig sync");
}

hook Sstore _Factory._linearKinkConfigByParamsHash[KEY bytes32 h] address val {
    ghostIcfLinearConfig[h] = val;
    ghostIcfLinearWrites = ghostIcfLinearWrites + 1;
}

// Transcribed from the config constructors; the IRM scene ghost ranges must match them.

definition WAD_INT_ICF_CVL() returns mathint = 1000000000000000000;
definition MAX_CURVE_STEEPNESS_ICF_CVL() returns mathint = 100000000000000000000;
definition MAX_ADJUSTMENT_SPEED_ICF_CVL() returns mathint = 317097919837645;
definition MAX_RATE_AT_TARGET_LIMIT_ICF_CVL() returns mathint = 317097919837645;
definition MAX_BORROW_RATE_LIMIT_ICF_CVL() returns mathint = 31709791983764500;
definition MAX_BORROW_RATE_LKI_ICF_CVL() returns mathint = 253678335870;

definition VALID_ADAPTIVE_PARAMS_ICF(IrmConfigFactory.AdaptiveCurveParams p) returns bool =
    to_mathint(p.curveSteepness) >= WAD_INT_ICF_CVL()
    && to_mathint(p.curveSteepness) <= MAX_CURVE_STEEPNESS_ICF_CVL()
    && to_mathint(p.adjustmentSpeed) >= 0
    && to_mathint(p.adjustmentSpeed) <= MAX_ADJUSTMENT_SPEED_ICF_CVL()
    && to_mathint(p.targetUtilization) > 0
    && to_mathint(p.targetUtilization) < WAD_INT_ICF_CVL()
    && to_mathint(p.minRateAtTarget) > 0
    && to_mathint(p.maxRateAtTarget) >= to_mathint(p.minRateAtTarget)
    && to_mathint(p.maxRateAtTarget) <= MAX_RATE_AT_TARGET_LIMIT_ICF_CVL()
    && to_mathint(p.initialRateAtTarget) >= to_mathint(p.minRateAtTarget)
    && to_mathint(p.initialRateAtTarget) <= to_mathint(p.maxRateAtTarget)
    && (to_mathint(p.maxBorrowRate) == 0 || to_mathint(p.maxBorrowRate) <= MAX_BORROW_RATE_LIMIT_ICF_CVL())
    ;

definition VALID_LINEAR_PARAMS_ICF(IrmConfigFactory.LinearKinkParams p) returns bool =
    to_mathint(p.optimalUtilization) > 0
    && to_mathint(p.optimalUtilization) < WAD_INT_ICF_CVL()
    && to_mathint(p.baseRate) + to_mathint(p.slope1) + to_mathint(p.slope2) <= MAX_BORROW_RATE_LKI_ICF_CVL()
    ;
