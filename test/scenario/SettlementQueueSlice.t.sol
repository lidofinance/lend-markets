// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {SettlementQueueLib} from "../../src/libs/SettlementQueueLib.sol";
import {MarketView, PositionView, SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {WAD} from "@lido-lend/src/libraries/MathLib.sol";

/// @dev Storage harness so the queue-bound `slice` view can be exercised.
contract QueueHarness {
    using SettlementQueueLib for SettlementQueueLib.State;

    SettlementQueueLib.State internal $;

    constructor() {
        $.init();
    }

    function sync(address borrower, uint256 borrowShares, uint256 rawCollateral) external {
        $.sync(borrower, PositionView({borrowShares: borrowShares, collateral: rawCollateral}));
    }

    function setSettlementConfig(SettlementConfig memory policy) external {
        $.setSettlementConfig(policy);
    }

    function allowedSlice(MarketView memory marketView, address borrower, PositionView memory position)
        external
        view
        returns (uint256)
    {
        return $.allowedSlice(marketView, borrower, position);
    }
}

/// @notice Coverage for `SettlementQueueLib` slice math: the pure `sliceToLtv`, and the
///         storage-bound `slice` policy terms and dust sweep.
contract SettlementQueueSliceTest is Test {
    address internal constant ROOT = address(0xA1);
    address internal constant RUNNER_UP = address(0xA2);

    function _position(uint256 borrowShares, uint256 rawCollateral) internal pure returns (PositionView memory) {
        return PositionView({borrowShares: borrowShares, collateral: rawCollateral});
    }

    /// @dev price 1e36 => collateralValue == rawCollateral; debt(shares) ≈ shares·(100e18/100e24).
    function _marketView() internal pure returns (MarketView memory) {
        return MarketView({
            totalSupplyAssets: 100e18,
            totalSupplyShares: 100e24,
            totalBorrowAssets: 100e18,
            totalBorrowShares: 100e24,
            price: 1e36,
            lltv: 0
        });
    }

    // ── sliceToLtv (pure)
    // ──────────────────────────────────

    function test_sliceToLtv_zeroWhenLtvAtOrBelowTarget() public pure {
        assertEq(SettlementQueueLib.sliceToLtv(50 ether, 100 ether, 0.5e18), 0, "ltv == target");
        assertEq(SettlementQueueLib.sliceToLtv(40 ether, 100 ether, 0.5e18), 0, "ltv < target");
    }

    function test_sliceToLtv_targetAtOrAboveWadReturnsZero() public pure {
        assertEq(SettlementQueueLib.sliceToLtv(50 ether, 100 ether, 1e18), 0, "target == WAD");
        assertEq(SettlementQueueLib.sliceToLtv(50 ether, 100 ether, 1.5e18), 0, "target > WAD");
    }

    function test_sliceToLtv_closedFormValue() public pure {
        // debt 80, collateralValue 100, target 50% => c = (80 - 0.5·100) / (1 - 0.5) = 60.
        uint256 slice = SettlementQueueLib.sliceToLtv(80 ether, 100 ether, 0.5e18);
        assertEq(slice, 60 ether, "closed form: cut 60 to land at LTV 50%");
    }

    function testFuzz_sliceToLtv_solventPostCutLtvAtTarget(uint256 debt, uint256 colValue, uint256 targetLtv)
        public
        pure
    {
        colValue = bound(colValue, 2, 1e30);
        debt = bound(debt, 1, colValue);
        targetLtv = bound(targetLtv, 1, 0.99e18);

        uint256 slice = SettlementQueueLib.sliceToLtv(debt, colValue, targetLtv);
        if (slice == 0) {
            assertLe(debt * WAD, targetLtv * colValue + WAD, "no-cut bound");
            return;
        }
        assertLe(slice, debt, "slice <= debt");
        uint256 postDebt = debt - slice;
        uint256 postColValue = colValue - slice;
        assertLe(postDebt * WAD, targetLtv * postColValue + WAD, "post-cut LTV at/under target");
    }

    // ── slice = max(bps·debt, abs, 1%-LTV) for the queue root ──

    function test_allowedSlice_zeroForNonRoot() public {
        QueueHarness h = new QueueHarness();
        h.sync(ROOT, 90e24, 100e18); // higher LTV => root
        h.sync(RUNNER_UP, 10e24, 100e18);
        assertEq(h.allowedSlice(_marketView(), RUNNER_UP, _position(10e24, 100e18)), 0, "non-root gets no slice");
    }

    /// @notice At a high LTV the 1%-LTV step is the largest term, so it wins the max; raising the
    ///         absolute floor above it makes the abs term win. Only ROOT is synced, so this is also
    ///         the lone-root case — now bounded by the rule rather than unbounded.
    function test_allowedSlice_ltvTermWins_thenAbsFloorWins() public {
        QueueHarness h = new QueueHarness();
        h.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 500, sliceFloorAssets: 1 ether, fullCutBelowCollateral: 0, ltvStepBps: 100
            })
        );
        h.sync(ROOT, 90e24, 100e18); // LTV ~0.9

        PositionView memory pos = _position(90e24, 100e18);
        MarketView memory mv = _marketView();
        uint256 debt = SharesMathLib.toAssetsUp(90e24, 100e18, 100e24);
        uint256 ltv = debt * WAD / 100e18;
        uint256 byLtv = SettlementQueueLib.sliceToLtv(debt, 100e18, ltv - 0.01e18);
        uint256 byBps = debt * 500 / 10_000;

        assertGt(byLtv, byBps, "1%-LTV step dominates 5% at ~0.9 LTV");
        assertEq(h.allowedSlice(mv, ROOT, pos), byLtv, "slice = largest term (1%-LTV step)");

        uint96 bigAbs = uint96(byLtv + 1 ether);
        h.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 500, sliceFloorAssets: bigAbs, fullCutBelowCollateral: 0, ltvStepBps: 100})
        );
        assertEq(h.allowedSlice(mv, ROOT, pos), bigAbs, "abs floor wins when it is the largest term");
    }

    /// @notice At a moderate LTV the 1%-LTV step is small, so the bps term wins.
    function test_allowedSlice_bpsTermWinsAtLowLtv() public {
        QueueHarness h = new QueueHarness();
        h.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 500, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 100})
        );
        h.sync(ROOT, 50e24, 100e18); // LTV ~0.5

        PositionView memory pos = _position(50e24, 100e18);
        MarketView memory mv = _marketView();
        uint256 debt = SharesMathLib.toAssetsUp(50e24, 100e18, 100e24);
        uint256 ltv = debt * WAD / 100e18;
        uint256 byLtv = SettlementQueueLib.sliceToLtv(debt, 100e18, ltv - 0.01e18);
        uint256 byBps = debt * 500 / 10_000;

        assertGe(byBps, byLtv, "5% term >= 1%-LTV step at ~0.5 LTV");
        assertEq(h.allowedSlice(mv, ROOT, pos), byBps, "slice = 5% of debt");
    }

    // ── slice dust sweep
    // ───────────────────────────────────────

    /// @notice When the policy slice would leave the borrower's collateral below the sweep floor,
    ///         the allowed slice lifts to the full debt so the position closes in one cut.
    function test_allowedSlice_dustExtensionLiftsToFullDebt() public {
        QueueHarness h = new QueueHarness();
        h.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 500, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 100})
        );
        h.sync(ROOT, 90e24, 100e18);
        h.sync(RUNNER_UP, 10e24, 100e18);

        PositionView memory pos = _position(90e24, 100e18);
        MarketView memory mv = _marketView();
        uint256 plainSlice = h.allowedSlice(mv, ROOT, pos);
        uint256 fullDebt = SharesMathLib.toAssetsUp(90e24, 100e18, 100e24);
        assertLt(plainSlice, fullDebt, "policy slice is partial without the sweep");

        // post-cut collateral = raw - seized; seized = plainSlice·SCALE/price (price 1e36 => seized == plainSlice).
        uint256 remaining = 100e18 - plainSlice;
        h.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 500, sliceFloorAssets: 0, fullCutBelowCollateral: uint96(remaining + 1), ltvStepBps: 100
            })
        );
        assertEq(h.allowedSlice(mv, ROOT, pos), fullDebt, "sweep lifts the bound to full debt");

        h.setSettlementConfig(
            SettlementConfig({
                sliceFloorBps: 500, sliceFloorAssets: 0, fullCutBelowCollateral: uint96(remaining), ltvStepBps: 100
            })
        );
        assertEq(h.allowedSlice(mv, ROOT, pos), plainSlice, "no sweep at the exact boundary");
    }

    function test_allowedSlice_capsAtDebt() public {
        QueueHarness h = new QueueHarness();
        h.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 0, sliceFloorAssets: 100 ether, fullCutBelowCollateral: 0, ltvStepBps: 0})
        );
        h.sync(ROOT, 10e24, 100e18);

        PositionView memory pos = _position(10e24, 100e18);
        uint256 debt = SharesMathLib.toAssetsUp(10e24, 100e18, 100e24);
        assertEq(h.allowedSlice(_marketView(), ROOT, pos), debt, "slice cannot exceed borrower debt");
    }
}
