// GuardianSignals unit tests: exact setter/signal effects, rotation frames, view derivations.

import "GuardianSignals_valid_state.spec";

// GS-UT-01: Setting the ban quorum stores exactly the number governance asked for.
rule utGsSetQuorumStoresValue(env e, uint256 newQuorum) {

    setupGuardianSignalsValidState(e);

    setQuorum(e, newQuorum);

    assert(ghostGsQuorum8 == to_mathint(newQuorum), "setQuorum stores the requested quorum");
}

// GS-UT-02: Setting the ban quorum leaves the committee the same size.
rule utGsSetQuorumKeepsCommitteeSize(env e, uint256 newQuorum) {

    setupGuardianSignalsValidState(e);
    mathint lenBefore = ghostGsGuardiansLen;

    setQuorum(e, newQuorum);

    assert(ghostGsGuardiansLen == lenBefore, "setQuorum never changes committee membership");
}

// GS-UT-03: Setting the suspect window stores exactly the length governance asked for.
rule utGsSetSuspectWindowStoresValue(env e, uint256 suspectWindow) {

    setupGuardianSignalsValidState(e);

    setSuspectWindow(e, suspectWindow);

    assert(ghostGsSuspectWindow40 == to_mathint(suspectWindow),
        "setSuspectWindow stores the requested window");
}

// GS-UT-04: Adding a guardian seats it on the committee.
rule utGsAddGuardianMakesMember(env e, address g) {

    setupGuardianSignalsValidState(e);

    addGuardian(e, g);

    assert(ghostGsGuardianPositions[to_bytes32(g)] != 0,
        "the added guardian is a committee member");
}

// GS-UT-05: Adding a guardian who is not yet seated grows the committee by exactly one.
rule utGsAddGuardianGrowsCommitteeByOne(env e, address g) {

    setupGuardianSignalsValidState(e);
    bool wasMember = ghostGsGuardianPositions[to_bytes32(g)] != 0;
    mathint lenBefore = ghostGsGuardiansLen;

    addGuardian(e, g);

    assert(!wasMember => ghostGsGuardiansLen == lenBefore + 1,
        "adding a new guardian grows the committee by one");
}

// GS-UT-06: Removing a guardian takes it off the committee.
rule utGsRemoveGuardianDropsMember(env e, address g) {

    setupGuardianSignalsValidState(e);

    removeGuardian(e, g);

    assert(ghostGsGuardianPositions[to_bytes32(g)] == 0,
        "the removed guardian is no longer a committee member");
}

// GS-UT-07: Removing a seated guardian shrinks the committee by exactly one.
rule utGsRemoveGuardianShrinksCommitteeByOne(env e, address g) {

    setupGuardianSignalsValidState(e);
    bool wasMember = ghostGsGuardianPositions[to_bytes32(g)] != 0;
    mathint lenBefore = ghostGsGuardiansLen;

    removeGuardian(e, g);

    assert(wasMember => ghostGsGuardiansLen == lenBefore - 1,
        "removing a member shrinks the committee by one");
}

// GS-UT-08: A guardian's heartbeat stores the scan time the guardian reports, not the current time.
rule utGsHeartbeatStoresReportedTimestamp(env e, GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);

    heartbeat(e, e.msg.sender, blk);

    assert(ghostGsHeartbeats40[e.msg.sender] == to_mathint(blk.timestamp),
        "the caller's heartbeat is the reported scanned-block timestamp");
}

// GS-UT-09: A ban by governance latches on the named account in the named market.
rule utGsBanSetsLatch(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    ban(e, id, a);

    assert(ghostGsSigBanned[id][a], "ban latches the account's ban for the market");
}

// GS-UT-10: Banning one account leaves the ban status of every other account and market unchanged.
rule utGsBanLeavesOtherAccounts(env e, GuardianSignals.Id id, address a,
    GuardianSignals.Id id2, address b) {

    setupGuardianSignalsValidState(e);
    require(!(id2 == id && b == a), "SCOPE: a bystander cell");
    bool bannedBefore = ghostGsSigBanned[id2][b];

    ban(e, id, a);

    assert(ghostGsSigBanned[id2][b] == bannedBefore,
        "ban leaves other ban latches untouched");
}

