// Reentrancy across the real core and controller: the hook latch at the core's call into the controller.
// STATICCALL is not watched: the controller's reads back into the core are not claimed.

import "LidoLend_LinkedController_valid_state.spec";

persistent ghost bool ghostClReControllerCalled;
persistent ghost bool ghostClReLatchAtControllerCall;

// TRUSTED: the scene wires the market's controller to the in-scene _Controller.
hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset,
    uint retLength) uint rc {

    if (addr == _Controller) {
        ghostClReControllerCalled = true;
        ghostClReLatchAtControllerCall = _Core._hookInProgress;
    }
}

// --- reentrancy ---

// CL-RE-01: A collateral deposit can hand control to the real controller with the hook latch raised.
rule reLwcLatchIsRaisedWhenTheCoreCallsTheController(env e, LidoLend.MarketParams params,
    uint256 assets, address onBehalf, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(!ghostClReControllerCalled && !ghostClReLatchAtControllerCall,
        "SAFE: the ledger starts empty at the top of a call");
    require(data.length == 0, "SCOPE: no supply-collateral callback");

    _Core.supplyCollateral(e, params, assets, onBehalf, data);

    satisfy(ghostClReControllerCalled && ghostClReLatchAtControllerCall,
        "the controller gets control with the hook latch raised");
}

// CL-RE-02: A collateral deposit never hands control to the controller with the hook latch down.
rule reLwcControllerNeverGetsControlWithTheLatchDown(env e, LidoLend.MarketParams params,
    uint256 assets, address onBehalf, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(!ghostClReControllerCalled && !ghostClReLatchAtControllerCall,
        "SAFE: the ledger starts empty at the top of a call");
    require(data.length == 0, "SCOPE: no supply-collateral callback");

    _Core.supplyCollateral(e, params, assets, onBehalf, data);

    assert(ghostClReControllerCalled => ghostClReLatchAtControllerCall,
        "the controller never gets control with the hook latch down");
}
