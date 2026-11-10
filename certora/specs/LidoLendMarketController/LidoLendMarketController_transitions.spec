// Each rule bounds how storage may move in any single call: snapshot it, invoke any external method, assert
// the law; first a single variable's own band, then the co-change of the variables that move together.

import "LidoLendMarketController_valid_state.spec";
import "../setup/LidoLend/LidoLend_cvl.spec";
import "../setup/GuardianSignals/GuardianSignals_cvl.spec";

// MC-VT-01: The controller stays bound to one market and can never be repointed at another.
rule vtMcMarketIdFrozen(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    LidoLendMarketController.Id marketIdBefore = ghostMcMarketId;

    f(e, args);

    LidoLendMarketController.Id marketIdAfter = ghostMcMarketId;

    assert(marketIdAfter == marketIdBefore, "the controlled market id never changes");
}

// MC-VT-02: The guardian registry the controller consults for bans and strikes can never be replaced.
rule vtMcGuardianRegistryFrozen(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    address registryBefore = ghostMcGuardianSignals;

    f(e, args);

    address registryAfter = ghostMcGuardianSignals;

    assert(registryAfter == registryBefore, "the guardian-signals registry never changes");
}

// MC-VT-03: The settlement queue grows or shrinks by at most one borrower per call, and never loses its reserved first slot.
rule vtMcHeapLengthStepsByOne(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    mathint lengthBefore = ghostMcHeapNodesLength;

    f(e, args);

    mathint lengthAfter = ghostMcHeapNodesLength;

    assert(lengthAfter <= lengthBefore + 1 && lengthBefore <= lengthAfter + 1,
        "the heap length changes by at most one node per call");
    assert(lengthBefore >= 1 => lengthAfter >= 1,
        "and an initialized heap keeps its index-0 sentinel");
}

// MC-VT-04: The settlement queue's reserved first slot never changes.
rule vtMcHeapSentinelUntouched(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    address sentinelAccountBefore = ghostMcHeapNodeAccount[0];
    mathint sentinelKeyBefore = ghostMcHeapNodeKey256[0];

    f(e, args);

    address sentinelAccountAfter = ghostMcHeapNodeAccount[0];
    mathint sentinelKeyAfter = ghostMcHeapNodeKey256[0];

    assert(sentinelAccountAfter == sentinelAccountBefore,
        "the index-0 sentinel account is never modified");
    assert(sentinelKeyAfter == sentinelKeyBefore,
        "the index-0 sentinel key is never modified");
}

// MC-VT-05: The inflow throttle's decay clock is only ever stamped with the current time.
rule vtMcInflowClockLandsAtNow(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    mathint clockBefore = ghostMcActInflowUpdatedAt40;

    f(e, args);

    mathint clockAfter = ghostMcActInflowUpdatedAt40;

    assert(clockAfter == clockBefore || clockAfter == to_mathint(e.block.timestamp),
        "the inflow snapshot clock is only ever stamped with the current block time");
}

// MC-VT-06: A borrower's activation timer is only ever cleared or started at the current time.
rule vtMcTimerStartClearsOrLandsAtNow(env e, method f, calldataarg args, address b)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    mathint startBefore = ghostMcPosActivatingStart40[b];

    f(e, args);

    mathint startAfter = ghostMcPosActivatingStart40[b];

    assert(startAfter == startBefore || startAfter == 0
        || startAfter == to_mathint(e.block.timestamp),
        "the activation-timer start is only ever cleared or set to the current block time");
}

// MC-VT-07: The time a pause ends is never moved into the past.
rule vtMcResumeStampNeverPast(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    mathint resumeBefore = ghostMcResumeSinceTimestamp256;

    f(e, args);

    mathint resumeAfter = ghostMcResumeSinceTimestamp256;

    assert(resumeAfter == resumeBefore || resumeAfter >= to_mathint(e.block.timestamp),
        "a moved resume timestamp is never strictly in the past");
}

// MC-VT-08: The activation wait floor is never set back to zero.
rule vtMcMinActivationDelayNeverZeroed(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bool setBefore = ghostMcCfgMinActivationDelay40 != 0;

    f(e, args);

    assert(setBefore => ghostMcCfgMinActivationDelay40 != 0,
        "the minimum activation delay never returns to zero");
}

