// Reentrancy in the controller: its outbound calls, with initialize and the role mutators out of the scene.
// What a callee does with control is not claimed.

import "LidoLendMarketController_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_core_view.spec";
import "../setup/GuardianSignals/GuardianSignals_cvl.spec";
import "../setup/erc20.spec";

// Scene-only encoder: turns a typed hook payload into the bytes on() decodes.
using LidoLendMarketControllerHookEncoder as _HookEncoder;

persistent ghost bool ghostMcReSawCall;
persistent ghost bool ghostMcReSawDelegateCall;
persistent ghost address ghostMcReCoreAddress;
persistent ghost bool ghostMcReReadTheCore;
persistent ghost bool ghostMcReReadTheGuardian;

hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength)
    uint rc {
    ghostMcReSawCall = true;
}

hook DELEGATECALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength)
    uint rc {
    ghostMcReSawDelegateCall = true;
}

hook STATICCALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength)
    uint rc {
    if (addr == ghostMcReCoreAddress) {
        ghostMcReReadTheCore = true;
    }
    if (addr == ghostMcGuardianSignals) {
        ghostMcReReadTheGuardian = true;
    }
}

// MC-RE-01: The controller issues no state changing call and no delegatecall of any kind.
rule reMcIssuesNoStateChangingCall(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketController(e);
    require(!ghostMcReSawCall && !ghostMcReSawDelegateCall,
        "SAFE: the ledger starts empty at the top of a call");

    f(e, args);

    assert(!ghostMcReSawCall && !ghostMcReSawDelegateCall,
        "the controller reaches every counterparty read-only");
}

// MC-RE-02: A collateral hook can read both the core and the guardian registry before it returns.
rule reMcHookReachesTheCoreAndTheGuardian(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    require(ghostMcReCoreAddress == _Controller.LIDO_LEND(e),
        "SAFE: the core is the controller's immutable LIDO_LEND");
    require(ghostMcGuardianSignals != ghostMcReCoreAddress,
        "TRUSTED: the guardian registry is not the core");
    require(!ghostMcReReadTheCore && !ghostMcReReadTheGuardian,
        "SAFE: the ledger starts empty at the top of a call");
    bytes payload = _HookEncoder.encodeSupplyCollateral(e, d);

    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, payload);

    satisfy(ghostMcReReadTheCore && ghostMcReReadTheGuardian,
        "a collateral hook reaches both of its counterparties read-only");
}
