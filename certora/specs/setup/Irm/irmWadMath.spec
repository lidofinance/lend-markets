// WAD helpers of the two MathLib libraries meeting in the IRM scenes: signed for the adaptive curve, unsigned
// for the core, all four bound by name because the library names collide. The require_ casts over approximate:
// they drop the states where the real checked math reverts.

methods {
    function _.wMulToZero(int256 x, int256 y) internal => wMulToZeroCVL(x, y) expect int256;
    function _.wDivToZero(int256 x, int256 y) internal => wDivToZeroCVL(x, y) expect int256;
    function _.wDivDown(uint256 x, uint256 y) internal => wDivDownCVL(x, y) expect uint256;
    function _.wMulDown(uint256 x, uint256 y) internal => wMulDownCVL(x, y) expect uint256;
}

definition WAD_MATH() returns mathint = 1000000000000000000;

// Magnitudes keep the truncation toward zero, as SDIV does.
function divToZeroCVL(mathint a, mathint b) returns mathint {
    require(b != 0, "SAFE: every call site guards its denominator");
    mathint absA = a >= 0 ? a : -a;
    mathint absB = b >= 0 ? b : -b;
    mathint mag = absA / absB;
    return (a < 0) != (b < 0) ? -mag : mag;
}

function wMulToZeroCVL(int256 x, int256 y) returns int256 {
    mathint product = to_mathint(x) * to_mathint(y);
    return require_int256(divToZeroCVL(product, WAD_MATH()));
}

function wDivToZeroCVL(int256 x, int256 y) returns int256 {
    mathint num = to_mathint(x) * WAD_MATH();
    return require_int256(divToZeroCVL(num, to_mathint(y)));
}

function wDivDownCVL(uint256 x, uint256 y) returns uint256 {
    require(y != 0, "SAFE: the call site reaches wDivDown only with a non zero denominator");
    mathint num = to_mathint(x) * WAD_MATH();
    return require_uint256(num / to_mathint(y));
}

function wMulDownCVL(uint256 x, uint256 y) returns uint256 {
    mathint product = to_mathint(x) * to_mathint(y);
    return require_uint256(product / WAD_MATH());
}
