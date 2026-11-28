// The settlement slice policy on a scene of its own: SettlementQueueLib carried by a harness, with no
// controller behind it. The laws here are about rules 2 and 3 of the root cut and the dust sweep over them,
// which the controller scene can state but not decide in reasonable time.

import "../setup/env.spec";
import "../setup/math.spec";
import "../setup/constants.spec";

methods {
    function settlementLtvOf(address) external returns (uint256) envfree;
    function allowedSliceAtValues(address, uint256, uint256) external returns (uint256) envfree;
    function sliceToLtv(uint256, uint256, uint256) external returns (uint256) envfree;
}

function setupRootLtvStepOnly(env e, address b, SettlementSliceHarness.SettlementConfig config) {

    setupEnv(e);
    require(config.sliceFloorBps == 0 && config.sliceFloorAssets == 0,
        "SCOPE: rules 1 and 2 of the root cut are off");
    require(config.fullCutBelowCollateral == 0, "SCOPE: no dust-strand lift to a full close");
    require(to_mathint(config.ltvStepBps) != 0,
        "SCOPE: rule 3 of the root cut is on");

    setSettlementConfig(e, config);

    require(settlementLtvOf(b) == 0, "SCOPE: no personal settlement target");
}

// The dust sweep is left live here: fullCutBelowCollateral stays free.
function setupRootFloorAssetsOnly(env e, address b, SettlementSliceHarness.SettlementConfig config) {

    setupEnv(e);
    require(config.sliceFloorBps == 0 && config.ltvStepBps == 0,
        "SCOPE: rules 1 and 3 of the root cut are off");

    setSettlementConfig(e, config);

    require(settlementLtvOf(b) == 0, "SCOPE: no personal settlement target");
}

function requireSlicePositionBounds(uint256 debtAssets, uint256 collateralValue) {
    require(debtAssets != 0 && debtAssets <= max_uint128,
        "SCOPE: debt is nonzero, within the core's totalBorrowAssets width");
    require(collateralValue != 0 && collateralValue <= max_uint128,
        "SCOPE: collateral value is nonzero, within the governance oracle band");
}

// --- unit_tests ---

// MC-UT-08: The settlement policy's step rule cuts a borrower's loan to value by one step, never more than their debt.
rule utMcRootSliceHonorsLtvStep(env e, address b, uint256 debtAssets, uint256 collateralValue) {

    SettlementSliceHarness.SettlementConfig config;
    setupRootLtvStepOnly(e, b, config);
    requireSlicePositionBounds(debtAssets, collateralValue);

    uint256 slice = allowedSliceAtValues(b, debtAssets, collateralValue);

    mathint step = to_mathint(config.ltvStepBps) * WAD_CVL() / BPS_CVL();
    mathint currentLtv = debtAssets * WAD_CVL() / collateralValue;
    mathint target = currentLtv > step ? currentLtv - step : 0;
    mathint byLtvStep = target >= WAD_CVL() || debtAssets * WAD_CVL() <= target * collateralValue
        ? 0
        : (debtAssets * WAD_CVL() - target * collateralValue) / (WAD_CVL() - target);

    assert(to_mathint(slice) == (byLtvStep < to_mathint(debtAssets) ? byLtvStep : to_mathint(debtAssets)),
        "the queue-root quote is the whole ltv step, capped at the debt");
}

// MC-UT-09: A borrower whose loan to value is within one policy step is quoted their whole debt.
rule utMcRootSliceSaturatesToFullDebt(env e, address b, uint256 debtAssets, uint256 collateralValue) {

    SettlementSliceHarness.SettlementConfig config;
    setupRootLtvStepOnly(e, b, config);
    requireSlicePositionBounds(debtAssets, collateralValue);

    mathint step = to_mathint(config.ltvStepBps) * WAD_CVL() / BPS_CVL();
    mathint currentLtv = debtAssets * WAD_CVL() / collateralValue;

    uint256 slice = allowedSliceAtValues(b, debtAssets, collateralValue);

    assert(sliceToLtv(debtAssets, collateralValue, 0) == debtAssets,
        "the cut that brings a position to a zero LTV is its whole debt");
    assert(currentLtv <= step => to_mathint(slice) == to_mathint(debtAssets),
        "a borrower at or under the step is quoted no partial cut, but its whole debt");
}

// MC-UT-13: A cut is lifted to a full close by the collateral it would strand, not by the loan amount it takes.
rule utMcRootSliceSweepReadsFullCutFloor(env e, address b, uint256 debtAssets, uint256 collateralValue) {

    SettlementSliceHarness.SettlementConfig config;
    setupRootFloorAssetsOnly(e, b, config);
    requireSlicePositionBounds(debtAssets, collateralValue);

    uint256 slice = allowedSliceAtValues(b, debtAssets, collateralValue);

    // The identity market view prices collateral one for one, so the sweep weighs the collateral left behind.
    mathint policy = to_mathint(config.sliceFloorAssets) < to_mathint(debtAssets)
        ? to_mathint(config.sliceFloorAssets)
        : to_mathint(debtAssets);
    mathint remaining = to_mathint(collateralValue) > policy ? to_mathint(collateralValue) - policy : 0;

    assert(to_mathint(slice) == (policy != 0 && remaining < to_mathint(config.fullCutBelowCollateral)
            ? to_mathint(debtAssets)
            : policy),
        "the sweep to a full close fires on fullCutBelowCollateral, the absolute floor only sizing the cut");
}
