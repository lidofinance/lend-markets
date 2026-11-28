// Properties of the router over its real bytecode: routing, roles, revert conditions and witnesses. The core
// and the routed rate model are free draws, so what a model computes is proven in its own scene and not here.

import "IrmRouter_valid_state.spec";

// --- transitions ---

// IRR-VT-01: A market that has a rate model never loses it, though the model can be switched.
rule vtIrrRoutedMarketNeverUnroutes(env e, method f, calldataarg args, IrmRouter.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_IRR(f) } {

    setupIrmRouter(e);
    address irmBefore = ghostIrrMarketIrm[id];

    f(e, args);

    assert(irmBefore != 0 => ghostIrrMarketIrm[id] != 0,
        "a routed market never becomes unrouted");
}

// IRR-VT-02: An owner or manager address, once set, is never cleared, though it can be rotated.
rule vtIrrRolesNeverClear(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_IRR(f)
        && f.selector != sig:initialize(address,address).selector } {

    setupIrmRouter(e);
    address ownerBefore = ghostIrrOwner;
    address managerBefore = ghostIrrManager;

    f(e, args);

    assert(ownerBefore != 0 => ghostIrrOwner != 0,
        "the owner is never cleared to the zero address once set");
    assert(managerBefore != 0 => ghostIrrManager != 0,
        "the manager is never cleared to the zero address once set");
}

// IRR-VT-03: Once the router is initialized, nothing can turn that state back off.
rule vtIrrInitializationLatchIsOneWay(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_IRR(f)
        && f.selector != sig:initialize(address,address).selector } {

    setupIrmRouter(e);
    bool initializedBefore = isInitialized(e);

    f(e, args);

    assert(initializedBefore => isInitialized(e),
        "the initialization latch never resets once set");
}

// --- unit_tests ---

// IRR-UT-01: Handing over ownership installs the named successor and leaves the manager untouched.
rule utIrrTransferOwnershipInstallsOwner(env e, address newOwner) {

    setupIrmRouterValidState(e);
    address managerBefore = ghostIrrManager;

    transferOwnership(e, newOwner);

    assert(ghostIrrOwner == newOwner, "transferOwnership installs the supplied owner");
    assert(ghostIrrManager == managerBefore, "transferOwnership leaves the manager alone");
}

// IRR-UT-02: Replacing the manager installs the named address and leaves ownership untouched.
rule utIrrSetManagerInstallsManager(env e, address newManager) {

    setupIrmRouterValidState(e);
    address ownerBefore = ghostIrrOwner;

    setManager(e, newManager);

    assert(ghostIrrManager == newManager, "setManager installs the supplied manager");
    assert(ghostIrrOwner == ownerBefore, "setManager leaves the owner alone");
}

// IRR-UT-03: Routing a market records exactly the rate model supplied and changes neither role.
rule utIrrSetMarketIrmRoutesTheMarket(env e, IrmRouter.MarketParams marketParams, address irm) {

    setupIrmRouterValidState(e);
    IrmRouter.Id id = marketParamsIdCVL(marketParams.loanToken, marketParams.collateralToken,
        marketParams.oracle, marketParams.irm, marketParams.lltv);
    address ownerBefore = ghostIrrOwner;
    address managerBefore = ghostIrrManager;

    setMarketIrm(e, marketParams, irm);

    assert(ghostIrrMarketIrm[id] == irm,
        "setMarketIrm routes the market to the supplied implementation");
    assert(ghostIrrOwner == ownerBefore && ghostIrrManager == managerBefore,
        "setMarketIrm changes no role");
}

// IRR-UT-04: Routing one market leaves every other market's rate model untouched.
rule utIrrSetMarketIrmTouchesOnlyItsOwnMarket(env e, IrmRouter.MarketParams marketParams,
    address irm, IrmRouter.Id otherId) {

    setupIrmRouterValidState(e);
    IrmRouter.Id id = marketParamsIdCVL(marketParams.loanToken, marketParams.collateralToken,
        marketParams.oracle, marketParams.irm, marketParams.lltv);
    address otherIrmBefore = ghostIrrMarketIrm[otherId];

    setMarketIrm(e, marketParams, irm);

    assert(otherId != id => ghostIrrMarketIrm[otherId] == otherIrmBefore,
        "setMarketIrm leaves every other market's route untouched");
}

