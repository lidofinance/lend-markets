// The controller's role administration: who may grant, revoke or renounce a role, and that no call changes a
// role's admin. Role membership and admins are read from the model in the controller setup; nothing calls
// _setRoleAdmin, so every role keeps the default admin role.

import "../setup/LidoLendMarketController/LidoLendMarketController_base.spec";

methods {
    // Summarized here so the getters answer from the rows the mutators write.
    function LidoLendMarketController.hasRole(bytes32 role, address account) internal returns (bool)
        => ghostMcHasRole[role][account];
    function LidoLendMarketController.getRoleAdmin(bytes32 role) internal returns (bytes32)
        => ghostMcRoleAdmin[role];
}

// MC-AC-12: Only a role's admin can grant or revoke it, apart from a holder giving up their own.
rule acMcOnlyDefaultAdminMovesControllerRoles(env e, method f, calldataarg args,
    bytes32 role, address account)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    require(role == _Controller.MANAGER_ROLE()
        || role == _Controller.FREEZER_ROLE()
        || role == _Controller.UNFREEZER_ROLE()
        || role == _Controller.PAUSER_ROLE()
        || role == _Controller.RESUMER_ROLE()
        || role == _Controller.DEFAULT_ADMIN_ROLE(),
        "SCOPE: the six roles the controller declares");
    bool memberBefore = ghostMcHasRole[role][account];

    f(e, args);

    bool memberAfter = ghostMcHasRole[role][account];
    assert(memberAfter != memberBefore
        => (ghostMcHasRole[_Controller.DEFAULT_ADMIN_ROLE()][e.msg.sender]
            || (account == e.msg.sender && memberBefore && !memberAfter)),
        "a controller role moves only for the default admin, or by its holder renouncing");
}

// MC-AC-13: Which role may grant and revoke a controller role never changes.
rule acMcRoleAdminNeverMoves(env e, method f, calldataarg args, bytes32 role)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bytes32 adminBefore = ghostMcRoleAdmin[role];

    f(e, args);

    assert(ghostMcRoleAdmin[role] == adminBefore, "no call re-points a role's admin");
}
