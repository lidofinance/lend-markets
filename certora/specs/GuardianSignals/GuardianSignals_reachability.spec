// Each rule witnesses that a call can succeed and take real effect

import "GuardianSignals_valid_state.spec";

// GS-RC-01: A manager can add a new guardian and the committee grows.
rule rcGsAddGuardianIsReachable(env e, address guardian) {

    setupGuardianSignalsValidState(e);
    mathint lenBefore = ghostGsGuardiansLen;

    addGuardian(e, guardian);

    satisfy(ghostGsGuardiansLen > lenBefore && ghostGsGuardianPositions[to_bytes32(guardian)] != 0,
        "the manager can add a fresh guardian to the committee");
}

// GS-RC-02: A manager can remove a guardian while the committee stays at or above quorum.
rule rcGsRemoveGuardianIsReachable(env e, address guardian) {

    setupGuardianSignalsValidState(e);
    mathint lenBefore = ghostGsGuardiansLen;

    removeGuardian(e, guardian);

    satisfy(ghostGsGuardiansLen < lenBefore && ghostGsGuardianPositions[to_bytes32(guardian)] == 0,
        "the manager can remove a guardian while staying at or above quorum");
}

// GS-RC-03: A guardian can report a heartbeat that advances its last scanned time.
rule rcGsHeartbeatIsReachable(env e, GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);
    mathint hbBefore = ghostGsHeartbeats40[e.msg.sender];

    heartbeat(e, e.msg.sender, blk);

    satisfy(ghostGsHeartbeats40[e.msg.sender] > hbBefore
        && ghostGsHeartbeats40[e.msg.sender] == to_mathint(blk.timestamp),
        "a guardian heartbeat advances the caller's scan stamp to the reported block time");
}

// GS-RC-04: A guardian can retract its strike and leave the account's strike list.
rule rcGsUnflagIsReachable(env e, GuardianSignals.Id id, address a, address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single unflagged target");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] != 0,
        "SCOPE: the caller holds the flag it retracts");
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    unflag(e, id, e.msg.sender, accounts);

    satisfy(ghostGsFlaggedByLen[id][a] < lenBefore
        && ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "a guardian can retract its flag, leaving the flagger set");
}

// GS-RC-05: A guardian can retract its suspect report, clearing the time it was filed.
rule rcGsUnsuspectIsReachable(env e, GuardianSignals.Id id, address a, address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single unsuspected target");
    require(ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] != 0,
        "SCOPE: the caller holds a live suspect report");
    require(ghostGsSigSuspectedAt40[id][a][e.msg.sender] + ghostGsSuspectWindow40 >= to_mathint(e.block.timestamp),
        "SCOPE: the caller's report is still inside the window");
    mathint lenBefore = ghostGsSuspectedByLen[id][a];

    unsuspect(e, id, e.msg.sender, accounts);

    satisfy(ghostGsSuspectedByLen[id][a] < lenBefore
        && ghostGsSigSuspectedAt40[id][a][e.msg.sender] == 0,
        "a guardian can retract its suspect report, clearing its stamp");
}

// GS-RC-06: Anyone can prune a former guardian's stale strike from an account.
rule rcGsPruneIsReachable(env e, GuardianSignals.Id id, address a, address g) {

    setupGuardianSignalsValidState(e);
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(g)] != 0,
        "SCOPE: g is a live entry in the flagger set");
    require(ghostGsGuardianPositions[to_bytes32(g)] == 0,
        "SCOPE: g has left the committee");
    require(ghostGsFlaggedByLen[id][a] == 1 && ghostGsSuspectedByLen[id][a] == 0,
        "SCOPE: a single flag and an empty suspect set");
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    prune(e, id, a);

    satisfy(ghostGsFlaggedByLen[id][a] < lenBefore
        && ghostGsFlaggedByPositions[id][a][to_bytes32(g)] == 0,
        "permissionless prune can drop an ex-guardian's stale flag");
}

// GS-RC-07: An access limiter can force a ban on an account.
rule rcGsBanIsReachable(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    require(!ghostGsSigBanned[id][a],
        "SCOPE: the account starts unbanned");

    ban(e, id, a);

    satisfy(ghostGsSigBanned[id][a],
        "an access limiter can force-latch a ban");
}

