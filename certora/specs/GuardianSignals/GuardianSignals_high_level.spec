// Each rule walks a concrete scenario: one named external call, or a sequence of them, then asserts the end-to-end
// law (conservation, isolation, monotonicity, a round trip).

import "GuardianSignals_valid_state.spec";

// GS-HL-01: A guardian flagging one account leaves every other account's strike count untouched.
rule hlGsFlagLeavesOtherAccounts(env e, GuardianSignals.Id id, address a,
    GuardianSignals.Id id2, address b, address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single flagged target");
    require(!(id2 == id && b == a), "SCOPE: a bystander cell, not the acted-on one");
    mathint lenBefore = ghostGsFlaggedByLen[id2][b];

    flag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByLen[id2][b] == lenBefore,
        "flag leaves other flagger sets untouched");
}

// GS-HL-02: An unban leaves every other account's ban exactly as it was.
rule hlGsUnbanLeavesOtherAccounts(env e, GuardianSignals.Id id, address a,
    GuardianSignals.Id id2, address b) {

    setupGuardianSignalsValidState(e);
    require(!(id2 == id && b == a), "SCOPE: a bystander cell, not the acted-on one");
    bool bannedBefore = ghostGsSigBanned[id2][b];

    unban(e, id, a);

    assert(ghostGsSigBanned[id2][b] == bannedBefore,
        "unban leaves other ban latches untouched");
}

// GS-HL-03: The cleanup never lifts a latched ban and latches one only when the surviving strikes reach quorum.
rule hlGsPruneKeepsBan(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool bannedBefore = ghostGsSigBanned[id][a];

    prune(e, id, a);

    assert((bannedBefore => ghostGsSigBanned[id][a])
        && ((!bannedBefore && ghostGsSigBanned[id][a])
            => ghostGsFlaggedByLen[id][a] >= ghostGsQuorum8),
        "prune keeps the ban latch and re-latches only at quorum");
}

// GS-HL-04: A guardian retracting a strike never lifts a ban and imposes one only when the strikes already reached the quorum.
rule hlGsUnflagKeepsBan(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single unflagged target");
    bool bannedBefore = ghostGsSigBanned[id][a];
    mathint strikesBefore = ghostGsFlaggedByLen[id][a];

    unflag(e, id, e.msg.sender, accounts);

    assert((bannedBefore => ghostGsSigBanned[id][a])
        && ((!bannedBefore && ghostGsSigBanned[id][a]) => strikesBefore >= ghostGsQuorum8),
        "unflag keeps the ban latch and writes one down only at quorum");
}

// GS-HL-05: A governance ban leaves the guardians' existing strikes on the account untouched.
rule hlGsBanKeepsFlaggers(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    ban(e, id, a);

    assert(ghostGsFlaggedByLen[id][a] == lenBefore,
        "ban keeps the flagger set");
}

// GS-HL-15: A guardian flagging the same account twice leaves its ban exactly as it was.
rule hlGsRepeatFlagLatchesNoBan(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single flagged target");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] != 0,
        "SCOPE: the caller already flagged the account");
    bool bannedBefore = ghostGsSigBanned[id][a];

    flag(e, id, e.msg.sender, accounts);

    assert(ghostGsSigBanned[id][a] == bannedBefore,
        "a repeat flag by an existing flagger writes no ban latch");
}

// GS-HL-06: The cleanup drops strikes cast by anyone no longer on the guardian committee.
rule hlGsPruneEvictsExGuardianFlag(env e, GuardianSignals.Id id, address a, address g) {

    setupGuardianSignalsValidState(e);
    require(ghostGsGuardianPositions[to_bytes32(g)] == 0, "SCOPE: not a live guardian");

    prune(e, id, a);

    assert(ghostGsFlaggedByPositions[id][a][to_bytes32(g)] == 0,
        "prune leaves no flag by a non-guardian");
}

