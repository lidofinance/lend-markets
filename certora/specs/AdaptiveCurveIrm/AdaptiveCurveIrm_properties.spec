// Properties of the adaptive curve rate model over its real bytecode: rate laws, transitions, unit effects,
// revert conditions, witnesses and access control. Config validity is assumed rather than proven, standing on
// the trust discharged in the factory scene.

import "AdaptiveCurveIrm_valid_state.spec";

// --- transitions ---

// ACI-VT-01: A market that has a rate configuration never loses it, though the configuration can be switched.
rule vtAciConfiguredMarketNeverUnconfigures(env e, env eFunc, method f, calldataarg args,
    AdaptiveCurveIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } {

    SETUP_ACI(e, eFunc);
    address configBefore = ghostAciMarketCurveConfig[id];

    f(eFunc, args);

    assert(configBefore != 0 => ghostAciMarketCurveConfig[id] != 0,
        "a configured market can never become unconfigured");
}

// ACI-VT-02: Once a market has a target rate, it never falls back to being unpriced.
rule vtAciPricedMarketNeverUnprices(env e, env eFunc, method f, calldataarg args, AdaptiveCurveIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } {

    SETUP_ACI(e, eFunc);
    mathint rateBefore = ghostAciRateAtTarget[id];

    f(eFunc, args);

    assert(rateBefore != 0 => ghostAciRateAtTarget[id] != 0,
        "a priced market never falls back to the unpriced sentinel");
}

// ACI-ST-01: Giving a market its first configuration leaves it unpriced until the first rate call.
rule stAciFreshConfigNeverPricesMarket(env e, env eFunc, method f, calldataarg args, AdaptiveCurveIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } {

    SETUP_FULL_ACI(e, eFunc);
    address configBefore = ghostAciMarketCurveConfig[id];

    f(eFunc, args);

    assert(configBefore == 0 && ghostAciMarketCurveConfig[id] != 0 => ghostAciRateAtTarget[id] == 0,
        "a first configuration leaves the market unpriced");
}

// ACI-ST-02: Applying a configuration to a priced market pulls its target rate into that configuration's band.
rule stAciConfigRenewalReclampsRateIntoNewBand(env e, AdaptiveCurveIrm.MarketParams marketParams,
    address config) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    mathint rateBefore = ghostAciRateAtTarget[id];
    mathint bandLow = ghostAciCfgMinRateAtTarget[config];
    mathint bandHigh = ghostAciCfgMaxRateAtTarget[config];

    applyIrmConfig(e, marketParams, config);

    mathint rateAfter = ghostAciRateAtTarget[id];

    assert(rateBefore != 0 => ghostAciMarketCurveConfig[id] == config,
        "the re-clamped market points at the config that was applied");
    assert(rateBefore != 0 => (rateAfter >= bandLow && rateAfter <= bandHigh),
        "the live rate is re-clamped into the band the applied config reports");
}

// ACI-ST-03: The new target rate comes from the band of the configuration being applied, not the one replaced.
rule stAciReclampBandComesFromTheNewConfig(env e, AdaptiveCurveIrm.MarketParams marketParams, address config) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address configBefore = ghostAciMarketCurveConfig[id];

    require(ghostAciRateAtTarget[id] != 0, "SCOPE: a priced market");
    require(ghostAciCfgMaxRateAtTarget[configBefore] < ghostAciCfgMinRateAtTarget[config],
        "SCOPE: the old band lies strictly below the new one");

    applyIrmConfig(e, marketParams, config);

    assert(ghostAciRateAtTarget[id] == ghostAciCfgMinRateAtTarget[config],
        "a rate below the new band lands on the new floor, so the clamp read the supplied config");
}

// --- high_level ---

// ACI-HL-01: The quoted borrow rate stays inside the band the market's configuration allows, widened by its curve steepness.
rule hlAciBorrowRateWithinAmplifiedConfigBand(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address config = ghostAciMarketCurveConfig[id];

    mathint rate = borrowRateView(e, marketParams, market);

    assert(rate >= 0, "the quoted rate is never negative");
    assert(rate * WAD_INT_CVL() <= ghostAciCfgCurveSteepness[config] * ghostAciCfgMaxRateAtTarget[config],
        "the quoted rate stays inside the curve amplified band of its config");
    assert(rate <= MAX_BORROW_RATE_LIMIT_CVL(),
        "the quoted rate stays under the ceiling every config shares");
}