// GS-UT-11: An unban clears the stored ban on the account in the named market.
rule utGsUnbanClearsLatch(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    unban(e, id, a);

    assert(!ghostGsSigBanned[id][a], "unban clears the account's ban latch");
}

// GS-UT-12: An unban also clears every strike standing against the account.
rule utGsUnbanEmptiesFlaggerSet(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    unban(e, id, a);

    assert(ghostGsFlaggedByLen[id][a] == 0, "unban clears the flagger set");
}

// GS-UT-13: The guardians' opinion reports an account banned exactly when a ban is latched or its strikes reach quorum.
rule utGsOpinionBannedIsEffectiveBan(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    GuardianSignals.GuardiansOpinion op = getOpinion(e, id, a);

    assert(op.banned
        == (ghostGsSigBanned[id][a] || ghostGsFlaggedByLen[id][a] >= ghostGsQuorum8),
        "opinion.banned is the stored latch or a flagger set at quorum");
}

// GS-UT-14: The reported strike count is the number of guardians currently flagging the account.
rule utGsOpinionStrikeCountIsFlaggerSetSize(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    GuardianSignals.GuardiansOpinion op = getOpinion(e, id, a);

    assert(to_mathint(op.strikeCount) == ghostGsFlaggedByLen[id][a],
        "opinion.strikeCount is the live flagger-set size");
}

// GS-UT-15: The reported suspect count is the stored snapshot, not a fresh scan of the reports.
rule utGsOpinionSuspectCountIsSnapshot(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    GuardianSignals.GuardiansOpinion op = getOpinion(e, id, a);

    assert(to_mathint(op.suspectCount) == ghostGsSigSuspectCount16[id][a],
        "opinion.suspectCount is the stored suspect snapshot");
}

// GS-UT-16: The reported expiry of a suspicion is its snapshot time plus the window in force when read.
rule utGsOpinionExpiryIsSnapshotPlusWindow(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    GuardianSignals.GuardiansOpinion op = getOpinion(e, id, a);

    assert(to_mathint(op.suspectExpiryTimestamp)
        == ghostGsSigSuspectReportedAt40[id][a] + ghostGsSuspectWindow40,
        "opinion.suspectExpiryTimestamp is reportedAt plus the current window");
}

// GS-UT-17: Every opinion carries the committee's current scan frontier timestamp.
rule utGsOpinionFrontierIsStored(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    GuardianSignals.GuardiansOpinion op = getOpinion(e, id, a);

    assert(to_mathint(op.quorumFrontierTimestamp) == ghostGsQuorumFrontierTimestamp40,
        "opinion.quorumFrontierTimestamp is the stored frontier");
}

// GS-UT-18: Only flagging, retracting, the cleanup or an unban can move who flags an account.
rule utGsRemoveGuardianKeepsFlagMembership(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a, address w)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    bool memberBefore = ghostGsFlaggedByPositions[id][a][to_bytes32(w)] != 0;

    f(e, args);

    assert((ghostGsFlaggedByPositions[id][a][to_bytes32(w)] != 0) != memberBefore
        => (f.selector == sig:flag(GuardianSignals.Id, address, address[]).selector
            || f.selector == sig:unflag(GuardianSignals.Id, address, address[]).selector
            || f.selector == sig:prune(GuardianSignals.Id, address).selector
            || f.selector == sig:unban(GuardianSignals.Id, address).selector),
        "flag membership moves only through flag/unflag/prune/unban, never a rotation");
}

// GS-UT-19: Only a suspect report, its retraction or the cleanup can move who suspects an account.
rule utGsRemoveGuardianKeepsSuspectMembership(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a, address w)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    bool memberBefore = ghostGsSuspectedByPositions[id][a][to_bytes32(w)] != 0;

    f(e, args);

    assert((ghostGsSuspectedByPositions[id][a][to_bytes32(w)] != 0) != memberBefore
        => (f.selector == sig:suspect(GuardianSignals.Id, address, address[]).selector
            || f.selector == sig:unsuspect(GuardianSignals.Id, address, address[]).selector
            || f.selector == sig:prune(GuardianSignals.Id, address).selector),
        "suspect membership moves only through suspect/unsuspect/prune");
}