// GS-HL-07: The cleanup drops suspect reports filed by anyone no longer on the guardian committee.
rule hlGsPruneEvictsExGuardianSuspect(env e, GuardianSignals.Id id, address a, address g) {

    setupGuardianSignalsValidState(e);
    require(ghostGsGuardianPositions[to_bytes32(g)] == 0, "SCOPE: not a live guardian");

    prune(e, id, a);

    assert(ghostGsSuspectedByPositions[id][a][to_bytes32(g)] == 0,
        "prune leaves no suspect report by a non-guardian");
}

// GS-HL-08: A guardian flagging then retracting leaves the account's strike count as it was.
rule hlGsFlagUnflagRoundTrip(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single flagged target");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "SCOPE: not yet a flagger");
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    flag(e, id, e.msg.sender, accounts);
    unflag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByLen[id][a] == lenBefore,
        "the round trip restores the strike count");
}

// GS-HL-09: Removing one guardian leaves every other committee member in place.
rule hlGsRemoveGuardianLeavesOtherMembers(env e, address g, address h) {

    setupGuardianSignalsValidState(e);
    require(h != g, "SCOPE: a bystander member, not the removed one");
    bool memberBefore = ghostGsGuardianPositions[to_bytes32(h)] != 0;

    removeGuardian(e, g);

    assert((ghostGsGuardianPositions[to_bytes32(h)] != 0) == memberBefore,
        "swap-and-pop evicts only its target");
}

// GS-HL-10: Adding a guardian changes no account's strike count and leaves the ban threshold where it was.
rule hlGsAddGuardianKeepsStrikes(env e, address g, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    mathint strikesBefore = ghostGsFlaggedByLen[id][a];
    mathint quorumBefore = ghostGsQuorum8;

    addGuardian(e, g);

    assert(ghostGsFlaggedByLen[id][a] == strikesBefore && ghostGsQuorum8 == quorumBefore,
        "rotation retallies no strikes and moves no strike threshold");
}

// GS-HL-11: Removing a guardian changes no account's strike count and leaves the ban threshold where it was.
rule hlGsRemoveGuardianKeepsStrikes(env e, address g, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    mathint strikesBefore = ghostGsFlaggedByLen[id][a];
    mathint quorumBefore = ghostGsQuorum8;

    removeGuardian(e, g);

    assert(ghostGsFlaggedByLen[id][a] == strikesBefore && ghostGsQuorum8 == quorumBefore,
        "rotation retallies no strikes and moves no strike threshold");
}

// GS-HL-12: Adding a guardian to the committee leaves every account's ban exactly as it was.
rule hlGsRotationKeepsBan(env e, address g, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool bannedBefore = ghostGsSigBanned[id][a];
    bool effectiveBefore = bannedBefore || ghostGsFlaggedByLen[id][a] >= ghostGsQuorum8;

    addGuardian(e, g);

    assert(ghostGsSigBanned[id][a] == bannedBefore
        && ((ghostGsSigBanned[id][a] || ghostGsFlaggedByLen[id][a] >= ghostGsQuorum8)
            == effectiveBefore),
        "rotation moves neither the ban latch nor the effective ban");
}

// GS-HL-13: A latched ban survives every call except an unban.
rule hlGsBanLiftedOnlyByUnban(env e, method f, calldataarg args, GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    bool bannedBefore = ghostGsSigBanned[id][a];

    f(e, args);

    bool bannedAfter = ghostGsSigBanned[id][a];

    assert((bannedBefore && !bannedAfter)
        => f.selector == sig:unban(GuardianSignals.Id, address).selector,
        "a latched ban is cleared only by unban");
}

// GS-HL-14: The permissionless cleanup can only relieve an account: never more strikes, no new ban, no later expiry.
rule hlGsPruneNeverWorsensOpinion(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    GuardianSignals.GuardiansOpinion opinionBefore = getOpinion(e, id, a);

    prune(e, id, a);

    GuardianSignals.GuardiansOpinion opinionAfter = getOpinion(e, id, a);

    assert(opinionAfter.strikeCount <= opinionBefore.strikeCount
        && (opinionAfter.banned => opinionBefore.banned)
        && (opinionBefore.suspectCount > 0
            => opinionAfter.suspectExpiryTimestamp <= opinionBefore.suspectExpiryTimestamp)
        && opinionAfter.quorumFrontierTimestamp == opinionBefore.quorumFrontierTimestamp,
        "prune may only drop strikes; it never puts a ban in force nor re-dates a counted suspicion later");
}

