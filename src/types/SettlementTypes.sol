// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

/// @notice Shared value types of the settlement subsystem. Defined at file scope (not in a library) so the
///         controller, `SettlementQueueLib`, and the vault can use them as bare `MarketView` / `PositionView` /
///         `SlicePolicy` without depending on each other.

/// @notice Live core/oracle snapshot of the market, built by the controller from core reads and consumed by
///         the slice, bad-debt, and active-health math alongside a borrower `Position`. Not carried in any
///         hook payload.
/// @param totalBorrowAssets Market total borrow assets, pending interest simulated.
/// @param totalBorrowShares Market total borrow shares.
/// @param price Collateral price in the loan asset, scaled by ORACLE_PRICE_SCALE.
/// @param lltv Market liquidation loan-to-value, in WAD.
struct MarketView {
    uint256 totalBorrowAssets;
    uint256 totalBorrowShares;
    uint256 price;
    uint256 lltv;
}

/// @notice Live core snapshot of a borrower position for the slice, bad-debt, and active-health math, widened
///         to uint256. Built by the controller from the core `Position` (which packs these as uint128).
/// @param borrowShares Borrow shares of the position.
/// @param collateral Raw collateral of the position, in collateral units.
struct PositionView {
    uint256 borrowShares;
    uint256 collateral;
}

/// @notice Slice policy knobs. They tune the same cut and move together, so they are set together
///         (`setSlicePolicy`). The uint96 amounts are policy bounds, not accounting: for a loan or
///         collateral token whose plausible amounts exceed uint96 (~7.9e28 base units) the configurable
///         floors saturate low — the policy weakens but nothing reverts or loses accounting.
/// @param sliceFloorBps Debt-fraction term of the root cut: one allowance is `debt * sliceFloorBps / BPS`.
/// @param sliceFloorAssets Absolute term of the root cut: one allowance is this many loan assets.
/// @param fallbackMinRequest Per-iteration cut floor for the vault's fallback exit (anti dust-spam, 0 = no floor).
/// @param fullCutBelowCollateral Sweep floor in collateral units: when a cut would leave the borrower's
///        remaining collateral below this, the slice lifts to the full debt so the position closes in one
///        cut, leaving no dust tail. 0 disables the sweep.
/// @param ltvStepBps LTV-step term of the root cut: one allowance is the cut that lowers the root's LTV by
///        `ltvStepBps / BPS`. The root cut is the largest of the three terms (debt-fraction, absolute, LTV-step).
struct SlicePolicy {
    uint16 sliceFloorBps;
    uint96 sliceFloorAssets;
    uint96 fallbackMinRequest;
    uint96 fullCutBelowCollateral;
    uint16 ltvStepBps;
}
