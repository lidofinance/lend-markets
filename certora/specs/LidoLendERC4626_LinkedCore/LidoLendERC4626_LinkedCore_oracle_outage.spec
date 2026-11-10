// Oracle outage for the vault over the real core: withdraw, redeem and a liquid fallback exit read no oracle.
// price() is summarized: the rows show the oracle is never called, not how a reverting feed behaves.

import "../LidoLend/LidoLend_valid_state.spec";
import "../LidoLendERC4626/LidoLendERC4626_valid_state.spec";
import "../setup/LidoLendERC4626_LinkedCore/LidoLendERC4626_LinkedCore.spec";

persistent ghost bool ghostVcOoSawOracleRead;

hook STATICCALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength)
    uint rc {
    if (addr == ghostLlOracle) {
        ghostVcOoSawOracleRead = true;
    }
}

function setupVcOracleOutage(env e) {
    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlOracle != 0 && ghostLlOracle != _Core && ghostLlOracle != _Vault
            && ghostLlOracle != ghostVaController && ghostLlOracle != ghostLlIrm
            && ghostLlOracle != ghostLlLoanToken && ghostLlOracle != ghostLlCollateralToken,
        "TRUSTED: the oracle is no other scene contract");
    require(!ghostVcOoSawOracleRead,
        "SAFE: the ledger starts empty at the top of a call");
}

// --- oracle_outage ---

// VC-OO-01: A vault withdraw never reads the market oracle on its way through the core.
rule ooVcWithdrawNeverReadsTheOracle(env e, uint256 assets, address receiver, address owner) {

    setupVcOracleOutage(e);

    withdraw(e, assets, receiver, owner);

    assert(!ghostVcOoSawOracleRead,
        "a vault withdraw never reads the market oracle");
}

// VC-OO-02: A vault redeem never reads the market oracle on its way through the core.
rule ooVcRedeemNeverReadsTheOracle(env e, uint256 shares, address receiver, address owner) {

    setupVcOracleOutage(e);

    redeem(e, shares, receiver, owner);

    assert(!ghostVcOoSawOracleRead,
        "a vault redeem never reads the market oracle");
}

// VC-OO-03: A fallback exit covered by free liquidity never reads the market oracle.
rule ooVcLiquidFallbackExitNeverReadsTheOracle(env e, uint256 shares, address receiver, address owner,
    uint256 maxIterations) {

    setupVcOracleOutage(e);
    require(to_mathint(shares) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][_Vault];
    require(liquid != 0 && to_mathint(previewRedeem(e, shares)) <= liquid,
        "SCOPE: positive free liquidity covers the whole request");

    fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(!ghostVcOoSawOracleRead,
        "an exit served out of free liquidity never reads the market oracle");
}

// VC-OO-04: A vault settlement can read the market oracle, as its design requires.
rule ooVcSettleCanReadTheOracle(env e, uint256 shares, address[] borrowers, address receiver, address owner) {

    setupVcOracleOutage(e);
    require(borrowers.length == 1,
        "SCOPE: a one element borrower list");

    settle(e, shares, borrowers, receiver, owner);

    satisfy(ghostVcOoSawOracleRead,
        "a settlement reads the market oracle");
}