// GS-HL-16: The first suspect report on an account counts as exactly one live suspicion.
rule hlGsFirstSuspectReportCountsOne(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single suspected target");
    require(ghostGsSuspectedByLen[id][a] == 0,
        "SCOPE: an empty suspect set");

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSigSuspectCount16[id][a] == 1
        && ghostGsSigSuspectedAt40[id][a][e.msg.sender] == to_mathint(e.block.timestamp)
        && ghostGsSigSuspectReportedAt40[id][a] == to_mathint(e.block.timestamp),
        "the first report snapshots exactly one live suspicion");
}

// GS-HL-17: When the only reporting guardian retracts, the account's suspicion clears completely.
rule hlGsSoleReporterDrainsToZero(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single target");
    require(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] == 1,
        "SCOPE: the caller is the sole reporter");
    require(ghostGsSigSuspectedAt40[id][a][e.msg.sender] + ghostGsSuspectWindow40
            >= to_mathint(e.block.timestamp),
        "SCOPE: the caller's report is still inside the window");

    unsuspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == 0
        && ghostGsSigSuspectCount16[id][a] == 0
        && ghostGsSigSuspectedAt40[id][a][e.msg.sender] == 0
        && ghostGsSigSuspectReportedAt40[id][a] == 0,
        "retracting the sole live report drains the snapshot to zero");
}

// GS-HL-18: A new suspect report sweeps out a lapsed one, which never reaches the tally.
rule hlGsExpiredReportNotCounted(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single suspected target");
    require(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] == 1,
        "SCOPE: g holds the only standing report");
    require(g != e.msg.sender, "SCOPE: the caller files a distinct fresh report");
    require(ghostGsSigSuspectedAt40[id][a][g] + ghostGsSuspectWindow40
            < to_mathint(e.block.timestamp),
        "SCOPE: g's report has lapsed");

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] == 0
        && ghostGsSigSuspectedAt40[id][a][g] == 0
        && ghostGsSigSuspectCount16[id][a] == 1,
        "a lapsed report is pruned and never counted");
}

// GS-HL-19: A suspect report sitting exactly at the window edge still counts.
rule hlGsBoundaryReportStillCounted(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single suspected target");
    require(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] == 1,
        "SCOPE: g holds the only standing report");
    require(g != e.msg.sender, "SCOPE: the caller files a distinct fresh report");
    require(ghostGsSigSuspectedAt40[id][a][g] + ghostGsSuspectWindow40
            == to_mathint(e.block.timestamp),
        "SCOPE: g's report sits exactly at the window edge");

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == 2
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0
        && ghostGsSigSuspectCount16[id][a] == 2,
        "a report exactly at the window edge survives the sweep and counts");
}

// GS-HL-20: A guardian reporting the same account again refreshes its report without counting twice.
rule hlGsRepeatSuspectRefreshesStamp(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single suspected target");
    require(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] == 1,
        "SCOPE: the caller is already the sole reporter");
    require(ghostGsSigSuspectedAt40[id][a][e.msg.sender] + ghostGsSuspectWindow40
            >= to_mathint(e.block.timestamp),
        "SCOPE: the standing report is still fresh");

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSigSuspectCount16[id][a] == 1
        && ghostGsSigSuspectedAt40[id][a][e.msg.sender] == to_mathint(e.block.timestamp),
        "a repeat report refreshes the stamp without double-counting");
}

