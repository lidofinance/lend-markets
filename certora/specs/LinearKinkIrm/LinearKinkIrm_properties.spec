// Properties of the linear kink rate model over its real bytecode: curve laws, transitions, unit effects,
// revert conditions, witnesses and access control. Config validity is assumed rather than proven, standing on
// the trust discharged in the factory scene.

import "LinearKinkIrm_valid_state.spec";

// --- transitions ---

// LKI-VT-01: An owner or manager address, once set, is never cleared, though it can be rotated.
rule vtLkiRolesNeverClear(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrm(e);
    address ownerBefore = ghostLkiOwner;
    address managerBefore = ghostLkiManager;

    f(e, args);

    assert(ownerBefore != 0 => ghostLkiOwner != 0, "the owner seat is never cleared once it holds an address");
    assert(managerBefore != 0 => ghostLkiManager != 0,
        "the manager seat is never cleared once it holds an address");
}

// LKI-VT-02: A market keeps its curve as long as every config reports a positive kink.
rule vtLkiConfiguredKinkNeverClears(env e, method f, calldataarg args, LinearKinkIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrm(e);
    mathint kinkBefore = ghostLkiOptimalUtilization64[id];

    f(e, args);

    assert(kinkBefore != 0 => ghostLkiOptimalUtilization64[id] != 0,
        "a configured market's kink never reverts to the unset sentinel");
}

// LKI-ST-01: Any change to a market's curve leaves that market configured, never cleared in place.
rule stLkiKinkRowWriteIsAConfiguredTuple(env e, method f, calldataarg args, LinearKinkIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrmValidState(e);
    mathint kinkBefore = ghostLkiOptimalUtilization64[id];
    mathint baseBefore = ghostLkiBaseRate64[id];
    mathint slope1Before = ghostLkiSlope1_64[id];
    mathint slope2Before = ghostLkiSlope2_64[id];

    f(e, args);

    bool rowChanged = ghostLkiOptimalUtilization64[id] != kinkBefore
        || ghostLkiBaseRate64[id] != baseBefore
        || ghostLkiSlope1_64[id] != slope1Before
        || ghostLkiSlope2_64[id] != slope2Before;

    assert(rowChanged => ghostLkiOptimalUtilization64[id] > 0,
        "any change to a kink row leaves the market configured");
}

// --- high_level ---

// LKI-HL-01: A market borrowed more heavily is never charged a lower interest rate.
rule hlLkiRateMonotoneInUtilization(env e, LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market marketLo, LinearKinkIrm.Market marketHi) {

    setupLinearKinkIrmValidState(e);
    require(marketLo.totalSupplyAssets == marketHi.totalSupplyAssets,
        "SCOPE: one supply for both, so the borrowed amount is exactly the utilization");
    mathint borrowLo = to_mathint(marketLo.totalBorrowAssets);
    mathint borrowHi = to_mathint(marketHi.totalBorrowAssets);

    mathint rateLo = borrowRateView(e, marketParams, marketLo);
    mathint rateHi = borrowRateView(e, marketParams, marketHi);

    assert(borrowLo <= borrowHi => rateLo <= rateHi, "higher utilization is never charged a lower rate");
}

// LKI-HL-02: The charged rate never falls below a market's base rate nor passes the 800 percent per year cap.
rule hlLkiRateWithinBaseAndPeak(env e, LinearKinkIrm.MarketParams marketParams, LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);

    mathint rate = borrowRateView(e, marketParams, market);

    assert(rate >= ghostLkiBaseRate64[id], "the rate never dips below the base rate");
    assert(rate <= MAX_BORROW_RATE_LKI_CVL(), "the rate never passes the peak rate cap");
}

// LKI-HL-03: The interest curve has no jump where its flat and steep legs meet.
rule hlLkiRateContinuousAtKink(env e, LinearKinkIrm.MarketParams marketParams, LinearKinkIrm.Market market,
    LinearKinkIrm.Market marketPastKink) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(to_mathint(market.totalSupplyAssets) == WAD_MATH(),
        "SCOPE: a unit supply, so utilization is the borrowed fraction");
    require(to_mathint(market.totalBorrowAssets) == ghostLkiOptimalUtilization64[id],
        "SCOPE: the kink fraction borrowed, so utilization sits exactly on the kink");
    require(to_mathint(marketPastKink.totalSupplyAssets) == WAD_MATH(),
        "SCOPE: the same unit supply on the second probe");
    require(to_mathint(marketPastKink.totalBorrowAssets) == ghostLkiOptimalUtilization64[id] + 1,
        "SCOPE: one wei past the kink, which lands on the steep leg");

    mathint rate = borrowRateView(e, marketParams, market);
    mathint ratePastKink = borrowRateView(e, marketParams, marketPastKink);

    // The steep leg as the source writes it: excess = (U - kink) * WAD / (WAD - kink) with U - kink of one wei.
    mathint excess = WAD_MATH() / (WAD_MATH() - ghostLkiOptimalUtilization64[id]);

    assert(rate == ghostLkiBaseRate64[id] + ghostLkiSlope1_64[id],
        "both legs agree on base rate plus the first slope at the kink");
    assert(ratePastKink == ghostLkiBaseRate64[id] + ghostLkiSlope1_64[id]
            + (ghostLkiSlope2_64[id] * excess) / WAD_MATH(),
        "one wei past the kink the steep leg charges exactly the rate its stored row prescribes");
}

