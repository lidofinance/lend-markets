// The LinearKinkIrm scene over the contract's own source: the packed kink row mirrored field by field, the
// base setup, and the model of the config a market applies. Config validity is assumed rather than proven,
// and the assumption is needed only at apply time.

import "../../env.spec";
import "../../marketParamsLib.spec";
import "../irmWadMath.spec";

using LinearKinkIrm as _Lki;

methods {
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    function _.getKinkParams() external
        => getKinkParamsCVL(calledContract)
        expect LinearKinkIrm.LinearKinkParams ALL;
}

definition EXCLUDED_FUNCTION_LKI(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

// No boundary pin on the market argument: it would make the WAD clamp on utilization dead code.
function setupLinearKinkIrm(env e) {
    setupEnv(e);

    require(forall address c. VALID_LKI_CONFIG(c),
        "TRUSTED: a config reports the params its constructor validated");
}

// The same scene without the config validity assumption.
function setupLinearKinkIrmUntrustedConfig(env e) {
    setupEnv(e);
}

// OwnerManagerBase: owner and manager each occupy a full slot.

persistent ghost address ghostLkiOwner {
    init_state axiom ghostLkiOwner == 0;
}

persistent ghost address ghostLkiManager {
    init_state axiom ghostLkiManager == 0;
}

hook Sload address val _Lki.owner {
    require(ghostLkiOwner == val, "SAFE: ghostLkiOwner sync");
}
hook Sstore _Lki.owner address val {
    ghostLkiOwner = val;
}

hook Sload address val _Lki.manager {
    require(ghostLkiManager == val, "SAFE: ghostLkiManager sync");
}
hook Sstore _Lki.manager address val {
    ghostLkiManager = val;
}

// marketKinkParams[id]: four uint64 fields in one slot, written only as a whole struct.

persistent ghost mapping(LinearKinkIrm.Id => mathint) ghostLkiOptimalUtilization64 {
    init_state axiom forall LinearKinkIrm.Id id. ghostLkiOptimalUtilization64[id] == 0;
    axiom forall LinearKinkIrm.Id id.
        ghostLkiOptimalUtilization64[id] >= 0 && ghostLkiOptimalUtilization64[id] <= max_uint64;
}

persistent ghost mapping(LinearKinkIrm.Id => mathint) ghostLkiBaseRate64 {
    init_state axiom forall LinearKinkIrm.Id id. ghostLkiBaseRate64[id] == 0;
    axiom forall LinearKinkIrm.Id id.
        ghostLkiBaseRate64[id] >= 0 && ghostLkiBaseRate64[id] <= max_uint64;
}

persistent ghost mapping(LinearKinkIrm.Id => mathint) ghostLkiSlope1_64 {
    init_state axiom forall LinearKinkIrm.Id id. ghostLkiSlope1_64[id] == 0;
    axiom forall LinearKinkIrm.Id id.
        ghostLkiSlope1_64[id] >= 0 && ghostLkiSlope1_64[id] <= max_uint64;
}

persistent ghost mapping(LinearKinkIrm.Id => mathint) ghostLkiSlope2_64 {
    init_state axiom forall LinearKinkIrm.Id id. ghostLkiSlope2_64[id] == 0;
    axiom forall LinearKinkIrm.Id id.
        ghostLkiSlope2_64[id] >= 0 && ghostLkiSlope2_64[id] <= max_uint64;
}

hook Sload uint64 val _Lki.marketKinkParams[KEY LinearKinkIrm.Id id].optimalUtilization {
    require(require_uint64(ghostLkiOptimalUtilization64[id]) == val, "SAFE: ghostLkiOptimalUtilization64 sync");
}
hook Sstore _Lki.marketKinkParams[KEY LinearKinkIrm.Id id].optimalUtilization uint64 val {
    ghostLkiOptimalUtilization64[id] = val;
}

hook Sload uint64 val _Lki.marketKinkParams[KEY LinearKinkIrm.Id id].baseRate {
    require(require_uint64(ghostLkiBaseRate64[id]) == val, "SAFE: ghostLkiBaseRate64 sync");
}
hook Sstore _Lki.marketKinkParams[KEY LinearKinkIrm.Id id].baseRate uint64 val {
    ghostLkiBaseRate64[id] = val;
}

hook Sload uint64 val _Lki.marketKinkParams[KEY LinearKinkIrm.Id id].slope1 {
    require(require_uint64(ghostLkiSlope1_64[id]) == val, "SAFE: ghostLkiSlope1_64 sync");
}
hook Sstore _Lki.marketKinkParams[KEY LinearKinkIrm.Id id].slope1 uint64 val {
    ghostLkiSlope1_64[id] = val;
}

hook Sload uint64 val _Lki.marketKinkParams[KEY LinearKinkIrm.Id id].slope2 {
    require(require_uint64(ghostLkiSlope2_64[id]) == val, "SAFE: ghostLkiSlope2_64 sync");
}
hook Sstore _Lki.marketKinkParams[KEY LinearKinkIrm.Id id].slope2 uint64 val {
    ghostLkiSlope2_64[id] = val;
}

// getKinkParams model: four ghosts keyed by the config address, so the answer is fixed per config.

// LinearKinkConfig.MAX_BORROW_RATE = 8 ether / 365 days, the peak rate charged at full utilization.
definition MAX_BORROW_RATE_LKI_CVL() returns mathint = 253678335870;

persistent ghost mapping(address => mathint) ghostLkiCfgOptimalUtilization64 {
    // SAFE: the ABI width of the field the config returns.
    axiom forall address c.
        ghostLkiCfgOptimalUtilization64[c] >= 0 && ghostLkiCfgOptimalUtilization64[c] <= max_uint64;
}

persistent ghost mapping(address => mathint) ghostLkiCfgBaseRate64 {
    // SAFE: the ABI width of the field the config returns.
    axiom forall address c.
        ghostLkiCfgBaseRate64[c] >= 0 && ghostLkiCfgBaseRate64[c] <= max_uint64;
}

persistent ghost mapping(address => mathint) ghostLkiCfgSlope1_64 {
    // SAFE: the ABI width of the field the config returns.
    axiom forall address c.
        ghostLkiCfgSlope1_64[c] >= 0 && ghostLkiCfgSlope1_64[c] <= max_uint64;
}

persistent ghost mapping(address => mathint) ghostLkiCfgSlope2_64 {
    // SAFE: the ABI width of the field the config returns.
    axiom forall address c.
        ghostLkiCfgSlope2_64[c] >= 0 && ghostLkiCfgSlope2_64[c] <= max_uint64;
}

// The three conditions the LinearKinkConfig constructor enforces.
definition VALID_LKI_CONFIG(address c) returns bool =
    ghostLkiCfgOptimalUtilization64[c] > 0
    && ghostLkiCfgOptimalUtilization64[c] < WAD_MATH()
    && ghostLkiCfgBaseRate64[c] + ghostLkiCfgSlope1_64[c] + ghostLkiCfgSlope2_64[c]
        <= MAX_BORROW_RATE_LKI_CVL();

function getKinkParamsCVL(address config) returns LinearKinkIrm.LinearKinkParams {
    LinearKinkIrm.LinearKinkParams p;
    require(config != 0,
        "SAFE: a call to a codeless config reverts on chain");
    require(
        to_mathint(p.optimalUtilization) == ghostLkiCfgOptimalUtilization64[config]
        && to_mathint(p.baseRate) == ghostLkiCfgBaseRate64[config]
        && to_mathint(p.slope1) == ghostLkiCfgSlope1_64[config]
        && to_mathint(p.slope2) == ghostLkiCfgSlope2_64[config],
        "TRUSTED: a config answers with its own validated params on every call"
    );
    return p;
}
