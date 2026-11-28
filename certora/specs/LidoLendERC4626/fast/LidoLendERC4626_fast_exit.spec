// Fast twins of the vault's fallbackExit rules that time out in the parent files, same names and bodies.
// Math.mulDiv is cut to its CVL model and the settlement sweep to a free stateless stub, so every rule
// asserts only figures produced outside the sweep.

import "../LidoLendERC4626_valid_state.spec";
import "../../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";
import "../../setup/math.spec";

methods {
    function LidoLendERC4626._settleNextAllowedBorrower(uint256 budgetSupplyShares, address receiver)
        internal returns (uint256, uint256, uint256) => fastVaSettleCutCVL(budgetSupplyShares);
}

// Free cut figures with no state change.
function fastVaSettleCutCVL(uint256 budgetSupplyShares) returns (uint256, uint256, uint256) {
    uint256 cutShares;
    uint256 cutCollateral;
    uint256 cutDebt;
    require(cutCollateral <= max_uint128 && cutDebt <= max_uint128,
        "SAFE: core seizures and cancellations are held in uint128 totals");
    return (cutShares, cutCollateral, cutDebt);
}

// Fast twin of VA-HL-22.
rule hlVaFallbackExitDeliversPreviewedLoanAssetsWhenLiquidCovers(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(to_mathint(shares) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(liquid != 0 && to_mathint(previewRedeem(e, shares)) <= liquid,
        "SCOPE: positive free liquidity covers the whole request");

    mathint quotedLoanAssets = previewRedeem(e, shares);

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(to_mathint(loanAssets) == quotedLoanAssets,
        "the exit pays the quoted loan assets, neither more nor less");
}

// Fast twin of VA-HL-23.
rule hlVaFallbackExitDeliversPreviewedLoanAssetsWhenLiquidPartial(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(to_mathint(shares) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(to_mathint(previewRedeem(e, shares)) > liquid && liquid != 0,
        "SCOPE: positive free liquidity is short of the request");

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(to_mathint(loanAssets) == liquid,
        "a short liquid leg pays exactly the free liquidity");
}

// Fast twin of VA-HL-25.
rule hlVaFallbackExitBurnsAtMostRequestedSharesWhenLiquidPartial(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(to_mathint(previewRedeem(e, shares)) > liquid && liquid != 0,
        "SCOPE: positive free liquidity is short of the request");
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(sharesBurned <= shares, "the redeem and settle legs together never burn past the requested shares");
    assert(ghostERC20Balances128[_Vault][owner] == balBefore - sharesBurned,
        "the reported burn is exactly what the owner lost");
}

// Fast twin of VA-HL-26.
rule hlVaFallbackExitBurnsAtMostRequestedSharesWhenNoLiquidity(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(ghostMcCvlMaxWithdrawable[ghostVaController][currentContract] == 0,
        "SCOPE: no free liquidity, the settle leg carries the request");
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(sharesBurned <= shares, "the settle leg alone never burns past the requested shares");
    assert(ghostERC20Balances128[_Vault][owner] == balBefore - sharesBurned,
        "the reported burn is exactly what the owner lost");
}

// Fast twin of VA-RC-23.
rule rcVaFallbackExitPartialFillIsReachable(env e, uint256 shares, address receiver, address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    satisfy(sharesBurned > 0 && to_mathint(sharesBurned) < to_mathint(shares),
        "a fallback exit can succeed on a shortfall, burning fewer shares than asked");
}

// Fast twin of VA-HL-24; a fully liquid exit never reaches the stubbed sweep.
rule hlVaFallbackExitBurnsAtMostRequestedSharesWhenLiquidCovers(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(liquid != 0 && to_mathint(previewRedeem(e, shares)) <= liquid,
        "SCOPE: positive free liquidity covers the whole request");
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(sharesBurned == shares, "a fully liquid exit burns exactly the request");
    assert(ghostERC20Balances128[_Vault][owner] == balBefore - sharesBurned,
        "the reported burn is exactly what the owner lost");
}