// GS-HL-21: Changing the quorum rewrites no signals and scores existing strikes against the new threshold.
rule hlGsSetQuorumBanCharacterization(env e, uint256 newQuorum,
    GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool latchBefore = ghostGsSigBanned[id][a];
    mathint strikesBefore = ghostGsFlaggedByLen[id][a];
    mathint countBefore = ghostGsSigSuspectCount16[id][a];
    mathint reportedAtBefore = ghostGsSigSuspectReportedAt40[id][a];

    setQuorum(e, newQuorum);
    bool effectiveAfter = isBanned(e, id, a);

    assert(ghostGsSigBanned[id][a] == latchBefore
        && ghostGsFlaggedByLen[id][a] == strikesBefore
        && ghostGsSigSuspectCount16[id][a] == countBefore
        && ghostGsSigSuspectReportedAt40[id][a] == reportedAtBefore,
        "setQuorum freezes every per-signal cell");
    assert(effectiveAfter == (latchBefore || strikesBefore >= to_mathint(newQuorum)),
        "the effective ban re-scores existing strikes against exactly the new quorum");
}

// GS-HL-22: A guardian's strike never touches the suspect reports standing against the same account.
rule hlGsFlagKeepsSoftChannel(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single flagged target");
    mathint suspLenBefore = ghostGsSuspectedByLen[id][a];
    mathint countBefore = ghostGsSigSuspectCount16[id][a];
    mathint reportedAtBefore = ghostGsSigSuspectReportedAt40[id][a];
    mathint stampBefore = ghostGsSigSuspectedAt40[id][a][g];

    flag(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == suspLenBefore
        && ghostGsSigSuspectCount16[id][a] == countBefore
        && ghostGsSigSuspectReportedAt40[id][a] == reportedAtBefore
        && ghostGsSigSuspectedAt40[id][a][g] == stampBefore,
        "a hard strike never leaks into the suspect channel");
}

// GS-HL-23: Retracting a strike never touches the suspect reports standing against the same account.
rule hlGsUnflagKeepsSoftChannel(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single unflagged target");
    mathint suspLenBefore = ghostGsSuspectedByLen[id][a];
    mathint countBefore = ghostGsSigSuspectCount16[id][a];
    mathint reportedAtBefore = ghostGsSigSuspectReportedAt40[id][a];
    mathint stampBefore = ghostGsSigSuspectedAt40[id][a][g];

    unflag(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == suspLenBefore
        && ghostGsSigSuspectCount16[id][a] == countBefore
        && ghostGsSigSuspectReportedAt40[id][a] == reportedAtBefore
        && ghostGsSigSuspectedAt40[id][a][g] == stampBefore,
        "a strike retraction never leaks into the suspect channel");
}

// GS-HL-24: A suspect report never adds a strike and never bans the account it names.
rule hlGsSuspectKeepsHardChannel(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single suspected target");
    bool bannedBefore = ghostGsSigBanned[id][a];
    mathint strikesBefore = ghostGsFlaggedByLen[id][a];
    mathint flagPosBefore = ghostGsFlaggedByPositions[id][a][to_bytes32(g)];

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSigBanned[id][a] == bannedBefore
        && ghostGsFlaggedByLen[id][a] == strikesBefore
        && ghostGsFlaggedByPositions[id][a][to_bytes32(g)] == flagPosBefore,
        "a soft report never leaks into the strike channel or the latch");
}

// GS-HL-25: Retracting a suspect report never changes an account's strikes or its ban.
rule hlGsUnsuspectKeepsHardChannel(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single unsuspected target");
    bool bannedBefore = ghostGsSigBanned[id][a];
    mathint strikesBefore = ghostGsFlaggedByLen[id][a];
    mathint flagPosBefore = ghostGsFlaggedByPositions[id][a][to_bytes32(g)];

    unsuspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSigBanned[id][a] == bannedBefore
        && ghostGsFlaggedByLen[id][a] == strikesBefore
        && ghostGsFlaggedByPositions[id][a][to_bytes32(g)] == flagPosBefore,
        "a soft retraction never leaks into the strike channel or the latch");
}

// GS-HL-26: After an unban the account no longer counts as banned, whatever strikes stood against it.
rule hlGsUnbanEndsEffectiveBan(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    unban(e, id, a);

    assert(!isBanned(e, id, a),
        "an unban leaves no effective ban behind");
}

