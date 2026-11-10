// Who may move a role row: a role is granted only by the holder of its admin role, and removed only by that
// admin or by its own holder. Role state is a CVL model, not storage, and the quorum scan entry is folded
// out.

import "../setup/GuardianSignals/GuardianSignals_base.spec";

methods {
    // Scene cleanup: the quorum scan entry, owned by GuardianSignals_frontier.spec; the role mutators stay in.
    function GuardianSignals.syncQuorumFrontier() external => NONDET DELETE;
}

// GS-AC-10: Only a role's admin can grant that role.
rule roleGrantedOnlyByItsAdmin(env e, method f, calldataarg args, bytes32 role, address account)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    bool heldBefore = ghostGsHasRole[role][account];

    f(e, args);

    assert((!heldBefore && ghostGsHasRole[role][account])
        => ghostGsHasRole[ghostGsRoleAdmin[role]][e.msg.sender],
        "a role is granted only by the holder of that role's admin role");
}

// GS-AC-11: Only a role's admin can revoke that role, apart from a holder giving up their own.
rule roleRevokedOnlyByItsAdminOrItsHolder(env e, method f, calldataarg args, bytes32 role, address account)
    filtered { f -> !EXCLUDED_FUNCTION_GS(f) } {

    setupGuardianSignals(e);
    bool heldBefore = ghostGsHasRole[role][account];

    f(e, args);

    assert((heldBefore && !ghostGsHasRole[role][account])
        => (ghostGsHasRole[ghostGsRoleAdmin[role]][e.msg.sender] || account == e.msg.sender),
        "a role is revoked only by that role's admin, or renounced by its own holder");
}