// GS-UT-20: Removing a guardian moves neither an account's ban nor the quorum bans are scored against.
rule utGsRemoveGuardianKeepsBanLatch(env e, address g, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);
    bool bannedBefore = ghostGsSigBanned[id][a];
    mathint quorumBefore = ghostGsQuorum8;

    removeGuardian(e, g);

    assert(ghostGsSigBanned[id][a] == bannedBefore && ghostGsQuorum8 == quorumBefore,
        "removal moves neither a ban latch nor the quorum");
}

// GS-UT-21: Removing a guardian erases only that guardian's last scan time and delegate.
rule utGsRemoveGuardianClearsOwnHeartbeat(env e, address g, address w) {

    setupGuardianSignalsValidState(e);
    mathint hbBefore = ghostGsHeartbeats40[w];
    address delegateBefore = ghostGsDelegates[w];

    removeGuardian(e, g);

    assert(ghostGsHeartbeats40[g] == 0
        && ghostGsDelegates[g] == 0
        && (w != g => (ghostGsHeartbeats40[w] == hbBefore
            && ghostGsDelegates[w] == delegateBefore)),
        "removal wipes the removed guardian's scan stamp and hot key, and no other seat's");
}

// GS-UT-22: Removing a guardian leaves the committee's scan frontier exactly where it stood.
rule utGsRemoveGuardianKeepsFrontier(env e, address g) {

    setupGuardianSignalsValidState(e);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    removeGuardian(e, g);

    assert(ghostGsQuorumFrontierTimestamp40 == frontierBefore,
        "removal never moves the quorum frontier");
}

// GS-UT-23: Only a suspect report, its retraction or the cleanup changes an account's suspicion snapshot and its date.
rule utGsAddGuardianKeepsSuspectSnapshot(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    mathint countBefore = ghostGsSigSuspectCount16[id][a];
    mathint reportedAtBefore = ghostGsSigSuspectReportedAt40[id][a];

    f(e, args);

    assert((ghostGsSigSuspectCount16[id][a] != countBefore
            || ghostGsSigSuspectReportedAt40[id][a] != reportedAtBefore)
        => (f.selector == sig:suspect(GuardianSignals.Id, address, address[]).selector
            || f.selector == sig:unsuspect(GuardianSignals.Id, address, address[]).selector
            || f.selector == sig:prune(GuardianSignals.Id, address).selector),
        "only a suspect report, its retraction or the cleanup re-snapshots the suspect head");
}

// GS-UT-24: Adding a guardian leaves the committee's scan frontier exactly where it stood.
rule utGsAddGuardianKeepsFrontier(env e, address g) {

    setupGuardianSignalsValidState(e);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    addGuardian(e, g);

    assert(ghostGsQuorumFrontierTimestamp40 == frontierBefore,
        "joining never moves the quorum frontier");
}

// GS-UT-25: A strike is recorded under the guardian that raised it.
rule utGsFlagInsertsCaller(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single flagged target");

    flag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] != 0,
        "flag inserts the caller into the flagger set");
}

// GS-UT-26: A guardian retracting a strike leaves no strike of its own on the account.
rule utGsUnflagRemovesCallerFlag(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target account");

    unflag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "the caller's flag is gone after unflag");
}

// GS-UT-27: One guardian's retraction leaves every other guardian's strike on the account standing.
rule utGsUnflagKeepsOtherFlaggers(env e, GuardianSignals.Id id, address a, address w,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target account");
    bool memberBefore = ghostGsFlaggedByPositions[id][a][to_bytes32(w)] != 0;

    unflag(e, id, e.msg.sender, accounts);

    assert(w != e.msg.sender
        => (ghostGsFlaggedByPositions[id][a][to_bytes32(w)] != 0) == memberBefore,
        "no other guardian's flag moves");
}

// GS-UT-28: A retraction lowers the strike count by exactly one when that guardian had a strike, otherwise not at all.
rule utGsUnflagDropsExactlyCallerStrike(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target account");
    bool callerWasMember = ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] != 0;
    mathint lenBefore = ghostGsFlaggedByLen[id][a];

    unflag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByLen[id][a] == lenBefore - (callerWasMember ? 1 : 0),
        "the strike count drops by exactly the retracted flag");
}

// GS-UT-29: A suspect report is filed under the guardian who raised it.
rule utGsSuspectInsertsCaller(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target account");

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] != 0,
        "suspect inserts the caller into the suspect set");
}

