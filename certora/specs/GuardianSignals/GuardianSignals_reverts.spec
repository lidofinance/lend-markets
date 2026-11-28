// Each rule pins when a call must fail and when it must not

import "GuardianSignals_valid_state.spec";

// GS-RV-01: Governance adding a guardian fails exactly when the address is zero or already sits on the committee.
rule rvGsAddGuardianRevertsIff(env e, address guardian) {

    setupGuardianSignalsValidState(e);
    require(forall address g. ghostGsGuardianPositions[to_bytes32(g)] == 0
            || ghostGsDelegates[g] != guardian,
        "SCOPE: the candidate is no seat's hot key");
    bool zeroGuardian = guardian == 0;
    bool alreadyMember = ghostGsGuardianPositions[to_bytes32(guardian)] != 0;

    addGuardian@withrevert(e, guardian);
    bool reverted = lastReverted;

    assert(reverted <=> (zeroGuardian || alreadyMember),
        "addGuardian rejects exactly the zero address and a repeat member");
}

// GS-RV-02: Governance removing a guardian fails exactly when the guardian is not seated or the committee would fall below quorum.
rule rvGsRemoveGuardianRevertsIff(env e, address guardian) {

    setupGuardianSignalsValidState(e);
    bool notMember = ghostGsGuardianPositions[to_bytes32(guardian)] == 0;
    bool breaksQuorum = ghostGsGuardiansLen - 1 < ghostGsQuorum8;

    removeGuardian@withrevert(e, guardian);
    bool reverted = lastReverted;

    assert(reverted <=> (notMember || breaksQuorum),
        "removeGuardian rejects exactly a non-member and a quorum-breaking removal");
}

// GS-RV-03: Governance setting the ban quorum fails exactly when the value is zero or above the committee size.
rule rvGsSetQuorumRevertsIff(env e, uint256 newQuorum) {

    setupGuardianSignalsValidState(e);
    bool badQuorum = newQuorum == 0 || to_mathint(newQuorum) > ghostGsGuardiansLen;

    setQuorum@withrevert(e, newQuorum);
    bool reverted = lastReverted;

    assert(reverted <=> badQuorum,
        "setQuorum rejects exactly a zero or above-committee quorum");
}

// GS-RV-04: Governance setting the suspect window fails exactly when it exceeds the 30 day cap.
rule rvGsSetSuspectWindowRevertsIff(env e, uint256 suspectWindow) {

    setupGuardianSignalsValidState(e);
    bool tooHigh = suspectWindow > _Signals.MAX_SUSPECT_WINDOW();

    setSuspectWindow@withrevert(e, suspectWindow);
    bool reverted = lastReverted;

    assert(reverted <=> tooHigh,
        "setSuspectWindow rejects exactly a window above the cap");
}

// GS-RV-05: Only a guardian, or the delegate it appointed, can record a heartbeat for that seat.
rule rvGsHeartbeatRevertsWhenNotGuardian(env e, address onBehalf,
    GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);
    bool unauthorized = !ACTS_FOR_GS(e.msg.sender, onBehalf);

    heartbeat@withrevert(e, onBehalf, blk);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "heartbeat rejects a caller the named seat did not authorize");
}

// GS-RV-06: A heartbeat naming a block that does not exist yet fails.
rule rvGsHeartbeatRevertsOnFutureBlockNumber(env e, GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);
    bool futureBlockNumber = to_mathint(blk.number) > to_mathint(e.block.number);

    heartbeat@withrevert(e, e.msg.sender, blk);
    bool reverted = lastReverted;

    assert(futureBlockNumber => reverted, "heartbeat rejects a block that does not exist yet");
}

// GS-RV-07: A heartbeat claiming a time later than the current block fails.
rule rvGsHeartbeatRevertsOnFutureTimestamp(env e, GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);
    bool futureTimestamp = to_mathint(blk.timestamp) > to_mathint(e.block.timestamp);

    heartbeat@withrevert(e, e.msg.sender, blk);
    bool reverted = lastReverted;

    assert(futureTimestamp => reverted, "heartbeat rejects a timestamp past the current block");
}

// GS-RV-08: A heartbeat that backdates the named seat's last scan time fails.
rule rvGsHeartbeatRevertsOnRegressedTimestamp(env e, address onBehalf,
    GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);
    bool regressed = to_mathint(blk.timestamp) < ghostGsHeartbeats40[onBehalf];

    heartbeat@withrevert(e, onBehalf, blk);
    bool reverted = lastReverted;

    assert(regressed => reverted,
        "heartbeat rejects a timestamp below the named seat's recorded scan stamp");
}