// GS-RC-08: A manager can remove a guardian, leaving the committee exactly at quorum.
rule rcGsRemoveGuardianDownToQuorumIsReachable(env e, address guardian) {

    setupGuardianSignalsValidState(e);
    require(ghostGsGuardiansLen == ghostGsQuorum8 + 1,
        "SCOPE: committee exactly one above quorum");

    removeGuardian(e, guardian);

    satisfy(ghostGsGuardiansLen == ghostGsQuorum8
        && ghostGsGuardianPositions[to_bytes32(guardian)] == 0,
        "the boundary removal lands the committee exactly at quorum");
}

// GS-RC-09: A strike that brings the count up to quorum can ban the account.
rule rcGsFlagLatchesBanAtQuorumIsReachable(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single flagged target");
    require(!ghostGsSigBanned[id][a],
        "SCOPE: the latch starts clear");
    require(ghostGsFlaggedByLen[id][a] == ghostGsQuorum8 - 1,
        "SCOPE: one flag short of quorum");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "SCOPE: the caller is not yet a flagger");

    flag(e, id, e.msg.sender, accounts);

    satisfy(ghostGsSigBanned[id][a] && ghostGsFlaggedByLen[id][a] == ghostGsQuorum8,
        "a quorum-crossing flag latches the ban");
}

// GS-RC-10: An access restorer can lift a ban and clear the strikes behind it.
rule rcGsUnbanClearsFlaggersIsReachable(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    require(ghostGsSigBanned[id][a],
        "SCOPE: the account starts banned");
    require(ghostGsFlaggedByLen[id][a] > 0,
        "SCOPE: a non-empty flagger set");

    unban(e, id, a);

    satisfy(!ghostGsSigBanned[id][a] && ghostGsFlaggedByLen[id][a] == 0,
        "an unban lifts the latch and clears the flagger set together");
}

// GS-RC-11: The last guardian to retract can clear an account's strikes entirely.
rule rcGsUnflagEmptiesSetIsReachable(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single unflagged target");
    require(ghostGsFlaggedByLen[id][a] == 1
        && ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 1,
        "SCOPE: the caller is the sole flagger");

    unflag(e, id, e.msg.sender, accounts);

    satisfy(ghostGsFlaggedByLen[id][a] == 0,
        "the last flag retraction can empty the flagger set");
}

// GS-RC-12: Anyone can prune a former guardian's stale suspect report from an account.
rule rcGsPruneDropsStaleSuspectIsReachable(env e, GuardianSignals.Id id, address a, address g) {

    setupGuardianSignalsValidState(e);
    require(ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0,
        "SCOPE: g is a live entry in the suspect set");
    require(ghostGsGuardianPositions[to_bytes32(g)] == 0,
        "SCOPE: g has left the committee");
    mathint lenBefore = ghostGsSuspectedByLen[id][a];

    prune(e, id, a);

    satisfy(ghostGsSuspectedByLen[id][a] < lenBefore
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] == 0
        && ghostGsSigSuspectedAt40[id][a][g] == 0,
        "permissionless prune can drop an ex-guardian's stale suspect report");
}

// GS-RC-13: A second guardian can add its own strike to the same account.
rule rcGsSecondDistinctFlaggerIsReachable(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single flagged target");
    require(ghostGsFlaggedByLen[id][a] > 0
        && ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "SCOPE: a prior flagger and a distinct new caller");
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    flag(e, id, e.msg.sender, accounts);

    satisfy(ghostGsFlaggedByLen[id][a] == lenBefore + 1
        && ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] != 0,
        "a second distinct guardian can join the flagger set");
}

// GS-RC-14: A second guardian can file its own suspect report on the same account.
rule rcGsSecondDistinctSuspecterIsReachable(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single suspected target");
    require(ghostGsSuspectedByLen[id][a] > 0
        && ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "SCOPE: a prior suspecter and a distinct new caller");
    mathint lenBefore = ghostGsSuspectedByLen[id][a];

    suspect(e, id, e.msg.sender, accounts);

    satisfy(ghostGsSuspectedByLen[id][a] == lenBefore + 1
        && ghostGsSigSuspectedAt40[id][a][e.msg.sender] == to_mathint(e.block.timestamp),
        "a second distinct guardian can join the suspect set");
}

