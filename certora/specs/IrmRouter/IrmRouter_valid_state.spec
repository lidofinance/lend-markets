// The single router invariant, that the zero market id is never routed, plus the proxy operational setup the
// property specs import. Owner and manager are assumed nonzero and the initialization latch assumed set
// rather than proven, and under that assumption initialize always reverts.

import "../setup/Irm/IrmRouter/IrmRouter.spec";

function requireIrmRouterInvariants(env e) {
    requireInvariant vsIrrZeroIdNeverRouted(e);
}

// The pins narrow the scene to the deployed proxy; the raw implementation is out of scope.
function setupIrmRouterValidState(env e) {
    setupIrmRouter(e);
    requireIrmRouterInvariants(e);

    require(ghostIrrIsInitialized,
        "TRUSTED: the router is initialized");
    require(ghostIrrOwner != 0,
        "TRUSTED: the owner is nonzero");
    require(ghostIrrManager != 0,
        "TRUSTED: the manager is nonzero");
}

function SETUP_IRR(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupIrmRouter(e);
}

function SETUP_FULL_IRR(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupIrmRouterValidState(e);
}

// IRR-VS-01: The zero market id never carries a rate model.
invariant vsIrrZeroIdNeverRouted(env e)
    forall IrmRouter.Id id. id == to_bytes32(0) => ghostIrrMarketIrm[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_IRR(f) } { preserved with (env eFunc) { SETUP_IRR(e, eFunc); } }