// IRR-UT-05: Pricing a market through the router changes nothing in the router.
rule utIrrBorrowRateRoutesAndWritesNothing(env e, IrmRouter.MarketParams marketParams,
    IrmRouter.Market market, IrmRouter.Id anyId) {

    setupIrmRouterValidState(e);
    IrmRouter.Id id = marketParamsIdCVL(marketParams.loanToken, marketParams.collateralToken,
        marketParams.oracle, marketParams.irm, marketParams.lltv);
    address ownerBefore = ghostIrrOwner;
    address managerBefore = ghostIrrManager;
    bool initializedBefore = ghostIrrIsInitialized;
    address anyIrmBefore = ghostIrrMarketIrm[anyId];

    borrowRate(e, marketParams, market);

    assert(ghostIrrMarketIrm[id] != 0, "borrowRate prices only a market that carries a route");
    assert(ghostIrrOwner == ownerBefore && ghostIrrManager == managerBefore
        && ghostIrrIsInitialized == initializedBefore,
        "borrowRate changes no role and never moves the init latch");
    assert(ghostIrrMarketIrm[anyId] == anyIrmBefore, "borrowRate changes no market's route");
}

// --- reachability ---

// IRR-RC-01: Morpho can get a live borrow rate for a market that has a rate model.
rule rcIrrBorrowRateIsReachable(env e, IrmRouter.MarketParams marketParams, IrmRouter.Market market) {

    setupIrmRouterValidState(e);
    IrmRouter.Id id = marketParamsIdCVL(marketParams.loanToken, marketParams.collateralToken,
        marketParams.oracle, marketParams.irm, marketParams.lltv);
    require(e.msg.sender == currentContract.MORPHO, "SCOPE: the caller is Morpho");
    require(ghostIrrMarketIrm[id] != 0, "SCOPE: the market carries a route");

    uint256 rate = borrowRate(e, marketParams, market);

    satisfy(rate > 0, "Morpho can price a routed market through the router");
}

// IRR-RC-02: An outsider holding no role can quote the borrow rate of a routed market.
rule rcIrrBorrowRateViewIsReachable(env e, IrmRouter.MarketParams marketParams, IrmRouter.Market market) {

    setupIrmRouterValidState(e);
    IrmRouter.Id id = marketParamsIdCVL(marketParams.loanToken, marketParams.collateralToken,
        marketParams.oracle, marketParams.irm, marketParams.lltv);
    require(ghostIrrMarketIrm[id] != 0, "SCOPE: the market carries a route");
    require(e.msg.sender != currentContract.MORPHO && e.msg.sender != ghostIrrOwner
        && e.msg.sender != ghostIrrManager,
        "SCOPE: the caller holds no role and is not Morpho");

    uint256 rate = borrowRateView(e, marketParams, market);

    satisfy(rate > 0, "an outsider can quote a routed market through the permissionless view");
}

// IRR-RC-03: The owner or the manager can give a market its first rate model.
rule rcIrrSetMarketIrmFreshIsReachable(env e, IrmRouter.MarketParams marketParams, address irm) {

    setupIrmRouterValidState(e);
    IrmRouter.Id id = marketParamsIdCVL(marketParams.loanToken, marketParams.collateralToken,
        marketParams.oracle, marketParams.irm, marketParams.lltv);
    require(e.msg.sender == ghostIrrOwner || e.msg.sender == ghostIrrManager,
        "SCOPE: the caller is the owner or the manager");
    require(irm != 0, "SCOPE: a nonzero implementation");
    require(marketParams.irm == currentContract,
        "SCOPE: the market names this router as its irm");
    require(ghostIrrMarketIrm[id] == 0, "SCOPE: the market carries no route yet");

    setMarketIrm(e, marketParams, irm);

    satisfy(ghostIrrMarketIrm[id] == irm && ghostIrrMarketIrm[id] != 0,
        "an authorized caller can route a fresh market to an implementation");
}