// GS-UT-30: A suspect report is stamped with the time it is filed, refreshing a repeat report.
rule utGsSuspectStampsCallerNow(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target account");

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSigSuspectedAt40[id][a][e.msg.sender] == to_mathint(e.block.timestamp),
        "the caller's report stamp is the report time");
}

// GS-UT-31: Reporting one account leaves the suspicions standing against every other account and market untouched.
rule utGsSuspectLeavesSiblingSets(env e, GuardianSignals.Id id, address a,
    GuardianSignals.Id id2, address b,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target account");
    require(!(id2 == id && b == a), "SCOPE: a bystander cell");
    mathint lenBefore = ghostGsSuspectedByLen[id2][b];

    suspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id2][b] == lenBefore,
        "suspect leaves other suspect sets untouched");
}

// GS-UT-32: A guardian withdrawing its suspicion leaves no report of its own on the account.
rule utGsUnsuspectRemovesCallerReport(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target account");

    unsuspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] == 0,
        "the caller's suspect report is gone after unsuspect");
}

// GS-UT-33: Withdrawing a suspicion clears the time stamp that report carried.
rule utGsUnsuspectClearsCallerStamp(env e, GuardianSignals.Id id, address a,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a,
        "SCOPE: single target account");

    unsuspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSigSuspectedAt40[id][a][e.msg.sender] == 0,
        "the caller's suspect stamp is zero after unsuspect");
}

// GS-UT-34: The permissionless cleanup keeps the strikes of guardians still seated on the committee.
rule utGsPruneKeepsLiveGuardianFlag(env e, GuardianSignals.Id id, address a, address g) {

    setupGuardianSignalsValidState(e);
    require(ghostGsGuardianPositions[to_bytes32(g)] != 0, "SCOPE: a live guardian");
    require(ghostGsFlaggedByPositions[id][a][to_bytes32(g)] != 0, "SCOPE: a standing flag");

    prune(e, id, a);

    assert(ghostGsFlaggedByPositions[id][a][to_bytes32(g)] != 0,
        "prune keeps a live guardian's flag");
}

// GS-UT-35: The permissionless cleanup keeps a seated guardian's suspect report, whether or not it has lapsed.
rule utGsPruneKeepsLiveGuardianSuspect(env e, GuardianSignals.Id id, address a, address g) {

    setupGuardianSignalsValidState(e);
    require(ghostGsGuardianPositions[to_bytes32(g)] != 0, "SCOPE: a live guardian");
    require(ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0,
        "SCOPE: a standing suspect report");

    prune(e, id, a);

    assert(ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0,
        "prune keeps a live guardian's suspect report");
}

// GS-UT-36: The heartbeat listing has one row per committee member, with the two lists the same length.
rule utGsHeartbeatsRowPerMember(env e) {

    setupGuardianSignalsValidState(e);

    address[] guardians; uint40[] timestamps;
    guardians, timestamps = getHeartbeats(e);

    assert(to_mathint(guardians.length) == ghostGsGuardiansLen
        && guardians.length == timestamps.length,
        "getHeartbeats returns one aligned row per committee member");
}

// GS-UT-37: Each timestamp in the heartbeat listing is that guardian's own recorded scan time.
rule utGsHeartbeatsValueMatchesRecord(env e, uint256 i) {

    setupGuardianSignalsValidState(e);

    address[] guardians; uint40[] timestamps;
    guardians, timestamps = getHeartbeats(e);

    require(i < guardians.length, "SCOPE: a live index of the returned arrays");
    require(ghostGsGuardianValues[i] & to_bytes32(max_uint160) == ghostGsGuardianValues[i],
        "SAFE: the committee set value is uint160-clean");

    assert(to_mathint(timestamps[i]) == ghostGsHeartbeats40[guardians[i]],
        "timestamps[i] is guardians[i]'s recorded heartbeat");
}

// GS-UT-38: Flagging never removes a strike from any account.
rule utGsFlagNeverShrinksFlaggers(env e, GuardianSignals.Id id,
    GuardianSignals.Id id2, address b,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    mathint lenBefore = ghostGsFlaggedByLen[id2][b];

    flag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByLen[id2][b] >= lenBefore,
        "flag never shrinks a flagger set");
}