// ACI-HL-02: When a configuration sets a borrow rate ceiling, the quoted rate never exceeds it.
rule hlAciBorrowRateCappedByMaxBorrowRate(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    mathint maxBorrowRate = ghostAciCfgMaxBorrowRate[ghostAciMarketCurveConfig[id]];

    mathint rate = borrowRateView(e, marketParams, market);

    assert(maxBorrowRate != 0 => rate <= maxBorrowRate,
        "an enabled ceiling caps the quoted rate for any market");
}

// ACI-HL-03: The quoted borrow rate never falls when more of a market's supply is borrowed.
rule hlAciBorrowRateMonotoneInUtilization(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market marketLo, AdaptiveCurveIrm.Market marketHi) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, marketLo);
    setupMarketAdaptiveCurveIrm(e, marketHi);

    require(forall mathint a. forall mathint b. (a <= b) => (wExpGhostFn(a) <= wExpGhostFn(b)),
        "SCOPE: a monotone exp model");
    require(marketLo.totalSupplyAssets == marketHi.totalSupplyAssets,
        "SCOPE: one supply on both sides");
    require(marketLo.lastUpdate == marketHi.lastUpdate,
        "SCOPE: one instant on both sides");

    mathint borrowLo = marketLo.totalBorrowAssets;
    mathint borrowHi = marketHi.totalBorrowAssets;

    mathint rateLo = borrowRateView(e, marketParams, marketLo);
    mathint rateHi = borrowRateView(e, marketParams, marketHi);

    assert(borrowLo <= borrowHi => rateLo <= rateHi,
        "higher utilization is quoted at a higher or equal rate");
}

// ACI-HL-04: The previewed borrow rate equals the rate the writing call charges on the same state.
rule hlAciBorrowRateMatchesView(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);

    mathint rateView = borrowRateView(e, marketParams, market);
    mathint rateWrite = borrowRate(e, marketParams, market);

    assert(rateView == rateWrite, "the view and the writing path quote the same rate");
}

// ACI-HL-05: On a market's very first pricing, the quoted rate stays inside its configuration's steepness widened band.
rule hlAciBorrowRateWithinAmplifiedBandOnFirstInteraction(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address config = ghostAciMarketCurveConfig[id];

    require(ghostAciRateAtTarget[id] == 0,
        "SCOPE: the first interaction branch");

    mathint rate = borrowRateView(e, marketParams, market);

    assert(rate >= 0, "the quoted rate is never negative");
    assert(rate * WAD_INT_CVL() <= ghostAciCfgCurveSteepness[config] * ghostAciCfgMaxRateAtTarget[config],
        "the first quoted rate stays inside the curve amplified band of its config");
    assert(rate <= MAX_BORROW_RATE_LIMIT_CVL(),
        "the first quoted rate stays under the ceiling every config shares");
}

// ACI-HL-06: With no time elapsed, the quoted rate still never falls as more is borrowed.
rule hlAciBorrowRateMonotoneInUtilizationWithoutAdaptation(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market marketLo, AdaptiveCurveIrm.Market marketHi) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, marketLo);
    setupMarketAdaptiveCurveIrm(e, marketHi);

    require(marketLo.totalSupplyAssets == marketHi.totalSupplyAssets,
        "SCOPE: one supply on both sides");
    require(to_mathint(marketLo.lastUpdate) == to_mathint(e.block.timestamp)
        && to_mathint(marketHi.lastUpdate) == to_mathint(e.block.timestamp),
        "SCOPE: no elapsed time");

    mathint borrowLo = marketLo.totalBorrowAssets;
    mathint borrowHi = marketHi.totalBorrowAssets;

    mathint rateLo = borrowRateView(e, marketParams, marketLo);
    mathint rateHi = borrowRateView(e, marketParams, marketHi);

    assert(borrowLo <= borrowHi => rateLo <= rateHi,
        "with adaptation frozen, higher utilization is still quoted at a higher or equal rate");
}

// --- unit_tests ---