// GS-HL-27: One batch call lands the guardian's strike on every account listed.
rule hlGsBatchFlagFlagsBothTargets(env e, GuardianSignals.Id id, address a, address b,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 2 && accounts[0] == a && accounts[1] == b,
        "SCOPE: a two-account batch");
    require(a != b, "SCOPE: distinct targets");

    flag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] != 0
        && ghostGsFlaggedByPositions[id][b][to_bytes32(e.msg.sender)] != 0,
        "one batch call lands the caller's strike on every listed account");
}

// GS-HL-28: Listing the same account twice in one call still lands a single strike.
rule hlGsBatchDuplicateFlagCountsOnce(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 2 && accounts[0] == a && accounts[1] == a,
        "SCOPE: the same account listed twice");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "SCOPE: the caller is a fresh flagger");
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    flag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByLen[id][a] == lenBefore + 1,
        "a duplicated batch entry lands a single strike");
}

// GS-HL-29: Changing the suspect window rewrites no signals and re-dates every expiry from the stored report time.
rule hlGsSetSuspectWindowExpiryCharacterization(env e, uint256 newWindow,
    GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool latchBefore = ghostGsSigBanned[id][a];
    mathint strikesBefore = ghostGsFlaggedByLen[id][a];
    mathint countBefore = ghostGsSigSuspectCount16[id][a];
    mathint reportedAtBefore = ghostGsSigSuspectReportedAt40[id][a];

    setSuspectWindow(e, newWindow);
    GuardianSignals.GuardiansOpinion opinionAfter = getOpinion(e, id, a);

    assert(ghostGsSigBanned[id][a] == latchBefore
        && ghostGsFlaggedByLen[id][a] == strikesBefore
        && ghostGsSigSuspectCount16[id][a] == countBefore
        && ghostGsSigSuspectReportedAt40[id][a] == reportedAtBefore,
        "setSuspectWindow freezes every per-signal cell");
    assert(to_mathint(opinionAfter.suspectExpiryTimestamp)
        == reportedAtBefore + to_mathint(newWindow),
        "the reported expiry re-scores the frozen snapshot against exactly the new window");
}

// GS-HL-30: Removing a guardian moves no account's ban, so the strikes that guardian already cast keep counting.
rule hlGsRemoveGuardianKeepsEffectiveBan(env e, address g, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool effectiveBefore = isBanned(e, id, a);

    removeGuardian(e, g);

    assert(isBanned(e, id, a) == effectiveBefore,
        "removal never moves the effective ban; a removed guardian's flag keeps counting");
}

// GS-HL-31: A suspect report that has lapsed on its own still counts in the account's reported suspicion.
rule hlGsStaleSuspectCountServedAfterExpiry(env e1, env e2, env e3, GuardianSignals.Id id, address a,
    address[] accounts1, address[] accounts2) {

    setupGuardianSignalsValidState(e1);
    setupEnv(e2);
    setupEnv(e3);
    require(accounts1.length == 1 && accounts1[0] == a, "SCOPE: single suspected target");
    require(accounts2.length == 1 && accounts2[0] == a, "SCOPE: single suspected target");
    require(ghostGsSuspectedByLen[id][a] == 0, "SCOPE: an empty suspect set");
    require(e1.msg.sender != e2.msg.sender, "SCOPE: two distinct reporters");

    mathint w = ghostGsSuspectWindow40;
    mathint t1 = e1.block.timestamp;
    mathint t2 = e2.block.timestamp;
    mathint t3 = e3.block.timestamp;
    require(t1 + w >= t2, "SCOPE: the first report is still fresh at the second snapshot");
    require(t1 + w < t3, "SCOPE: the first report has individually expired at the read");
    require(t2 + w >= t3, "SCOPE: the snapshot as a whole has not lapsed");

    suspect(e1, id, e1.msg.sender, accounts1);
    suspect(e2, id, e2.msg.sender, accounts2);

    GuardianSignals.GuardiansOpinion op = getOpinion(e3, id, a);

    assert(to_mathint(op.suspectCount) == 2
        && ghostGsSigSuspectedAt40[id][a][e1.msg.sender] + w < t3
        && to_mathint(op.suspectExpiryTimestamp) >= t3,
        "the served count still charges the individually-expired report");
}

