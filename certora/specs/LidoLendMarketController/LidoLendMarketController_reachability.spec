// Each rule witnesses that a call can succeed and take real effect

import "LidoLendMarketController_valid_state.spec";
import "../setup/LidoLend/LidoLend_cvl.spec";
import "../setup/GuardianSignals/GuardianSignals_cvl.spec";

// Scene-only encoder: turns a typed hook payload into the bytes on() decodes.
using LidoLendMarketControllerHookEncoder as _HookEncoder;

// MC-RC-01: The manager can move the floor or the ceiling on the activation wait.
rule rcMcSetCollateralActivationConfigIsReachable(env e,
    LidoLendMarketController.CollateralActivationConfig cfg) {

    setupLidoLendMarketControllerValidState(e);
    mathint minBefore = ghostMcCfgMinActivationDelay40;
    mathint maxBefore = ghostMcCfgMaxActivationDelay40;

    setCollateralActivationConfig(e, cfg);

    satisfy(ghostMcCfgMinActivationDelay40 != minBefore || ghostMcCfgMaxActivationDelay40 != maxBefore,
        "the manager can install a new activation delay band");
}

// MC-RC-02: The manager can change how deep a settlement may cut a borrower's debt.
rule rcMcSetSettlementConfigIsReachable(env e, LidoLendMarketController.SettlementConfig config) {

    setupLidoLendMarketControllerValidState(e);
    mathint sliceBefore = ghostMcSetSliceFloorBps16;
    mathint stepBefore = ghostMcSetLtvStepBps16;

    setSettlementConfig(e, config);

    satisfy(ghostMcSetSliceFloorBps16 != sliceBefore || ghostMcSetLtvStepBps16 != stepBefore,
        "the manager can install new settlement cut knobs");
}

// MC-RC-03: A borrow can add a new borrower to the settlement queue.
rule rcMcOnBorrowGrowsHeapIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    require(ev == ILidoLendMarketController.HookEvent.Borrow,
        "SCOPE: witness the Borrow dispatch arm");
    mathint lenBefore = ghostMcHeapNodesLength;

    on(e, id, ev, data);

    satisfy(ghostMcHeapNodesLength == lenBefore + 1,
        "a borrow hook can enqueue a fresh borrower into the settlement heap");
}

// MC-RC-04: A collateral deposit can enter the activation timer.
rule rcMcOnSupplyCollateralCreditsActivatingIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, address borrower) {

    setupLidoLendMarketControllerValidState(e);
    require(ev == ILidoLendMarketController.HookEvent.SupplyCollateral, "SCOPE: witness the SupplyCollateral arm");
    mathint actBefore = ghostMcPosActivating128[borrower];

    on(e, id, ev, data);

    satisfy(ghostMcPosActivating128[borrower] > actBefore,
        "a supply-collateral hook can credit a borrower's activating bucket");
}

// MC-RC-05: A borrower can withdraw dust or collateral that is still waiting to activate.
rule rcMcOnWithdrawCollateralDebitsBucketsIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, address borrower) {

    setupLidoLendMarketControllerValidState(e);
    require(ev == ILidoLendMarketController.HookEvent.WithdrawCollateral, "SCOPE: witness the WithdrawCollateral arm");
    mathint dustBefore = ghostMcPosDust128[borrower];
    mathint actBefore = ghostMcPosActivating128[borrower];

    on(e, id, ev, data);

    satisfy(ghostMcPosDust128[borrower] < dustBefore
        || (ghostMcPosActivating128[borrower] > 0 && ghostMcPosActivating128[borrower] < actBefore),
        "a withdraw-collateral hook can debit a borrower's dust or activating bucket");
}

// MC-RC-06: A borrower can repay the whole debt and leave the settlement queue.
rule rcMcOnRepayShrinksHeapIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, address borrower) {

    setupLidoLendMarketControllerValidState(e);
    require(ev == ILidoLendMarketController.HookEvent.Repay,
        "SCOPE: witness the Repay dispatch arm");
    mathint lenBefore = ghostMcHeapNodesLength;
    uint256 slotBefore = ghostMcHeapSlot[borrower];

    on(e, id, ev, data);

    satisfy(ghostMcHeapNodesLength == lenBefore - 1 && slotBefore != 0
        && ghostMcHeapSlot[borrower] == 0 && ghostLlCvlPosCollateral[borrower] > 0,
        "a repay-to-zero hook can drive a borrower out of the settlement heap");
}