// ACI-UT-01: Handing over ownership installs the new owner and leaves the manager in place.
rule utAciTransferOwnershipInstallsOwner(env e, address newOwner) {

    setupAdaptiveCurveIrmValidState(e);
    address managerBefore = ghostAciManager;

    transferOwnership(e, newOwner);

    assert(ghostAciOwner == newOwner, "transferOwnership installs the requested owner");
    assert(ghostAciManager == managerBefore, "transferOwnership leaves the manager untouched");
}

// ACI-UT-02: Appointing a new manager installs that manager and leaves ownership unchanged.
rule utAciSetManagerInstallsManager(env e, address newManager) {

    setupAdaptiveCurveIrmValidState(e);
    address ownerBefore = ghostAciOwner;

    setManager(e, newManager);

    assert(ghostAciManager == newManager, "setManager installs the requested manager");
    assert(ghostAciOwner == ownerBefore, "setManager leaves the owner untouched");
}

// ACI-UT-03: Applying a config leaves the market with a config attached and any existing rate at or above the new floor.
rule utAciApplyIrmConfigBindsMarket(env e, AdaptiveCurveIrm.MarketParams marketParams, address config) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    mathint rateBefore = ghostAciRateAtTarget[id];
    address ownerBefore = ghostAciOwner;
    address managerBefore = ghostAciManager;

    applyIrmConfig(e, marketParams, config);

    assert(ghostAciMarketCurveConfig[id] != 0, "the market is bound to a live config");
    assert(rateBefore == 0 => ghostAciRateAtTarget[id] == 0,
        "an unpriced market keeps its zero seed, since the clamp runs only on a priced one");
    assert(rateBefore != 0 => ghostAciRateAtTarget[id] >= ghostAciCfgMinRateAtTarget[config],
        "a priced market's rate is lifted to at least the new floor");
    assert(ghostAciOwner == ownerBefore && ghostAciManager == managerBefore,
        "applying a config changes neither role");
}

// ACI-UT-04: Applying a config to one market leaves every other market's rate and config untouched.
rule utAciApplyIrmConfigTouchesOnlyTargetMarket(env e, AdaptiveCurveIrm.MarketParams marketParams,
    address config, AdaptiveCurveIrm.Id otherId) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    mathint otherRateBefore = ghostAciRateAtTarget[otherId];
    address otherConfigBefore = ghostAciMarketCurveConfig[otherId];

    applyIrmConfig(e, marketParams, config);

    assert(otherId != id => ghostAciRateAtTarget[otherId] == otherRateBefore,
        "another market's rate at target is untouched");
    assert(otherId != id => ghostAciMarketCurveConfig[otherId] == otherConfigBefore,
        "another market's config binding is untouched");
}

// ACI-UT-05: Pricing a market leaves it priced under the same config and never returns a rate above its ceiling.
rule utAciBorrowRateLeavesMarketPricedAndCapped(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address configBefore = ghostAciMarketCurveConfig[id];
    address ownerBefore = ghostAciOwner;
    address managerBefore = ghostAciManager;

    uint256 rate = borrowRate(e, marketParams, market);

    mathint maxBorrowRate = ghostAciCfgMaxBorrowRate[configBefore];

    assert(ghostAciRateAtTarget[id] != 0, "a priced market carries a non zero rate at target");
    assert(ghostAciMarketCurveConfig[id] == configBefore, "borrowRate never rebinds the config");
    assert(maxBorrowRate != 0 => to_mathint(rate) <= maxBorrowRate,
        "an enabled ceiling caps the rate borrowRate reports");
    assert(ghostAciOwner == ownerBefore && ghostAciManager == managerBefore,
        "borrowRate changes neither role");
}

// ACI-UT-06: Pricing one market leaves every other market's stored rate untouched.
rule utAciBorrowRateTouchesOnlyTargetMarket(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market, AdaptiveCurveIrm.Id otherId) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    mathint otherRateBefore = ghostAciRateAtTarget[otherId];

    borrowRate(e, marketParams, market);

    assert(otherId != id => ghostAciRateAtTarget[otherId] == otherRateBefore,
        "another market's rate at target is untouched");
}