// GS-HL-32: When one of two reporters retracts, the account's expiry follows the surviving report.
rule hlGsRetractionAnchorsToSurvivor(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single target");
    require(ghostGsSuspectedByLen[id][a] == 2
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0
        && ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] != 0,
        "SCOPE: g and the caller hold the only two reports");
    require(g != e.msg.sender, "SCOPE: distinct reporters");
    mathint gStamp = ghostGsSigSuspectedAt40[id][a][g];
    require(gStamp + ghostGsSuspectWindow40 >= to_mathint(e.block.timestamp)
        && ghostGsSigSuspectedAt40[id][a][e.msg.sender] + ghostGsSuspectWindow40
            >= to_mathint(e.block.timestamp),
        "SCOPE: both reports still live");

    unsuspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0
        && ghostGsSigSuspectCount16[id][a] == 1
        && ghostGsSigSuspectedAt40[id][a][g] == gStamp
        && ghostGsSigSuspectReportedAt40[id][a] == gStamp,
        "a retraction re-anchors the account to the surviving report, expiry and all");
}

// GS-HL-33: Another guardian's fresh report extends the expiry an older live report is scored by.
rule hlGsFreshReportExtendsSurvivorExpiry(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single suspected target");
    require(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] == 1,
        "SCOPE: g holds the only standing report");
    require(g != e.msg.sender, "SCOPE: the caller files a distinct fresh report");
    mathint gStamp = ghostGsSigSuspectedAt40[id][a][g];
    require(gStamp + ghostGsSuspectWindow40 >= to_mathint(e.block.timestamp),
        "SCOPE: g's report is still live");
    require(gStamp < to_mathint(e.block.timestamp),
        "SCOPE: g's report is strictly older than the touch");

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id][a] == 2
        && ghostGsSigSuspectCount16[id][a] == 2
        && ghostGsSigSuspectedAt40[id][a][g] == gStamp
        && ghostGsSigSuspectReportedAt40[id][a] == to_mathint(e.block.timestamp)
        && ghostGsSigSuspectReportedAt40[id][a] + ghostGsSuspectWindow40
            > gStamp + ghostGsSuspectWindow40,
        "a still-fresh earlier report is counted into the new snapshot and rides its extended expiry");
}

// GS-HL-35: The cleanup ends a ban only by evicting the strikes behind it, never by clearing a latch.
rule hlGsPruneNeverLiftsLatchedBan(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool latchBefore = ghostGsSigBanned[id][a];
    bool effectiveBefore = isBanned(e, id, a);

    prune(e, id, a);

    assert((effectiveBefore && !isBanned(e, id, a))
        => (!latchBefore && ghostGsFlaggedByLen[id][a] < ghostGsQuorum8),
        "the prune lifts a ban only by evicting ex-guardian flags below quorum");
}

// GS-HL-36: Retracting a suspect report never pushes an account's suspicion expiry later.
rule hlGsRetractionNeverExtendsExpiry(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single target");
    require(ghostGsSuspectedByLen[id][a] == 2
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0
        && ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] != 0,
        "SCOPE: g and the caller hold the only two reports");
    require(g != e.msg.sender, "SCOPE: distinct reporters");
    require(ghostGsSigSuspectedAt40[id][a][g] + ghostGsSuspectWindow40 >= to_mathint(e.block.timestamp)
        && ghostGsSigSuspectedAt40[id][a][e.msg.sender] + ghostGsSuspectWindow40
            >= to_mathint(e.block.timestamp),
        "SCOPE: both reports still live");
    mathint anchorBefore = ghostGsSigSuspectReportedAt40[id][a];
    require(anchorBefore < to_mathint(e.block.timestamp),
        "SCOPE: the account was last touched strictly earlier");
    require(ghostGsSigSuspectCount16[id][a] > 0,
        "SCOPE: excludes the stale-empty suspect snapshot");

    unsuspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSigSuspectReportedAt40[id][a] <= anchorBefore,
        "a retraction never pushes the account anchor forward");
}
