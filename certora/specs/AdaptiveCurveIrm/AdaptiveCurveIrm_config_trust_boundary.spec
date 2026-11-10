// One witness rule: an authorized applier applies a config the AdaptiveCurveConfig constructor would have
// rejected and lifts a market's rate at target above the ceiling every validated config shares. The config
// model here drops leg (b) of the config assumption, and the witness is designed behaviour, not a finding.

import "../setup/env.spec";
import "../setup/marketParamsLib.spec";
import "../setup/Irm/adaptiveCurveMath.spec";

methods {
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    function _.getCurveParams() external
        => getCurveParamsUnvalidatedCVL()
        expect AdaptiveCurveIrm.AdaptiveCurveParams ALL;
}

definition MAX_RATE_AT_TARGET_LIMIT_TB_CVL() returns mathint = 317097919837645;

// The production model with every range dropped: an arbitrary address answers with arbitrary parameters.
function getCurveParamsUnvalidatedCVL() returns AdaptiveCurveIrm.AdaptiveCurveParams {
    AdaptiveCurveIrm.AdaptiveCurveParams p;
    return p;
}

// ACI-TB-01: A config the constructor would have rejected can push a live market's target rate above the shared ceiling.
rule tbAciUnvalidatedConfigLiftsRateAboveTheSharedCeiling(env e,
    AdaptiveCurveIrm.MarketParams marketParams, address config) {

    setupEnv(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    require(e.msg.sender == owner(e), "SCOPE: the owner as the caller");
    require(config != 0, "SCOPE: a nonzero config address");

    mathint rateBefore = to_mathint(rateAtTarget(e, id));

    require(rateBefore != 0, "SCOPE: a priced market");
    require(rateBefore <= MAX_RATE_AT_TARGET_LIMIT_TB_CVL(),
        "SCOPE: a rate that starts under the shared ceiling");

    applyIrmConfig(e, marketParams, config);

    mathint rateAfter = to_mathint(rateAtTarget(e, id));

    satisfy(rateAfter > MAX_RATE_AT_TARGET_LIMIT_TB_CVL() && rateAfter != rateBefore,
        "an unvalidated config can move a market that started inside the shared band above its ceiling");
}