// ACI-UT-07: The quoted borrow rate is the same for every caller at the same moment.
rule utAciBorrowRateViewIsCallerAgnostic(env e1, env e2, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e1);
    setupAdaptiveCurveIrmValidState(e2);
    require(e1.block.timestamp == e2.block.timestamp, "SCOPE: one instant for both callers");

    storage init = lastStorage;
    uint256 rate1 = borrowRateView(e1, marketParams, market) at init;
    uint256 rate2 = borrowRateView(e2, marketParams, market) at init;

    assert(rate1 == rate2, "the view quotes one rate to every caller");
}

// ACI-UT-08: A market ends up pointing at exactly the config address that was applied.
rule utAciApplyIrmConfigStoresSuppliedConfigAddress(env e, AdaptiveCurveIrm.MarketParams marketParams,
    address config) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    applyIrmConfig(e, marketParams, config);

    assert(ghostAciMarketCurveConfig[id] == config,
        "the market points at exactly the config address that was applied");
}

// ACI-UT-09: A rate already inside the new bounds survives a config swap unchanged.
rule utAciApplyIrmConfigKeepsAnInBandRateUnchanged(env e, AdaptiveCurveIrm.MarketParams marketParams,
    address config) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    mathint rateBefore = ghostAciRateAtTarget[id];

    require(rateBefore != 0, "SCOPE: a priced market");
    require(rateBefore >= ghostAciCfgMinRateAtTarget[config] && rateBefore <= ghostAciCfgMaxRateAtTarget[config],
        "SCOPE: the stored rate already obeys the new band");

    applyIrmConfig(e, marketParams, config);

    assert(ghostAciRateAtTarget[id] == rateBefore,
        "a rate already inside the new band survives the config swap unchanged");
}

// --- reachability ---

// ACI-RC-01: The router can price a newly configured market and give it a first target rate.
rule rcAciBorrowRateFirstInteractionIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    require(e.msg.sender == _Aci.ROUTER(), "SCOPE: borrowRate accepts the router only");
    require(ghostAciMarketCurveConfig[id] != 0, "SCOPE: a configured market");
    require(ghostAciRateAtTarget[id] == 0, "SCOPE: the first interaction branch");

    uint256 rate = borrowRate(e, marketParams, market);

    satisfy(rate > 0 && ghostAciRateAtTarget[id] != 0,
        "a first interaction prices the market and seeds a positive rate at target");
}

// ACI-RC-02: Pricing can carry a market's target rate upward when borrowing sits above target.
rule rcAciBorrowRateAdaptsUpwardIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address config = ghostAciMarketCurveConfig[id];

    require(e.msg.sender == _Aci.ROUTER(), "SCOPE: borrowRate accepts the router only");
    require(ghostAciRateAtTarget[id] != 0, "SCOPE: the adaptation branch");
    require(ghostAciRateAtTarget[id] < ghostAciCfgMaxRateAtTarget[config],
        "SCOPE: a rate below its ceiling");
    require(to_mathint(market.totalSupplyAssets) > 0
        && to_mathint(market.totalBorrowAssets) == to_mathint(market.totalSupplyAssets),
        "SCOPE: full utilization");
    require(to_mathint(market.lastUpdate) < to_mathint(e.block.timestamp), "SCOPE: time has elapsed");

    mathint rateBefore = ghostAciRateAtTarget[id];

    borrowRate(e, marketParams, market);

    satisfy(ghostAciRateAtTarget[id] > rateBefore, "adaptation can carry the rate at target upward");
}

// ACI-RC-03: Pricing can carry a market's target rate downward when borrowing sits below target.
rule rcAciBorrowRateAdaptsDownwardIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address config = ghostAciMarketCurveConfig[id];

    require(e.msg.sender == _Aci.ROUTER(), "SCOPE: borrowRate accepts the router only");
    require(ghostAciRateAtTarget[id] != 0, "SCOPE: the adaptation branch");
    require(ghostAciRateAtTarget[id] > ghostAciCfgMinRateAtTarget[config],
        "SCOPE: a rate above its floor");
    require(to_mathint(market.totalBorrowAssets) == 0,
        "SCOPE: no utilization");
    require(to_mathint(market.lastUpdate) < to_mathint(e.block.timestamp), "SCOPE: time has elapsed");

    mathint rateBefore = ghostAciRateAtTarget[id];

    borrowRate(e, marketParams, market);

    satisfy(ghostAciRateAtTarget[id] < rateBefore, "adaptation can carry the rate at target downward");
}

