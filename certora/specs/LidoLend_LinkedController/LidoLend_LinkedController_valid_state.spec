// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external method call.
// Every invariant here is a cross-contract fact: neither contract alone can state it.

import "../LidoLend/LidoLend_valid_state.spec";
import "../LidoLendMarketController/LidoLendMarketController_valid_state.spec";
import "../setup/LidoLend_LinkedController/LidoLend_LinkedController.spec";

function requireLidoLend_LinkedControllerInvariants(env e) {
    requireInvariant heapKeyFreshCoreBacked(e);
    requireInvariant heapMembershipMatchesCoreLifecycle(e);
    requireInvariant activationBucketsBackedByCoreCollateral(e);
}

function setupLidoLend_LinkedControllerValidState(env e) {
    setupLidoLend_LinkedController(e);
    requireLidoLendInvariants(e);
    requireLidoLendMarketControllerInvariants(e);
    requireLidoLend_LinkedControllerInvariants(e);
}

function SETUP_LWC(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupLidoLend_LinkedController(e);
}

definition LWC_LIVE_RISK_KEY_CVL(address b) returns mathint =
    ghostLlCollateral128[b] == 0
        ? 0
        : ghostLlBorrowShares128[b] * WAD_LL_CVL() / ghostLlCollateral128[b];

// CL-VS-01: Every queued borrower's stored risk score matches its current debt per unit of collateral.
invariant heapKeyFreshCoreBacked(env e)
    forall address b. ghostMcHeapSlot[b] != 0
        => (ghostLlCollateral128[b] != 0
            && ghostMcHeapNodeKey256[ghostMcHeapSlot[b]] == LWC_LIVE_RISK_KEY_CVL(b))
filtered { f -> !EXCLUDED_FUNCTION_LWC(f) } {
    preserved with (env eFunc) {
        SETUP_LWC(e, eFunc);
        requireMaxHeapInvariants(e);
        requireInvariant heapMembershipMatchesCoreLifecycle(e);
    }
}

// CL-VS-02: The settlement queue holds exactly those borrowers who carry both debt and collateral.
invariant heapMembershipMatchesCoreLifecycle(env e)
    forall address b. ghostMcHeapSlot[b] != 0
        <=> (ghostLlBorrowShares128[b] != 0 && ghostLlCollateral128[b] != 0)
filtered { f -> !EXCLUDED_FUNCTION_LWC(f) } {
    preserved with (env eFunc) {
        SETUP_LWC(e, eFunc);
        requireMaxHeapInvariants(e);
        requireInvariant heapKeyFreshCoreBacked(e);
    }
}

// CL-VS-03: A borrower's inactive collateral never exceeds the collateral the market holds for that borrower.
invariant activationBucketsBackedByCoreCollateral(env e)
    forall address b.
        ghostMcPosActivating128[b] + ghostMcPosDust128[b] <= ghostLlCollateral128[b]
filtered { f -> !EXCLUDED_FUNCTION_LWC(f) } {
    preserved with (env eFunc) {
        SETUP_LWC(e, eFunc);
        requireMaxHeapInvariants(e);
    }
}
