// Reentrancy in the core: no storage touch after an untrusted call, and no delegatecall.
// STATICCALL is not watched, so read-only reentrancy is not claimed.

import "../setup/marketParamsLib.spec";

using LidoLend as _Core;

methods {
    // SAFE: injective id ghost; pure, so no call opcode is lost.
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    // SCOPE: excluded; neither calls another contract.
    function _Core.extSloads(bytes32[]) external returns (bytes32[]) => NONDET DELETE;
    function _Core.setAuthorizationWithSig(LidoLend.Authorization, LidoLend.Signature)
        external => NONDET DELETE;

    // TRUSTED: rate model and controller calls are not counted as untrusted.
    function _.borrowRate(LidoLend.MarketParams, LidoLend.Market) external
        => llReTrustedIrmCVL(calledContract) expect uint256;
    function _.on(bytes32, uint8, bytes) external
        => llReTrustedControllerCVL(calledContract) expect void;
}

persistent ghost bool ghostLlReTrustArmed;
persistent ghost address ghostLlReTrustCallee;

persistent ghost bool ghostLlReTouchedStorage;
persistent ghost bool ghostLlReCallAfterTouch;
persistent ghost bool ghostLlReUnsafeCall;
persistent ghost bool ghostLlReDelegateCall;
persistent ghost mathint ghostLlReUntrustedCalls;

function llReTrustedIrmCVL(address callee) returns uint256 {
    ghostLlReTrustArmed = true;
    ghostLlReTrustCallee = callee;
    uint256 rate;
    return rate;
}

function llReTrustedControllerCVL(address callee) {
    ghostLlReTrustArmed = true;
    ghostLlReTrustCallee = callee;
}

hook ALL_SSTORE(uint loc, uint v) {
    ghostLlReTouchedStorage = true;
    ghostLlReUnsafeCall = ghostLlReCallAfterTouch;
}

hook ALL_SLOAD(uint loc) uint v {
    ghostLlReTouchedStorage = true;
    ghostLlReUnsafeCall = ghostLlReCallAfterTouch;
}

hook CALL(uint g, address addr, uint value, uint ao, uint al, uint ro, uint rl) uint rc {
    bool trusted = ghostLlReTrustArmed && addr == ghostLlReTrustCallee;
    ghostLlReTrustArmed = false;
    if (!trusted) {
        ghostLlReCallAfterTouch = ghostLlReTouchedStorage;
        ghostLlReUntrustedCalls = ghostLlReUntrustedCalls + 1;
    }
}

hook DELEGATECALL(uint g, address addr, uint ao, uint al, uint ro, uint rl) uint rc {
    ghostLlReDelegateCall = true;
}

// LL-RE-05: The core never touches storage, calls a token or a callback, then touches storage again.
rule reLlNoStorageTouchAfterUntrustedCall(env e, method f, calldataarg args) {

    require(!ghostLlReTrustArmed && !ghostLlReTouchedStorage
        && !ghostLlReCallAfterTouch && !ghostLlReUnsafeCall,
        "SAFE: the ledger starts empty at the top of a call");

    f(e, args);

    assert(!ghostLlReUnsafeCall,
        "no storage touch follows an untrusted call made after a storage touch");
}

// LL-RE-06: A supply carrying callback data can call out twice after touching its own storage.
rule reLlSupplyCallsOutAfterWritingItsPosition(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {

    require(ghostLlReUntrustedCalls == 0 && !ghostLlReTrustArmed
        && !ghostLlReTouchedStorage && !ghostLlReCallAfterTouch,
        "SAFE: the ledger starts empty at the top of a call");

    supply(e, mp, assets, 0, onBehalf, data);

    satisfy(ghostLlReUntrustedCalls >= 2 && ghostLlReCallAfterTouch,
        "a supply reaches its callback and its token pull after touching storage");
}

// LL-RE-07: The core executes no delegatecall, so no foreign code runs against its storage.
rule reLlMakesNoDelegateCall(env e, method f, calldataarg args) {

    require(!ghostLlReDelegateCall, "SAFE: the ledger starts empty at the top of a call");

    f(e, args);

    assert(!ghostLlReDelegateCall,
        "the core issues no delegatecall");
}
