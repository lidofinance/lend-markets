// Each rule bounds how storage may move in any single call: snapshot it, invoke any external method, assert
// the law; first a single variable's own band, then the co-change of the variables that move together.

import "GuardianSignals_valid_state.spec";

// GS-VT-01: A guardian's last scan time only moves forward or resets to zero.
rule vtGsHeartbeatRisesOrClears(env e, method f, calldataarg args, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    mathint heartbeatBefore = ghostGsHeartbeats40[g];

    f(e, args);

    mathint heartbeatAfter = ghostGsHeartbeats40[g];

    assert(heartbeatAfter >= heartbeatBefore || heartbeatAfter == 0,
        "a recorded liveness beat only moves forward or clears to zero");
}

// GS-VT-02: The committee gains or loses at most one member per call.
rule vtGsCommitteeSizeStepsByOne(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    mathint lenBefore = ghostGsGuardiansLen;

    f(e, args);

    mathint lenAfter = ghostGsGuardiansLen;

    assert(lenAfter >= lenBefore - 1 && lenAfter <= lenBefore + 1,
        "the committee gains or loses at most one member per call");
}

// GS-VT-03: A guardian's suspect report time only moves forward or resets to zero.
rule vtGsSuspectStampRisesOrClears(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    requireInvariant suspectedAtNotInFuture(e);
    mathint stampBefore = ghostGsSigSuspectedAt40[id][a][g];

    f(e, args);

    mathint stampAfter = ghostGsSigSuspectedAt40[id][a][g];

    assert(stampAfter == 0 || stampAfter >= stampBefore,
        "a suspect stamp only refreshes forward or clears to zero");
}

// GS-VT-04: An account's strike list gains at most one guardian per call.
rule vtGsFlaggerSetGrowsByOne(env e, method f, calldataarg args, GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    f(e, args);

    mathint lenAfter = ghostGsFlaggedByLen[id][a];

    assert(lenAfter <= lenBefore + 1,
        "the flagger set gains at most one member per call");
}

// GS-VT-05: An account's suspect list gains at most one guardian per call.
rule vtGsSuspectSetGrowsByOne(env e, method f, calldataarg args, GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    mathint lenBefore = ghostGsSuspectedByLen[id][a];

    f(e, args);

    mathint lenAfter = ghostGsSuspectedByLen[id][a];

    assert(lenAfter <= lenBefore + 1,
        "the suspect set gains at most one member per call");
}

// GS-ST-01: When an account's suspect tally changes, its date is cleared or set to a report still in force.
rule stGsSnapshotRestamped(env e, method f, calldataarg args, GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    mathint countBefore = ghostGsSigSuspectCount16[id][a];

    f(e, args);

    mathint countAfter = ghostGsSigSuspectCount16[id][a];
    mathint reportedAfter = ghostGsSigSuspectReportedAt40[id][a];

    assert(countAfter != countBefore
        => ((countAfter == 0 => reportedAfter == 0)
            && (countAfter > 0
                => (reportedAfter <= to_mathint(e.block.timestamp)
                    && reportedAfter + ghostGsSuspectWindow40 >= to_mathint(e.block.timestamp)))),
        "suspect count changes only with an anchor that is itself a live report");
}

// GS-ST-02: A ban latched by a new strike fires only once the strikes reach quorum.
rule stGsFlagLatchNeedsQuorum(env e, method f, calldataarg args, GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    bool bannedBefore = ghostGsSigBanned[id][a];
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    f(e, args);

    assert((!bannedBefore && ghostGsSigBanned[id][a] && ghostGsFlaggedByLen[id][a] > lenBefore)
        => ghostGsFlaggedByLen[id][a] >= ghostGsQuorum8,
        "a flag-driven latch requires the flagger set at quorum");
}

// GS-ST-03: Only a sitting committee member's scan time can move.
rule stGsHeartbeatSeatOnly(env e, method f, calldataarg args, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    bool isGuardianBefore = ghostGsGuardianPositions[to_bytes32(g)] != 0;
    mathint hbBefore = ghostGsHeartbeats40[g];

    f(e, args);

    assert(ghostGsHeartbeats40[g] != hbBefore => isGuardianBefore,
        "only a sitting guardian's heartbeat moves");
}

// GS-ST-04: A guardian joining an account's suspect set is stamped with the current time.
rule stGsSuspectAddStampsSeat(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    mathint positionBefore = ghostGsSuspectedByPositions[id][a][to_bytes32(g)];

    f(e, args);

    assert((positionBefore == 0 && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0)
        => ghostGsSigSuspectedAt40[id][a][g] == to_mathint(e.block.timestamp),
        "a fresh report carries the time it joined the suspect set");
}

// GS-VT-08: A call never leaves a seated guardian's hot key sitting on the committee itself.
rule vtGsDelegateNeverBecomesASeat(env e, method f, calldataarg args, address g, address d)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    requireInvariant onlyASeatHoldsADelegate(e);
    require((ghostGsGuardianPositions[to_bytes32(g)] != 0 && ghostGsDelegates[g] == d && d != 0)
        => ghostGsGuardianPositions[to_bytes32(d)] == 0,
        "SAFE: no seated guardian's key holds a seat before the call");

    f(e, args);

    assert((ghostGsGuardianPositions[to_bytes32(g)] != 0 && ghostGsDelegates[g] == d && d != 0)
        => ghostGsGuardianPositions[to_bytes32(d)] == 0,
        "no seated guardian's key holds a seat after the call");
}
