// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external method call.
// Once proven, the other spec files assume them through setupLidoLendMarketControllerValidState, which
// confines every rule to states the contract can actually reach.

import "../setup/LidoLendMarketController/LidoLendMarketController.spec";
import "MaxHeap_valid_state.spec";

function requireLidoLendMarketControllerInvariants(env e) {
    requireMaxHeapInvariants(e);
    requireInvariant activatingRequiresTimerStart(e);
    requireInvariant timerStartRequiresActivating(e);
    requireInvariant clearedTimerClearsDelay(e);
    requireInvariant timerStartRequiresDelay(e);
    requireInvariant timerStartNotInFuture(e);
    requireInvariant inflowSnapshotNotInFuture(e);
    requireInvariant activatingDelayCapped(e);
    requireInvariant minDelayLeMaxDelay(e);
    requireInvariant maxActivationDelayCapped(e);
    requireInvariant activatingLockDurationCapped(e);
    requireInvariant quorumDelayZeroOrAboveMaxDelay(e);
    requireInvariant maxGuardiansQuorumDelayCapped(e);
    requireInvariant delayPerStrikeCapped(e);
    requireInvariant delayPerSuspectCapped(e);
    requireInvariant sliceFloorBpsCapped(e);
    requireInvariant ltvStepBpsCapped(e);
    requireInvariant settlementLtvBelowWad(e);
}

function setupLidoLendMarketControllerValidState(env e) {
    setupLidoLendMarketController(e);
    requireLidoLendMarketControllerInvariants(e);
}

function SETUP_MC(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupLidoLendMarketController(e);
}

function SETUP_FULL_MC(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupLidoLendMarketController(e);
    requireLidoLendMarketControllerInvariants(e);
}

// MC-VS-06: Collateral still waiting to activate always has its activation timer running.
invariant activatingRequiresTimerStart(env e)
    forall address b. ghostMcPosActivating128[b] != 0 => ghostMcPosActivatingStart40[b] != 0
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) {
    SETUP_MC(e, eFunc);
    requireInvariant clearedTimerClearsDelay(e);
} }

// MC-VS-07: Once the activation timer is cleared, no stale waiting period is left behind.
invariant clearedTimerClearsDelay(env e)
    forall address b. ghostMcPosActivatingStart40[b] == 0 => ghostMcPosActivatingDelay32[b] == 0
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-20: A running activation timer always has collateral waiting inside it.
invariant timerStartRequiresActivating(env e)
    forall address b. ghostMcPosActivatingStart40[b] != 0 => ghostMcPosActivating128[b] != 0
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-21: A running activation timer always carries a nonzero waiting period.
invariant timerStartRequiresDelay(env e)
    forall address b. ghostMcPosActivatingStart40[b] != 0 => ghostMcPosActivatingDelay32[b] != 0
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) {
    SETUP_MC(e, eFunc);
    requireInvariant minDelayLeMaxDelay(e);
} }

// MC-VS-08: A deposit's activation timer never starts in the future.
invariant timerStartNotInFuture(env e)
    forall address b. ghostMcPosActivatingStart40[b] <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-09: The inflow throttle's last update is never stamped in the future.
invariant inflowSnapshotNotInFuture(env e)
    ghostMcActInflowUpdatedAt40 <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-10: The wait recorded on a borrower's deposit never exceeds seven days.
invariant activatingDelayCapped(env e)
    forall address b. ghostMcPosActivatingDelay32[b] <= MAX_DELAY_DURATION_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) {
    SETUP_MC(e, eFunc);
    requireInvariant minDelayLeMaxDelay(e);
    requireInvariant maxActivationDelayCapped(e);
} }

// MC-VS-11: The activation wait floor never exceeds the activation wait ceiling.
invariant minDelayLeMaxDelay(env e)
    ghostMcCfgMinActivationDelay40 <= ghostMcCfgMaxActivationDelay40
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-12: The activation wait ceiling set by governance never exceeds seven days.
invariant maxActivationDelayCapped(env e)
    ghostMcCfgMaxActivationDelay40 <= MAX_DELAY_DURATION_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-13: The withdrawal lock on freshly deposited collateral never lasts more than seven days.
invariant activatingLockDurationCapped(env e)
    ghostMcCfgActivatingLockDuration40 <= MAX_DELAY_DURATION_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-14: A guardian quorum fallback delay, when set, always outlasts the activation wait ceiling.
invariant quorumDelayZeroOrAboveMaxDelay(env e)
    ghostMcCfgMaxGuardiansQuorumDelay40 == 0
        || ghostMcCfgMaxGuardiansQuorumDelay40 > ghostMcCfgMaxActivationDelay40
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-22: The guardian quorum fallback delay never exceeds seven days.
invariant maxGuardiansQuorumDelayCapped(env e)
    ghostMcCfgMaxGuardiansQuorumDelay40 <= MAX_DELAY_DURATION_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-15: A single guardian strike never adds more than seven days to a borrower's wait.
invariant delayPerStrikeCapped(env e)
    ghostMcCfgDelayPerStrike40 <= MAX_DELAY_DURATION_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-16: A single suspect report never adds more than seven days to a borrower's wait.
invariant delayPerSuspectCapped(env e)
    ghostMcCfgDelayPerSuspect40 <= MAX_DELAY_DURATION_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-17: The settlement policy's debt fraction is never configured above 100 percent.
invariant sliceFloorBpsCapped(env e)
    ghostMcSetSliceFloorBps16 <= BPS_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-18: The settlement policy's loan to value step is never configured above 100 percent.
invariant ltvStepBpsCapped(env e)
    ghostMcSetLtvStepBps16 <= BPS_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }

// MC-VS-19: A borrower's own settlement target always sits below 100 percent loan to value.
invariant settlementLtvBelowWad(env e)
    forall address b. ghostMcSettlementLtv256[b] < WAD_MC_CVL()
filtered { f -> !EXCLUDED_FUNCTION_MC(f) } { preserved with (env eFunc) { SETUP_MC(e, eFunc); } }
