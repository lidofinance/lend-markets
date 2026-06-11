// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {DeleverageQueueLib} from "../../src/libs/DeleverageQueueLib.sol";
import {SharesMathLib} from "@lido-blue/src/libraries/SharesMathLib.sol";
import {WAD} from "@lido-blue/src/libraries/MathLib.sol";

/// @dev Storage harness so the queue-bound views (`heapSlice` / `allowedSlice`) can be exercised.
contract QueueHarness {
    using DeleverageQueueLib for DeleverageQueueLib.State;

    DeleverageQueueLib.State internal $;

    constructor() {
        $.init();
    }

    function sync(address borrower, uint256 borrowShares, uint256 rawCollateral) external {
        $.sync(borrower, borrowShares, rawCollateral);
    }

    function setSlicePolicy(DeleverageQueueLib.SlicePolicy memory policy) external {
        $.setSlicePolicy(policy);
    }

    function heapSlice(address borrower, DeleverageQueueLib.MarketView memory marketView)
        external
        view
        returns (uint256)
    {
        return $.heapSlice(borrower, marketView);
    }

    function allowedSlice(
        address borrower,
        DeleverageQueueLib.MarketView memory marketView,
        uint256 minRemainingCollateral
    ) external view returns (uint256) {
        return $.allowedSlice(borrower, marketView, minRemainingCollateral);
    }
}

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
    ///         saturation regime. `heapSlice` (the operational caller) still adds the overshoot
    ///         `max(debt / 100, sliceFloorAssets)`, which is what keeps the queue moving here.
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
        assertEq(slice, 0, "saturated tie collapses to zero (overshoot still applies in heapSlice)");
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

    // ── heapSlice / allowedSlice (storage-bound, via harness)
    // ─────────────────────────

    address internal constant ROOT = address(0xA1);
    address internal constant RUNNER_UP = address(0xA2);

    function _marketView(uint256 borrowShares, uint256 rawCollateral)
        internal
        pure
        returns (DeleverageQueueLib.MarketView memory)
    {
        return DeleverageQueueLib.MarketView({
            borrowShares: borrowShares,
            rawCollateral: rawCollateral,
            totalBorrowAssets: 100e18,
            totalBorrowShares: 100e24,
            price: 1e36
        });
    }

    /// @notice heapSlice = closed-form + overshoot, overshoot = max(debt * bps / 10000, sliceFloorAssets).
    function test_heapSlice_addsOvershootOnTopOfClosedForm() public {
        QueueHarness h = new QueueHarness();
        h.setSlicePolicy(
            DeleverageQueueLib.SlicePolicy({overshootBps: 100, sliceFloorAssets: 0, fallbackMinRequest: 0})
        );
        h.sync(ROOT, 20e24, 1e25); // key = 2e18
        h.sync(RUNNER_UP, 10e24, 1e25); // key = 1e18

        DeleverageQueueLib.MarketView memory mv = _marketView(20e24, 1e25);
        uint256 debt = SharesMathLib.toAssetsUp(20e24, 100e18, 100e24);

        uint256 closedForm = DeleverageQueueLib.computeSlice(mv, 2e18, 1e18);
        assertGt(closedForm, 0, "closed form positive for this setup");

        // floor below debt * bps: overshoot = debt * bps / 10000
        assertEq(h.heapSlice(ROOT, mv), closedForm + debt / 100, "overshoot = 1% of debt when floor smaller");

        // floor above debt * bps: overshoot = floor
        uint96 bigFloor = uint96(debt / 100 + 1 ether);
        h.setSlicePolicy(
            DeleverageQueueLib.SlicePolicy({overshootBps: 100, sliceFloorAssets: bigFloor, fallbackMinRequest: 0})
        );
        assertEq(h.heapSlice(ROOT, mv), closedForm + bigFloor, "overshoot = floor when floor larger");
    }

    function test_heapSlice_zeroForNonRoot_andMaxForLoneRoot() public {
        QueueHarness h = new QueueHarness();
        h.sync(ROOT, 20e24, 10e18);
        h.sync(RUNNER_UP, 10e24, 10e18);

        DeleverageQueueLib.MarketView memory mv = _marketView(10e24, 10e18);
        assertEq(h.heapSlice(RUNNER_UP, mv), 0, "non-root gets no heap slice");

        h.sync(RUNNER_UP, 0, 0); // drop the runner-up
        assertEq(
            h.heapSlice(ROOT, _marketView(20e24, 10e18)),
            type(uint256).max,
            "lone root unbounded (caller caps to remaining exit)"
        );
    }

    /// @notice Saturated key tie: computeSlice contributes 0, the overshoot alone keeps the cut
    ///         non-zero so the queue can make forward progress.
    function test_heapSlice_overshootSalvagesSaturatedTie() public {
        QueueHarness h = new QueueHarness();
        h.setSlicePolicy(
            DeleverageQueueLib.SlicePolicy({overshootBps: 100, sliceFloorAssets: 0, fallbackMinRequest: 0})
        );
        uint256 hugeShares = uint256(type(uint96).max) * 2e18; // saturates the uint96 key
        h.sync(ROOT, hugeShares, 1e18);
        h.sync(RUNNER_UP, hugeShares, 1e18);

        DeleverageQueueLib.MarketView memory mv = _marketView(20e24, 10e18);
        uint256 debt = SharesMathLib.toAssetsUp(20e24, 100e18, 100e24);
        assertEq(h.heapSlice(ROOT, mv), debt / 100, "tied keys: slice is pure overshoot");
    }

    /// @notice Dust extension: when the allowed slice would leave the borrower's collateral below the
    ///         supplied minimum, the bound lifts to the full debt so the position closes in one cut.
    function test_allowedSlice_dustExtensionLiftsToFullDebt() public {
        QueueHarness h = new QueueHarness();
        h.setSlicePolicy(
            DeleverageQueueLib.SlicePolicy({overshootBps: 100, sliceFloorAssets: 0, fallbackMinRequest: 0})
        );
        h.sync(ROOT, 20e24, 1e25);
        h.sync(RUNNER_UP, 10e24, 1e25);

        DeleverageQueueLib.MarketView memory mv = _marketView(20e24, 1e25);
        uint256 plainSlice = h.allowedSlice(ROOT, mv, 0);
        uint256 fullDebt = SharesMathLib.toAssetsUp(20e24, 100e18, 100e24);
        assertLt(plainSlice, fullDebt, "policy slice is partial without the extension");

        // post-cut collateral = raw - slice * SCALE / price; pick a minimum above it to trigger.
        uint256 seized = plainSlice * 1e36 / 1e36;
        uint256 remaining = 1e25 - seized;
        assertEq(h.allowedSlice(ROOT, mv, remaining + 1), fullDebt, "extension lifts the bound to full debt");
        assertEq(h.allowedSlice(ROOT, mv, remaining), plainSlice, "no extension at the exact boundary");
    }
}