// ACI-RC-04: A target rate below its ceiling can rise all the way onto that ceiling.
rule rcAciBorrowRateReachesMaxClampIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address config = ghostAciMarketCurveConfig[id];

    require(e.msg.sender == _Aci.ROUTER(), "SCOPE: borrowRate accepts the router only");
    require(ghostAciRateAtTarget[id] != 0, "SCOPE: the adaptation branch");
    require(ghostAciRateAtTarget[id] < ghostAciCfgMaxRateAtTarget[config],
        "SCOPE: a rate below its ceiling");
    require(to_mathint(market.totalSupplyAssets) > 0
        && to_mathint(market.totalBorrowAssets) == to_mathint(market.totalSupplyAssets),
        "SCOPE: full utilization");
    require(to_mathint(market.lastUpdate) < to_mathint(e.block.timestamp), "SCOPE: time has elapsed");

    mathint rateBefore = ghostAciRateAtTarget[id];

    borrowRate(e, marketParams, market);

    satisfy(ghostAciRateAtTarget[id] == ghostAciCfgMaxRateAtTarget[config]
            && ghostAciRateAtTarget[id] != rateBefore,
        "adaptation can carry a rate below its ceiling up onto the config ceiling");
}

// ACI-RC-05: A target rate above its floor can fall all the way onto that floor.
rule rcAciBorrowRateReachesMinClampIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address config = ghostAciMarketCurveConfig[id];

    require(e.msg.sender == _Aci.ROUTER(), "SCOPE: borrowRate accepts the router only");
    require(ghostAciRateAtTarget[id] != 0, "SCOPE: the adaptation branch");
    require(ghostAciRateAtTarget[id] > ghostAciCfgMinRateAtTarget[config],
        "SCOPE: a rate above its floor");
    require(to_mathint(market.totalBorrowAssets) == 0,
        "SCOPE: no utilization");
    require(to_mathint(market.lastUpdate) < to_mathint(e.block.timestamp), "SCOPE: time has elapsed");

    mathint rateBefore = ghostAciRateAtTarget[id];

    borrowRate(e, marketParams, market);

    satisfy(ghostAciRateAtTarget[id] == ghostAciCfgMinRateAtTarget[config]
            && ghostAciRateAtTarget[id] != rateBefore,
        "adaptation can carry a rate above its floor down onto the config floor");
}

// ACI-RC-06: A market with nothing borrowed can still be quoted a positive interest rate.
rule rcAciBorrowRateAtZeroUtilizationIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    require(e.msg.sender == _Aci.ROUTER(), "SCOPE: borrowRate accepts the router only");
    require(ghostAciMarketCurveConfig[id] != 0, "SCOPE: a configured market");
    require(ghostAciRateAtTarget[id] == 0, "SCOPE: the first interaction branch");
    require(to_mathint(market.totalBorrowAssets) == 0, "SCOPE: the zero utilization boundary");

    uint256 rate = borrowRate(e, marketParams, market);

    satisfy(rate > 0, "a market with nothing borrowed still quotes a positive rate");
}

// ACI-RC-07: A fully borrowed market can still be quoted a positive interest rate.
rule rcAciBorrowRateAtFullUtilizationIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    require(e.msg.sender == _Aci.ROUTER(), "SCOPE: borrowRate accepts the router only");
    require(ghostAciMarketCurveConfig[id] != 0, "SCOPE: a configured market");
    require(ghostAciRateAtTarget[id] == 0, "SCOPE: the first interaction branch");
    require(to_mathint(market.totalSupplyAssets) > 0
        && to_mathint(market.totalBorrowAssets) == to_mathint(market.totalSupplyAssets),
        "SCOPE: the full utilization boundary");

    uint256 rate = borrowRate(e, marketParams, market);

    satisfy(rate > 0, "a fully drawn market quotes a positive rate");
}

// ACI-RC-08: Anyone can preview a positive borrow rate for a configured market.
rule rcAciBorrowRateViewIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    setupMarketAdaptiveCurveIrm(e, market);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    require(ghostAciMarketCurveConfig[id] != 0, "SCOPE: a configured market");

    uint256 rate = borrowRateView(e, marketParams, market);

    satisfy(rate > 0, "the view quotes a positive rate");
}

