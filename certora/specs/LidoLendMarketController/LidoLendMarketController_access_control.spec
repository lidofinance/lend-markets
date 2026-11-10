// Each rule names the authority a piece of state requires: snapshot it, invoke any external method,
// assert it moved only if the caller held that role or committee seat.

import "LidoLendMarketController_valid_state.spec";
import "../setup/LidoLend/LidoLend_cvl.spec";
import "../setup/GuardianSignals/GuardianSignals_cvl.spec";

definition MC_IS_PAUSED_AT(env e) returns bool =
    to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;

// MC-AC-01: Only a manager can change the collateral activation delays and limits.
rule acMcOnlyManagerMovesActivationConfig(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    mathint minDelayBefore = ghostMcCfgMinActivationDelay40;
    mathint maxDelayBefore = ghostMcCfgMaxActivationDelay40;
    mathint maxInflowBefore = ghostMcCfgMaxDelayInflow128;
    mathint minDepositBefore = ghostMcCfgMinDepositAmount128;
    mathint lockDurationBefore = ghostMcCfgActivatingLockDuration40;
    mathint minAmountBefore = ghostMcCfgMinActivationAmount128;
    mathint quorumDelayBefore = ghostMcCfgMaxGuardiansQuorumDelay40;
    mathint perStrikeBefore = ghostMcCfgDelayPerStrike40;
    mathint perSuspectBefore = ghostMcCfgDelayPerSuspect40;

    f(e, args);

    bool changed = ghostMcCfgMinActivationDelay40 != minDelayBefore
        || ghostMcCfgMaxActivationDelay40 != maxDelayBefore
        || ghostMcCfgMaxDelayInflow128 != maxInflowBefore
        || ghostMcCfgMinDepositAmount128 != minDepositBefore
        || ghostMcCfgActivatingLockDuration40 != lockDurationBefore
        || ghostMcCfgMinActivationAmount128 != minAmountBefore
        || ghostMcCfgMaxGuardiansQuorumDelay40 != quorumDelayBefore
        || ghostMcCfgDelayPerStrike40 != perStrikeBefore
        || ghostMcCfgDelayPerSuspect40 != perSuspectBefore;
    assert(changed => ghostMcHasRole[_Controller.MANAGER_ROLE()][e.msg.sender],
        "the collateral-activation config moves only for a MANAGER_ROLE holder");
}

// MC-AC-02: Only a manager can change the settlement policy that sizes debt cuts.
rule acMcOnlyManagerMovesSettlementConfig(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    mathint sliceFloorBpsBefore = ghostMcSetSliceFloorBps16;
    mathint sliceFloorAssetsBefore = ghostMcSetSliceFloorAssets96;
    mathint fullCutBefore = ghostMcSetFullCutBelowCollateral96;
    mathint ltvStepBpsBefore = ghostMcSetLtvStepBps16;

    f(e, args);

    bool changed = ghostMcSetSliceFloorBps16 != sliceFloorBpsBefore
        || ghostMcSetSliceFloorAssets96 != sliceFloorAssetsBefore
        || ghostMcSetFullCutBelowCollateral96 != fullCutBefore
        || ghostMcSetLtvStepBps16 != ltvStepBpsBefore;
    assert(changed => ghostMcHasRole[_Controller.MANAGER_ROLE()][e.msg.sender],
        "the settlement-queue config moves only for a MANAGER_ROLE holder");
}

// MC-AC-03: Only a manager can raise or lower the market's supply cap.
rule acMcOnlyManagerMovesSupplyCap(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    mathint capBefore = ghostMcSupplyCap256;

    f(e, args);

    assert(ghostMcSupplyCap256 != capBefore => ghostMcHasRole[_Controller.MANAGER_ROLE()][e.msg.sender],
        "the supply cap moves only for a MANAGER_ROLE holder");
}

// MC-AC-04: Only a manager can grant or revoke a caller's exemption from the collateral activation delay.
rule acMcOnlyManagerFlipsInstantActivation(env e, method f, calldataarg args, address c)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bool permissionBefore = ghostMcInstantActivationCallers[c];

    f(e, args);

    assert(ghostMcInstantActivationCallers[c] != permissionBefore
        => ghostMcHasRole[_Controller.MANAGER_ROLE()][e.msg.sender],
        "an instant-activation permission flips only for a MANAGER_ROLE holder");
}