// MC-RC-07: A settled borrower can leave the settlement queue.
rule rcMcOnSettleShrinksHeapIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, address borrower) {

    setupLidoLendMarketControllerValidState(e);
    require(ev == ILidoLendMarketController.HookEvent.Settle,
        "SCOPE: witness the Settle dispatch arm");
    mathint lenBefore = ghostMcHeapNodesLength;
    uint256 slotBefore = ghostMcHeapSlot[borrower];

    on(e, id, ev, data);

    satisfy(ghostMcHeapNodesLength == lenBefore - 1 && slotBefore != 0
        && ghostMcHeapSlot[borrower] == 0,
        "a settle hook can drive a borrower out of the settlement heap");
}

// MC-RC-08: A liquidation can seize dust or collateral still waiting to activate.
rule rcMcOnLiquidateSeizesBucketsIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, address borrower) {

    setupLidoLendMarketControllerValidState(e);
    require(ev == ILidoLendMarketController.HookEvent.Liquidate,
        "SCOPE: witness the Liquidate dispatch arm");
    mathint bucketsBefore = ghostMcPosDust128[borrower] + ghostMcPosActivating128[borrower];

    on(e, id, ev, data);

    satisfy(ghostMcPosDust128[borrower] + ghostMcPosActivating128[borrower] < bucketsBefore,
        "a liquidate hook can seize a borrower's dust or activating collateral");
}

// MC-RC-09: A deposit can fill the market exactly to its supply cap and still pass.
rule rcMcOnSupplyPassesLiveCapIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(d.assets > 0,
        "SCOPE: a deposit that moves the market");
    require(to_mathint(ghostLlCvlTotalSupplyAssets) + to_mathint(d.assets) == ghostMcSupplyCap256,
        "SCOPE: the deposit lands on the cap itself");
    mathint totalsBefore = to_mathint(ghostLlCvlTotalSupplyAssets);

    bytes data = _HookEncoder.encodeSupply(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Supply, data);

    satisfy(ghostMcSupplyCap256 > 0 && to_mathint(d.assets) > 0
        && totalsBefore + to_mathint(d.assets) == ghostMcSupplyCap256,
        "a real deposit can land exactly on a live finite supply cap and still pass the cap check");
}

// MC-RC-10: A lender withdrawal and an interest accrual can pass the policy hook carrying no data.
rule rcMcOnNoOpEventsSucceedWithEmptyPayloadIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev1, bytes d1,
    ILidoLendMarketController.HookEvent ev2, bytes d2) {

    setupLidoLendMarketControllerValidState(e);
    require(ev1 == ILidoLendMarketController.HookEvent.Withdraw,
        "SCOPE: witness the Withdraw arm, which decodes no payload");
    require(ev2 == ILidoLendMarketController.HookEvent.AccrueInterest,
        "SCOPE: witness the AccrueInterest arm, which decodes no payload");

    on(e, id, ev1, d1);
    on(e, id, ev2, d2);

    satisfy(d1.length == 0 && d2.length == 0,
        "the recognized no-op hooks succeed without any payload to decode");
}

// MC-RC-11: The first borrower can enter an empty settlement queue.
rule rcMcOnFirstEnqueueFromEmptyHeapIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    mathint lenBefore = ghostMcHeapNodesLength;

    on(e, id, ev, data);

    satisfy(lenBefore == 1 && ghostMcHeapNodesLength == 2,
        "the first enqueue can grow the heap from its sentinel-only state");
}

// MC-RC-12: A queued borrower's risk ranking can change while the queue keeps its size.
rule rcMcOnRekeysNodeAtFullHeapIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, uint256 i) {

    setupLidoLendMarketControllerValidState(e);
    mathint keyBefore = ghostMcHeapNodeKey256[i];
    mathint lenBefore = ghostMcHeapNodesLength;

    on(e, id, ev, data);

    satisfy(lenBefore == MAX_HEAP_NODES_MC_CVL() + 1 && ghostMcHeapNodesLength == lenBefore
        && to_mathint(i) >= 1 && to_mathint(i) < lenBefore && ghostMcHeapNodeKey256[i] != keyBefore,
        "a hook can re-key a live node while the narrowed heap window is full");
}

// MC-RC-13: The market can be frozen and then unfrozen again.
rule rcMcFreezeThenUnfreezeIsReachable(env e) {

    setupLidoLendMarketControllerValidState(e);
    bool frozenBefore = ghostMcIsFrozen;

    freeze(e);
    bool frozenMid = ghostMcIsFrozen;
    unfreeze(e);

    satisfy(!frozenBefore && frozenMid && !ghostMcIsFrozen,
        "the market can round-trip through frozen and back to running");
}

