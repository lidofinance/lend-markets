// The AdaptiveCurveIrm scene: storage mirrors and hooks, the base setup, an opt in well formedness
// requirement on the market argument, and a model of the curve config the IRM prices from. Config validity is
// assumed, not proven, and must hold for the market's whole life.

import "../../env.spec";
import "../../marketParamsLib.spec";
import "../irmWadMath.spec";
import "../adaptiveCurveMath.spec";

using AdaptiveCurveIrm as _Aci;

methods {
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    function _.getCurveParams() external
        => getCurveParamsCVL(calledContract)
        expect AdaptiveCurveIrm.AdaptiveCurveParams ALL;

    function _Aci.ROUTER() external returns (address) envfree;
}

definition EXCLUDED_FUNCTION_ACI(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

function setupAdaptiveCurveIrm(env e) {
    setupEnv(e);

    require(forall address c. VALID_ACI_CONFIG(c),
        "TRUSTED: a config satisfies the constructor's cross field relations");
}

// Opt in per rule, same env as the priced call; borrowRateView is ungated, so adversarial view rules skip it.
function setupMarketAdaptiveCurveIrm(env e, AdaptiveCurveIrm.Market market) {
    require(to_mathint(market.totalBorrowAssets) <= to_mathint(market.totalSupplyAssets),
        "TRUSTED: the router forwards a stored market with borrow <= supply");
    require(to_mathint(market.lastUpdate) <= to_mathint(e.block.timestamp),
        "TRUSTED: the router forwards a market with lastUpdate <= block.timestamp");
}

// OwnerManagerBase: owner and manager each occupy a full slot.

persistent ghost address ghostAciOwner {
    init_state axiom ghostAciOwner == 0;
}

persistent ghost address ghostAciManager {
    init_state axiom ghostAciManager == 0;
}

hook Sload address val _Aci.owner {
    require(ghostAciOwner == val, "SAFE: ghostAciOwner sync");
}
hook Sstore _Aci.owner address val {
    ghostAciOwner = val;
}

hook Sload address val _Aci.manager {
    require(ghostAciManager == val, "SAFE: ghostAciManager sync");
}
hook Sstore _Aci.manager address val {
    ghostAciManager = val;
}

// rateAtTarget[id]: the signed curve state, 0 marks a market that was never priced.

definition MIN_INT256_CVL() returns mathint = -(2^255);
definition MAX_INT256_CVL() returns mathint = 2^255 - 1;

persistent ghost mapping(AdaptiveCurveIrm.Id => mathint) ghostAciRateAtTarget {
    init_state axiom forall AdaptiveCurveIrm.Id id. ghostAciRateAtTarget[id] == 0;
    // SAFE: the mirrored field is int256.
    axiom forall AdaptiveCurveIrm.Id id.
        ghostAciRateAtTarget[id] >= MIN_INT256_CVL() && ghostAciRateAtTarget[id] <= MAX_INT256_CVL();
}

hook Sload int256 val _Aci.rateAtTarget[KEY AdaptiveCurveIrm.Id id] {
    require(ghostAciRateAtTarget[id] == to_mathint(val), "SAFE: ghostAciRateAtTarget sync");
}
hook Sstore _Aci.rateAtTarget[KEY AdaptiveCurveIrm.Id id] int256 val {
    ghostAciRateAtTarget[id] = to_mathint(val);
}

persistent ghost mapping(AdaptiveCurveIrm.Id => address) ghostAciMarketCurveConfig {
    init_state axiom forall AdaptiveCurveIrm.Id id. ghostAciMarketCurveConfig[id] == 0;
}

hook Sload address val _Aci.marketCurveConfig[KEY AdaptiveCurveIrm.Id id] {
    require(ghostAciMarketCurveConfig[id] == val, "SAFE: ghostAciMarketCurveConfig sync");
}
hook Sstore _Aci.marketCurveConfig[KEY AdaptiveCurveIrm.Id id] address val {
    ghostAciMarketCurveConfig[id] = val;
}

// getCurveParams model: one ghost per field, ranges from AdaptiveCurveConfig._validateCurveParams.

definition WAD_INT_CVL() returns mathint = 1000000000000000000;
definition MAX_CURVE_STEEPNESS_CVL() returns mathint = 100000000000000000000;
definition MAX_ADJUSTMENT_SPEED_CVL() returns mathint = 317097919837645;
definition MAX_RATE_AT_TARGET_LIMIT_CVL() returns mathint = 317097919837645;
definition MAX_BORROW_RATE_LIMIT_CVL() returns mathint = 31709791983764500;

persistent ghost mapping(address => mathint) ghostAciCfgCurveSteepness {
    // TRUSTED: curveSteepness in [WAD, MAX_CURVE_STEEPNESS].
    axiom forall address c.
        ghostAciCfgCurveSteepness[c] >= WAD_INT_CVL()
        && ghostAciCfgCurveSteepness[c] <= MAX_CURVE_STEEPNESS_CVL();
}

persistent ghost mapping(address => mathint) ghostAciCfgAdjustmentSpeed {
    // TRUSTED: adjustmentSpeed in [0, MAX_ADJUSTMENT_SPEED].
    axiom forall address c.
        ghostAciCfgAdjustmentSpeed[c] >= 0
        && ghostAciCfgAdjustmentSpeed[c] <= MAX_ADJUSTMENT_SPEED_CVL();
}

persistent ghost mapping(address => mathint) ghostAciCfgTargetUtilization {
    // TRUSTED: targetUtilization in (0, WAD).
    axiom forall address c.
        ghostAciCfgTargetUtilization[c] > 0
        && ghostAciCfgTargetUtilization[c] < WAD_INT_CVL();
}

persistent ghost mapping(address => mathint) ghostAciCfgInitialRateAtTarget {
    // TRUSTED: initialRateAtTarget in (0, MAX_RATE_AT_TARGET_LIMIT].
    axiom forall address c.
        ghostAciCfgInitialRateAtTarget[c] > 0
        && ghostAciCfgInitialRateAtTarget[c] <= MAX_RATE_AT_TARGET_LIMIT_CVL();
}

persistent ghost mapping(address => mathint) ghostAciCfgMinRateAtTarget {
    // TRUSTED: minRateAtTarget in (0, MAX_RATE_AT_TARGET_LIMIT].
    axiom forall address c.
        ghostAciCfgMinRateAtTarget[c] > 0
        && ghostAciCfgMinRateAtTarget[c] <= MAX_RATE_AT_TARGET_LIMIT_CVL();
}

persistent ghost mapping(address => mathint) ghostAciCfgMaxRateAtTarget {
    // TRUSTED: maxRateAtTarget in (0, MAX_RATE_AT_TARGET_LIMIT].
    axiom forall address c.
        ghostAciCfgMaxRateAtTarget[c] > 0
        && ghostAciCfgMaxRateAtTarget[c] <= MAX_RATE_AT_TARGET_LIMIT_CVL();
}

persistent ghost mapping(address => mathint) ghostAciCfgMaxBorrowRate {
    // TRUSTED: maxBorrowRate in [0, MAX_BORROW_RATE_LIMIT].
    axiom forall address c.
        ghostAciCfgMaxBorrowRate[c] >= 0
        && ghostAciCfgMaxBorrowRate[c] <= MAX_BORROW_RATE_LIMIT_CVL();
}

// The constructor relations that span several ghosts and so cannot sit on one declaration.
definition VALID_ACI_CONFIG(address c) returns bool =
    ghostAciCfgMaxRateAtTarget[c] >= ghostAciCfgMinRateAtTarget[c]
    && ghostAciCfgInitialRateAtTarget[c] >= ghostAciCfgMinRateAtTarget[c]
    && ghostAciCfgInitialRateAtTarget[c] <= ghostAciCfgMaxRateAtTarget[c];

function getCurveParamsCVL(address config) returns AdaptiveCurveIrm.AdaptiveCurveParams {
    AdaptiveCurveIrm.AdaptiveCurveParams p;
    require(config != 0,
        "SAFE: a call to a codeless config reverts on the ABI decode");
    require(
        to_mathint(p.curveSteepness) == ghostAciCfgCurveSteepness[config]
        && to_mathint(p.adjustmentSpeed) == ghostAciCfgAdjustmentSpeed[config]
        && to_mathint(p.targetUtilization) == ghostAciCfgTargetUtilization[config]
        && to_mathint(p.initialRateAtTarget) == ghostAciCfgInitialRateAtTarget[config]
        && to_mathint(p.minRateAtTarget) == ghostAciCfgMinRateAtTarget[config]
        && to_mathint(p.maxRateAtTarget) == ghostAciCfgMaxRateAtTarget[config]
        && to_mathint(p.maxBorrowRate) == ghostAciCfgMaxBorrowRate[config],
        "TRUSTED: a config answers with its own validated params on every call"
    );
    return p;
}