// ACI-RC-09: It is possible to preview a rate for a market that borrowed more than it holds.
rule rcAciBorrowRateViewAboveWadUtilizationIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    require(ghostAciMarketCurveConfig[id] != 0, "SCOPE: a configured market");
    require(to_mathint(market.totalSupplyAssets) > 0
        && to_mathint(market.totalBorrowAssets) > to_mathint(market.totalSupplyAssets),
        "SCOPE: a utilization above WAD");

    uint256 rate = borrowRateView(e, marketParams, market);

    satisfy(rate > 0, "the view answers a market whose utilization is above WAD");
}

// ACI-RC-10: The owner or the manager can give a market its first rate configuration.
rule rcAciApplyIrmConfigOnFreshMarketIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    address config) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    require(e.msg.sender == ghostAciOwner || e.msg.sender == ghostAciManager,
        "SCOPE: the owner or the manager as the caller");
    require(ghostAciMarketCurveConfig[id] == 0, "SCOPE: a market with no config yet");

    applyIrmConfig(e, marketParams, config);

    satisfy(ghostAciMarketCurveConfig[id] != 0, "a fresh market can be bound to a config");
}

// ACI-RC-11: The owner or the manager can move a live market onto a different configuration, and it stays priced.
rule rcAciApplyIrmConfigReconfigureIsReachable(env e, AdaptiveCurveIrm.MarketParams marketParams,
    address config) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);
    address configBefore = ghostAciMarketCurveConfig[id];

    require(e.msg.sender == ghostAciOwner || e.msg.sender == ghostAciManager,
        "SCOPE: the owner or the manager as the caller");
    require(ghostAciRateAtTarget[id] != 0, "SCOPE: a market that is already priced");
    require(config != configBefore, "SCOPE: a second, different config address");

    applyIrmConfig(e, marketParams, config);

    satisfy(ghostAciMarketCurveConfig[id] == config && ghostAciRateAtTarget[id] != 0,
        "a priced market can be swapped onto another config and stays priced");
}

// --- reverts ---

// ACI-RV-01: Handing over ownership fails exactly when the caller is not the owner or the new owner is zero.
rule rvAciTransferOwnershipRevertsIff(env e, address newOwner) {

    setupAdaptiveCurveIrmValidState(e);
    bool notOwner = e.msg.sender != ghostAciOwner;
    bool zeroNewOwner = newOwner == 0;

    transferOwnership@withrevert(e, newOwner);
    bool reverted = lastReverted;

    assert(reverted <=> (notOwner || zeroNewOwner),
        "transferOwnership rejects exactly a stranger and the zero owner");
}

// ACI-RV-02: Replacing the manager fails exactly when the caller is not the owner or the new manager is zero.
rule rvAciSetManagerRevertsIff(env e, address newManager) {

    setupAdaptiveCurveIrmValidState(e);
    bool notOwner = e.msg.sender != ghostAciOwner;
    bool zeroNewManager = newManager == 0;

    setManager@withrevert(e, newManager);
    bool reverted = lastReverted;

    assert(reverted <=> (notOwner || zeroNewManager),
        "setManager rejects exactly a stranger and the zero manager");
}

// ACI-RV-03: Applying a rate configuration to a market fails for anyone but the owner or the manager.
rule rvAciApplyIrmConfigRevertsWhenNotAuthorized(env e, AdaptiveCurveIrm.MarketParams marketParams,
    address config) {

    setupAdaptiveCurveIrmValidState(e);
    bool notAuthorized = e.msg.sender != ghostAciOwner && e.msg.sender != ghostAciManager;

    applyIrmConfig@withrevert(e, marketParams, config);
    bool reverted = lastReverted;

    assert(notAuthorized => reverted,
        "applying a config from a stranger reverts");
}

// ACI-RV-04: Pricing a market and storing its new rate fails for any caller but the router.
rule rvAciBorrowRateRevertsWhenNotRouter(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    bool notRouter = e.msg.sender != _Aci.ROUTER();

    borrowRate@withrevert(e, marketParams, market);
    bool reverted = lastReverted;

    assert(notRouter => reverted, "borrowRate from anybody but the router reverts");
}

