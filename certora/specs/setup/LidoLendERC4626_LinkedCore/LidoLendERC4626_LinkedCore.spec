// Attached when the scene runs both contracts' real bytecode, linked.

import "../LidoLendMarketController/LidoLendMarketController_cvl.spec";

methods {
    // Called by the vault.
    function _.supply(LidoLend.MarketParams, uint256, uint256, address, bytes) external => DISPATCHER(true);
    function _.withdraw(LidoLend.MarketParams, uint256, uint256, address, address) external => DISPATCHER(true);
    function _.settle(LidoLend.MarketParams, uint256, address, address, address) external
        => DISPATCHER(true);
    function _.position(LidoLend.Id, address) external => DISPATCHER(true);
    function _.market(LidoLend.Id) external => DISPATCHER(true);
}

definition EXCLUDED_FUNCTION_VC(method f) returns bool =
    EXCLUDED_FUNCTION_VA(f)
    // The loop-carrying exits: rules filtered here cover the remaining seven entry points only.
    || f.selector == sig:LidoLendERC4626.settle(uint256,address[],address,address).selector
    || f.selector == sig:LidoLendERC4626.fallbackExit(uint256,address,address,uint256).selector
    ;

function setupLidoLendERC4626_LinkedCore(env e) {
    setupLidoLendValidState(e);
    setupLidoLendERC4626(e);
    requireLidoLendERC4626Invariants(e);

    require(ghostVaParamsLoanToken == ghostLlLoanToken
            && ghostVaParamsCollateralToken == ghostLlCollateralToken
            && ghostVaParamsOracle == ghostLlOracle
            && ghostVaParamsIrm == ghostLlIrm
            && ghostVaParamsLltv256 == ghostLlLltv256,
        "TRUSTED: the vault caches the one market's row");
    require(ghostVaController == ghostLlMarketController
            && ghostVaController != _Vault && ghostVaController != _Core,
        "TRUSTED: one controller, deployed outside the scene");
    require(ghostLlLoanToken != _Core && ghostLlCollateralToken != _Core
            && ghostLlCollateralToken != _Vault,
        "TRUSTED: neither market token is the core, and collateral is not the vault");

    require(ERC20_ACCOUNT_BOUNDS(ghostLlLoanToken, _Vault)
            && ERC20_ACCOUNT_BOUNDS(ghostLlLoanToken, _Core),
        "SCOPE: both scene contracts hold loan-token accounts in the bounded set");
    require(ghostERC20Allowances256[ghostLlLoanToken][_Vault][_Core] == max_uint256,
        "TRUSTED: initialize granted the core a max loan-token approval");
}
