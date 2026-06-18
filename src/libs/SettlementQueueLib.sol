// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {MathLib, WAD} from "@lido-lend/src/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MaxHeapLib} from "./MaxHeapLib.sol";
import {MarketView, PositionView, SlicePolicy} from "../types/SettlementTypes.sol";

/// @title SettlementQueueLib
/// @author Lido Lending contributors.
/// @notice Risk-ordered queue of borrowers for the settle waterfall, with per-borrower watermark
///         opt-in and the slice-sizing policy. Wraps a max-heap keyed by
///         borrowShares * KEY_SCALE / rawCollateral, so the root is the highest-LTV position: a
///         solvent root means no tracked position is bad debt, which is what makes the bad-debt gate
///         an O(1) root check.
/// @dev Self-contained module: the caller embeds `State`, forwards mutations, and supplies a
///      `MarketView` (live core/oracle snapshot) for the slice math. The lib makes no external calls;
///      the slice arithmetic (`sliceToLtv`) is pure and fuzz-testable.
library SettlementQueueLib {
    using MaxHeapLib for MaxHeapLib.Heap;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    /// @dev Heap key scale: key = borrowShares * KEY_SCALE / rawCollateral.
    uint256 internal constant KEY_SCALE = 1e18;

    uint256 internal constant BPS = 10_000;

    error WatermarkOutOfRange();
    error SlicePolicyOutOfRange();

    /// @notice Emitted when a borrower sets their personal settle-down watermark.
    event WatermarkSet(address indexed borrower, uint256 ltv);

    /// @notice Emitted when the settle slice policy is set.
    event SlicePolicySet(
        uint16 sliceFloorBps,
        uint96 sliceFloorAssets,
        uint96 fallbackMinRequest,
        uint96 fullCutBelowCollateral,
        uint16 ltvStepBps
    );

    struct State {
        MaxHeapLib.Heap heap;
        SlicePolicy policy;
        mapping(address borrower => uint256) watermarkLtv; // WAD target post-cut LTV, 0 = unset
    }

    // ---
    // MUTATIONS
    // ---

    /// @notice Push the heap's zero sentinel. Call once before any other operation.
    function init(State storage $) internal {
        $.heap.init();
    }

    /// @notice Store the borrower's projected post-action risk key, or remove it when it has no debt/collateral.
    function sync(State storage $, address borrower, PositionView memory position) internal {
        if (position.borrowShares == 0 || position.collateral == 0) {
            $.heap.remove(borrower);
            return;
        }
        $.heap.upsert(borrower, _riskKey(position));
    }

    function setSlicePolicy(State storage $, SlicePolicy memory policy) internal {
        if (policy.sliceFloorBps > BPS || policy.ltvStepBps > BPS) revert SlicePolicyOutOfRange();
        $.policy = policy;
        emit SlicePolicySet(
            policy.sliceFloorBps,
            policy.sliceFloorAssets,
            policy.fallbackMinRequest,
            policy.fullCutBelowCollateral,
            policy.ltvStepBps
        );
    }

    /// @notice Set `borrower`'s personal target post-cut LTV (WAD). 0 clears it; must be < WAD.
    function setWatermark(State storage $, address borrower, uint256 ltv) internal {
        if (ltv >= WAD) revert WatermarkOutOfRange();
        $.watermarkLtv[borrower] = ltv;
        emit WatermarkSet(borrower, ltv);
    }

    // ---
    // VIEWS
    // ---

    function watermarkOf(State storage $, address borrower) internal view returns (uint256) {
        return $.watermarkLtv[borrower];
    }

    function size(State storage $) internal view returns (uint256) {
        return $.heap.size();
    }

    /// @notice Riskiest borrower (heap root), or address(0) when the queue is empty.
    function peekRoot(State storage $) internal view returns (address riskiestBorrower) {
        if ($.heap.size() == 0) return address(0);
        (riskiestBorrower,) = $.heap.peek();
    }

    /// @notice Borrowers in the queue in heap-array order (approximate, not a strict sort), up to
    ///         `maxCount`.
    function eligibleBorrowers(State storage $, uint256 maxCount)
        internal
        view
        returns (address[] memory borrowers, uint256[] memory keys)
    {
        uint256 n = $.heap.size();
        uint256 count = n < maxCount ? n : maxCount;
        borrowers = new address[](count);
        keys = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            (borrowers[i], keys[i]) = $.heap.nodeAt(i);
        }
    }

    // ---
    // SLICE SIZING
    // ---

    /// @notice Maximum loan-asset slice the policy allows for one cut against `borrower`. A queue-root
    ///         borrower gets the policy slice; a watermarked borrower gets the watermark slice; if both
    ///         apply, the larger slice wins. Zero means ineligible or empty debt/collateral.
    function allowedSlice(State storage $, MarketView memory marketView, address borrower, PositionView memory position)
        internal
        view
        returns (uint256)
    {
        (uint256 debt, uint256 collateralValue) = _positionValues(marketView, position);
        if (debt == 0 || collateralValue == 0) return 0;

        uint256 rootCut = peekRoot($) == borrower ? _policySlice($.policy, debt, collateralValue) : 0;
        uint256 watermarkCut = _watermarkSlice($, borrower, debt, collateralValue);

        uint256 slice = Math.min(Math.max(rootCut, watermarkCut), debt);
        if (slice == 0) return 0;

        // A cut that would strand sub-threshold collateral is lifted to a full close.
        return _strandsDust($, marketView, position, slice) ? debt : slice;
    }

    /// @notice Watermark cut: the slice that brings `borrower`'s LTV down to its personal target. Zero
    ///         when no watermark, no debt/collateral, or the current LTV is already at/under the target.
    function watermarkSlice(
        State storage $,
        MarketView memory marketView,
        address borrower,
        PositionView memory position
    ) internal view returns (uint256) {
        (uint256 debt, uint256 collateralValue) = _positionValues(marketView, position);
        return _watermarkSlice($, borrower, debt, collateralValue);
    }

    /// @notice Effective cut for one loop iteration: the policy slice clamped to the remaining exit,
    ///         or 0 when the clamped cut would fall below `minCutAssets` — the policy would reject
    ///         such a cut, so the caller should stop (heap walk) or skip (explicit list) instead of
    ///         letting the whole call revert on a dust tail.
    function effectiveCut(uint256 sliceAssets, uint256 remainingExitAssets, uint256 minCutAssets)
        internal
        pure
        returns (uint256)
    {
        uint256 cut = sliceAssets > remainingExitAssets ? remainingExitAssets : sliceAssets;
        return cut < minCutAssets ? 0 : cut;
    }

    // ---
    // PURE MATH
    // ---

    /// @notice Loan-asset slice that brings a position's LTV down to `targetLtv` (WAD), cutting at the
    ///         oracle rate so equal-value collateral leaves with the debt. Backs both the watermark cut
    ///         and the root LTV-step rule.
    /// @param debt            Borrower debt in loan-asset units.
    /// @param collateralValue Borrower collateral value in loan-asset units (rawCollateral × price / SCALE).
    /// @dev c = (debt × WAD − targetLtv × collateralValue) / (WAD − targetLtv); 0 when already at or below
    ///      the target, or when `targetLtv >= WAD`.
    function sliceToLtv(uint256 debt, uint256 collateralValue, uint256 targetLtv) internal pure returns (uint256) {
        if (targetLtv >= WAD) return 0;
        uint256 debtScaled = debt * WAD;
        uint256 targetTerm = targetLtv * collateralValue;
        if (debtScaled <= targetTerm) return 0;
        return (debtScaled - targetTerm) / (WAD - targetLtv);
    }

    // ---
    // INTERNAL HELPERS
    // ---

    /// @dev True when cutting `slice` would leave the borrower's collateral below the full-close floor.
    function _strandsDust(State storage $, MarketView memory marketView, PositionView memory position, uint256 slice)
        private
        view
        returns (bool)
    {
        if (marketView.price == 0) return false;
        uint256 seized = slice.mulDivDown(ORACLE_PRICE_SCALE, marketView.price);
        uint256 remainingCollateral = Math.saturatingSub(position.collateral, seized);
        return remainingCollateral < $.policy.fullCutBelowCollateral;
    }

    /// @dev Root cut: the largest of the three slice rules — `sliceFloorBps` of the debt, `sliceFloorAssets`,
    ///      and the cut that lowers the LTV by `ltvStepBps`. Caller guarantees `debt > 0` and
    ///      `collateralValue > 0` (the `allowedSlice` entry gate), so the LTV division here is safe.
    function _policySlice(SlicePolicy storage policy, uint256 debt, uint256 collateralValue)
        private
        view
        returns (uint256)
    {
        uint256 byDebtFraction = debt * policy.sliceFloorBps / BPS;

        uint256 byLtvReduction;
        if (policy.ltvStepBps != 0) {
            uint256 currentLtv = debt * WAD / collateralValue;
            uint256 ltvReduction = uint256(policy.ltvStepBps) * WAD / BPS;
            byLtvReduction =
                sliceToLtv(debt, collateralValue, currentLtv > ltvReduction ? currentLtv - ltvReduction : 0);
        }

        return Math.max(policy.sliceFloorAssets, Math.max(byDebtFraction, byLtvReduction));
    }

    function _watermarkSlice(State storage $, address borrower, uint256 debt, uint256 collateralValue)
        private
        view
        returns (uint256)
    {
        uint256 watermark = $.watermarkLtv[borrower];
        if (watermark == 0 || debt == 0 || collateralValue == 0) return 0;
        return sliceToLtv(debt, collateralValue, watermark);
    }

    function _positionValues(MarketView memory marketView, PositionView memory position)
        private
        pure
        returns (uint256 debt, uint256 collateralValue)
    {
        debt = _debtAssets(marketView, position);
        collateralValue = _collateralValue(marketView, position);
    }

    function _riskKey(PositionView memory position) private pure returns (uint256) {
        return position.borrowShares * KEY_SCALE / position.collateral;
    }

    /// @dev Borrower debt in loan assets from a position + market snapshot.
    function _debtAssets(MarketView memory marketView, PositionView memory position) private pure returns (uint256) {
        return position.borrowShares.toAssetsUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
    }

    /// @dev Borrower collateral value in loan assets: rawCollateral × price / ORACLE_PRICE_SCALE.
    function _collateralValue(MarketView memory marketView, PositionView memory position)
        private
        pure
        returns (uint256)
    {
        return position.collateral.mulDivDown(marketView.price, ORACLE_PRICE_SCALE);
    }
}