// LKI-HL-04: A market is charged exactly the rate the public view quotes for it.
rule hlLkiRateEqualsView(env e, LinearKinkIrm.MarketParams marketParams, LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);

    mathint rateView = borrowRateView(e, marketParams, market);
    mathint rateAccrual = borrowRate(e, marketParams, market);

    assert(rateView == rateAccrual, "the stateless borrowRate returns what borrowRateView advertises");
}

// LKI-HL-05: Two markets carrying the same stored curve are charged the same rate for the same state.
rule hlLkiRateDependsOnlyOnTheStoredRow(env e, LinearKinkIrm.MarketParams marketParamsA,
    LinearKinkIrm.MarketParams marketParamsB, LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id idA = summaryMarketParamsId(marketParamsA);
    LinearKinkIrm.Id idB = summaryMarketParamsId(marketParamsB);
    require(ghostLkiOptimalUtilization64[idA] == ghostLkiOptimalUtilization64[idB]
        && ghostLkiBaseRate64[idA] == ghostLkiBaseRate64[idB]
        && ghostLkiSlope1_64[idA] == ghostLkiSlope1_64[idB]
        && ghostLkiSlope2_64[idA] == ghostLkiSlope2_64[idB],
        "SCOPE: two markets carrying the same kink row");

    mathint rateA = borrowRateView(e, marketParamsA, market);
    mathint rateB = borrowRateView(e, marketParamsB, market);

    assert(rateA == rateB, "markets carrying the same kink row are priced identically");
}

// --- unit_tests ---

// LKI-UT-01: Handing over ownership installs the named successor and leaves the manager seat alone.
rule utLkiTransferOwnershipInstallsOwner(env e, address newOwner) {

    setupLinearKinkIrmValidState(e);
    address managerBefore = ghostLkiManager;

    transferOwnership(e, newOwner);

    assert(ghostLkiOwner == newOwner, "transferOwnership installs the requested owner");
    assert(ghostLkiManager == managerBefore, "transferOwnership leaves the manager where it was");
}

// LKI-UT-02: Rotating the manager installs the named manager and leaves ownership alone.
rule utLkiSetManagerInstallsManager(env e, address newManager) {

    setupLinearKinkIrmValidState(e);
    address ownerBefore = ghostLkiOwner;

    setManager(e, newManager);

    assert(ghostLkiManager == newManager, "setManager installs the requested manager");
    assert(ghostLkiOwner == ownerBefore, "setManager leaves the owner where it was");
}

// LKI-UT-03: Applying a curve to a market moves neither the owner seat nor the manager seat.
rule utLkiApplyIrmConfigLeavesRolesUntouched(env e, LinearKinkIrm.MarketParams marketParams, address config) {

    setupLinearKinkIrmValidState(e);
    address ownerBefore = ghostLkiOwner;
    address managerBefore = ghostLkiManager;

    applyIrmConfig(e, marketParams, config);

    assert(ghostLkiOwner == ownerBefore, "applying a config leaves the owner where it was");
    assert(ghostLkiManager == managerBefore, "applying a config leaves the manager where it was");
}

// LKI-UT-04: Applying a curve to one market leaves every other market's curve untouched.
rule utLkiApplyIrmConfigTouchesOnlyItsOwnMarket(env e, LinearKinkIrm.MarketParams marketParams, address config,
    LinearKinkIrm.Id otherId) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    mathint otherKinkBefore = ghostLkiOptimalUtilization64[otherId];
    mathint otherBaseBefore = ghostLkiBaseRate64[otherId];
    mathint otherSlope1Before = ghostLkiSlope1_64[otherId];
    mathint otherSlope2Before = ghostLkiSlope2_64[otherId];

    applyIrmConfig(e, marketParams, config);

    assert(otherId != id => (ghostLkiOptimalUtilization64[otherId] == otherKinkBefore
            && ghostLkiBaseRate64[otherId] == otherBaseBefore
            && ghostLkiSlope1_64[otherId] == otherSlope1Before
            && ghostLkiSlope2_64[otherId] == otherSlope2Before),
        "applying a config leaves every other market's row alone");
}

