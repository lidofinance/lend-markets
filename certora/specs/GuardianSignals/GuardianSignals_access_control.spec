// Each rule names the authority a piece of state requires: snapshot it, invoke any external method,
// assert it moved only if the caller held that role or committee seat.

import "GuardianSignals_valid_state.spec";

// GS-AC-01: Only a governance manager can change how many guardian flags it takes to ban an account.
rule acGsOnlyManagerMovesQuorum(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    mathint quorumBefore = ghostGsQuorum8;

    f(e, args);

    assert(ghostGsQuorum8 != quorumBefore
        => ghostGsHasRole[_Signals.MANAGER_ROLE()][e.msg.sender],
        "the quorum moves only for a manager");
}

// GS-AC-02: Only a governance manager can change how long a guardian's suspect report keeps counting.
rule acGsOnlyManagerMovesSuspectWindow(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    mathint windowBefore = ghostGsSuspectWindow40;

    f(e, args);

    assert(ghostGsSuspectWindow40 != windowBefore
        => ghostGsHasRole[_Signals.MANAGER_ROLE()][e.msg.sender],
        "the suspect window moves only for a manager");
}

// GS-AC-03: An account is banned only by the access limiter or by guardian strikes reaching quorum.
rule acGsBanLatchedOnlyByLimiterOrFlagger(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    bool bannedBefore = ghostGsSigBanned[id][a];
    mathint strikesBefore = ghostGsFlaggedByLen[id][a];

    f(e, args);

    assert((!bannedBefore && ghostGsSigBanned[id][a])
        => (ghostGsHasRole[_Signals.ACCESS_LIMITER_ROLE()][e.msg.sender]
            || strikesBefore >= ghostGsQuorum8
            || ghostGsFlaggedByLen[id][a] >= ghostGsQuorum8),
        "a ban latches only for the access limiter or a flagger set at quorum");
}

// GS-AC-04: Only the access restorer can lift a latched ban.
rule acGsBanLiftedOnlyByRestorer(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    bool bannedBefore = ghostGsSigBanned[id][a];

    f(e, args);

    assert((bannedBefore && !ghostGsSigBanned[id][a])
        => ghostGsHasRole[_Signals.ACCESS_RESTORER_ROLE()][e.msg.sender],
        "a latched ban is lifted only by an access restorer");
}

// GS-AC-05: Only a governance manager can add or remove a seat on the guardian committee.
rule acGsOnlyManagerMovesCommitteeMembership(env e, method f, calldataarg args, bytes32 v)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    mathint positionBefore = ghostGsGuardianPositions[v];

    f(e, args);

    assert(ghostGsGuardianPositions[v] != positionBefore
        => ghostGsHasRole[_Signals.MANAGER_ROLE()][e.msg.sender],
        "a committee membership row moves only for a manager");
}

// GS-AC-06: Only a guardian or its delegate writes that guardian's last scan time, and only a manager clears it.
rule acGsOnlyGuardianMovesHeartbeat(env e, method f, calldataarg args, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    bool actsForBefore = ACTS_FOR_GS(e.msg.sender, g);
    mathint heartbeatBefore = ghostGsHeartbeats40[g];

    f(e, args);

    assert(ghostGsHeartbeats40[g] != heartbeatBefore
        => (actsForBefore
            || (ghostGsHeartbeats40[g] == 0
                && ghostGsHasRole[_Signals.MANAGER_ROLE()][e.msg.sender])),
        "a heartbeat moves only for its own seat, or is cleared by a manager");
}