// GS-RC-15: A newly seated guardian can report a heartbeat in the same block.
rule rcGsAddThenHeartbeatIsReachable(env e, env e2, address guardian,
    GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);
    setupGuardianSignalsValidState(e2);
    require(e2.block.timestamp == e.block.timestamp && e2.block.number == e.block.number
        && e2.msg.sender == guardian,
        "SCOPE: the freshly added guardian calls heartbeat in the same block");

    addGuardian(e, guardian);
    heartbeat(e2, e2.msg.sender, blk);

    satisfy(ghostGsHeartbeats40[guardian] > 0
        && ghostGsHeartbeats40[guardian] == to_mathint(blk.timestamp),
        "a freshly added guardian can immediately report a heartbeat");
}

// GS-RC-16: A guardian can flag an account and then retract, restoring the count.
rule rcGsFlagThenUnflagRoundTripIsReachable(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target for both calls");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "SCOPE: the caller starts outside the flagger set");
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    flag(e, id, e.msg.sender, accounts);
    mathint lenMid = ghostGsFlaggedByLen[id][a];
    unflag(e, id, e.msg.sender, accounts);

    satisfy(lenMid == lenBefore + 1 && ghostGsFlaggedByLen[id][a] == lenBefore,
        "a flag followed by its retraction returns the flagger set to baseline");
}

// GS-RC-17: Lowering the quorum can ban an account with no new flag.
rule rcGsQuorumLoweringRetroBansIsReachable(env e, uint256 newQuorum,
    GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool effectiveBefore = isBanned(e, id, a);

    setQuorum(e, newQuorum);
    bool effectiveAfter = isBanned(e, id, a);

    satisfy(!effectiveBefore && effectiveAfter,
        "a quorum lowering can retro-latch an effective ban with no new flag");
}

// GS-RC-18: Raising the quorum can lift a ban that was never written down.
rule rcGsQuorumRaiseUnbansUnlatchedIsReachable(env e, uint256 newQuorum,
    GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool effectiveBefore = isBanned(e, id, a);

    setQuorum(e, newQuorum);
    bool effectiveAfter = isBanned(e, id, a);

    satisfy(effectiveBefore && !effectiveAfter,
        "a quorum raise can silently drop an effective-but-never-latched ban");
}

// GS-RC-19: A retraction can record the ban already in force before the strike count drops.
rule rcGsUnflagLatchesBeforeDropIsReachable(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single unflagged target");
    bool latchBefore = ghostGsSigBanned[id][a];
    bool effectiveBefore = isBanned(e, id, a);

    unflag(e, id, e.msg.sender, accounts);

    satisfy(!latchBefore && effectiveBefore
        && ghostGsSigBanned[id][a]
        && ghostGsFlaggedByLen[id][a] < ghostGsQuorum8,
        "a retraction writes down the ban its own strike was carrying");
}

// GS-RC-20: An account can carry one guardian's strike and another guardian's unexpired suspect report.
rule rcGsOpinionPopulatedIsReachable(env e1, env e2, GuardianSignals.Id id, address a,
    address[] accounts1, address[] accounts2) {

    setupGuardianSignalsValidState(e1);
    setupEnv(e2);
    require(accounts1.length == 1 && accounts1[0] == a,
        "SCOPE: single flagged target");
    require(accounts2.length == 1 && accounts2[0] == a,
        "SCOPE: single suspected target");
    require(e1.msg.sender != e2.msg.sender,
        "SCOPE: the strike and the suspect report come from two distinct seats");
    require(e1.block.timestamp <= e2.block.timestamp,
        "SCOPE: the flag lands no later than the suspect report");
    require(ghostGsFlaggedByLen[id][a] == 0 && ghostGsSuspectedByLen[id][a] == 0,
        "SCOPE: both sets start empty");

    flag(e1, id, e1.msg.sender, accounts1);
    suspect(e2, id, e2.msg.sender, accounts2);

    GuardianSignals.GuardiansOpinion op = getOpinion(e2, id, a);

    satisfy(op.strikeCount > 0 && op.suspectCount > 0
        && to_mathint(op.suspectExpiryTimestamp) > to_mathint(e2.block.timestamp),
        "a flag and a suspect report build an opinion with a strike and a live suspect surcharge");
}