// LKI-UT-05: The quoted borrow rate is the same for every caller at the same moment.
rule utLkiBorrowRateViewIsCallerAgnostic(env e1, env e2, LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e1);
    setupLinearKinkIrmValidState(e2);

    storage init = lastStorage;
    uint256 rate1 = borrowRateView(e1, marketParams, market) at init;
    uint256 rate2 = borrowRateView(e2, marketParams, market) at init;

    assert(rate1 == rate2, "the quoted rate is the same for every caller");
}

// LKI-UT-06: An idle market is charged its base rate and a fully borrowed one the peak rate.
rule utLkiRateSaturatesAtBothEndsOfTheCurve(env e, LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    mathint totalSupply = to_mathint(market.totalSupplyAssets);
    mathint totalBorrow = to_mathint(market.totalBorrowAssets);

    mathint rate = borrowRate(e, marketParams, market);

    assert((totalSupply == 0 || totalBorrow == 0) => rate == ghostLkiBaseRate64[id],
        "an idle market is charged exactly the base rate");
    assert((totalSupply > 0 && totalBorrow >= totalSupply)
            => rate == ghostLkiBaseRate64[id] + ghostLkiSlope1_64[id] + ghostLkiSlope2_64[id],
        "a fully borrowed market is charged exactly the peak rate");
}

// LKI-UT-07: Configuring a fresh market copies all four rate parameters from the curve it was given.
rule utLkiApplyIrmConfigCopiesAllFourFields(env e, LinearKinkIrm.MarketParams marketParams, address config) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(ghostLkiOptimalUtilization64[id] == 0, "SCOPE: a market that carries no row yet");

    applyIrmConfig(e, marketParams, config);

    assert(ghostLkiOptimalUtilization64[id] == ghostLkiCfgOptimalUtilization64[config]
        && ghostLkiBaseRate64[id] == ghostLkiCfgBaseRate64[config]
        && ghostLkiSlope1_64[id] == ghostLkiCfgSlope1_64[config]
        && ghostLkiSlope2_64[id] == ghostLkiCfgSlope2_64[config],
        "the stored row is the row the supplied config reports, field by field");
}

// LKI-UT-08: Reconfiguring a live market replaces all four curve parameters, leaving nothing of the old curve.
rule utLkiApplyIrmConfigOverwritesEveryField(env e, LinearKinkIrm.MarketParams marketParams, address config) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(ghostLkiOptimalUtilization64[id] != 0, "SCOPE: a market that already carries a row");

    applyIrmConfig(e, marketParams, config);

    assert(ghostLkiOptimalUtilization64[id] == ghostLkiCfgOptimalUtilization64[config]
        && ghostLkiBaseRate64[id] == ghostLkiCfgBaseRate64[config]
        && ghostLkiSlope1_64[id] == ghostLkiCfgSlope1_64[config]
        && ghostLkiSlope2_64[id] == ghostLkiCfgSlope2_64[config],
        "re-configuring leaves no field of the previous row behind");
}

// --- reachability ---

// LKI-RC-01: It is possible to price an idle configured market at exactly its base rate.
rule rcLkiBelowKinkRateIsReachable(env e, LinearKinkIrm.MarketParams marketParams, LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(ghostLkiOptimalUtilization64[id] != 0, "SCOPE: a configured market");
    require(to_mathint(market.totalSupplyAssets) > 0 && to_mathint(market.totalBorrowAssets) == 0,
        "SCOPE: zero utilization picks the below kink leg");

    uint256 rate = borrowRate(e, marketParams, market);

    satisfy(to_mathint(rate) == ghostLkiBaseRate64[id],
        "an idle configured market is priced at exactly its base rate");
}

// LKI-RC-02: It is possible for a fully borrowed market to be charged exactly the rate cap.
rule rcLkiPeakRateReachesTheCap(env e, LinearKinkIrm.MarketParams marketParams, LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(ghostLkiBaseRate64[id] + ghostLkiSlope1_64[id] + ghostLkiSlope2_64[id]
            == MAX_BORROW_RATE_LKI_CVL(),
        "SCOPE: a market provisioned right up to the cap");
    require(to_mathint(market.totalSupplyAssets) > 0
        && to_mathint(market.totalBorrowAssets) == to_mathint(market.totalSupplyAssets),
        "SCOPE: full utilization reaches the peak");

    uint256 rate = borrowRate(e, marketParams, market);

    satisfy(to_mathint(rate) == MAX_BORROW_RATE_LKI_CVL(),
        "a market provisioned to the cap is charged exactly the cap at full utilization");
}

