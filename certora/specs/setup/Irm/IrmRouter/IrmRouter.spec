// IrmRouter setup: the erc7201 storage mirrors and a summary for every call the router makes out of the scene.
// Verified from source, no harness: `layout at erc7201(...)` forbids a subclass, and every field the rules read
// (owner, manager, isInitialized, MORPHO, marketIrm) is already public.

import "../../env.spec";
import "../../marketParamsLib.spec";

using IrmRouter as _IrmRouter;

methods {
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    // Morpho core is out of this scene; the router only tests `lastUpdate` and calls accrueInterest.
    function _.market(IrmRouter.Id) external => NONDET;
    function _.accrueInterest(IrmRouter.MarketParams) external => NONDET;

    // The dispatched implementation only, not ALL: the router's own borrowRate and borrowRateView stay real.
    function _.borrowRate(IrmRouter.MarketParams, IrmRouter.Market) external => NONDET;
    function _.borrowRateView(IrmRouter.MarketParams, IrmRouter.Market) external => NONDET;
}

definition EXCLUDED_FUNCTION_IRR(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

// No boundary pins: no bounded array, no rate math, no read of the forwarded market fields.
function setupIrmRouter(env e) {
    setupEnv(e);
}

// manager and isInitialized share a slot, so a write havocs the sibling ghost; read it back via the getter.

persistent ghost address ghostIrrOwner {
    init_state axiom ghostIrrOwner == 0;
}

persistent ghost address ghostIrrManager {
    init_state axiom ghostIrrManager == 0;
}

persistent ghost bool ghostIrrIsInitialized {
    init_state axiom ghostIrrIsInitialized == false;
}

hook Sload address val _IrmRouter.owner {
    require(ghostIrrOwner == val, "SAFE: ghostIrrOwner sync");
}
hook Sstore _IrmRouter.owner address val {
    ghostIrrOwner = val;
}

hook Sload address val _IrmRouter.manager {
    require(ghostIrrManager == val, "SAFE: ghostIrrManager sync");
}
hook Sstore _IrmRouter.manager address val {
    ghostIrrManager = val;
}

hook Sload bool val _IrmRouter.isInitialized {
    require(ghostIrrIsInitialized == val, "SAFE: ghostIrrIsInitialized sync");
}
hook Sstore _IrmRouter.isInitialized bool val {
    ghostIrrIsInitialized = val;
}

persistent ghost mapping(IrmRouter.Id => address) ghostIrrMarketIrm {
    init_state axiom forall IrmRouter.Id id. ghostIrrMarketIrm[id] == 0;
}

hook Sload address val _IrmRouter.marketIrm[KEY IrmRouter.Id id] {
    require(ghostIrrMarketIrm[id] == val, "SAFE: ghostIrrMarketIrm sync");
}
hook Sstore _IrmRouter.marketIrm[KEY IrmRouter.Id id] address val {
    ghostIrrMarketIrm[id] = val;
}