// MC-AC-05: Only a freezer can put the market into the frozen state.
rule acMcOnlyFreezerFreezes(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bool frozenBefore = ghostMcIsFrozen;

    f(e, args);

    assert((!frozenBefore && ghostMcIsFrozen) => ghostMcHasRole[_Controller.FREEZER_ROLE()][e.msg.sender],
        "the market is frozen only by a FREEZER_ROLE holder");
}

// MC-AC-06: Only an unfreezer can lift the market out of the frozen state.
rule acMcOnlyUnfreezerUnfreezes(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bool frozenBefore = ghostMcIsFrozen;

    f(e, args);

    assert((frozenBefore && !ghostMcIsFrozen) => ghostMcHasRole[_Controller.UNFREEZER_ROLE()][e.msg.sender],
        "the market is unfrozen only by an UNFREEZER_ROLE holder");
}

// MC-AC-07: Only a pauser can put the controller into a paused state.
rule acMcOnlyPauserPauses(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bool pausedBefore = MC_IS_PAUSED_AT(e);

    f(e, args);

    assert((!pausedBefore && MC_IS_PAUSED_AT(e)) => ghostMcHasRole[_Controller.PAUSER_ROLE()][e.msg.sender],
        "the controller is paused only by a PAUSER_ROLE holder");
}

// MC-AC-08: Only a resumer can lift an active pause before it expires.
rule acMcOnlyResumerResumes(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    bool pausedBefore = MC_IS_PAUSED_AT(e);

    f(e, args);

    assert((pausedBefore && !MC_IS_PAUSED_AT(e)) => ghostMcHasRole[_Controller.RESUMER_ROLE()][e.msg.sender],
        "the controller is resumed only by a RESUMER_ROLE holder");
}

// MC-AC-14: Only a pauser or a resumer can move the moment a pause ends.
rule acMcOnlyPauseAuthoritiesMoveResumeStamp(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    mathint resumeBefore = ghostMcResumeSinceTimestamp256;

    f(e, args);

    assert(ghostMcResumeSinceTimestamp256 != resumeBefore
        => (ghostMcHasRole[_Controller.PAUSER_ROLE()][e.msg.sender]
            || ghostMcHasRole[_Controller.RESUMER_ROLE()][e.msg.sender]),
        "the resume timestamp moves only for a PAUSER_ROLE or RESUMER_ROLE holder");
}

// MC-AC-09: Only the core can change a borrower's collateral that is not yet active, or its timer.
rule acMcOnlyCoreMovesActivationPosition(env e, method f, calldataarg args, address b)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    address core = _Controller.LIDO_LEND(e);
    mathint dustBefore = ghostMcPosDust128[b];
    mathint activatingBefore = ghostMcPosActivating128[b];
    mathint startBefore = ghostMcPosActivatingStart40[b];
    mathint delayBefore = ghostMcPosActivatingDelay32[b];

    f(e, args);

    bool changed = ghostMcPosDust128[b] != dustBefore
        || ghostMcPosActivating128[b] != activatingBefore
        || ghostMcPosActivatingStart40[b] != startBefore
        || ghostMcPosActivatingDelay32[b] != delayBefore;
    assert(changed => e.msg.sender == core,
        "a borrower's activation position moves only when the core calls the hook");
}

// MC-AC-10: Only the core can change the recorded collateral inflow that sets activation delays.
rule acMcOnlyCoreMovesInflow(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    address core = _Controller.LIDO_LEND(e);
    mathint inflowBefore = ghostMcActInflow128;
    mathint clockBefore = ghostMcActInflowUpdatedAt40;

    f(e, args);

    bool changed = ghostMcActInflow128 != inflowBefore
        || ghostMcActInflowUpdatedAt40 != clockBefore;
    assert(changed => e.msg.sender == core,
        "the inflow accumulator moves only when the core calls the hook");
}

// MC-AC-11: Only the core can change the settlement queue of borrowers.
rule acMcOnlyCoreMovesSettlementHeap(env e, method f, calldataarg args, address a, uint256 i)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    address core = _Controller.LIDO_LEND(e);
    mathint lengthBefore = ghostMcHeapNodesLength;
    uint256 slotBefore = ghostMcHeapSlot[a];
    address accountBefore = ghostMcHeapNodeAccount[i];
    mathint keyBefore = ghostMcHeapNodeKey256[i];

    f(e, args);

    bool changed = ghostMcHeapNodesLength != lengthBefore
        || ghostMcHeapSlot[a] != slotBefore
        || ghostMcHeapNodeAccount[i] != accountBefore
        || ghostMcHeapNodeKey256[i] != keyBefore;
    assert(changed => e.msg.sender == core,
        "the settlement heap moves only when the core calls the hook");
}