// LKI-RC-03: It is possible to quote a configured market through the public view and get a positive rate.
rule rcLkiBorrowRateViewIsReachable(env e, LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(ghostLkiBaseRate64[id] > 0, "SCOPE: a market that charges a positive base rate");
    require(to_mathint(market.totalSupplyAssets) > 0 && to_mathint(market.totalBorrowAssets) == 0,
        "SCOPE: the below kink leg");

    uint256 rate = borrowRateView(e, marketParams, market);

    satisfy(rate > 0, "the permissionless view quotes a positive rate");
}

// LKI-RC-04: A market claiming more borrowed than supplied can still be priced, at the curve's peak.
rule rcLkiAboveWadUtilizationIsClamped(env e, LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(ghostLkiOptimalUtilization64[id] != 0, "SCOPE: a configured market");
    require(to_mathint(market.totalSupplyAssets) > 0
        && to_mathint(market.totalBorrowAssets) > to_mathint(market.totalSupplyAssets),
        "SCOPE: an above WAD utilization exercises the clamp");

    uint256 rate = borrowRateView(e, marketParams, market);

    satisfy(to_mathint(rate)
            == ghostLkiBaseRate64[id] + ghostLkiSlope1_64[id] + ghostLkiSlope2_64[id],
        "an above WAD utilization is clamped to WAD and priced at the peak");
}

// LKI-RC-05: The owner or the manager can give a curve to a market that has none.
rule rcLkiApplyIrmConfigOnFreshMarketIsReachable(env e, LinearKinkIrm.MarketParams marketParams,
    address config) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(e.msg.sender == ghostLkiOwner || e.msg.sender == ghostLkiManager,
        "SCOPE: the owner or the manager as the caller");
    require(ghostLkiOptimalUtilization64[id] == 0, "SCOPE: a market that carries no row yet");

    applyIrmConfig(e, marketParams, config);

    satisfy(ghostLkiOptimalUtilization64[id] != 0, "a fresh market can be configured");
}

// LKI-RC-06: The owner or the manager can move a configured market onto a different curve.
rule rcLkiApplyIrmConfigReconfiguresIsReachable(env e, LinearKinkIrm.MarketParams marketParams,
    address config) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(e.msg.sender == ghostLkiOwner || e.msg.sender == ghostLkiManager,
        "SCOPE: the owner or the manager as the caller");
    require(ghostLkiOptimalUtilization64[id] != 0, "SCOPE: a market that already carries a row");
    require(ghostLkiCfgOptimalUtilization64[config] != ghostLkiOptimalUtilization64[id],
        "SCOPE: a second config, whose kink differs from the one in force");
    mathint kinkBefore = ghostLkiOptimalUtilization64[id];

    applyIrmConfig(e, marketParams, config);

    satisfy(ghostLkiOptimalUtilization64[id] != 0 && ghostLkiOptimalUtilization64[id] != kinkBefore,
        "a configured market can be moved onto a second config with a different kink");
}

// --- reverts ---

// LKI-RV-01: Handing over ownership fails exactly when the caller is not the owner or the new owner is zero.
rule rvLkiTransferOwnershipRevertsIff(env e, address newOwner) {

    setupLinearKinkIrmValidState(e);
    bool notOwner = e.msg.sender != ghostLkiOwner;
    bool zeroNewOwner = newOwner == 0;

    transferOwnership@withrevert(e, newOwner);

    assert(lastReverted <=> (notOwner || zeroNewOwner),
        "transferOwnership rejects exactly a caller other than the owner and a zero owner");
}

// LKI-RV-02: Rotating the manager fails exactly when the caller is not the owner or the new manager is zero.
rule rvLkiSetManagerRevertsIff(env e, address newManager) {

    setupLinearKinkIrmValidState(e);
    bool notOwner = e.msg.sender != ghostLkiOwner;
    bool zeroNewManager = newManager == 0;

    setManager@withrevert(e, newManager);

    assert(lastReverted <=> (notOwner || zeroNewManager),
        "setManager rejects exactly a caller other than the owner and a zero manager");
}

