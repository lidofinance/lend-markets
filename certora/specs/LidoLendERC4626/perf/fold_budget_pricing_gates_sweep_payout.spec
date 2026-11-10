// Perf lane for the rule below: mulDiv, pricing, liquidity, the sweep and the payout summarized in CVL.
// Overflowing quotients and sums are pruned rather than reverted; the burn's round up stays native.

import "../LidoLendERC4626_high_level.spec";

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256)
        => mulDivVaCVL(x, y, denominator);

    function Math.min(uint256 a, uint256 b) internal returns (uint256) => minVaCVL(a, b);
    function Math.ternary(bool c, uint256 a, uint256 b) internal returns (uint256) => ternaryVaCVL(c, a, b);

    function ERC4626Upgradeable._convertToShares(uint256 assets, Math.Rounding rounding)
        internal returns (uint256) => convertToSharesVaCVL(assets, rounding);
    function ERC4626Upgradeable._convertToAssets(uint256 shares, Math.Rounding rounding)
        internal returns (uint256) => convertToAssetsVaCVL(shares, rounding);

    function LidoLendERC4626._decimalsOffset() internal returns (uint8) => decimalsOffsetVaCVL();

    function LidoLendERC4626._marketSupplyTotals() internal returns (uint256, uint256)
        => marketSupplyTotalsVaCVL();

    function MathLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256)
        => mulDivDownVaCVL(x, y, d);

    function LidoLendERC4626._morphoWithdrawableAssets() internal returns (uint256)
        => morphoWithdrawableAssetsVaCVL();

    function LidoLendERC4626._settleBorrower(uint256 budgetSupplyShares, address borrower, address receiver)
        internal returns (uint256, uint256, uint256) => settleCutVaCVL(budgetSupplyShares);
    function LidoLendERC4626._settleNextAllowedBorrower(uint256 budgetSupplyShares, address receiver)
        internal returns (uint256, uint256, uint256) => settleCutVaCVL(budgetSupplyShares);

    function ERC4626Upgradeable._transferOut(address to, uint256 assets)
        internal => transferOutVaCVL(to, assets);
}

// 10**offset for the offsets 0 to 18 that offsetBounded allows.
persistent ghost ghostVaPow10(mathint) returns mathint {
    axiom ghostVaPow10(0) == 1;
    axiom ghostVaPow10(1) == 10;
    axiom ghostVaPow10(2) == 10^2;
    axiom ghostVaPow10(3) == 10^3;
    axiom ghostVaPow10(4) == 10^4;
    axiom ghostVaPow10(5) == 10^5;
    axiom ghostVaPow10(6) == 10^6;
    axiom ghostVaPow10(7) == 10^7;
    axiom ghostVaPow10(8) == 10^8;
    axiom ghostVaPow10(9) == 10^9;
    axiom ghostVaPow10(10) == 10^10;
    axiom ghostVaPow10(11) == 10^11;
    axiom ghostVaPow10(12) == 10^12;
    axiom ghostVaPow10(13) == 10^13;
    axiom ghostVaPow10(14) == 10^14;
    axiom ghostVaPow10(15) == 10^15;
    axiom ghostVaPow10(16) == 10^16;
    axiom ghostVaPow10(17) == 10^17;
    axiom ghostVaPow10(18) == 10^18;
}

// SCOPE: a quotient wider than 256 bits is pruned rather than reverted.
function mulDivVaCVL(uint256 x, uint256 y, uint256 denominator) returns uint256 {
    require(denominator != 0, "SAFE: the denominator is nonzero");
    return require_uint256(x * y / denominator);
}

function minVaCVL(uint256 a, uint256 b) returns uint256 {
    return a < b ? a : b;
}

function ternaryVaCVL(bool c, uint256 a, uint256 b) returns uint256 {
    return c ? a : b;
}

function decimalsOffsetVaCVL() returns uint8 {
    return require_uint8(ghostVaLoanDecimalsOffset8);
}

function marketSupplyTotalsVaCVL() returns (uint256, uint256) {
    return (require_uint256(ghostLlCvlTotalSupplyAssets), require_uint256(ghostLlCvlTotalSupplyShares));
}

// SCOPE: exact value; an overflow panic becomes a prune.
function mulDivDownVaCVL(uint256 x, uint256 y, uint256 d) returns uint256 {
    require(d != 0, "SAFE: totalSupplyShares plus VIRTUAL_SHARES is nonzero");
    return require_uint256(x * y / d);
}

function morphoWithdrawableAssetsVaCVL() returns uint256 {
    return ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
}

function totalAssetsVaCVL() returns mathint {
    if (ghostVaManagedSupplyShares256 == 0) {
        return 0;
    }
    return toAssetsDownLlCVL(ghostVaManagedSupplyShares256,
        ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares);
}

// SCOPE: overflow is pruned rather than reverted; the odd rounding modes round up.
function convertToSharesVaCVL(uint256 assets, Math.Rounding rounding) returns uint256 {
    mathint num = assets * (ghostERC20TotalSupply256[_Vault] + ghostVaPow10(ghostVaLoanDecimalsOffset8));
    mathint den = totalAssetsVaCVL() + 1;
    bool up = (to_mathint(assert_uint8(rounding)) % 2 == 1) && (num % den != 0);
    return require_uint256(up ? num / den + 1 : num / den);
}

function convertToAssetsVaCVL(uint256 shares, Math.Rounding rounding) returns uint256 {
    mathint num = shares * (totalAssetsVaCVL() + 1);
    mathint den = ghostERC20TotalSupply256[_Vault] + ghostVaPow10(ghostVaLoanDecimalsOffset8);
    require(den != 0, "SAFE: the virtual share unit keeps the denominator nonzero");
    bool up = (to_mathint(assert_uint8(rounding)) % 2 == 1) && (num % den != 0);
    return require_uint256(up ? num / den + 1 : num / den);
}

// Free cut figures and no state change: a widening of the real cut.
function settleCutVaCVL(uint256 budgetSupplyShares) returns (uint256, uint256, uint256) {
    uint256 cutShares;
    uint256 cutCollateral;
    uint256 cutDebt;
    require(cutCollateral <= max_uint128 && cutDebt <= max_uint128,
        "SAFE: core cuts fit its uint128 totals");
    return (cutShares, cutCollateral, cutDebt);
}

function transferOutVaCVL(address to, uint256 assets) {
    transferERC20CVL(ghostVaAsset, currentContract, to, assets);
}

use rule hlVaSettleBurnsAtMostRequestedShares;