// GS-AC-13: A guardian's delegate key changes only at that guardian's own hand, or clears when its seat leaves the committee.
rule acGsDelegateRowMovesOnlyForItsSeat(env e, method f, calldataarg args, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    bool isGuardianBefore = ghostGsGuardianPositions[to_bytes32(g)] != 0;
    address delegateBefore = ghostGsDelegates[g];

    f(e, args);

    assert(ghostGsDelegates[g] != delegateBefore
        => ((e.msg.sender == g && isGuardianBefore)
            || (ghostGsDelegates[g] == 0
                && isGuardianBefore
                && ghostGsGuardianPositions[to_bytes32(g)] == 0)),
        "a delegate row moves only for its own seat, or clears with the seat that just left the committee");
}

// GS-AC-07: A strike is recorded only under the seat the caller acts for, never another guardian's.
rule acGsFlaggerEntryIsCallerOnly(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    requireGsFlaggerSetBijection();
    bool actsForBefore = ACTS_FOR_GS(e.msg.sender, g);
    mathint positionBefore = ghostGsFlaggedByPositions[id][a][to_bytes32(g)];

    f(e, args);

    assert((positionBefore == 0 && ghostGsFlaggedByPositions[id][a][to_bytes32(g)] != 0)
        => actsForBefore,
        "only the seat the caller acts for enters a flagger set");
}

// GS-AC-08: A suspect report is filed only under the seat the caller acts for, never another guardian's.
rule acGsSuspectEntryIsCallerOnly(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    requireGsSuspectSetBijection();
    bool actsForBefore = ACTS_FOR_GS(e.msg.sender, g);
    mathint positionBefore = ghostGsSuspectedByPositions[id][a][to_bytes32(g)];

    f(e, args);

    assert((positionBefore == 0 && ghostGsSuspectedByPositions[id][a][to_bytes32(g)] != 0)
        => actsForBefore,
        "only the seat the caller acts for enters a suspect set");
}

// GS-AC-09: A suspect report's timestamp is set only by the guardian it stands for, or that guardian's delegate.
rule acGsSuspectStampWrittenOnlyBySelf(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a, address g)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    bool actsForBefore = ACTS_FOR_GS(e.msg.sender, g);
    mathint stampBefore = ghostGsSigSuspectedAt40[id][a][g];

    f(e, args);

    assert((ghostGsSigSuspectedAt40[id][a][g] != stampBefore
        && ghostGsSigSuspectedAt40[id][a][g] != 0)
        => actsForBefore,
        "a live suspect stamp is written only for its own seat");
}

// GS-AC-12: A caller with no role and no seat can end a ban only through the permissionless cleanup, and never a latched one.
rule acGsPermissionlessUnbanOnlyByPrune(env e, method f, calldataarg args,
    GuardianSignals.Id id, address a)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f)
        && f.selector != sig:heartbeat(address, GuardianSignals.BlockInfoWithHash).selector
        && f.selector != sig:flag(GuardianSignals.Id, address, address[]).selector
        && f.selector != sig:unflag(GuardianSignals.Id, address, address[]).selector
        && f.selector != sig:suspect(GuardianSignals.Id, address, address[]).selector
        && f.selector != sig:unsuspect(GuardianSignals.Id, address, address[]).selector } {

    setupGuardianSignals(e);
    // The premise sits in the assert antecedent: a require here prunes the caller gated paths.
    bool unprivilegedBefore = !ghostGsHasRole[_Signals.ACCESS_RESTORER_ROLE()][e.msg.sender]
        && !ghostGsHasRole[_Signals.ACCESS_LIMITER_ROLE()][e.msg.sender]
        && !ghostGsHasRole[_Signals.MANAGER_ROLE()][e.msg.sender]
        && ghostGsGuardianPositions[to_bytes32(e.msg.sender)] == 0;
    bool latchBefore = ghostGsSigBanned[id][a];
    bool effectiveBefore = isBanned(e, id, a);

    f(e, args);

    assert((unprivilegedBefore && effectiveBefore && !isBanned(e, id, a))
        => (!latchBefore
            && f.selector == sig:prune(GuardianSignals.Id, address).selector),
        "an unprivileged caller reaches a ban only through the cleanup, and never a latched one");
}
