// OZ Math.mulDiv as CVL: the native 512-bit Yul implementation is out of the solver's reach, so the
// product is taken in mathint and the quotient is required back into 256 bits.

methods {
    function Math.mulDiv(uint256 x, uint256 y, uint256 denominator) internal returns (uint256)
        => mulDivCVL(x, y, denominator);
}

// SCOPE: a quotient wider than 256 bits is pruned rather than reverted.
function mulDivCVL(uint256 x, uint256 y, uint256 denominator) returns uint256 {
    require(denominator != 0, "SAFE: the denominator is nonzero");
    return require_uint256(x * y / denominator);
}
