// Attached when the scene runs the vault's real bytecode against the CVL core stub: the vault's valid
// state, plus the token identities the stub's ledger legs need. The invariant pack it requires comes
// from LidoLendERC4626_valid_state.spec, which the consuming spec imports.

import "LidoLendERC4626.spec";
import "../LidoLend/LidoLend_cvl.spec";

// VA-VS-04: The vault never counts more managed shares than its supply position in the core actually holds.
invariant managedSharesBackedByCorePosition(env e)
    ghostVaManagedSupplyShares256 <= to_mathint(ghostLlCvlPosSupplyShares[_Vault])
filtered { f -> !EXCLUDED_FUNCTION_VA(f) } { preserved with (env eFunc) { SETUP_VA(e, eFunc); } }

function setupLidoLendERC4626ValidState(env e) {
    setupLidoLendERC4626(e);
    requireLidoLendERC4626Invariants(e);
    requireInvariant managedSharesBackedByCorePosition(e);

    require(ghostLlCvlLoanToken == ghostVaParamsLoanToken
            && ghostLlCvlCollateralToken == ghostVaParamsCollateralToken,
        "TRUSTED: the stub serves the one market the vault cached");
    require(ghostLlCvlCollateralToken != _Vault,
        "TRUSTED: the collateral token is not the vault share token");

    mathint vaultSupplyAssets = toAssetsDownLlCVL(ghostLlCvlPosSupplyShares[_Vault],
        ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares);
    mathint freeLiquidity = ghostLlCvlTotalSupplyAssets > ghostLlCvlTotalBorrowAssets
        ? ghostLlCvlTotalSupplyAssets - ghostLlCvlTotalBorrowAssets
        : 0;
    require(to_mathint(ghostMcCvlMaxWithdrawable[ghostVaController][_Vault])
            <= (vaultSupplyAssets < freeLiquidity ? vaultSupplyAssets : freeLiquidity),
        "PROVED: the quote is the supplier's supply capped by idle liquidity");
}