// MC-RC-14: The market can be paused and then resumed before the pause expires.
rule rcMcPauseThenResumeIsReachable(env e, uint256 duration) {

    setupLidoLendMarketControllerValidState(e);
    mathint resumeB0 = ghostMcResumeSinceTimestamp256;

    pauseFor(e, duration);
    mathint resumeMid = ghostMcResumeSinceTimestamp256;
    resume(e);

    satisfy(resumeB0 <= to_mathint(e.block.timestamp) && resumeMid > to_mathint(e.block.timestamp)
        && ghostMcResumeSinceTimestamp256 <= to_mathint(e.block.timestamp),
        "the controller can round-trip through paused and back to running");
}

// MC-RC-15: A borrower's chosen settlement target can be read back exactly as it was set.
rule rcMcSetThenReadSettlementLtvIsReachable(env e, uint256 ltv) {

    setupLidoLendMarketControllerValidState(e);

    setSettlementLtv(e, ltv);
    uint256 readLtv; uint256 sliceAssets;
    readLtv, sliceAssets = settlementLtv(e, e.msg.sender);

    satisfy(to_mathint(readLtv) == to_mathint(ltv) && readLtv > 0,
        "a fresh opt-in reads back through the settlement ltv view");
}

// MC-RC-16: The pause can be lifted while the market stays frozen.
rule rcMcResumeWhileFrozenIsReachable(env e) {

    setupLidoLendMarketControllerValidState(e);
    bool frozenBefore = ghostMcIsFrozen;
    mathint resumeBefore = ghostMcResumeSinceTimestamp256;

    resume(e);

    satisfy(frozenBefore && resumeBefore > to_mathint(e.block.timestamp)
        && ghostMcResumeSinceTimestamp256 <= to_mathint(e.block.timestamp),
        "the resumer can resume a paused controller while the market is frozen");
}

// MC-RC-17: The settlement queue can name a real borrower to settle next.
rule rcMcNextSettlementBorrowerRealIsReachable(env e, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);

    address borrower; LidoLendMarketController.SettlementSlice slice;
    borrower, slice = nextSettlementBorrower(e, budgetSupplyShares);

    satisfy(borrower != 0,
        "the settlement-queue root can expose a real borrower");
}

// MC-RC-18: The market can report bad debt on the borrower first in line to settle.
rule rcMcHasBadDebtIsReachable(env e) {

    setupLidoLendMarketControllerValidState(e);

    bool bad = hasBadDebt(e);

    satisfy(bad,
        "the settlement-queue root can be a bad-debt position");
}

// MC-RC-19: A borrower can be quoted a positive settlement cut.
rule rcMcSettlementForSizesPositiveCutIsReachable(env e, address borrower, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);

    LidoLendMarketController.SettlementQuote quote = settlementFor(e, borrower, budgetSupplyShares);

    satisfy(quote.queueRoot.borrowShares > 0,
        "the settlement sizing can cut a positive borrow-share slice");
}

// MC-RC-20: The market can still report room to deposit while a supply cap is set.
rule rcMcMaxDepositPositiveUnderCapIsReachable(env e) {

    setupLidoLendMarketControllerValidState(e);

    mathint room = maxDeposit(e);

    satisfy(room > 0 && ghostMcSupplyCap256 > 0,
        "the market can report positive deposit room under a live finite cap");
}

// MC-RC-21: A lender can be shown a positive withdrawable amount.
rule rcMcMaxWithdrawableAssetsPositiveIsReachable(env e, address supplier) {

    setupLidoLendMarketControllerValidState(e);

    mathint withdrawable = maxWithdrawableAssets(e, supplier);

    satisfy(withdrawable > 0,
        "a supplier can have positive withdrawable assets");
}

// MC-RC-22: A bigger deposit can face a strictly longer activation wait.
rule rcMcActivationDelayStrictlyGrowsIsReachable(env e, uint256 x, uint256 y) {

    setupLidoLendMarketControllerValidState(e);

    mathint delayX = currentActivationDelay(e, x);
    mathint delayY = currentActivationDelay(e, y);

    satisfy(x < y && delayX < delayY,
        "a larger inflow increment can quote a strictly longer activation delay");
}

// MC-RC-23: The last borrower leaving can return the settlement queue to empty.
rule rcMcOnLastDequeueEmptiesHeapIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    mathint lenBefore = ghostMcHeapNodesLength;

    on(e, id, ev, data);

    satisfy(lenBefore == 2 && ghostMcHeapNodesLength == 1,
        "the last dequeue can return the heap to its sentinel-only state");
}

