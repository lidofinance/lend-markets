// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeleverageSliceLib} from "../../src/libs/DeleverageSliceLib.sol";

contract DeleverageSliceLibTest is Test {
    uint256 internal constant KEY_SCALE = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    function _slice(
        uint256 topKey,
        uint256 targetKey,
        uint256 topCollateral,
        uint256 totalBorrowShares,
        uint256 totalBorrowAssets,
        uint256 collateralPrice,
        uint256 sliceFloor
    ) internal pure returns (uint256) {
        return DeleverageSliceLib.computeSlice(
            topKey, targetKey, topCollateral, totalBorrowShares, totalBorrowAssets, collateralPrice, sliceFloor
        );
    }

    // ── Degenerate inputs return the floor ──────────────────────────

    function test_targetNotBelowTop_returnsFloor() public pure {
        uint256 f = 1 ether;
        assertEq(_slice(100, 100, 1e18, 1e24, 1e18, 1e36, f), f, "target == top");
        assertEq(_slice(100, 150, 1e18, 1e24, 1e18, 1e36, f), f, "target > top");
    }

    function test_zeroCollateral_returnsFloor() public pure {
        uint256 f = 1 ether;
        assertEq(_slice(200, 100, 0, 1e24, 1e18, 1e36, f), f);
    }

    function test_zeroTotals_returnsFloor() public pure {
        uint256 f = 1 ether;
        assertEq(_slice(200, 100, 1e18, 0, 1e18, 1e36, f), f, "zero shares");
        assertEq(_slice(200, 100, 1e18, 1e24, 0, 1e36, f), f, "zero assets");
    }

    function test_zeroPrice_returnsFloor() public pure {
        uint256 f = 1 ether;
        assertEq(_slice(200, 100, 1e18, 1e24, 1e18, 0, f), f);
    }

    function test_denominatorInversion_returnsFloor() public pure {
        // sharesPerAssetTerm <= targetPriceTerm: pick a tiny totalBorrowShares/assets ratio and a
        // large targetKey/price ratio so the denominator goes non-positive.
        uint256 f = 1 ether;
        uint256 slice = _slice(
            2e18, // topKey
            1e18, // targetKey
            100e18, // topCollateral
            1, // totalBorrowShares (tiny → sharesPerAssetTerm ~ 0)
            1e30, // totalBorrowAssets (huge)
            1, // collateralPrice (tiny → targetPriceTerm huge)
            f
        );
        assertEq(slice, f, "inverted denominator falls back to floor");
    }

    // ── Result never below the floor ────────────────────────────────

    function testFuzz_neverBelowFloor(
        uint256 topKey,
        uint256 targetKey,
        uint256 topCollateral,
        uint256 totalBorrowShares,
        uint256 totalBorrowAssets,
        uint256 collateralPrice,
        uint256 sliceFloor
    ) public pure {
        topKey = bound(topKey, 1, 1e24);
        targetKey = bound(targetKey, 0, 1e24);
        topCollateral = bound(topCollateral, 0, 1e30);
        totalBorrowShares = bound(totalBorrowShares, 0, 1e36);
        totalBorrowAssets = bound(totalBorrowAssets, 0, 1e30);
        collateralPrice = bound(collateralPrice, 0, 1e40);
        sliceFloor = bound(sliceFloor, 0, 100 ether);

        uint256 slice =
            _slice(topKey, targetKey, topCollateral, totalBorrowShares, totalBorrowAssets, collateralPrice, sliceFloor);
        assertGe(slice, sliceFloor, "slice >= floor always");
    }

    // ── Monotonicity: a larger key gap yields a larger-or-equal slice ──

    function testFuzz_largerGapNotSmaller(uint256 topKey, uint256 targetA, uint256 gapDelta) public pure {
        topKey = bound(topKey, 2e18, 1e24);
        targetA = bound(targetA, 1, topKey - 1);
        gapDelta = bound(gapDelta, 1, targetA); // targetB < targetA → bigger gap
        uint256 targetB = targetA - gapDelta;

        uint256 topCollateral = 50e18;
        uint256 totalBorrowShares = 100e24;
        uint256 totalBorrowAssets = 100e18;
        uint256 collateralPrice = 1.2e36;
        uint256 floor = 0;

        uint256 sliceA =
            _slice(topKey, targetA, topCollateral, totalBorrowShares, totalBorrowAssets, collateralPrice, floor);
        uint256 sliceB =
            _slice(topKey, targetB, topCollateral, totalBorrowShares, totalBorrowAssets, collateralPrice, floor);

        // Bigger gap (targetB lower) should not produce a smaller slice. Both must be valid
        // (denominator positive) for the comparison to hold.
        if (sliceA > floor && sliceB > floor) {
            assertGe(sliceB, sliceA, "larger gap => slice not smaller");
        }
    }

    // ── Known closed-form value ─────────────────────────────────────

    // ── Watermark slice ─────────────────────────────────────────────

    function test_watermarkSlice_zeroWhenLtvAtOrBelowTarget() public pure {
        // current LTV = 0.5; target = 0.5 → no cut.
        assertEq(DeleverageSliceLib.computeWatermarkSlice(50 ether, 100 ether, 0.5e18), 0, "ltv == target");
        // current LTV = 0.4; target = 0.5 → no cut.
        assertEq(DeleverageSliceLib.computeWatermarkSlice(40 ether, 100 ether, 0.5e18), 0, "ltv < target");
    }

    function test_watermarkSlice_targetAtOrAboveWadReturnsZero() public pure {
        assertEq(DeleverageSliceLib.computeWatermarkSlice(50 ether, 100 ether, 1e18), 0, "target == WAD");
        assertEq(DeleverageSliceLib.computeWatermarkSlice(50 ether, 100 ether, 1.5e18), 0, "target > WAD");
    }

    function test_watermarkSlice_closedFormValue() public pure {
        // debt 80, collateralValue 100, target 50% → c = (80*1 - 0.5*100) / (1 - 0.5) = 30 / 0.5 = 60.
        // Post-cut: debt 20, colValue 40, LTV = 0.5 ✓
        uint256 slice = DeleverageSliceLib.computeWatermarkSlice(80 ether, 100 ether, 0.5e18);
        assertEq(slice, 60 ether, "closed form: cut 60 to land at LTV 50%");
    }

    function testFuzz_watermarkSlice_solventPostCutLtvAtTarget(uint256 debt, uint256 colValue, uint256 targetLtv)
        public
        pure
    {
        // Only solvent (debt ≤ colValue) inputs: the lib does not promise a seizable slice for
        // already-bad-debt positions, callers cap by collateral.
        colValue = bound(colValue, 2, 1e30);
        debt = bound(debt, 1, colValue);
        targetLtv = bound(targetLtv, 1, 0.99e18);

        uint256 slice = DeleverageSliceLib.computeWatermarkSlice(debt, colValue, targetLtv);
        if (slice == 0) {
            assertLe(debt * DeleverageSliceLib.WAD, targetLtv * colValue + DeleverageSliceLib.WAD, "no-cut bound");
            return;
        }
        // Solvent inputs imply slice ≤ debt ≤ colValue.
        assertLe(slice, debt, "slice <= debt");
        uint256 postDebt = debt - slice;
        uint256 postColValue = colValue - slice;
        assertLe(
            postDebt * DeleverageSliceLib.WAD,
            targetLtv * postColValue + DeleverageSliceLib.WAD,
            "post-cut LTV at/under target"
        );
    }

    function test_closedFormValue() public pure {
        // topKey=2e18, targetKey=1e18, topCollateral=100e18
        // totalBorrowShares=100e24, totalBorrowAssets=100e18 → sharesPerAssetTerm = 1e24
        // collateralPrice=1e36 → targetPriceTerm = 1e18 * 1e36 / 1e36 = 1e18
        // numerator = (2e18-1e18)*100e18 = 1e20*1e18 = 1e38
        // denom = 1e24 - 1e18 ≈ 1e24
        // slice ≈ 1e38 / (1e24 - 1e18)
        uint256 numerator = uint256(1e18) * 100e18;
        uint256 denominator = uint256(1e24) - 1e18;
        uint256 expected = numerator / denominator;
        uint256 slice = _slice(2e18, 1e18, 100e18, 100e24, 100e18, 1e36, 0);
        assertEq(slice, expected, "closed form matches");
    }
}
