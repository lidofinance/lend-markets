// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

/// @title DeleverageSliceLib
/// @notice Pure slice-sizing math for the deleverage waterfall.
/// @dev Shared by both selection rules: the queue passes the runner-up key as `targetKey`,
///      the watermark passes `topKey × watermarkPct`. The math is identical — size a cut so the
///      top borrower's key drops to `targetKey`, accounting for the collateral that leaves with
///      the cut. Keeping this pure makes the linear-algebra part unit- and fuzz-testable in
///      isolation, which is where the tricky edge cases (denominator inversion, rounding) live.
library DeleverageSliceLib {
    /// @dev Heap key scale: key = borrowShares × KEY_SCALE / rawCollateral.
    uint256 internal constant KEY_SCALE = 1e18;
    /// @dev Morpho oracle price scale (collateral price quoted in loan asset, 1e36).
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

    /// @notice Loan-asset slice that brings `topKey` down to `targetKey`.
    /// @param topKey            Current key of the borrower being cut.
    /// @param targetKey         Key the borrower should drop to (runner-up key, or watermark target).
    /// @param topCollateral     Borrower's raw collateral.
    /// @param totalBorrowShares Market total borrow shares.
    /// @param totalBorrowAssets Market total borrow assets.
    /// @param collateralPrice   Collateral price in loan asset, scaled by ORACLE_PRICE_SCALE.
    /// @param sliceFloor        Minimum slice; also the fallback on any degenerate input.
    /// @return The slice size in loan-asset units, at least `sliceFloor`.
    /// @dev Derived by requiring the post-cut key to equal `targetKey`. Both debt and collateral
    ///      shrink as the cut applies, so the denominator combines the per-share debt term and the
    ///      target-key price term:
    ///
    ///        slice = (topKey - targetKey) × topCollateral
    ///              / [ totalBorrowShares×KEY_SCALE/totalBorrowAssets
    ///                  - targetKey×ORACLE_PRICE_SCALE/collateralPrice ]
    ///
    ///      Returns `sliceFloor` when the target is not below the top, when any market input is
    ///      zero, or when the denominator is non-positive (linear system inverts in extreme regimes).
    function computeSlice(
        uint256 topKey,
        uint256 targetKey,
        uint256 topCollateral,
        uint256 totalBorrowShares,
        uint256 totalBorrowAssets,
        uint256 collateralPrice,
        uint256 sliceFloor
    ) internal pure returns (uint256) {
        if (targetKey >= topKey) return sliceFloor;
        if (topCollateral == 0) return sliceFloor;
        if (totalBorrowShares == 0 || totalBorrowAssets == 0) return sliceFloor;
        if (collateralPrice == 0) return sliceFloor;

        uint256 keyGapWeighted = (topKey - targetKey) * topCollateral;
        uint256 sharesPerAssetTerm = (totalBorrowShares * KEY_SCALE) / totalBorrowAssets;
        uint256 targetPriceTerm = (targetKey * ORACLE_PRICE_SCALE) / collateralPrice;
        if (sharesPerAssetTerm <= targetPriceTerm) return sliceFloor;

        uint256 slice = keyGapWeighted / (sharesPerAssetTerm - targetPriceTerm);
        return slice > sliceFloor ? slice : sliceFloor;
    }
}
