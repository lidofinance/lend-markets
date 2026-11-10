// The quorum scan frontier's update law: it never moves backwards, and each advance is backed by a quorum
// that scanned that far. It is a high water mark over past advances, not a claim about the current committee,
// which is capped at three seats.

import "../setup/GuardianSignals/GuardianSignals_base.spec";

methods {
    // Scene cleanup: the role mutators, which GuardianSignals_access_control_roles.spec covers on its own scene.
    function GuardianSignals.grantRole(bytes32, address) external => NONDET DELETE;
    function GuardianSignals.revokeRole(bytes32, address) external => NONDET DELETE;
    function GuardianSignals.renounceRole(bytes32, address) external => NONDET DELETE;
}

function setupGuardianSignalsSync(env e) {
    setupEnv(e);
}

// The committee mirror is capped at three slots, so three names cover it exhaustively.
function requireCommitteeSlotsGs(address g0, address g1, address g2) {
    require(ghostGsGuardianValues[0] == to_bytes32(g0)
        && ghostGsGuardianValues[1] == to_bytes32(g1)
        && ghostGsGuardianValues[2] == to_bytes32(g2),
        "SAFE: naming the mirrored committee slots constrains nothing");
    require((ghostGsGuardiansLen > 1 => g0 != g1)
        && (ghostGsGuardiansLen > 2 => (g0 != g2 && g1 != g2)),
        "SAFE: the committee set's index to position bijection, an OZ EnumerableSet fact");
}

// How many of the live committee slots report having scanned at least as far as `mark`.
function committeeScannedCountGs(mathint mark, address g0, address g1, address g2) returns mathint {
    return (ghostGsGuardiansLen > 0 && ghostGsHeartbeats40[g0] >= mark ? 1 : 0)
        + (ghostGsGuardiansLen > 1 && ghostGsHeartbeats40[g1] >= mark ? 1 : 0)
        + (ghostGsGuardiansLen > 2 && ghostGsHeartbeats40[g2] >= mark ? 1 : 0);
}

// How many of the live committee slots report having scanned strictly past `mark`.
function committeeAheadCountGs(mathint mark, address g0, address g1, address g2) returns mathint {
    return (ghostGsGuardiansLen > 0 && ghostGsHeartbeats40[g0] > mark ? 1 : 0)
        + (ghostGsGuardiansLen > 1 && ghostGsHeartbeats40[g1] > mark ? 1 : 0)
        + (ghostGsGuardiansLen > 2 && ghostGsHeartbeats40[g2] > mark ? 1 : 0);
}

// GS-VS-13: The guardian scan frontier never runs ahead of the current block time.
invariant frontierNotInFuture(env e)
    ghostGsQuorumFrontierTimestamp40 <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_GS(f) } { preserved with (env eFunc) {
    requireSameEnv(e, eFunc);
    setupGuardianSignalsSync(e);
    require(forall address g. ghostGsHeartbeats40[g] <= to_mathint(e.block.timestamp),
        "PROVED: no heartbeat stands ahead of the current block");
} }

// GS-VT-06: The guardian scan frontier only ever moves forward, never back to an earlier time.
rule quorumFrontierNeverRegresses(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsSync(e);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    f(e, args);

    assert(ghostGsQuorumFrontierTimestamp40 >= frontierBefore,
        "the quorum-scan frontier never moves backwards");
}

// GS-VT-07: Only the quorum scan changes the guardian frontier, whether it is called directly or reached through a heartbeat.
rule quorumFrontierMovesOnlyInSync(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignalsSync(e);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    f(e, args);

    assert(ghostGsQuorumFrontierTimestamp40 != frontierBefore
        => (f.selector == sig:syncQuorumFrontier().selector
            || f.selector == sig:heartbeat(address, GuardianSignals.BlockInfoWithHash).selector),
        "only the quorum-scan sync writes the frontier");
}

// GS-UT-52: A scan leaves the frontier alone when no quorum is set or the committee is smaller than the quorum.
rule syncBelowQuorumLeavesFrontierUntouched(env e) {

    setupGuardianSignalsSync(e);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    syncQuorumFrontier(e);

    assert((ghostGsQuorum8 == 0 || ghostGsGuardiansLen < ghostGsQuorum8)
        => ghostGsQuorumFrontierTimestamp40 == frontierBefore,
        "a sub-quorum committee leaves the frontier untouched");
}

// GS-UT-53: The frontier advances only as far as a quorum of guardians has already scanned.
rule frontierAdvanceIsBackedByQuorum(env e, address g0, address g1, address g2) {

    setupGuardianSignalsSync(e);
    requireCommitteeSlotsGs(g0, g1, g2);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    syncQuorumFrontier(e);

    mathint frontierAfter = ghostGsQuorumFrontierTimestamp40;

    assert(frontierAfter > frontierBefore
        => committeeScannedCountGs(frontierAfter, g0, g1, g2) >= ghostGsQuorum8,
        "a quorum of guardians have scanned up to the frontier the sync just set");
}

// GS-UT-54: After an advance, fewer than a quorum of guardians have scanned past the new frontier.
rule frontierAdvanceIsNotAboveQuorumthHighest(env e, address g0, address g1, address g2) {

    setupGuardianSignalsSync(e);
    requireCommitteeSlotsGs(g0, g1, g2);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    syncQuorumFrontier(e);

    mathint frontierAfter = ghostGsQuorumFrontierTimestamp40;

    assert(frontierAfter > frontierBefore
        => committeeAheadCountGs(frontierAfter, g0, g1, g2) < ghostGsQuorum8,
        "no quorum of guardians is strictly ahead of the frontier the sync just set");
}