// GS-RC-21: An account can count as banned on flag count alone, with no ban stored.
rule rcGsDynamicBanWithoutLatchIsReachable(env e, uint256 newQuorum,
    GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    require(!ghostGsSigBanned[id][a],
        "SCOPE: no stored latch to start from");
    require(ghostGsFlaggedByLen[id][a] < ghostGsQuorum8,
        "SCOPE: the flags stand below the quorum in force before the call");

    setQuorum(e, newQuorum);
    bool effective = isBanned(e, id, a);

    satisfy(effective && !ghostGsSigBanned[id][a],
        "a quorum lowering can leave an effective ban standing on flags alone, with no stored latch");
}

// GS-RC-22: A guardian can file a suspect report and then retract it, restoring the count.
rule rcGsSuspectThenUnsuspectRoundTripIsReachable(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target for both calls");
    require(ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "SCOPE: the caller starts outside the suspect set");
    mathint lenBefore = ghostGsSuspectedByLen[id][a];

    suspect(e, id, e.msg.sender, accounts);
    mathint lenMid = ghostGsSuspectedByLen[id][a];
    unsuspect(e, id, e.msg.sender, accounts);

    satisfy(lenMid == lenBefore + 1 && ghostGsSuspectedByLen[id][a] == lenBefore,
        "a suspect report followed by its retraction returns the suspect set to baseline");
}

// GS-RC-23: An unbanned account can be flagged straight back into a ban.
rule rcGsRelatchAfterUnbanIsReachable(env e, env e2, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    setupGuardianSignalsValidState(e2);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single flagged target");
    require(e2.block.timestamp == e.block.timestamp && e2.block.number == e.block.number,
        "SCOPE: the re-flag lands in the same block");
    require(ghostGsSigBanned[id][a], "SCOPE: the account starts banned");

    unban(e, id, a);
    flag(e2, id, e2.msg.sender, accounts);

    satisfy(ghostGsSigBanned[id][a],
        "an unbanned account can be re-flagged straight back into a latched ban");
}

// GS-RC-24: Shortening the suspect window alone can expire a live suspicion.
rule rcGsWindowCutRetroExpiresIsReachable(env e, uint256 newWindow,
    GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    GuardianSignals.GuardiansOpinion before = getOpinion(e, id, a);
    setSuspectWindow(e, newWindow);
    GuardianSignals.GuardiansOpinion after = getOpinion(e, id, a);

    satisfy(before.suspectCount > 0 && after.suspectCount == before.suspectCount
        && to_mathint(before.suspectExpiryTimestamp) > to_mathint(e.block.timestamp)
        && to_mathint(after.suspectExpiryTimestamp) <= to_mathint(e.block.timestamp),
        "a window cut alone can retro-expire a live suspect snapshot");
}

// GS-RC-28: An account can be shown a suspicion that rests only on a lapsed report.
rule rcGsStaleSuspectCountIsReachable(env e1, env e2, env e3, GuardianSignals.Id id, address a,
    address[] accounts1, address[] accounts2) {

    setupGuardianSignalsValidState(e1);
    setupEnv(e2);
    setupEnv(e3);
    require(accounts1.length == 1 && accounts1[0] == a,
        "SCOPE: single suspected target");
    require(accounts2.length == 1 && accounts2[0] == a,
        "SCOPE: single suspected target");
    require(ghostGsSuspectedByLen[id][a] == 0,
        "SCOPE: an empty suspect set");
    require(e1.msg.sender != e2.msg.sender,
        "SCOPE: two distinct reporters");
    require(e1.block.timestamp <= e2.block.timestamp && e2.block.timestamp <= e3.block.timestamp,
        "SCOPE: the two reports and the read run in time order");

    suspect(e1, id, e1.msg.sender, accounts1);
    suspect(e2, id, e2.msg.sender, accounts2);

    GuardianSignals.GuardiansOpinion op = getOpinion(e3, id, a);

    satisfy(op.suspectCount == 2
        && ghostGsSigSuspectedAt40[id][a][e1.msg.sender] + ghostGsSuspectWindow40 < to_mathint(e3.block.timestamp)
        && to_mathint(op.suspectExpiryTimestamp) >= to_mathint(e3.block.timestamp),
        "a stale over-count is served while the snapshot is unexpired");
}

