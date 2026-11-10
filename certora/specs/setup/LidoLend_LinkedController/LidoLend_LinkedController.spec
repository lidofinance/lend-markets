// Attached when the scene runs both contracts' real bytecode, linked.

import "../GuardianSignals/GuardianSignals_cvl.spec";

methods {
    // Called by the core.
    function _.on(LidoLendMarketController.Id, ILidoLendMarketController.HookEvent, bytes) external
        => DISPATCHER(true);

    // Called by the controller.
    function _.market(LidoLend.Id) external => DISPATCHER(true);
    function _.position(LidoLend.Id, address) external => DISPATCHER(true);
    function _.idToMarketParams(LidoLend.Id) external => DISPATCHER(true);
}

definition EXCLUDED_FUNCTION_LWC(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    // A direct on() always reverts; the sender is never the core.
    || f.selector == sig:LidoLendMarketController.on(LidoLendMarketController.Id,
        ILidoLendMarketController.HookEvent, bytes).selector
    ;

function setupLidoLend_LinkedController(env e) {
    setupLidoLend(e);
    setupLidoLendMarketController(e);

    require(e.msg.sender != _Controller && e.msg.sender != _Core,
        "SAFE: scene contracts originate no top-level calls");

    require(ghostLlMarketController == _Controller,
        "TRUSTED: the in-scene controller supervises the one market");
    require(ghostMcMarketId == marketParamsIdCVL(ghostLlLoanToken, ghostLlCollateralToken,
            ghostLlOracle, ghostLlIrm, require_uint256(ghostLlLltv256)),
        "TRUSTED: the controller's marketId is the one market's id");
}

// --- the contract math a rule restates to check the pair against ---

// SharesMathLib.toAssetsUp: the debt sizing the controller and the core share.
function clDebtAssetsCVL(mathint shares, mathint totalAssets, mathint totalShares) returns mathint {
    mathint den = totalShares + VIRTUAL_SHARES_LL_CVL();
    return (shares * (totalAssets + VIRTUAL_ASSETS_LL_CVL()) + den - 1) / den;
}

// SharesMathLib.toAssetsDown, the supplier leg.
function clSupplyAssetsCVL(mathint shares, mathint totalAssets, mathint totalShares) returns mathint {
    return shares * (totalAssets + VIRTUAL_ASSETS_LL_CVL()) / (totalShares + VIRTUAL_SHARES_LL_CVL());
}

// Controller._getMaxBorrow: sub-threshold collateral backs nothing, the rest is its oracle value at LLTV.
function clMaxBorrowCVL(mathint collateral) returns mathint {
    if (collateral < ghostMcCfgMinActivationAmount128) {
        return 0;
    }
    return (collateral * ghostOraclePrice256[ghostLlOracle] / ORACLE_PRICE_SCALE_MC_CVL())
        * ghostLlLltv256 / WAD_MC_CVL();
}

// ACTIVE collateral: the core position minus the un-matured buckets, which valid state bounds by it.
function clActiveCollateralCVL(address b) returns mathint {
    return ghostLlCollateral128[b] - ghostMcPosActivating128[b] - ghostMcPosDust128[b];
}