// GS-UT-39: Retracting a strike never adds one to any account.
rule utGsUnflagNeverGrowsFlaggers(env e, GuardianSignals.Id id,
    GuardianSignals.Id id2, address b,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    mathint lenBefore = ghostGsFlaggedByLen[id2][b];

    unflag(e, id, e.msg.sender, accounts);

    assert(ghostGsFlaggedByLen[id2][b] <= lenBefore,
        "unflag never grows a flagger set");
}

// GS-UT-40: Withdrawing a suspicion never adds a suspect report to any account.
rule utGsUnsuspectNeverGrowsSuspectSet(env e, GuardianSignals.Id id,
    GuardianSignals.Id id2, address b,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    mathint lenBefore = ghostGsSuspectedByLen[id2][b];

    unsuspect(e, id, e.msg.sender, accounts);

    assert(ghostGsSuspectedByLen[id2][b] <= lenBefore,
        "unsuspect never grows a suspect set");
}

// GS-UT-41: The permissionless cleanup can only remove strikes and suspect reports, never add them.
rule utGsPruneShrinkOnly(env e, GuardianSignals.Id id, address a,
    GuardianSignals.Id id2, address b) {

    setupGuardianSignalsValidState(e);
    mathint flagLenBefore = ghostGsFlaggedByLen[id2][b];
    mathint suspLenBefore = ghostGsSuspectedByLen[id2][b];

    prune(e, id, a);

    assert(ghostGsFlaggedByLen[id2][b] <= flagLenBefore
        && ghostGsSuspectedByLen[id2][b] <= suspLenBefore,
        "prune only ever shrinks a signal set");
}

// GS-UT-42: The reported ban quorum is exactly the threshold governance stored.
rule utGsGetQuorumIsStored(env e) {

    setupGuardianSignalsValidState(e);

    uint256 quorum = getQuorum(e);

    assert(to_mathint(quorum) == ghostGsQuorum8, "getQuorum returns the stored quorum");
}

// GS-UT-43: The reported suspect window is exactly the window governance stored.
rule utGsGetSuspectWindowIsStored(env e) {

    setupGuardianSignalsValidState(e);

    uint256 window = getSuspectWindow(e);

    assert(to_mathint(window) == ghostGsSuspectWindow40,
        "getSuspectWindow returns the stored window");
}

// GS-UT-44: The reported scan frontier is exactly the one the contract recorded.
rule utGsGetQuorumFrontierIsStored(env e) {

    setupGuardianSignalsValidState(e);

    uint40 frontier = getQuorumFrontier(e);

    assert(to_mathint(frontier) == ghostGsQuorumFrontierTimestamp40,
        "getQuorumFrontier returns the stored frontier");
}

// GS-UT-45: The reported guardian count is the true size of the committee.
rule utGsGetGuardianCountIsCommitteeSize(env e) {

    setupGuardianSignalsValidState(e);

    uint256 count = getGuardianCount(e);

    assert(to_mathint(count) == ghostGsGuardiansLen,
        "getGuardianCount returns the committee size");
}

// GS-UT-46: A reported heartbeat belongs to the guardian asked about, not to the caller.
rule utGsGetHeartbeatIsGuardianStamp(env e, address g) {

    setupGuardianSignalsValidState(e);

    uint40 timestamp = getHeartbeat(e, g);

    assert(to_mathint(timestamp) == ghostGsHeartbeats40[g],
        "getHeartbeat returns the named guardian's stamp");
}

// GS-UT-47: The membership check answers for the account asked about, not for the caller.
rule utGsIsGuardianIsMembership(env e, address a) {

    setupGuardianSignalsValidState(e);

    bool member = isGuardian(e, a);

    assert(member == (ghostGsGuardianPositions[to_bytes32(a)] != 0),
        "isGuardian is the named account's committee membership");
}

// GS-UT-48: The ban check answers yes exactly when a ban is latched or the strikes reach quorum.
rule utGsIsBannedIsEffectiveBan(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    bool banned = isBanned(e, id, a);

    assert(banned == (ghostGsSigBanned[id][a] || ghostGsFlaggedByLen[id][a] >= ghostGsQuorum8),
        "isBanned is the stored latch or a flagger set at quorum");
}

