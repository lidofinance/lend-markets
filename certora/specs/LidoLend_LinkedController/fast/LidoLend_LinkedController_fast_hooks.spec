// Fast twins of two linked scene settle properties, driving the controller's Settle hook against a CVL core
// model. They take the seizure and canceled debt from the payload rather than core storage, an equality
// assumed here; the second twin keeps only the first assert.

import "../../LidoLendMarketController/LidoLendMarketController_valid_state.spec";
import "../../setup/LidoLendMarketController/LidoLendMarketController_core_view.spec";
import "../../setup/GuardianSignals/GuardianSignals_cvl.spec";

using LidoLendMarketControllerHookEncoder as _HookEncoder;

// Fast twin of CL-HL-03; the payload's seizedAssets is the parent's collateral delta.
rule hlLwcSettleSeizureDrainsBucketsExactly(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SettleHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(id == ghostMcMarketId,
        "SCOPE: the bound market");

    mathint buckets0 = ghostMcPosActivating128[d.borrower] + ghostMcPosDust128[d.borrower];
    requireBucketsWithinCollateral(d.borrower);
    mathint active0 = to_mathint(ghostLlCvlPosCollateral[d.borrower]) - buckets0;

    bytes data = _HookEncoder.encodeSettle(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Settle, data);

    mathint buckets1 = ghostMcPosActivating128[d.borrower] + ghostMcPosDust128[d.borrower];
    mathint uncovered = to_mathint(d.seizedAssets) > active0 ? to_mathint(d.seizedAssets) - active0 : 0;

    assert(buckets1 == buckets0 - uncovered,
        "a settlement drains the buckets by exactly the uncovered amount");
}

// Fast twin of CL-HL-11, first assert; the supply anchored closing assert stays with the parent.
rule hlLwcSettleStrandsAtMostSubWeiDebt(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SettleHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(id == ghostMcMarketId,
        "SCOPE: the bound market");
    require(ghostMcHeapNodesLength >= 2 && d.borrower == ghostMcHeapNodeAccount[1],
        "SCOPE: the settled borrower is the queue root");
    require(ghostMcSetLtvStepBps16 == 0 && ghostMcSettlementLtv256[d.borrower] == 0,
        "SCOPE: the two dividing slice rules are off");

    mathint tBA0 = ghostLlCvlTotalBorrowAssets;
    mathint tBS0 = ghostLlCvlTotalBorrowShares;
    mathint price = ghostOraclePrice256[ghostLlCvlOracle];
    require(price != 0,
        "SCOPE: a nonzero oracle price");

    require(to_mathint(d.borrowSharesCanceled) <= to_mathint(ghostLlCvlPosBorrowShares[d.borrower]),
        "SCOPE: a core payload, whose canceled shares stay within the borrower's debt");
    require(to_mathint(d.borrowAssetsCanceled)
            == toAssetsUpLlCVL(d.borrowSharesCanceled, tBA0, tBS0),
        "SCOPE: a core payload, whose canceled assets price the shares up");
    require(to_mathint(d.seizedAssets)
            == toAssetsDownLlCVL(d.borrowSharesCanceled, tBA0, tBS0)
                * ORACLE_PRICE_SCALE_LL_CVL() / price,
        "SCOPE: a core payload, whose seizure prices the shares down at the oracle rate");
    require(d.seizedAssets != 0,
        "SCOPE: a core payload, carrying a nonzero seizure");

    mathint borrowShares0 = ghostLlCvlPosBorrowShares[d.borrower];

    bytes data = _HookEncoder.encodeSettle(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Settle, data);

    mathint left = borrowShares0 - d.borrowSharesCanceled;

    assert(to_mathint(d.seizedAssets) == to_mathint(ghostLlCvlPosCollateral[d.borrower])
            => left * (tBA0 + VIRTUAL_ASSETS_LL_CVL()) < tBS0 + VIRTUAL_SHARES_LL_CVL(),
        "a fully seized position keeps fewer debt shares than one loan asset buys at the pre cut index");
}