// MC-RC-24: A trusted caller's large deposit can count as active at once with no timer.
rule rcMcOnSupplyCollateralInstantActivationIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcInstantActivationCallers[d.caller],
        "SCOPE: witness pin, a granted caller");
    mathint inflowBefore = ghostMcActInflow128;

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    satisfy(to_mathint(d.assets) >= ghostMcCfgMinActivationAmount128
        && ghostMcPosActivating128[d.onBehalf] == 0
        && ghostMcPosActivatingStart40[d.onBehalf] == 0
        && ghostMcActInflow128 == inflowBefore,
        "a granted caller's deposit past the threshold can land active with no timer and no throttle charge");
}

// MC-RC-25: A deposit below the threshold can stay dust and leave the timed lot alone.
rule rcMcOnSupplyCollateralDustStaysIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, address borrower) {

    setupLidoLendMarketControllerValidState(e);
    require(ev == ILidoLendMarketController.HookEvent.SupplyCollateral,
        "SCOPE: witness the sub-threshold dust arm of SupplyCollateral");
    mathint dustBefore = ghostMcPosDust128[borrower];
    mathint actBefore = ghostMcPosActivating128[borrower];

    on(e, id, ev, data);

    satisfy(ghostMcPosDust128[borrower] > dustBefore && ghostMcPosActivating128[borrower] == actBefore,
        "a sub-threshold deposit can stay dust with the activating lot untouched");
}

// MC-RC-26: An unflagged borrower's collateral can mature the moment its wait elapses.
rule rcMcOnBorrowMaturesLotIsReachable(env e, LidoLendMarketController.Id id, bytes data, address b) {

    setupLidoLendMarketControllerValidState(e);
    mathint act0 = ghostMcPosActivating128[b];
    mathint start0 = ghostMcPosActivatingStart40[b];
    mathint delay0 = ghostMcPosActivatingDelay32[b];
    mathint dust0 = ghostMcPosDust128[b];

    on(e, id, ILidoLendMarketController.HookEvent.Borrow, data);

    satisfy(act0 > 0 && ghostMcPosActivating128[b] == 0 && ghostMcPosDust128[b] == dust0
        && to_mathint(e.block.timestamp) == start0 + delay0
        && ghostGsCvlStrikeCount[ghostMcMarketId][b] == 0
        && ghostGsCvlSuspectCount[ghostMcMarketId][b] == 0,
        "a borrow hook can mature a lot at exactly start + delay");
}

// MC-RC-27: A deposit can pass the cap check with the market total below the cap.
rule rcMcOnSupplyWithCapHeadroomIsReachable(env e, LidoLendMarketController.Id id, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    mathint totalsBefore = to_mathint(ghostLlCvlTotalSupplyAssets);

    on(e, id, ILidoLendMarketController.HookEvent.Supply, data);

    satisfy(totalsBefore < ghostMcSupplyCap256,
        "a supply hook can pass a live cap with strictly positive headroom");
}

// MC-RC-28: A flagged deposit can still mature on the fallback when guardians have not scanned it.
rule rcMcOnBorrowFallbackMaturesSurchargedLotIsReachable(env e, LidoLendMarketController.Id id,
    bytes data, address b) {

    setupLidoLendMarketControllerValidState(e);
    mathint act0 = ghostMcPosActivating128[b];
    mathint start0 = ghostMcPosActivatingStart40[b];
    mathint delay0 = ghostMcPosActivatingDelay32[b];
    mathint surcharge = ghostGsCvlStrikeCount[ghostMcMarketId][b] * ghostMcCfgDelayPerStrike40
        + (start0 < ghostGsCvlSuspectExpiry256[ghostMcMarketId][b]
            ? ghostGsCvlSuspectCount[ghostMcMarketId][b] * ghostMcCfgDelayPerSuspect40 : 0);
    mathint unlock = start0 + delay0 + surcharge;

    on(e, id, ILidoLendMarketController.HookEvent.Borrow, data);

    satisfy(act0 > 0 && ghostMcPosActivating128[b] == 0 && surcharge > 0
        && ghostMcCfgMaxGuardiansQuorumDelay40 != 0
        && unlock >= start0 + ghostMcCfgMaxGuardiansQuorumDelay40
        && ghostGsCvlQuorumFrontier40 < unlock
        && to_mathint(e.block.timestamp) >= unlock,
        "a surcharged lot can mature on the fallback alone with the quorum behind");
}

// MC-RC-29: A trusted caller's deposit can leave a borrower's existing dust exactly where it was.
rule rcMcOnSupplyCollateralInstantDustStaysIsReachable(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcInstantActivationCallers[d.caller], "SCOPE: witness pin, a granted caller");
    mathint dustBefore = ghostMcPosDust128[d.onBehalf];
    require(dustBefore > 0, "SCOPE: witness pin, the borrower already holds dust");
    mathint actBefore = ghostMcPosActivating128[d.onBehalf];

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    satisfy(d.assets > 0 && ghostMcPosDust128[d.onBehalf] == dustBefore
        && ghostMcPosActivating128[d.onBehalf] == actBefore,
        "a granted caller's deposit can leave the dust already held exactly where it was");
}