// GS-RC-29: A departed guardian's strike can be the one that tips an account into a ban.
rule rcGsStaleFlagCompletesQuorumIsReachable(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single flagged target");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(g)] != 0
        && ghostGsGuardianPositions[to_bytes32(g)] == 0,
        "SCOPE: g's flag survived its removal from the committee");
    require(!ghostGsSigBanned[id][a],
        "SCOPE: the latch starts clear");
    require(ghostGsFlaggedByLen[id][a] == ghostGsQuorum8 - 1,
        "SCOPE: one flag short of quorum, counting g's stale flag");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "SCOPE: the caller is a fresh flagger");

    flag(e, id, e.msg.sender, accounts);

    satisfy(ghostGsSigBanned[id][a]
        && ghostGsFlaggedByPositions[id][a][to_bytes32(g)] != 0
        && ghostGsGuardianPositions[to_bytes32(g)] == 0,
        "one live flag latches the ban with an ex-guardian's stale flag inside the quorum");
}

// GS-RC-30: An account can stay banned on strikes cast only by guardians who have left.
rule rcGsBanQuorumMetByExGuardiansIsReachable(env e, GuardianSignals.Id id, address a,
    address g1, address g2) {

    setupGuardianSignalsValidState(e);
    require(ghostGsQuorum8 == 2 && ghostGsFlaggedByLen[id][a] == 2,
        "SCOPE: the flagger set exactly at quorum");
    require(ghostGsFlaggedByValues[id][a][0] == to_bytes32(g1)
        && ghostGsFlaggedByValues[id][a][1] == to_bytes32(g2),
        "SCOPE: g1 and g2 are the only counted flaggers");
    require(ghostGsGuardianPositions[to_bytes32(g1)] == 0
        && ghostGsGuardianPositions[to_bytes32(g2)] == 0,
        "SCOPE: both flaggers have left the committee");
    require(!ghostGsSigBanned[id][a],
        "SCOPE: no stored latch");

    bool effective = isBanned(e, id, a);

    satisfy(effective,
        "the ban quorum can be met entirely by non-current guardians until prune runs");
}

// GS-RC-31: A guardian's heartbeat can pair a block long past with the current time.
rule rcGsHeartbeatUnboundTimestampIsReachable(env e, GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);

    heartbeat(e, e.msg.sender, blk);

    satisfy(to_mathint(blk.number) + 256 >= to_mathint(e.block.number)
        && to_mathint(blk.number) + 100 <= to_mathint(e.block.number)
        && to_mathint(blk.timestamp) == to_mathint(e.block.timestamp)
        && ghostGsHeartbeats40[e.msg.sender] == to_mathint(blk.timestamp),
        "an aged attested block paired with a now-timestamp is accepted and stored verbatim");
}

// GS-RC-32: A guardian removed and later re-added can come back with a cleared heartbeat.
rule rcGsReAddClearsHeartbeatIsReachable(env e, env e2, address g) {

    setupGuardianSignalsValidState(e);
    setupGuardianSignalsValidState(e2);
    require(e2.block.timestamp >= e.block.timestamp,
        "SCOPE: the re-add happens no earlier than the removal");
    mathint hbBefore = ghostGsHeartbeats40[g];

    removeGuardian(e, g);
    addGuardian(e2, g);

    satisfy(ghostGsGuardianPositions[to_bytes32(g)] != 0
        && hbBefore > 0 && ghostGsHeartbeats40[g] == 0,
        "a re-added guardian starts over from a cleared stamp");
}

// GS-RC-33: Pruning a former guardian's report can stop it counting toward the delay at once.
rule rcGsPruneClearsStaleSuspectCountIsReachable(env e, GuardianSignals.Id id, address a, address g) {

    setupGuardianSignalsValidState(e);
    require(ghostGsSuspectedByLen[id][a] == 1
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0,
        "SCOPE: g's report is the only live entry in the suspect set");
    require(ghostGsGuardianPositions[to_bytes32(g)] == 0,
        "SCOPE: g has left the committee");
    require(ghostGsSigSuspectCount16[id][a] == 1,
        "SCOPE: the cached snapshot honestly counts g's report pre-prune");
    require(ghostGsSigSuspectedAt40[id][a][g] + ghostGsSuspectWindow40 >= to_mathint(e.block.timestamp),
        "SCOPE: g's report is still inside the window");
    require(ghostGsFlaggedByLen[id][a] == 0,
        "SCOPE: an empty flagger set");

    prune(e, id, a);

    GuardianSignals.GuardiansOpinion opinion = getOpinion(e, id, a);

    satisfy(ghostGsSuspectedByLen[id][a] == 0
        && opinion.suspectCount == 0
        && to_mathint(opinion.suspectExpiryTimestamp) <= to_mathint(e.block.timestamp),
        "a pruned ex-guardian's report stops counting toward the delay at once");
}