// GS-RV-09: A heartbeat carrying a zero block hash fails.
rule rvGsHeartbeatRevertsOnZeroBlockHash(env e, GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsValidState(e);
    bool zeroHash = blk.hash == to_bytes32(0);

    heartbeat@withrevert(e, e.msg.sender, blk);
    bool reverted = lastReverted;

    assert(zeroHash => reverted, "heartbeat rejects a zero reported block hash");
}

// GS-RV-10: Only a guardian, or the delegate it appointed, can flag an account for that seat.
rule rvGsFlagRevertsWhenNotGuardian(env e, GuardianSignals.Id id, address onBehalf,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    bool unauthorized = !ACTS_FOR_GS(e.msg.sender, onBehalf);

    flag@withrevert(e, id, onBehalf, accounts);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "flag rejects a caller the named seat did not authorize");
}

// GS-RV-11: Flagging the zero address fails, so no strike is recorded against it.
rule rvGsFlagRevertsOnZeroAccount(env e, GuardianSignals.Id id, address[] accounts) {

    setupGuardianSignalsValidState(e);
    bool zeroEntry = accounts.length == 1 && accounts[0] == 0;

    flag@withrevert(e, id, e.msg.sender, accounts);
    bool reverted = lastReverted;

    assert(zeroEntry => reverted, "flag rejects a zero-address batch entry");
}

// GS-RV-12: Only a guardian, or the delegate it appointed, can withdraw that seat's strike.
rule rvGsUnflagRevertsWhenNotGuardian(env e, GuardianSignals.Id id, address onBehalf,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    bool unauthorized = !ACTS_FOR_GS(e.msg.sender, onBehalf);

    unflag@withrevert(e, id, onBehalf, accounts);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "unflag rejects a caller the named seat did not authorize");
}

// GS-RV-13: Only a guardian, or the delegate it appointed, can file a suspect report for that seat.
rule rvGsSuspectRevertsWhenNotGuardian(env e, GuardianSignals.Id id, address onBehalf,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    bool unauthorized = !ACTS_FOR_GS(e.msg.sender, onBehalf);

    suspect@withrevert(e, id, onBehalf, accounts);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "suspect rejects a caller the named seat did not authorize");
}

// GS-RV-14: Filing a suspect report against the zero address fails.
rule rvGsSuspectRevertsOnZeroAccount(env e, GuardianSignals.Id id, address[] accounts) {

    setupGuardianSignalsValidState(e);
    bool zeroEntry = accounts.length == 1 && accounts[0] == 0;

    suspect@withrevert(e, id, e.msg.sender, accounts);
    bool reverted = lastReverted;

    assert(zeroEntry => reverted, "suspect rejects a zero-address batch entry");
}

// GS-RV-15: Only a guardian, or the delegate it appointed, can retract that seat's suspect report.
rule rvGsUnsuspectRevertsWhenNotGuardian(env e, GuardianSignals.Id id, address onBehalf,
    address[] accounts) {

    setupGuardianSignalsValidState(e);
    bool unauthorized = !ACTS_FOR_GS(e.msg.sender, onBehalf);

    unsuspect@withrevert(e, id, onBehalf, accounts);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "unsuspect rejects a caller the named seat did not authorize");
}

// GS-RV-16: The permissionless cleanup of stale flags and reports never fails, whoever calls it.
rule rvGsPruneNeverReverts(env e, GuardianSignals.Id id, address account) {

    setupGuardianSignalsValidState(e);

    prune@withrevert(e, id, account);
    bool reverted = lastReverted;

    assert(!reverted, "prune never reverts under valid state");
}

// GS-RV-17: A ban by the access limiter fails exactly when the named account is the zero address.
rule rvGsBanRevertsIff(env e, GuardianSignals.Id id, address account) {

    setupGuardianSignalsValidState(e);
    bool zeroAccount = account == 0;

    ban@withrevert(e, id, account);
    bool reverted = lastReverted;

    assert(reverted <=> zeroAccount, "ban rejects exactly the zero address");
}

// GS-RV-18: Lifting a ban never fails for the restorer, whatever state the account is in.
rule rvGsUnbanNeverReverts(env e, GuardianSignals.Id id, address account) {

    setupGuardianSignalsValidState(e);

    unban@withrevert(e, id, account);
    bool reverted = lastReverted;

    assert(!reverted, "unban never reverts under valid state");
}

// GS-RV-19: Listing the committee together with each member's delegate never fails.
rule rvGsGetGuardiansNeverReverts(env e) {

    setupGuardianSignalsValidState(e);

    getGuardians@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "getGuardians never reverts under valid state");
}

// GS-RV-20: Listing every guardian's last scan time never fails.
rule rvGsGetHeartbeatsNeverReverts(env e) {

    setupGuardianSignalsValidState(e);

    getHeartbeats@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "getHeartbeats never reverts under valid state");
}

