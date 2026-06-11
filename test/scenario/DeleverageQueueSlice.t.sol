// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeleverageQueueLib} from "../../src/libs/DeleverageQueueLib.sol";
import {WAD} from "@lido-blue/src/libraries/MathLib.sol";

/// @notice Fuzz/unit coverage for the pure slice math now folded into `DeleverageQueueLib`
///         (`computeSlice` / `computeWatermarkSlice`).
contract DeleverageQueueSliceTest is Test {
    uint256 internal constant KEY_SCALE = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    function _slice(
        uint256 topKey,
        uint256 targetKey,
        uint256 topCollateral,
        uint256 totalBorrowShares,
        uint256 totalBorrowAssets,
        uint256 collateralPrice
    ) internal pure returns (uint256) {
        DeleverageQueueLib.MarketView memory marketView = DeleverageQueueLib.MarketView({
            borrowShares: 0,
            rawCollateral: topCollateral,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: totalBorrowShares,
            price: collateralPrice
        });
        return DeleverageQueueLib.computeSlice(marketView, topKey, targetKey);
    }

    // ── Degenerate inputs return zero
    // ──────────────────────────

    function test_targetNotBelowTop_returnsZero() public pure {
        assertEq(_slice(100, 100, 1e18, 1e24, 1e18, 1e36), 0, "target == top");
        assertEq(_slice(100, 150, 1e18, 1e24, 1e18, 1e36), 0, "target > top");
    }

    function test_zeroCollateral_returnsZero() public pure {
        assertEq(_slice(200, 100, 0, 1e24, 1e18, 1e36), 0);
    }

    function test_zeroTotals_returnsZero() public pure {
        assertEq(_slice(200, 100, 1e18, 0, 1e18, 1e36), 0, "zero shares");
        assertEq(_slice(200, 100, 1e18, 1e24, 0, 1e36), 0, "zero assets");
    }

    function test_zeroPrice_returnsZero() public pure {
        assertEq(_slice(200, 100, 1e18, 1e24, 1e18, 0), 0);
    }

    function test_denominatorInversion_returnsZero() public pure {
        // sharesPerAssetTerm <= targetPriceTerm: tiny totalBorrowShares/assets ratio and a large
        // targetKey/price ratio drive the denominator non-positive.
        uint256 slice = _slice(
            2e18, // topKey
            1e18, // targetKey
            100e18, // topCollateral
            1, // totalBorrowShares (tiny → sharesPerAssetTerm ~ 0)
            1e30, // totalBorrowAssets (huge)
            1 // collateralPrice (tiny → targetPriceTerm huge)
        );
        assertEq(slice, 0, "inverted denominator returns zero");
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

        uint256 sliceA = _slice(topKey, targetA, topCollateral, totalBorrowShares, totalBorrowAssets, collateralPrice);
        uint256 sliceB = _slice(topKey, targetB, topCollateral, totalBorrowShares, totalBorrowAssets, collateralPrice);

        // Bigger gap (targetB lower) should not produce a smaller slice. Both must be valid
        // (denominator positive) for the comparison to hold.
        if (sliceA > 0 && sliceB > 0) {
            assertGe(sliceB, sliceA, "larger gap => slice not smaller");
        }
    }

    // ── Known closed-form value
    // ─────────────────────────────────────

    // ── Watermark slice
    // ─────────────────────────────────────────────

    function test_watermarkSlice_zeroWhenLtvAtOrBelowTarget() public pure {
        // current LTV = 0.5; target = 0.5 → no cut.
        assertEq(DeleverageQueueLib.computeWatermarkSlice(50 ether, 100 ether, 0.5e18), 0, "ltv == target");
        // current LTV = 0.4; target = 0.5 → no cut.
        assertEq(DeleverageQueueLib.computeWatermarkSlice(40 ether, 100 ether, 0.5e18), 0, "ltv < target");
    }

    function test_watermarkSlice_targetAtOrAboveWadReturnsZero() public pure {
        assertEq(DeleverageQueueLib.computeWatermarkSlice(50 ether, 100 ether, 1e18), 0, "target == WAD");
        assertEq(DeleverageQueueLib.computeWatermarkSlice(50 ether, 100 ether, 1.5e18), 0, "target > WAD");
    }

    function test_watermarkSlice_closedFormValue() public pure {
        // debt 80, collateralValue 100, target 50% → c = (80*1 - 0.5*100) / (1 - 0.5) = 30 / 0.5 = 60.
        // Post-cut: debt 20, colValue 40, LTV = 0.5 ✓
        uint256 slice = DeleverageQueueLib.computeWatermarkSlice(80 ether, 100 ether, 0.5e18);
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

        uint256 slice = DeleverageQueueLib.computeWatermarkSlice(debt, colValue, targetLtv);
        if (slice == 0) {
            assertLe(debt * WAD, targetLtv * colValue + WAD, "no-cut bound");
            return;
        }
        // Solvent inputs imply slice ≤ debt ≤ colValue.
        assertLe(slice, debt, "slice <= debt");
        uint256 postDebt = debt - slice;
        uint256 postColValue = colValue - slice;
        assertLe(postDebt * WAD, targetLtv * postColValue + WAD, "post-cut LTV at/under target");
    }

    /// @notice When the heap key saturates at `type(uint96).max` (uint96-packed slot), distinct
    ///         high-risk borrowers tie at the top: `topKey == targetKey`. `computeSlice` then takes
    ///         the `targetKey >= topKey` fallback and returns 0 — silent slice degradation in the
    ///         saturation regime. `heapSlice` (the operational caller) clamps to `sliceFloorAssets`,
    ///         which is what salvages forward progress in this corner.
    function test_keySaturation_tiedTopReturnsZero() public pure {
        uint256 saturatedKey = uint256(type(uint96).max);
        uint256 slice = _slice(
            saturatedKey, // topKey at uint96.max
            saturatedKey, // childMaxKey also at uint96.max — tied
            100 ether,
            1e24,
            1e18,
            1e36
        );
        assertEq(slice, 0, "saturated tie collapses to zero (heapSlice then clamps to floor)");
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
        uint256 slice = _slice(2e18, 1e18, 100e18, 100e24, 100e18, 1e36);
        assertEq(slice, expected, "closed form matches");
    }
}