// GS-UT-49: The strike listing returns as many addresses as there are guardians flagging the account.
rule utGsFlaggedByRowPerFlagger(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    address[] flaggers = getFlaggedBy(e, id, a);

    assert(to_mathint(flaggers.length) == ghostGsFlaggedByLen[id][a],
        "getFlaggedBy returns one row per live flagger");
}

// GS-UT-50: The suspect listing returns as many guardians and report times as there are live reports.
rule utGsSuspectedByRowPerReporter(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsValidState(e);

    address[] guardians; uint40[] reportedAt;
    guardians, reportedAt = getSuspectedBy(e, id, a);

    assert(to_mathint(guardians.length) == ghostGsSuspectedByLen[id][a]
        && guardians.length == reportedAt.length,
        "getSuspectedBy returns one aligned row per live reporter");
}

// GS-UT-51: Each listed report time is the one recorded for the guardian beside it.
rule utGsSuspectedByStampMatchesRecord(env e, GuardianSignals.Id id, address a, uint256 i) {

    setupGuardianSignalsValidState(e);

    address[] guardians; uint40[] reportedAt;
    guardians, reportedAt = getSuspectedBy(e, id, a);

    require(i < guardians.length, "SCOPE: a live index of the returned arrays");

    assert(to_mathint(reportedAt[i]) == ghostGsSigSuspectedAt40[id][a][guardians[i]],
        "reportedAt[i] is guardians[i]'s recorded suspect stamp");
}

// GS-UT-56: Changing the quorum never moves the committee's scan frontier.
rule utGsSetQuorumKeepsFrontier(env e, uint256 newQuorum) {

    setupGuardianSignalsValidState(e);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    setQuorum(e, newQuorum);

    assert(ghostGsQuorumFrontierTimestamp40 == frontierBefore,
        "setting the quorum never moves the quorum frontier");
}

// GS-UT-57: Appointing a delegate files it under the appointing guardian and under no other.
rule utGsSetDelegateStoresValue(env e, address newDelegate, address g) {

    setupGuardianSignalsValidState(e);
    address delegateBefore = ghostGsDelegates[g];

    setDelegate(e, newDelegate);

    assert(ghostGsDelegates[e.msg.sender] == newDelegate
        && (g != e.msg.sender => ghostGsDelegates[g] == delegateBefore),
        "setDelegate stores the requested hot key under the caller's own seat and no other");
}

// GS-UT-58: Appointing a delegate costs a guardian neither its committee seat nor its last scan time.
rule utGsSetDelegateKeepsSeatStanding(env e, address newDelegate) {

    setupGuardianSignalsValidState(e);
    mathint hbBefore = ghostGsHeartbeats40[e.msg.sender];

    setDelegate(e, newDelegate);

    assert(ghostGsHeartbeats40[e.msg.sender] == hbBefore
        && ghostGsGuardianPositions[to_bytes32(e.msg.sender)] != 0,
        "a delegate rotation moves neither the caller's scan stamp nor its committee seat");
}

// GS-UT-59: The delegate reported for a guardian is that guardian's own, not the caller's.
rule utGsGetDelegateIsStoredDelegate(env e, address g) {

    setupGuardianSignalsValidState(e);

    address delegate = getDelegate(e, g);

    assert(delegate == ghostGsDelegates[g],
        "getDelegate returns the named guardian's appointed hot key");
}

// GS-UT-60: Replacing a guardian seats the newcomer, unseats the old one, and moves neither count nor quorum.
rule utGsReplaceGuardianSwapsSeats(env e, address oldGuardian, address newGuardian) {

    setupGuardianSignalsValidState(e);
    mathint lenBefore = ghostGsGuardiansLen;
    mathint quorumBefore = ghostGsQuorum8;

    replaceGuardian(e, oldGuardian, newGuardian);

    assert(ghostGsGuardianPositions[to_bytes32(oldGuardian)] == 0
        && ghostGsGuardianPositions[to_bytes32(newGuardian)] != 0
        && ghostGsGuardiansLen == lenBefore
        && ghostGsQuorum8 == quorumBefore,
        "the swap drops the outgoing seat, seats the incoming one, and moves neither count nor quorum");
}