// GS-RV-21: Reading the guardians' opinion on an account never fails, whatever reports stand against it.
rule rvGsGetOpinionNeverReverts(env e, GuardianSignals.Id id, address account) {

    setupGuardianSignalsValidState(e);

    getOpinion@withrevert(e, id, account);
    bool reverted = lastReverted;

    assert(!reverted, "getOpinion never reverts under valid state");
}

// GS-RV-22: Checking whether an account is banned in a market never fails.
rule rvGsIsBannedNeverReverts(env e, GuardianSignals.Id id, address account) {

    setupGuardianSignalsValidState(e);

    isBanned@withrevert(e, id, account);
    bool reverted = lastReverted;

    assert(!reverted, "isBanned never reverts under valid state");
}

// GS-RV-23: Listing the guardians who flagged an account never fails.
rule rvGsGetFlaggedByNeverReverts(env e, GuardianSignals.Id id, address account) {

    setupGuardianSignalsValidState(e);

    getFlaggedBy@withrevert(e, id, account);
    bool reverted = lastReverted;

    assert(!reverted, "getFlaggedBy never reverts under valid state");
}

// GS-RV-24: Listing the guardians who reported an account, with their report times, never fails.
rule rvGsGetSuspectedByNeverReverts(env e, GuardianSignals.Id id, address account) {

    setupGuardianSignalsValidState(e);

    getSuspectedBy@withrevert(e, id, account);
    bool reverted = lastReverted;

    assert(!reverted, "getSuspectedBy never reverts under valid state");
}

// GS-RV-26: Appointing or revoking a delegate fails exactly when the caller holds no committee seat or the key already sits on the committee.
rule rvGsSetDelegateRevertsIff(env e, address newDelegate) {

    setupGuardianSignalsValidState(e);
    require(forall address g. ghostGsGuardianPositions[to_bytes32(g)] == 0
            || ghostGsDelegates[g] != newDelegate,
        "SCOPE: the key is no seat's hot key; a revoke needs every seat keyed");
    bool notGuardian = ghostGsGuardianPositions[to_bytes32(e.msg.sender)] == 0;
    bool keyIsSeated = ghostGsGuardianPositions[to_bytes32(newDelegate)] != 0;

    setDelegate@withrevert(e, newDelegate);
    bool reverted = lastReverted;

    assert(reverted <=> (notGuardian || keyIsSeated),
        "setDelegate rejects exactly a seatless caller and a seated key");
}

// GS-RV-29: A hot key another guardian already uses cannot be appointed a second time.
rule rvGsSetDelegateRevertsWhenKeyIsTaken(env e, address newDelegate, address other) {

    setupGuardianSignalsValidState(e);
    require(newDelegate != 0, "SCOPE: appointing a key, not revoking one");
    require(ghostGsGuardianPositions[to_bytes32(other)] != 0,
        "SCOPE: the other account holds a seat");
    require(ghostGsDelegates[other] == newDelegate,
        "SCOPE: that seat already acts through this key");

    setDelegate@withrevert(e, newDelegate);

    assert(lastReverted, "one hot key never answers for two seats");
}

// GS-RV-27: Governance swapping a guardian fails exactly when the incoming address is zero or seated, or the outgoing one is absent.
rule rvGsReplaceGuardianRevertsIff(env e, address oldGuardian, address newGuardian) {

    setupGuardianSignalsValidState(e);
    require(forall address g. ghostGsGuardianPositions[to_bytes32(g)] == 0
            || g == oldGuardian || ghostGsDelegates[g] != newGuardian,
        "SCOPE: the incoming address is no other seat's hot key");
    bool zeroIncoming = newGuardian == 0;
    bool incomingSeated = ghostGsGuardianPositions[to_bytes32(newGuardian)] != 0;
    bool outgoingAbsent = ghostGsGuardianPositions[to_bytes32(oldGuardian)] == 0;

    replaceGuardian@withrevert(e, oldGuardian, newGuardian);
    bool reverted = lastReverted;

    assert(reverted <=> (zeroIncoming || incomingSeated || outgoingAbsent),
        "replaceGuardian rejects exactly a zero or seated incoming guardian and an absent outgoing one");
}

// GS-RV-30: An address that already answers as a seat's hot key cannot be seated as a guardian.
rule rvGsAddGuardianRevertsWhenCandidateIsAKey(env e, address guardian, address holder) {

    setupGuardianSignalsValidState(e);
    require(guardian != 0, "SCOPE: a nonzero candidate");
    require(ghostGsGuardianPositions[to_bytes32(holder)] != 0,
        "SCOPE: the holder sits on the committee");
    require(ghostGsDelegates[holder] == guardian,
        "SCOPE: that seat already acts through the candidate");

    addGuardian@withrevert(e, guardian);

    assert(lastReverted, "a standing hot key never takes a seat of its own");
}