// GS-RC-34: Retracting one of two suspect reports can shorten how long the remaining one counts.
rule rcGsRetractionCutsExpiryIsReachable(env e, GuardianSignals.Id id, address a, address g,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single unsuspected target");
    require(g != e.msg.sender,
        "SCOPE: a distinct surviving reporter");
    require(ghostGsSuspectedByLen[id][a] == 2
        && ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] != 0
        && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0,
        "SCOPE: exactly the caller and g hold reports");
    mathint lenBefore = ghostGsSuspectedByLen[id][a];
    mathint expiryBefore = ghostGsSigSuspectReportedAt40[id][a] + ghostGsSuspectWindow40;

    unsuspect(e, id, e.msg.sender, accounts);

    satisfy(ghostGsSuspectedByLen[id][a] < lenBefore
        && ghostGsSigSuspectCount16[id][a] > 0
        && ghostGsSigSuspectReportedAt40[id][a] + ghostGsSuspectWindow40 < expiryBefore,
        "retracting one of two live reports strictly cuts the survivor's surcharge expiry");
}

// GS-RC-35: Pruning stale flags can still ban the account on the flags that survive.
rule rcGsPruneLatchesSurvivorQuorumIsReachable(env e, GuardianSignals.Id id, address a, address g) {

    setupGuardianSignalsValidState(e);
    require(!ghostGsSigBanned[id][a],
        "SCOPE: the latch starts clear");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(g)] != 0
        && ghostGsGuardianPositions[to_bytes32(g)] == 0,
        "SCOPE: g's flag outlived its seat");
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    prune(e, id, a);

    satisfy(ghostGsSigBanned[id][a]
        && ghostGsFlaggedByLen[id][a] < lenBefore
        && ghostGsFlaggedByLen[id][a] >= ghostGsQuorum8,
        "a cleanup that drops a stale flag can still latch the ban on the survivors");
}

// GS-RC-36: A guardian's delegate can send every signal and heartbeat on the guardian's behalf.
rule rcGsDelegateActsForSeatIsReachable(env e, method f, GuardianSignals.Id id, address a,
    address onBehalf, address[] accounts, GuardianSignals.BlockInfoWithHash blk)
    filtered { f -> DELEGATABLE_ENTRY_GS(f) } {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single named target");
    require(e.msg.sender != onBehalf && ghostGsDelegates[onBehalf] == e.msg.sender,
        "SCOPE: the caller is the appointed hot key, not the seat itself");
    mathint scanBefore = ghostGsHeartbeats40[onBehalf];
    bool flaggedBefore = ghostGsFlaggedByPositions[id][a][to_bytes32(onBehalf)] != 0;
    bool suspectedBefore = ghostGsSuspectedByPositions[id][a][to_bytes32(onBehalf)] != 0;

    if (f.selector == sig:heartbeat(address, GuardianSignals.BlockInfoWithHash).selector) {
        heartbeat(e, onBehalf, blk);
    } else if (f.selector == sig:flag(GuardianSignals.Id, address, address[]).selector) {
        flag(e, id, onBehalf, accounts);
    } else if (f.selector == sig:unflag(GuardianSignals.Id, address, address[]).selector) {
        unflag(e, id, onBehalf, accounts);
    } else if (f.selector == sig:suspect(GuardianSignals.Id, address, address[]).selector) {
        suspect(e, id, onBehalf, accounts);
    } else {
        unsuspect(e, id, onBehalf, accounts);
    }

    satisfy(ghostGsHeartbeats40[onBehalf] != scanBefore
        || (ghostGsFlaggedByPositions[id][a][to_bytes32(onBehalf)] != 0) != flaggedBefore
        || (ghostGsSuspectedByPositions[id][a][to_bytes32(onBehalf)] != 0) != suspectedBefore,
        "the hot key can carry each of the guardian's calls, and the record moves under the guardian");
}