// IRR-RC-04: Two different markets can be routed one after the other, each to its own rate model.
rule rcIrrSetMarketIrmRoutingChainIsReachable(env e, IrmRouter.MarketParams marketParamsA, address irmA,
    IrmRouter.MarketParams marketParamsB, address irmB) {

    setupIrmRouterValidState(e);
    IrmRouter.Id idA = marketParamsIdCVL(marketParamsA.loanToken, marketParamsA.collateralToken,
        marketParamsA.oracle, marketParamsA.irm, marketParamsA.lltv);
    IrmRouter.Id idB = marketParamsIdCVL(marketParamsB.loanToken, marketParamsB.collateralToken,
        marketParamsB.oracle, marketParamsB.irm, marketParamsB.lltv);
    require(e.msg.sender == ghostIrrOwner || e.msg.sender == ghostIrrManager,
        "SCOPE: the caller is the owner or the manager");
    require(irmA != 0 && irmB != 0, "SCOPE: nonzero implementations");
    require(marketParamsA.irm == currentContract && marketParamsB.irm == currentContract,
        "SCOPE: both markets name this router as their irm");

    setMarketIrm(e, marketParamsA, irmA);
    setMarketIrm(e, marketParamsB, irmB);

    satisfy(idA != idB && ghostIrrMarketIrm[idA] == irmA && ghostIrrMarketIrm[idB] == irmB,
        "two distinct markets can be routed in sequence");
}

// IRR-RC-05: It is possible to initialize a fresh router, installing the owner and the manager and locking initialization.
rule rcIrrInitializeIsReachable(env e, address owner_, address manager_) {

    setupIrmRouter(e);
    requireIrmRouterInvariants(e);
    require(!ghostIrrIsInitialized,
        "SCOPE: the router is not initialized yet");
    require(owner_ != 0, "SCOPE: a nonzero owner argument");
    require(manager_ != 0, "SCOPE: a nonzero manager argument");

    initialize(e, owner_, manager_);

    satisfy(ghostIrrIsInitialized && ghostIrrOwner == owner_ && ghostIrrManager == manager_,
        "initialize latches the router and installs both roles in one call");
}

// --- reverts ---

// IRR-RV-01: The router can be initialized only once.
rule rvIrrInitializeAlwaysReverts(env e, address newOwner, address newManager) {

    setupIrmRouterValidState(e);

    initialize@withrevert(e, newOwner, newManager);

    assert(lastReverted, "initialize always reverts once the router is initialized");
}

// IRR-RV-02: Routing a market fails for an unauthorized caller, a zero rate model, or a market that names another router.
rule rvIrrSetMarketIrmRevertsOnGuardFailure(env e, IrmRouter.MarketParams marketParams, address irm) {

    setupIrmRouterValidState(e);
    bool notAuthorized = e.msg.sender != ghostIrrOwner && e.msg.sender != ghostIrrManager;
    bool zeroIrm = irm == 0;
    bool notRouterMarket = marketParams.irm != currentContract;

    setMarketIrm@withrevert(e, marketParams, irm);

    assert((notAuthorized || zeroIrm || notRouterMarket) => lastReverted,
        "setMarketIrm rejects an unauthorized caller, a zero implementation and a foreign market");
}

// IRR-RV-03: Asking for a live rate fails for any caller other than Morpho and for a market with no rate model.
rule rvIrrBorrowRateRevertsOnGuardFailure(env e, IrmRouter.MarketParams marketParams,
    IrmRouter.Market market) {

    setupIrmRouterValidState(e);
    bool notMorpho = e.msg.sender != MORPHO(e);
    IrmRouter.Id id = summaryMarketParamsId(marketParams);
    bool irmNotSet = ghostIrrMarketIrm[id] == 0;

    borrowRate@withrevert(e, marketParams, market);

    assert((notMorpho || irmNotSet) => lastReverted,
        "borrowRate rejects a caller other than Morpho and an unrouted market");
}