// GS-UT-55: When the committee can reach quorum, a scan leaves the frontier alone only if fewer than a quorum have passed it.
rule syncKeepsFrontierOnlyWhenItAlreadyDominatesTheCommittee(env e, address g0, address g1, address g2) {

    setupGuardianSignalsSync(e);
    requireCommitteeSlotsGs(g0, g1, g2);
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    syncQuorumFrontier(e);

    assert(ghostGsQuorum8 > 0 && ghostGsGuardiansLen >= ghostGsQuorum8
        && ghostGsQuorumFrontierTimestamp40 == frontierBefore
        => committeeAheadCountGs(frontierBefore, g0, g1, g2) < ghostGsQuorum8,
        "a sync that leaves the frontier put found no quorum of the committee ahead of it");
}

// GS-UT-61: A heartbeat moves the frontier only when it carries its own seat past it.
rule utGsHeartbeatWithoutCrossingKeepsFrontier(env e, address onBehalf,
    GuardianSignals.BlockInfoWithHash blk) {

    setupGuardianSignalsSync(e);
    mathint scanBefore = ghostGsHeartbeats40[onBehalf];
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    heartbeat(e, onBehalf, blk);

    assert(!(scanBefore <= frontierBefore && to_mathint(blk.timestamp) > frontierBefore)
        => ghostGsQuorumFrontierTimestamp40 == frontierBefore,
        "a beat that does not carry its own seat past the frontier leaves the frontier where it was");
}

// GS-HL-34: Raising the quorum leaves the frontier where the smaller quorum had already set it.
rule quorumRaiseKeepsStaleFrontier(env e, uint256 newQuorum, address g0, address g1, address g2) {

    setupGuardianSignalsSync(e);
    requireCommitteeSlotsGs(g0, g1, g2);

    mathint quorumBefore = ghostGsQuorum8;
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;
    require(to_mathint(newQuorum) > quorumBefore, "SCOPE: the quorum-raise scenario");
    require(committeeScannedCountGs(frontierBefore, g0, g1, g2) < to_mathint(newQuorum),
        "SCOPE: the raised quorum has not collectively reached the stored frontier");

    setQuorum(e, newQuorum);
    syncQuorumFrontier(e);

    assert(ghostGsQuorumFrontierTimestamp40 == frontierBefore,
        "the ratchet keeps the pre-raise frontier though the raised quorum never scanned that far");
}

// GS-RC-25: It is possible for a raised quorum to inherit a frontier only the smaller quorum backed.
rule quorumRaiseStaleFrontierWitness(env e, uint256 newQuorum, address g0, address g1, address g2) {

    setupGuardianSignalsSync(e);
    requireCommitteeSlotsGs(g0, g1, g2);

    mathint quorumBefore = ghostGsQuorum8;
    mathint frontierBefore = ghostGsQuorumFrontierTimestamp40;

    setQuorum(e, newQuorum);
    syncQuorumFrontier(e);

    satisfy(to_mathint(newQuorum) > quorumBefore
        && frontierBefore > 0
        && ghostGsQuorumFrontierTimestamp40 == frontierBefore
        && committeeScannedCountGs(frontierBefore, g0, g1, g2) < to_mathint(newQuorum),
        "reachable: getOpinion reports a frontier the sitting quorum never collectively scanned");
}

// GS-RC-26: Right after the quorum is set, a quorum of guardians can already have scanned past the stored frontier.
rule setQuorumStaleFrontierWitness(env e, uint256 newQuorum, address g0, address g1, address g2) {

    setupGuardianSignalsSync(e);
    requireCommitteeSlotsGs(g0, g1, g2);

    setQuorum(e, newQuorum);

    satisfy(committeeAheadCountGs(ghostGsQuorumFrontierTimestamp40, g0, g1, g2) >= ghostGsQuorum8,
        "a full quorum can sit strictly past the frontier until someone calls the permissionless sync");
}

// GS-RC-27: A guardian opinion can report a frontier that a permissionless scan advances in the same block.
rule opinionFrontierStaleUntilSync(env e, GuardianSignals.Id id, address a) {

    setupGuardianSignalsSync(e);
    requireInvariant frontierNotInFuture(e);
    require(forall address g. ghostGsHeartbeats40[g] <= to_mathint(e.block.timestamp),
        "PROVED: no heartbeat stands ahead of the current block");

    GuardianSignals.GuardiansOpinion opBefore = getOpinion(e, id, a);

    syncQuorumFrontier(e);

    GuardianSignals.GuardiansOpinion opAfter = getOpinion(e, id, a);

    satisfy(to_mathint(opAfter.quorumFrontierTimestamp) > to_mathint(opBefore.quorumFrontierTimestamp),
        "a same-block permissionless sync strictly advances the frontier getOpinion just reported");
}

// GS-RV-28: Anyone can run the scan that refreshes the guardian frontier, and the call never fails.
rule rvGsSyncQuorumFrontierNeverReverts(env e) {

    setupGuardianSignalsSync(e);

    syncQuorumFrontier@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "the quorum-scan sync never reverts, whoever calls it");
}