// LKI-RV-03: Applying a curve to a market fails for a caller who is neither the owner nor the manager.
rule rvLkiApplyIrmConfigRevertsWhenNotAuthorized(env e, LinearKinkIrm.MarketParams marketParams,
    address config) {

    setupLinearKinkIrmValidState(e);
    bool notAuthorized = e.msg.sender != ghostLkiOwner && e.msg.sender != ghostLkiManager;

    applyIrmConfig@withrevert(e, marketParams, config);

    assert(notAuthorized => lastReverted,
        "applying a config rejects a caller that is neither the owner nor the manager");
}

// LKI-RV-04: Pricing a market for interest accrual fails exactly when that market has no curve set.
rule rvLkiBorrowRateRevertsIffConfigNotSet(env e, LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    bool configNotSet = ghostLkiOptimalUtilization64[id] == 0;

    borrowRate@withrevert(e, marketParams, market);

    assert(lastReverted <=> configNotSet, "borrowRate rejects exactly a market that carries no row");
}

// LKI-RV-05: The public rate quote fails exactly when a market has no curve set.
rule rvLkiBorrowRateViewRevertsIffConfigNotSet(env e, LinearKinkIrm.MarketParams marketParams,
    LinearKinkIrm.Market market) {

    setupLinearKinkIrmValidState(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    bool configNotSet = ghostLkiOptimalUtilization64[id] == 0;

    borrowRateView@withrevert(e, marketParams, market);

    assert(lastReverted <=> configNotSet, "borrowRateView rejects exactly a market that carries no row");
}

// --- access_control ---

// LKI-AC-01: Only the current owner can hand over ownership.
rule acLkiOnlyOwnerModifiesOwner(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrm(e);
    address ownerBefore = ghostLkiOwner;

    f(e, args);

    assert(ghostLkiOwner != ownerBefore => e.msg.sender == ownerBefore,
        "only the current owner may change the owner");
}

// LKI-AC-02: Only the owner can replace the rate model's manager.
rule acLkiOnlyOwnerModifiesManager(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrm(e);
    address ownerBefore = ghostLkiOwner;
    address managerBefore = ghostLkiManager;

    f(e, args);

    assert(ghostLkiManager != managerBefore => e.msg.sender == ownerBefore,
        "only the owner may change the manager");
}

// LKI-AC-03: Only the owner or the manager can move a market's kink, where its rate curve steepens.
rule acLkiOnlyAuthorizedModifiesOptimalUtilization(env e, method f, calldataarg args, LinearKinkIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrm(e);
    address ownerBefore = ghostLkiOwner;
    address managerBefore = ghostLkiManager;
    mathint kinkBefore = ghostLkiOptimalUtilization64[id];

    f(e, args);

    assert(ghostLkiOptimalUtilization64[id] != kinkBefore
        => e.msg.sender == ownerBefore || e.msg.sender == managerBefore,
        "only the owner or the manager may move a market's kink");
}

// LKI-AC-04: Only the owner or the manager can change a market's base rate.
rule acLkiOnlyAuthorizedModifiesBaseRate(env e, method f, calldataarg args, LinearKinkIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrm(e);
    address ownerBefore = ghostLkiOwner;
    address managerBefore = ghostLkiManager;
    mathint baseBefore = ghostLkiBaseRate64[id];

    f(e, args);

    assert(ghostLkiBaseRate64[id] != baseBefore
        => e.msg.sender == ownerBefore || e.msg.sender == managerBefore,
        "only the owner or the manager may move a market's base rate");
}

// LKI-AC-05: Only the owner or the manager can change a market's slope below the kink.
rule acLkiOnlyAuthorizedModifiesSlope1(env e, method f, calldataarg args, LinearKinkIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrm(e);
    address ownerBefore = ghostLkiOwner;
    address managerBefore = ghostLkiManager;
    mathint slope1Before = ghostLkiSlope1_64[id];

    f(e, args);

    assert(ghostLkiSlope1_64[id] != slope1Before
        => e.msg.sender == ownerBefore || e.msg.sender == managerBefore,
        "only the owner or the manager may move a market's first slope");
}

// LKI-AC-06: Only the owner or the manager can change a market's steeper slope above the kink.
rule acLkiOnlyAuthorizedModifiesSlope2(env e, method f, calldataarg args, LinearKinkIrm.Id id)
    filtered { f -> !EXCLUDED_FUNCTION_LKI(f) } {

    setupLinearKinkIrm(e);
    address ownerBefore = ghostLkiOwner;
    address managerBefore = ghostLkiManager;
    mathint slope2Before = ghostLkiSlope2_64[id];

    f(e, args);

    assert(ghostLkiSlope2_64[id] != slope2Before
        => e.msg.sender == ownerBefore || e.msg.sender == managerBefore,
        "only the owner or the manager may move a market's second slope");
}