// GS-UT-62: A guardian's last scan time moves only on a heartbeat and clears only when the seat leaves.
rule utGsHeartbeatMovesOnlyInBeatOrRotation(env e, method f, calldataarg args, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsValidState(e);
    mathint scanBefore = ghostGsHeartbeats40[g];

    f(e, args);

    assert(ghostGsHeartbeats40[g] != scanBefore
        => (f.selector == sig:heartbeat(address, GuardianSignals.BlockInfoWithHash).selector
            || (ghostGsHeartbeats40[g] == 0
                && (f.selector == sig:removeGuardian(address).selector
                    || f.selector == sig:replaceGuardian(address, address).selector))),
        "a scan stamp moves in the beat alone, and clears only with the seat that leaves the committee");
}

// GS-UT-63: Replacing a guardian clears the outgoing seat's delegate and last scan time.
rule utGsReplaceGuardianClearsOutgoingSeat(env e, address oldGuardian, address newGuardian) {

    setupGuardianSignalsValidState(e);

    replaceGuardian(e, oldGuardian, newGuardian);

    assert(ghostGsHeartbeats40[oldGuardian] == 0 && ghostGsDelegates[oldGuardian] == 0,
        "the swap leaves the outgoing seat neither a hot key nor a scan stamp");
}

// GS-UT-64: A delegate acting for a guardian records under that guardian, never under itself.
rule utGsDelegateRecordsUnderSeat(env e, method f, GuardianSignals.Id id, address a,
    address onBehalf, address[] accounts, GuardianSignals.BlockInfoWithHash blk)
    filtered { f -> DELEGATABLE_ENTRY_GS(f) } {

    setupGuardianSignalsValidState(e);
    require(accounts.length == 1 && accounts[0] == a, "SCOPE: single named target");
    require(e.msg.sender != onBehalf && ghostGsDelegates[onBehalf] == e.msg.sender,
        "SCOPE: the caller is the seat's delegate, not the seat");
    require(ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] != 0
        => ghostGsSigSuspectedAt40[id][a][e.msg.sender] + ghostGsSuspectWindow40
            >= to_mathint(e.block.timestamp),
        "SCOPE: the caller holds no lapsed report on the target");
    mathint callerScan = ghostGsHeartbeats40[e.msg.sender];
    bool callerFlagged = ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] != 0;
    bool callerSuspected = ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] != 0;
    mathint callerStamp = ghostGsSigSuspectedAt40[id][a][e.msg.sender];

    if (f.selector == sig:heartbeat(address, GuardianSignals.BlockInfoWithHash).selector) {
        heartbeat(e, onBehalf, blk);
        assert(ghostGsHeartbeats40[onBehalf] == to_mathint(blk.timestamp),
            "the beat lands on the named seat's scan stamp");
    } else if (f.selector == sig:flag(GuardianSignals.Id, address, address[]).selector) {
        flag(e, id, onBehalf, accounts);
        assert(ghostGsFlaggedByPositions[id][a][to_bytes32(onBehalf)] != 0,
            "the strike lands under the named seat");
    } else if (f.selector == sig:unflag(GuardianSignals.Id, address, address[]).selector) {
        unflag(e, id, onBehalf, accounts);
        assert(ghostGsFlaggedByPositions[id][a][to_bytes32(onBehalf)] == 0,
            "the retraction takes the named seat's strike");
    } else if (f.selector == sig:suspect(GuardianSignals.Id, address, address[]).selector) {
        suspect(e, id, onBehalf, accounts);
        assert(ghostGsSuspectedByPositions[id][a][to_bytes32(onBehalf)] != 0
            && ghostGsSigSuspectedAt40[id][a][onBehalf] == to_mathint(e.block.timestamp),
            "the report lands under the named seat, stamped at the report time");
    } else {
        unsuspect(e, id, onBehalf, accounts);
        assert(ghostGsSuspectedByPositions[id][a][to_bytes32(onBehalf)] == 0
            && ghostGsSigSuspectedAt40[id][a][onBehalf] == 0,
            "the retraction takes the named seat's report and its stamp");
    }

    assert(ghostGsHeartbeats40[e.msg.sender] == callerScan
        && (ghostGsFlaggedByPositions[id][a][to_bytes32(e.msg.sender)] != 0) == callerFlagged
        && (ghostGsSuspectedByPositions[id][a][to_bytes32(e.msg.sender)] != 0) == callerSuspected
        && ghostGsSigSuspectedAt40[id][a][e.msg.sender] == callerStamp,
        "acting for a guardian writes nothing under the caller's own address");
}
