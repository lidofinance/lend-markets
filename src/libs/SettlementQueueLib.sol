// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MaxHeapLib} from "./MaxHeapLib.sol";
import {WAD, BPS} from "./Constants.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {MarketView, PositionView, SettlementConfig, SettlementSlice} from "../types/SettlementTypes.sol";

/// @title SettlementQueueLib
/// @author Lido Lending contributors.
/// @notice Risk-ordered queue of borrowers for the settle waterfall, with per-borrower settlement-LTV
///         targets and the slice-sizing policy. Wraps a max-heap keyed by
///         borrowShares * KEY_SCALE / rawCollateral, so the root is the highest-LTV position: a
///         solvent root means no tracked position is bad debt, which is what makes the bad-debt gate
///         an O(1) root check.
/// @dev Self-contained module: the caller embeds `State`, forwards mutations, and supplies a
///      `MarketView` (live core/oracle snapshot) for the slice math. The lib makes no external calls;
///      the slice arithmetic (`sliceToLtv`) is pure and fuzz-testable.
library SettlementQueueLib {
    using MaxHeapLib for MaxHeapLib.Heap;
    using SharesMathLib for uint256;

    // ---
    // CONSTANTS
    // ---

    /// @dev Heap key scale: key = borrowShares * KEY_SCALE / rawCollateral.
    uint256 internal constant KEY_SCALE = WAD;

    // ---
    // ERRORS
    // ---

    /// @notice A borrower's personal settlement LTV is not strictly below WAD (100%).
    error SettlementLtvOutOfRange();

    /// @notice A slice-policy percentage (`sliceFloorBps` or `ltvStepBps`) exceeds 100% (`BPS`).
    error SettlementConfigOutOfRange();

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a borrower sets their personal settlement LTV.
    event SettlementLtvSet(address indexed borrower, uint256 ltv);

    /// @notice Emitted when the settlement config is set.
    event SettlementConfigSet(SettlementConfig config);

    // ---
    // TYPES
    // ---

    /// @notice Embedded settlement-queue state: the risk-ordered heap, the settlement config, and per-borrower
    ///         settlement-LTV targets.
    /// @param heap Max-heap of borrowers keyed by `_riskKey` (borrowShares * KEY_SCALE / collateral), so the
    ///        root is the highest-LTV position.
    /// @param config Slice-sizing policy applied to the queue root.
    /// @param settlementLtv Per-borrower target post-cut LTV (WAD), 0 = unset.
    struct State {
        MaxHeapLib.Heap heap;
        SettlementConfig config;
        mapping(address borrower => uint256) settlementLtv;
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

    /// @notice Set the slice-sizing policy applied to the queue root. Reverts if `sliceFloorBps` or
    ///         `ltvStepBps` exceeds 100% (`BPS`).
    function setSettlementConfig(State storage $, SettlementConfig memory config) internal {
        if (config.sliceFloorBps > BPS || config.ltvStepBps > BPS) revert SettlementConfigOutOfRange();
        $.config = config;
        emit SettlementConfigSet(config);
    }

    /// @notice Set `borrower`'s personal target post-cut LTV (WAD). A positive target can make a non-root position
    ///         eligible for settlement; 0 clears it and every nonzero value must be below WAD.
    function setSettlementLtv(State storage $, address borrower, uint256 ltv) internal {
        if (ltv >= WAD) revert SettlementLtvOutOfRange();
        $.settlementLtv[borrower] = ltv;
        emit SettlementLtvSet(borrower, ltv);
    }

    // ---
    // VIEWS
    // ---

    /// @notice The borrower's personal target post-cut LTV (WAD), 0 when unset.
    function settlementLtvOf(State storage $, address borrower) internal view returns (uint256) {
        return $.settlementLtv[borrower];
    }

    /// @notice Number of borrowers currently tracked in the queue.
    function size(State storage $) internal view returns (uint256) {
        return $.heap.size();
    }

    /// @notice Riskiest borrower (heap root), or address(0) when the queue is empty.
    function peekRoot(State storage $) internal view returns (address riskiestBorrower) {
        if ($.heap.size() == 0) return address(0);
        (riskiestBorrower,) = $.heap.peek();
    }

    /// @notice A window of the queue in heap-array order (approximate, not a strict sort): up to `maxCount`
    ///         borrowers starting at `offset`. Past the end the arrays come back empty, so callers can page
    ///         until they do.
    function settlementBorrowers(State storage $, uint256 offset, uint256 maxCount)
        internal
        view
        returns (address[] memory borrowers, uint256[] memory keys)
    {
        uint256 n = $.heap.size();
        if (offset >= n) return (new address[](0), new uint256[](0));
        uint256 remaining = n - offset;
        uint256 count = remaining < maxCount ? remaining : maxCount;
        borrowers = new address[](count);
        keys = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            (borrowers[i], keys[i]) = $.heap.nodeAt(offset + i);
        }
    }

    // ---
    // SLICE SIZING
    // ---

    /// @notice Effective personal and queue-root slices for `borrower`, independently debt-capped and dust-promoted.
    ///         The queue-root slice is prospective: the caller decides whether `borrower` is currently the root.
    function allowedSliceAssets(
        State storage $,
        MarketView memory marketView,
        address borrower,
        PositionView memory position
    ) internal view returns (uint256 personalSliceAssets, uint256 queueRootSliceAssets) {
        (uint256 debtAssets, uint256 collateralValue) = _positionValues(marketView, position);
        if (debtAssets == 0 || collateralValue == 0) return (0, 0);

        personalSliceAssets = Math.min(_settlementLtvSlice($, borrower, debtAssets, collateralValue), debtAssets);
        queueRootSliceAssets = Math.min(_policySlice($.config, debtAssets, collateralValue), debtAssets);

        if (personalSliceAssets != 0 && _strandsDust($, marketView, position, personalSliceAssets)) {
            personalSliceAssets = debtAssets;
        }
        if (queueRootSliceAssets != 0 && _strandsDust($, marketView, position, queueRootSliceAssets)) {
            queueRootSliceAssets = debtAssets;
        }
    }

    /// @notice Converts a loan-asset slice into the two anchors a core `settle` accepts: the caller passes one and
    ///         0 for the other. `supplyShares` settles supply-anchored, `borrowShares` borrow-anchored.
    ///         `remainingBorrowShares` is the debt left after the cut, 0 for a full close.
    /// @dev A full close (`remainingBorrowShares == 0`) must use `borrowShares`: it is the whole debt and closes
    ///      the position to exactly zero. `supplyShares` there is the close's supply cost — supply-anchoring with
    ///      it rounds the derived debt up past the position and reverts `SETTLEMENT_EXCEEDS_DEBT`.
    /// @param position The borrower's position to cut.
    /// @param sliceAssets Policy-bounded debt to cancel, in loan assets.
    function settlementSlice(MarketView memory marketView, PositionView memory position, uint256 sliceAssets)
        internal
        pure
        returns (SettlementSlice memory slice)
    {
        if (sliceAssets == 0 || position.borrowShares == 0) return slice;

        (uint256 debtAssets,) = _positionValues(marketView, position);
        uint256 canceledShares = sliceAssets.toSharesUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);

        // Slice spans (or rounds up to) the whole debt: a full close. supplyShares is the supply cost of closing
        // it (what a borrow-anchored close burns), computed the core's way. The settle itself uses borrowShares.
        if (sliceAssets == debtAssets || canceledShares >= position.borrowShares) {
            slice.supplyShares = uint256(position.borrowShares)
                .toAssetsUp(marketView.totalBorrowAssets, marketView.totalBorrowShares)
                .toSharesUp(marketView.totalSupplyAssets, marketView.totalSupplyShares);
            slice.borrowShares = position.borrowShares;
            return slice;
        }

        // Partial cut: both anchors for the slice. supplyShares burns supply worth the slice (down-rounded),
        // borrowShares cancels the slice's debt (up-rounded), remaining is the debt left behind.
        slice.borrowShares = canceledShares;
        slice.supplyShares = sliceAssets.toSharesDown(marketView.totalSupplyAssets, marketView.totalSupplyShares);
        slice.remainingBorrowShares = uint256(position.borrowShares) - canceledShares;
    }

    /// @notice Settlement-LTV slice: brings `borrower`'s LTV down to its personal target. Zero
    ///         when no settlement LTV is set, no debt/collateral, or the current LTV is already at/under the target.
    function settlementLtvSlice(
        State storage $,
        MarketView memory marketView,
        address borrower,
        PositionView memory position
    ) internal view returns (uint256) {
        (uint256 debtAssets, uint256 collateralValue) = _positionValues(marketView, position);
        return _settlementLtvSlice($, borrower, debtAssets, collateralValue);
    }

    // ---
    // PURE MATH
    // ---

    /// @notice Loan-asset slice that brings a position's LTV down to `targetLtv` (WAD), using oracle-value math
    ///         before the core rounds collateral to token units. Backs both the settlement-LTV slice and the root
    ///         LTV-step rule.
    /// @param debtAssets      Borrower debt in loan-asset units.
    /// @param collateralValue Borrower collateral value in loan-asset units (rawCollateral × price / SCALE).
    /// @dev c = (debtAssets × WAD − targetLtv × collateralValue) / (WAD − targetLtv); 0 when already at or below
    ///      the target, or when `targetLtv >= WAD`.
    function sliceToLtv(uint256 debtAssets, uint256 collateralValue, uint256 targetLtv)
        internal
        pure
        returns (uint256)
    {
        if (targetLtv >= WAD) return 0;
        uint256 debtScaled = debtAssets * WAD;
        uint256 targetTerm = targetLtv * collateralValue;
        if (debtScaled <= targetTerm) return 0;
        return (debtScaled - targetTerm) / (WAD - targetLtv);
    }

    // ---
    // INTERNAL HELPERS
    // ---

    /// @dev True when cutting `sliceAssets` would leave the borrower's collateral below the full-close floor.
    function _strandsDust(
        State storage $,
        MarketView memory marketView,
        PositionView memory position,
        uint256 sliceAssets
    ) private view returns (bool) {
        if (marketView.price == 0) return false;
        uint256 seizedCollateral = Math.mulDiv(sliceAssets, ORACLE_PRICE_SCALE, marketView.price);
        uint256 remainingCollateral = Math.saturatingSub(position.collateral, seizedCollateral);
        return remainingCollateral < $.config.fullCutBelowCollateral;
    }

    /// @dev Root slice: the largest of the three slice rules — `sliceFloorBps` of the debt, `sliceFloorAssets`,
    ///      and the slice that lowers the LTV by `ltvStepBps`. Caller guarantees `debtAssets > 0` and
    ///      `collateralValue > 0` (the `slice` entry gate), so the LTV division here is safe.
    function _policySlice(SettlementConfig storage config, uint256 debtAssets, uint256 collateralValue)
        private
        view
        returns (uint256)
    {
        uint256 byDebtFractionAssets = Math.mulDiv(debtAssets, config.sliceFloorBps, BPS);

        uint256 byLtvReductionAssets;
        if (config.ltvStepBps != 0) {
            uint256 currentLtv = Math.mulDiv(debtAssets, WAD, collateralValue);
            uint256 ltvReduction = Math.mulDiv(config.ltvStepBps, WAD, BPS);
            byLtvReductionAssets = sliceToLtv(debtAssets, collateralValue, Math.saturatingSub(currentLtv, ltvReduction));
        }

        return Math.max(config.sliceFloorAssets, Math.max(byDebtFractionAssets, byLtvReductionAssets));
    }

    /// @dev Slice that lowers the borrower to its personal settlement LTV. Zero when no settlement LTV is set or
    ///      there is no debt/collateral to cut against.
    function _settlementLtvSlice(State storage $, address borrower, uint256 debtAssets, uint256 collateralValue)
        private
        view
        returns (uint256)
    {
        uint256 ltv = $.settlementLtv[borrower];
        if (ltv == 0 || debtAssets == 0 || collateralValue == 0) return 0;
        return sliceToLtv(debtAssets, collateralValue, ltv);
    }

    /// @dev Resolve a position into loan-asset units: `debtAssets` from borrow shares at the live borrow index,
    ///      and `collateralValue` as rawCollateral priced at the oracle rate.
    function _positionValues(MarketView memory marketView, PositionView memory position)
        private
        pure
        returns (uint256 debtAssets, uint256 collateralValue)
    {
        if (position.borrowShares != 0) {
            debtAssets = position.borrowShares.toAssetsUp(marketView.totalBorrowAssets, marketView.totalBorrowShares);
        }
        collateralValue = Math.mulDiv(position.collateral, marketView.price, ORACLE_PRICE_SCALE);
    }

    /// @dev Heap ordering key: borrowShares * KEY_SCALE / collateral, monotonic in LTV so the heap root is the
    ///      riskiest position. Caller guarantees non-zero collateral.
    function _riskKey(PositionView memory position) private pure returns (uint256) {
        return Math.mulDiv(position.borrowShares, KEY_SCALE, position.collateral);
    }
}