// IRR-RV-04: Quoting a market that has no rate model fails.
rule rvIrrBorrowRateViewRevertsWhenIrmNotSet(env e, IrmRouter.MarketParams marketParams,
    IrmRouter.Market market) {

    setupIrmRouterValidState(e);
    IrmRouter.Id id = summaryMarketParamsId(marketParams);
    bool irmNotSet = ghostIrrMarketIrm[id] == 0;

    borrowRateView@withrevert(e, marketParams, market);

    assert(irmNotSet => lastReverted, "borrowRateView rejects an unrouted market");
}

// IRR-RV-05: Handing over ownership fails exactly when the caller is not the owner or the new owner is zero.
rule rvIrrTransferOwnershipRevertsIff(env e, address newOwner) {

    setupIrmRouterValidState(e);
    bool notOwner = e.msg.sender != ghostIrrOwner;
    bool zeroNewOwner = newOwner == 0;

    transferOwnership@withrevert(e, newOwner);

    assert(lastReverted <=> (notOwner || zeroNewOwner),
        "transferOwnership rejects exactly a non-owner caller and the zero owner");
}

// IRR-RV-06: Replacing the manager fails exactly when the caller is not the owner or the new manager is zero.
rule rvIrrSetManagerRevertsIff(env e, address newManager) {

    setupIrmRouterValidState(e);
    bool notOwner = e.msg.sender != ghostIrrOwner;
    bool zeroNewManager = newManager == 0;

    setManager@withrevert(e, newManager);

    assert(lastReverted <=> (notOwner || zeroNewManager),
        "setManager rejects exactly a non-owner caller and the zero manager");
}

// --- access_control ---

// IRR-AC-01: Only the current owner can hand over ownership.
rule acIrrOnlyOwnerModifiesOwner(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_IRR(f)
        && f.selector != sig:initialize(address,address).selector } {

    env eFunc;
    SETUP_FULL_IRR(e, eFunc);
    address ownerBefore = ghostIrrOwner;

    f(e, args);

    assert(ghostIrrOwner != ownerBefore => e.msg.sender == ownerBefore,
        "only the current owner changes the owner");
}

// IRR-AC-02: Only the owner can replace the router's manager.
rule acIrrOnlyOwnerModifiesManager(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_IRR(f)
        && f.selector != sig:initialize(address,address).selector } {

    env eFunc;
    SETUP_FULL_IRR(e, eFunc);
    address ownerBefore = ghostIrrOwner;
    address managerBefore = _IrmRouter.manager(e);

    f(e, args);

    assert(_IrmRouter.manager(e) != managerBefore => e.msg.sender == ownerBefore,
        "only the owner changes the manager");
}

// IRR-AC-03: Only the owner or the manager can point a market at a rate model.
rule acIrrOnlyAuthorizedModifiesMarketIrm(env e, method f, calldataarg args, IrmRouter.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_IRR(f)
        && f.selector != sig:initialize(address,address).selector } {

    env eFunc;
    SETUP_FULL_IRR(e, eFunc);
    address ownerBefore = ghostIrrOwner;
    address managerBefore = _IrmRouter.manager(e);
    address irmBefore = ghostIrrMarketIrm[id];

    f(e, args);

    assert(ghostIrrMarketIrm[id] != irmBefore
        => e.msg.sender == ownerBefore || e.msg.sender == managerBefore,
        "only the owner or the manager routes a market");
}

// IRR-AC-04: The Morpho address the router trusts is fixed at deployment and never changes.
rule acIrrMorphoImmutable(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_IRR(f)
        && f.selector != sig:initialize(address,address).selector } {

    env eFunc;
    SETUP_FULL_IRR(e, eFunc);
    address morphoBefore = _IrmRouter.MORPHO(e);

    f(e, args);

    assert(_IrmRouter.MORPHO(e) == morphoBefore, "the Morpho address is immutable");
}
