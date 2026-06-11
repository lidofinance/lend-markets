// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {SharesMathLib} from "@lido-blue/src/libraries/SharesMathLib.sol";
import {MathLib, WAD} from "@lido-blue/src/libraries/MathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-blue/src/libraries/ConstantsLib.sol";
import {MaxHeapLib} from "./MaxHeapLib.sol";

/// @title DeleverageQueueLib
/// @author Lido Lending contributors.
/// @notice Risk-ordered queue of borrowers for the deleverage waterfall, with per-borrower watermark
///         opt-in and the slice-sizing policy. Wraps a max-heap keyed by
///         borrowShares * KEY_SCALE / rawCollateral, so the root is the highest-LTV position: a
///         solvent root means no tracked position is bad debt, which is what makes the bad-debt gate
///         an O(1) root check.
/// @dev Self-contained module: the caller embeds `State`, forwards mutations, and supplies a
///      `MarketView` (live core/oracle snapshot) for the slice math. The lib makes no external calls;
///      the slice arithmetic (`computeSlice` / `computeWatermarkSlice`) is pure and fuzz-testable.
library DeleverageQueueLib {
    using MaxHeapLib for MaxHeapLib.Heap;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    /// @dev Heap key scale: key = borrowShares × KEY_SCALE / rawCollateral.
    uint256 internal constant KEY_SCALE = 1e18;

    error WatermarkOutOfRange();

    event WatermarkSet(address indexed borrower, uint256 ltv);

    /// @notice Live core/oracle snapshot of a borrower position, built by the controller from core
    ///         reads and consumed by the slice and bad-debt math. Not carried in any hook payload.
    struct MarketView {
        uint256 borrowShares;
        uint256 rawCollateral;
        uint256 totalBorrowAssets;
        uint256 totalBorrowShares;
        uint256 price; // collateral price in loan asset, ORACLE_PRICE_SCALE
    }

    struct State {
        MaxHeapLib.Heap heap;
        uint128 sliceFloorAssets; // minimum heap-safety overshoot added to each cut (0 = pure 1%-of-debt)
        uint128 fallbackMinRequest; // minimum loan assets one deleverage call may cancel (0 = no floor)
        mapping(address borrower => uint256) watermarkLtv; // WAD target post-cut LTV, 0 = unset
    }

    /// @notice Push the heap's zero sentinel. Call once before any other operation.
    function init(State storage $) internal {
        $.heap.init();
    }

    /// @notice Re-key `borrower` by risk, or drop it from the queue once it has no debt or no
    ///         collateral. Risk key = borrowShares * KEY_SCALE / rawCollateral.
    function sync(State storage $, address borrower, uint256 borrowShares, uint256 rawCollateral) internal {
        if (borrowShares == 0 || rawCollateral == 0) {
            $.heap.remove(borrower);
            return;
        }
        $.heap.upsert(borrower, borrowShares * KEY_SCALE / rawCollateral);
    }

    function setSliceFloor(State storage $, uint128 floor) internal {
        $.sliceFloorAssets = floor;
    }

    /// @notice Set the minimum loan assets one deleverage call may cancel (anti dust-spam).
    function setFallbackMinRequest(State storage $, uint128 minRequest) internal {
        $.fallbackMinRequest = minRequest;
    }

    /// @notice Set `borrower`'s personal target post-cut LTV (WAD). 0 clears it; must be < WAD.
    function setWatermark(State storage $, address borrower, uint256 ltv) internal {
        if (ltv >= WAD) revert WatermarkOutOfRange();
        $.watermarkLtv[borrower] = ltv;
        emit WatermarkSet(borrower, ltv);
    }

    function watermarkOf(State storage $, address borrower) internal view returns (uint256) {
        return $.watermarkLtv[borrower];
    }

    function size(State storage $) internal view returns (uint256) {
        return $.heap.size();
    }

    /// @notice Riskiest borrower (heap root), or address(0) when the queue is empty.
    function peekRoot(State storage $) internal view returns (address) {
        if ($.heap.size() == 0) return address(0);
        (address top,) = $.heap.peek();
        return top;
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

    /// @notice Maximum loan-asset slice the policy allows for one cut against `borrower`:
    ///         max(heap slice, watermark slice). Zero means ineligible: neither the root nor a
    ///         watermarked borrower, or it has no debt/collateral.
    function allowedSlice(State storage $, address borrower, MarketView memory marketView)
        internal
        view
        returns (uint256)
    {
        uint256 hs = heapSlice($, borrower, marketView);
        uint256 ws = watermarkSlice($, borrower, marketView);
        return hs >= ws ? hs : ws;
    }

    /// @notice Heap-driven slice: brings the root's key down to the runner-up's. Non-zero only for the
    ///         root. type(uint256).max for a lone borrower (no runner-up to bound against; the caller
    ///         caps it to the remaining exit).
    function heapSlice(State storage $, address borrower, MarketView memory marketView)
        internal
        view
        returns (uint256)
    {
        if ($.heap.size() == 0) return 0;
        (address top, uint256 topKey) = $.heap.peek();
        if (top != borrower) return 0;
        uint256 childMaxKey = $.heap.rootChildMaxKey();
        if (childMaxKey == 0) return type(uint256).max;
        uint256 slice = computeSlice(marketView, topKey, childMaxKey);
        // Heap-safety overshoot pushes the post-cut root key strictly below the runner-up,
        // immune to integer rounding in `LidoBlue.deleverage`'s `collateralSeized = mulDivDown(...)`.
        uint256 debt = marketView.borrowShares.toAssetsDown(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        uint256 overshoot = debt / 100;
        if (overshoot < $.sliceFloorAssets) overshoot = $.sliceFloorAssets;
        return slice + overshoot;
    }

    /// @notice Watermark-driven slice: brings `borrower`'s LTV down to its target. Zero when no
    ///         watermark, no debt/collateral, or the current LTV is already at/under the target.
    function watermarkSlice(State storage $, address borrower, MarketView memory marketView)
        internal
        view
        returns (uint256)
    {
        uint256 watermark = $.watermarkLtv[borrower];
        if (watermark == 0 || marketView.borrowShares == 0 || marketView.rawCollateral == 0) return 0;
        uint256 debt = marketView.borrowShares.toAssetsUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        uint256 colValue = marketView.rawCollateral.mulDivDown(marketView.price, ORACLE_PRICE_SCALE);
        return computeWatermarkSlice(debt, colValue, watermark);
    }

    // --- slice math (pure; fuzz-tested in test/scenario/DeleverageQueueSlice.t.sol) ---

    /// @notice Closed-form solve: loan-asset slice that brings `topKey` down to `targetKey`.
    /// @dev    Requiring the post-cut key to equal `targetKey` (both debt and collateral shrink with
    ///         the cut) gives
    ///           slice = (topKey − targetKey) × rawCollateral
    ///                 / [ totalBorrowShares×KEY_SCALE/totalBorrowAssets − targetKey×ORACLE_PRICE_SCALE/price ]
    ///         Returns 0 when the target is not below the top, when any market input is zero, or
    ///         when the denominator is non-positive (linear system inverts in extreme regimes).
    ///         Heap-safety overshoot and the floor are applied by the caller (`heapSlice`).
    function computeSlice(MarketView memory marketView, uint256 topKey, uint256 targetKey)
        internal
        pure
        returns (uint256)
    {
        if (targetKey >= topKey) return 0;
        if (marketView.rawCollateral == 0) return 0;
        if (marketView.totalBorrowShares == 0 || marketView.totalBorrowAssets == 0) return 0;
        if (marketView.price == 0) return 0;

        uint256 keyGapWeighted = (topKey - targetKey) * marketView.rawCollateral;
        uint256 sharesPerAssetTerm = (marketView.totalBorrowShares * KEY_SCALE) / marketView.totalBorrowAssets;
        uint256 targetPriceTerm = (targetKey * ORACLE_PRICE_SCALE) / marketView.price;
        if (sharesPerAssetTerm <= targetPriceTerm) return 0;

        return keyGapWeighted / (sharesPerAssetTerm - targetPriceTerm);
    }

    /// @notice Loan-asset slice that brings a borrower's LTV down to `watermarkLtv` (WAD), cutting at
    ///         the oracle rate so equal-value collateral leaves with the debt.
    /// @param debt            Borrower debt in loan-asset units.
    /// @param collateralValue Borrower collateral value in loan-asset units (rawCollateral × price / SCALE).
    /// @dev c = (debt × WAD − watermarkLtv × collateralValue) / (WAD − watermarkLtv); 0 when already at
    ///      or below the target, or when `watermarkLtv >= WAD`.
    function computeWatermarkSlice(uint256 debt, uint256 collateralValue, uint256 watermarkLtv)
        internal
        pure
        returns (uint256)
    {
        if (watermarkLtv >= WAD) return 0;
        uint256 debtScaled = debt * WAD;
        uint256 targetTerm = watermarkLtv * collateralValue;
        if (debtScaled <= targetTerm) return 0;
        return (debtScaled - targetTerm) / (WAD - watermarkLtv);
    }
}