// ACI-RV-05: Pricing a market that has no rate configuration fails.
rule rvAciBorrowRateRevertsWhenConfigNotSet(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    bool configNotSet = ghostAciMarketCurveConfig[summaryMarketParamsId(marketParams)] == 0;

    borrowRate@withrevert(e, marketParams, market);
    bool reverted = lastReverted;

    assert(configNotSet => reverted, "pricing a market with no config reverts");
}

// ACI-RV-06: Previewing a rate for a market that has no configuration fails.
rule rvAciBorrowRateViewRevertsWhenConfigNotSet(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    bool configNotSet = ghostAciMarketCurveConfig[summaryMarketParamsId(marketParams)] == 0;

    borrowRateView@withrevert(e, marketParams, market);
    bool reverted = lastReverted;

    assert(configNotSet => reverted, "quoting a market with no config reverts");
}

// ACI-RV-07: Previewing a rate for a priced market dated in the future fails.
rule rvAciBorrowRateViewRevertsOnFutureLastUpdate(env e, AdaptiveCurveIrm.MarketParams marketParams,
    AdaptiveCurveIrm.Market market) {

    setupAdaptiveCurveIrmValidState(e);
    AdaptiveCurveIrm.Id id = summaryMarketParamsId(marketParams);

    require(ghostAciRateAtTarget[id] != 0, "SCOPE: a priced market");

    bool futureLastUpdate = to_mathint(market.lastUpdate) > to_mathint(e.block.timestamp);

    borrowRateView@withrevert(e, marketParams, market);
    bool reverted = lastReverted;

    assert(futureLastUpdate => reverted, "a market dated in the future reverts the quote");
}

// --- access_control ---

// ACI-AC-01: Only the current owner can hand over ownership.
rule acAciOnlyOwnerMovesOwner(env e, env eFunc, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } {

    SETUP_ACI(e, eFunc);
    address ownerBefore = ghostAciOwner;

    f(e, args);

    assert(ghostAciOwner != ownerBefore => e.msg.sender == ownerBefore,
        "only the owner moves the owner seat");
}

// ACI-AC-02: Only the owner can replace the rate model's manager.
rule acAciOnlyOwnerMovesManager(env e, env eFunc, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } {

    SETUP_ACI(e, eFunc);
    address ownerBefore = ghostAciOwner;
    address managerBefore = ghostAciManager;

    f(e, args);

    assert(ghostAciManager != managerBefore => e.msg.sender == ownerBefore,
        "only the owner moves the manager seat");
}

// ACI-AC-03: Only the owner or the manager can change a market's rate configuration.
rule acAciOnlyAuthorizedMovesMarketConfig(env e, env eFunc, method f, calldataarg args,
    AdaptiveCurveIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } {

    SETUP_ACI(e, eFunc);
    address ownerBefore = ghostAciOwner;
    address managerBefore = ghostAciManager;
    address configBefore = ghostAciMarketCurveConfig[id];

    f(e, args);

    assert(ghostAciMarketCurveConfig[id] != configBefore
        => (e.msg.sender == ownerBefore || e.msg.sender == managerBefore),
        "only the owner or the manager binds a market to a config");
}

// ACI-AC-04: Only the router, the owner or the manager can change a market's target rate.
rule acAciOnlyRouterOrAuthorizedMovesRateAtTarget(env e, env eFunc, method f, calldataarg args,
    AdaptiveCurveIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } {

    SETUP_ACI(e, eFunc);
    address routerBefore = _Aci.ROUTER();
    address ownerBefore = ghostAciOwner;
    address managerBefore = ghostAciManager;
    mathint rateBefore = ghostAciRateAtTarget[id];

    f(e, args);

    assert(ghostAciRateAtTarget[id] != rateBefore
        => (e.msg.sender == routerBefore || e.msg.sender == ownerBefore
            || e.msg.sender == managerBefore),
        "a market's rate at target moves only through the router or an authorized re-clamp");
}

// ACI-AC-05: The router address the rate model was deployed with never changes.
rule acAciRouterImmutable(env e, env eFunc, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_ACI(f) } {

    SETUP_ACI(e, eFunc);
    address routerBefore = _Aci.ROUTER();

    f(e, args);

    assert(_Aci.ROUTER() == routerBefore, "the router address is immutable");
}
