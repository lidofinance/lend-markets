// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external call. Other spec
// files then assume them through setupGuardianSignalsValidState, which narrows the Prover's storage havoc to
// reachable states and so cuts the false counterexamples those files hit.

import "../setup/GuardianSignals/GuardianSignals.spec";

function requireGuardianSignalsInvariants(env e) {
    requireGsEnumerableSetCoherence();
    requireInvariant suspectStampImpliesMembership(e);
    requireInvariant membershipImpliesSuspectStamp(e);
    requireInvariant heartbeatNotInFuture(e);
    requireInvariant suspectedAtNotInFuture(e);
    requireInvariant quorumBoundedByCommittee(e);
    requireInvariant suspectWindowBounded(e);
    requireInvariant suspectSnapshotNotInFuture(e);
    requireInvariant suspectCountBoundedByCommittee(e);
    requireInvariant suspectCountAnchoredBySnapshot(e);
    requireInvariant emptyCountImpliesZeroSnapshot(e);
    requireInvariant suspectTimestampBoundedBySnapshot(e);
    requireInvariant quorumAtLeastOne(e);
}

function setupGuardianSignalsValidState(env e) {
    setupGuardianSignals(e);
    requireGuardianSignalsInvariants(e);
}

function SETUP_GS(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupGuardianSignals(e);
}

function SETUP_CORE_GS(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupGuardianSignalsCore(e);
}

function SETUP_FULL_GS(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupGuardianSignals(e);
    requireGuardianSignalsInvariants(e);
}

// GS-VS-01: A guardian's report time is stored only while its suspect report stands.
invariant suspectStampImpliesMembership(env e)
    forall GuardianSignals.Id id. forall address a. forall address g.
        ghostGsSigSuspectedAt40[id][a][g] != 0
            => ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_FULL_GS(e, eFunc); } }

// GS-VS-02: Every live suspect report on an account carries the time it was filed.
invariant membershipImpliesSuspectStamp(env e)
    forall GuardianSignals.Id id. forall address a. forall address g.
        ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0
            => ghostGsSigSuspectedAt40[id][a][g] != 0
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_FULL_GS(e, eFunc); } }

// GS-VS-03: A guardian's last scanned time never runs ahead of the current time.
invariant heartbeatNotInFuture(env e)
    forall address g. ghostGsHeartbeats40[g] <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_GS(e, eFunc); } }

// GS-VS-04: A guardian's suspect report is never dated in the future.
invariant suspectedAtNotInFuture(env e)
    forall GuardianSignals.Id id. forall address a. forall address g.
        ghostGsSigSuspectedAt40[id][a][g] <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_GS(e, eFunc); } }

// GS-VS-05: The ban quorum never requires more votes than the committee has guardians.
invariant quorumBoundedByCommittee(env e)
    ghostGsQuorum8 <= ghostGsGuardiansLen
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_GS(e, eFunc); } }

// GS-VS-06: The suspect window never exceeds the contract's hard cap of 30 days.
invariant suspectWindowBounded(env e)
    ghostGsSuspectWindow40 <= to_mathint(_Signals.MAX_SUSPECT_WINDOW())
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_GS(e, eFunc); } }

// GS-VS-07: The report date recorded for an account is never in the future.
invariant suspectSnapshotNotInFuture(env e)
    forall GuardianSignals.Id id. forall address a.
        ghostGsSigSuspectReportedAt40[id][a] <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) {
    SETUP_GS(e, eFunc);
    requireInvariant suspectedAtNotInFuture(e);
} }

// GS-VS-08: An account's suspect count never exceeds the modeled size of the guardian committee.
invariant suspectCountBoundedByCommittee(env e)
    forall GuardianSignals.Id id. forall address a.
        ghostGsSigSuspectCount16[id][a] <= MAX_COMMITTEE_GS_CVL()
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_GS(e, eFunc); } }

// GS-VS-09: An account with a live suspect count always carries a report date.
invariant suspectCountAnchoredBySnapshot(env e)
    forall GuardianSignals.Id id. forall address a.
        ghostGsSigSuspectCount16[id][a] > 0 => ghostGsSigSuspectReportedAt40[id][a] > 0
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_FULL_GS(e, eFunc); } }

// GS-VS-10: An account with no suspect count carries no report date either.
invariant emptyCountImpliesZeroSnapshot(env e)
    forall GuardianSignals.Id id. forall address a.
        ghostGsSigSuspectCount16[id][a] == 0 => ghostGsSigSuspectReportedAt40[id][a] == 0
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) {
    SETUP_GS(e, eFunc);
    requireInvariant membershipImpliesSuspectStamp(e);
} }

// GS-VS-11: While an account's suspect count stands, no report on it is dated after the recorded date.
invariant suspectTimestampBoundedBySnapshot(env e)
    forall GuardianSignals.Id id. forall address a. forall address g.
        ghostGsSigSuspectCount16[id][a] > 0
            => ghostGsSigSuspectedAt40[id][a][g] <= ghostGsSigSuspectReportedAt40[id][a]
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_FULL_GS(e, eFunc); } }

// GS-VS-12: Once the contract is initialized, the ban quorum is at least one guardian.
invariant quorumAtLeastOne(env e)
    ghostGsInitialized64 == 1 => ghostGsQuorum8 >= 1
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_CORE_GS(e, eFunc); } }

// GS-VS-15: Only an account that holds a committee seat carries an appointed hot key.
invariant onlyASeatHoldsADelegate(env e)
    forall address g.
        ghostGsDelegates[g] != 0 => ghostGsGuardianPositions[to_bytes32(g)] != 0
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_CORE_GS(e, eFunc); } }

// GS-VS-14: The stored suspect tally never counts more reports than the account actually carries.
invariant suspectCountWithinLiveSet(env e)
    forall GuardianSignals.Id id. forall address a.
        ghostGsSigSuspectCount16[id][a] <= ghostGsSuspectedByLen[id][a]
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) { SETUP_FULL_GS(e, eFunc); } }
