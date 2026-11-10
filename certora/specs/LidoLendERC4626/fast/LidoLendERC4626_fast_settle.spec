// Mutation kill twins of the fallbackExit rules about the settlement sweep, the seized collateral reaching
// the receiver, remaining holders never diluted and the iteration cap holding, with the parents' names and
// bodies. The lane computes mulDiv in CVL and pins maxIterations to one.

import "../LidoLendERC4626_valid_state.spec";
import "../../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";
import "../../setup/math.spec";

// Fast twin of VA-HL-13.
rule hlVaFallbackExitPaysSeizedCollateralToReceiver(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(maxIterations == 1,
        "SCOPE: one iteration, enough to walk the full payout route");
    require(receiver != LIDO_LEND(e),
        "SCOPE: the receiver is not the paying core");
    mathint recvBefore = ghostERC20Balances128[ghostVaParamsCollateralToken][receiver];
    mathint vaultBefore = ghostERC20Balances128[ghostVaParamsCollateralToken][currentContract];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(ghostERC20Balances128[ghostVaParamsCollateralToken][receiver] == recvBefore + collateralSeized,
        "the receiver gains exactly the seized collateral, whoever it is");
    assert(receiver != currentContract
        => ghostERC20Balances128[ghostVaParamsCollateralToken][currentContract] == vaultBefore,
        "the vault custodies no collateral unless the caller named it as the receiver");
}

// Fast twin of VA-HL-16.
rule hlVaFallbackExitDoesNotDiluteRemainingHolders(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(maxIterations == 1,
        "SCOPE: one iteration, a single settle cut exposes the burn rounding");
    require(ghostMcCvlMaxWithdrawable[ghostVaController][currentContract] == 0,
        "SCOPE: no free liquidity, the settle leg carries the request");
    mathint managedBefore = ghostVaManagedSupplyShares256;
    mathint supplyBefore = ghostERC20TotalSupply256[_Vault];

    fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(ghostVaManagedSupplyShares256 * supplyBefore
            >= managedBefore * ghostERC20TotalSupply256[_Vault],
        "managed core supply per remaining share never falls");
}

// Fast twin of VA-HL-15, the sweep stays real; the lane adds only mulDivCVL and loop_iter 2.
rule hlVaFallbackExitSettleLegRespectsIterationCap(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations, address b1, address b2) {

    setupLidoLendERC4626ValidState(e);
    require(maxIterations == 1,
        "SCOPE: one iteration cap on the settle sweep");
    require(b1 != b2,
        "SCOPE: two distinct borrowers");
    mathint debtBefore1 = ghostLlCvlPosBorrowShares[b1];
    mathint collateralBefore1 = ghostLlCvlPosCollateral[b1];
    mathint debtBefore2 = ghostLlCvlPosBorrowShares[b2];
    mathint collateralBefore2 = ghostLlCvlPosCollateral[b2];

    fallbackExit(e, shares, receiver, owner, maxIterations);

    assert((ghostLlCvlPosBorrowShares[b1] == debtBefore1 && ghostLlCvlPosCollateral[b1] == collateralBefore1)
        || (ghostLlCvlPosBorrowShares[b2] == debtBefore2 && ghostLlCvlPosCollateral[b2] == collateralBefore2),
        "a one-iteration sweep never cuts two borrowers");
}