// MC-VT-09: The threshold a deposit must reach to enter activation is never set back to zero.
rule vtMcMinActivationAmountNeverZeroed(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bool setBefore = ghostMcCfgMinActivationAmount128 != 0;

    f(e, args);

    assert(setBefore => ghostMcCfgMinActivationAmount128 != 0,
        "the minimum activation amount never returns to zero");
}

// MC-VT-10: The inflow reference the activation wait scales against is never set back to zero.
rule vtMcMaxDelayInflowNeverZeroed(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bool setBefore = ghostMcCfgMaxDelayInflow128 != 0;

    f(e, args);

    assert(setBefore => ghostMcCfgMaxDelayInflow128 != 0,
        "the max delay inflow never returns to zero");
}

// MC-ST-01: Adding collateral never pulls a borrower's stored unlock deadline earlier.
rule stMcActivatingDeadlineMonotone(env e, method f, calldataarg args, address b)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketControllerValidState(e);
    mathint actBefore = ghostMcPosActivating128[b];
    mathint startBefore = ghostMcPosActivatingStart40[b];
    mathint delayBefore = ghostMcPosActivatingDelay32[b];

    f(e, args);

    assert(ghostMcPosActivating128[b] > actBefore
        => ghostMcPosActivatingStart40[b] + ghostMcPosActivatingDelay32[b]
            >= startBefore + delayBefore,
        "a top-up never shortens the stored base deadline");
}

// MC-ST-02: A borrower joining the settlement queue adds exactly one entry to it.
rule stMcEnqueueGrowsHeap(env e, method f, calldataarg args, address a)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketControllerValidState(e);
    uint256 slotBefore = ghostMcHeapSlot[a];
    mathint lenBefore = ghostMcHeapNodesLength;

    f(e, args);

    assert((slotBefore == 0 && ghostMcHeapSlot[a] != 0)
        => ghostMcHeapNodesLength == lenBefore + 1,
        "a first-time enqueue appends exactly one node");
}

// MC-ST-03: A borrower leaving the settlement queue removes exactly one entry from it.
rule stMcDequeueShrinksHeap(env e, method f, calldataarg args, address a)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketControllerValidState(e);
    uint256 slotBefore = ghostMcHeapSlot[a];
    mathint lenBefore = ghostMcHeapNodesLength;

    f(e, args);

    assert((slotBefore != 0 && ghostMcHeapSlot[a] == 0)
        => ghostMcHeapNodesLength == lenBefore - 1,
        "a removal pops exactly one node");
}

// MC-ST-04: Any rise in the inflow throttle restarts its decay clock at the current time.
rule stMcInflowStampsSnapshot(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketControllerValidState(e);
    mathint inflowBefore = ghostMcActInflow128;

    f(e, args);

    assert(ghostMcActInflow128 > inflowBefore
        => ghostMcActInflowUpdatedAt40 == to_mathint(e.block.timestamp),
        "an inflow increase refreshes the snapshot clock");
}

// MC-ST-05: Only the borrower themselves can move their own settlement target.
rule stMcSettlementLtvSelfService(env e, method f, calldataarg args, address b)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketControllerValidState(e);
    mathint ltvBefore = ghostMcSettlementLtv256[b];

    f(e, args);

    assert(ghostMcSettlementLtv256[b] != ltvBefore => b == e.msg.sender,
        "only the borrower moves their settlement ltv");
}

// MC-ST-06: Collateral entering the activation timer is metered into the inflow throttle, up to its ceiling.
rule stMcTimerEntryFeedsThrottle(env e, method f, calldataarg args, address b)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketControllerValidState(e);
    mathint activatingBefore = ghostMcPosActivating128[b];

    f(e, args);

    mathint activatingDelta = ghostMcPosActivating128[b] - activatingBefore;

    assert(activatingDelta > 0
        => (ghostMcActInflow128 >= activatingDelta
            || ghostMcActInflow128 >= ghostMcCfgMaxDelayInflow128),
        "collateral entering the timer is metered as inflow, up to the throttle cap");
}