// MC-RC-30: Collateral past its unlock can still read as waiting until a market action matures it.
rule rcMcMaturedLotReportedActivatingIsReachable(env e, address b) {

    setupLidoLendMarketControllerValidState(e);
    mathint start = ghostMcPosActivatingStart40[b];
    mathint delay = ghostMcPosActivatingDelay32[b];
    mathint actBefore = ghostMcPosActivating128[b];
    mathint surcharge = ghostGsCvlStrikeCount[ghostMcMarketId][b] * ghostMcCfgDelayPerStrike40
        + (start < ghostGsCvlSuspectExpiry256[ghostMcMarketId][b]
            ? ghostGsCvlSuspectCount[ghostMcMarketId][b] * ghostMcCfgDelayPerSuspect40 : 0);
    mathint unlock = start + delay + surcharge;
    bool banned = ghostGsCvlBanned[ghostMcMarketId][b];
    bool quorumGateOpen = unlock <= ghostGsCvlQuorumFrontier40
        || to_mathint(e.block.timestamp) >= start + ghostMcCfgMaxGuardiansQuorumDelay40;

    ILidoLendMarketController.BorrowerPosition dash = positionOf(e, b);

    satisfy(start != 0 && !banned && to_mathint(e.block.timestamp) >= unlock && quorumGateOpen
        && to_mathint(dash.activating) == actBefore && actBefore > 0,
        "a matured lot the view still reports as activating");
}

// Permitting direction: what the gates must still let through.

// MC-RC-31: A borrower can still repay while the market is frozen.
rule rcMcOnRepayNotBlockedByFreeze(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.RepayHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcIsFrozen, "SCOPE: the frozen market");

    bytes data = _HookEncoder.encodeRepay(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Repay, data);

    satisfy(true, "a freeze never blocks a repayment");
}

// MC-RC-32: A banned borrower can still repay their debt.
rule rcMcOnRepayNotBlockedByBan(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.RepayHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostGsCvlBanned[id][d.caller], "SCOPE: the paying caller is banned");
    require(ghostGsCvlBanned[id][d.onBehalf], "SCOPE: the repaying borrower is banned");

    bytes data = _HookEncoder.encodeRepay(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Repay, data);

    satisfy(true, "a ban never blocks a repayment");
}

// MC-RC-33: A debt-free borrower can still withdraw collateral under both a freeze and a ban.
rule rcMcOnWithdrawCollateralDebtFreeExitNotBlocked(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcIsFrozen && ghostGsCvlBanned[id][d.caller]
            && ghostGsCvlBanned[id][d.onBehalf]
            && ghostLlCvlPosBorrowShares[d.onBehalf] == 0,
        "SCOPE: a debt-free exit under both gates");
    require(d.assets != 0, "SCOPE: a withdrawal that moves collateral, not a zero-amount call");

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);

    satisfy(true, "a debt-free collateral exit clears both the freeze and the ban");
}

// MC-RC-34: A banned address can still deposit collateral into the market.
rule rcMcOnSupplyCollateralNotBlockedByBan(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostGsCvlBanned[id][d.onBehalf] && ghostGsCvlBanned[id][d.caller],
        "SCOPE: both the depositor and the position owner are banned");

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    satisfy(true, "a banned address still deposits collateral");
}

// MC-RC-35: A withdrawal can carry a borrower's whole inactive holding away in one call and leave the timer cleared.
rule rcMcOnWithdrawCollateralClearsWholeHoldingIsReachable(env e, LidoLendMarketController.Id id,
    bytes data, address borrower) {

    setupLidoLendMarketControllerValidState(e);
    mathint heldBefore = ghostMcPosDust128[borrower] + ghostMcPosActivating128[borrower];
    require(ghostMcPosActivatingStart40[borrower] == 0
            || to_mathint(e.block.timestamp) < ghostMcPosActivatingStart40[borrower]
                + ghostMcPosActivatingDelay32[borrower],
        "SCOPE: the lot is not yet due");

    on(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);

    satisfy(heldBefore > 0 && ghostMcPosDust128[borrower] == 0
        && ghostMcPosActivating128[borrower] == 0
        && ghostMcPosActivatingStart40[borrower] == 0,
        "a withdraw-collateral hook can clear the whole inactive holding at once");
}
