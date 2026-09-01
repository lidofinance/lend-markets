// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Shared value types of the settlement subsystem. Defined at file scope (not in a library) so the
///         controller and `SettlementQueueLib` can use them as bare `MarketView` / `PositionView` /
///         `SettlementConfig` without depending on each other.

// ---
// TYPES
// ---

/// @notice Live core/oracle snapshot of the market, built by the controller from core reads and consumed by
///         the slice, bad-debt, and active-health math alongside a borrower `PositionView`. Not carried in any
///         hook payload.
/// @param totalSupplyAssets Market total supply assets, pending interest simulated.
/// @param totalSupplyShares Market total supply shares.
/// @param totalBorrowAssets Market total borrow assets, pending interest simulated.
/// @param totalBorrowShares Market total borrow shares.
/// @param price Collateral price in the loan asset, scaled by ORACLE_PRICE_SCALE.
/// @param lltv Market liquidation loan-to-value, in WAD.
struct MarketView {
    uint256 totalSupplyAssets;
    uint256 totalSupplyShares;
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

/// @notice One settlement cut. All three fields describe the same cut, so a budgeted quote stays consistent.
///         A cut that cannot execute has zero `borrowShares` and `supplyShares`.
/// @param supplyShares Core supply shares the cut burns, computed the way the core computes it. Exact for the
///        market state it was read at; interest accrued before execution raises it.
/// @param borrowShares Borrow shares canceled by the cut.
/// @param remainingBorrowShares Borrow shares left after the cut: 0 for a full close or a debtless position,
///        the borrower's untouched debt for a cut that cannot execute.
struct SettlementSlice {
    uint256 supplyShares;
    uint256 borrowShares;
    uint256 remainingBorrowShares;
}

/// @notice The two cuts a borrower may be eligible for, each already shrunk to the requesting caller's supply
///         budget. Both are still subject to the pause and bad-debt gates at execution.
/// @param personal Cut allowed by the borrower's personal settlement-LTV target, independent of queue membership,
///        market liquidity, and the settling lender's illiquid supply tail.
/// @param queueRoot Cut allowed by the queue-root policy. Execution requires the borrower to be the live queue
///        root; any executed amount above `personal` must fit the settling lender's illiquid supply tail.
struct SettlementQuote {
    SettlementSlice personal;
    SettlementSlice queueRoot;
}

/// @notice Sizing policy for the queue-root settlement cut, set together via `setSettlementConfig`. The queue
///         root did not opt into settlement, so this policy decides how much of its debt one lender exit may
///         settle: the largest of the three allowances below, capped at the debt. The uint96 amounts are policy
///         bounds, not accounting: for a loan or collateral token whose plausible amounts exceed uint96
///         (~7.9e28 base units) the configurable floors cannot be set high enough to match; the policy weakens
///         but nothing reverts or loses accounting.
/// @param sliceFloorBps Debt-fraction term of the root cut: one allowance is `debt * sliceFloorBps / BPS`.
/// @param sliceFloorAssets Absolute term of the root cut: one allowance is this many loan assets.
/// @param fullCutBelowCollateral Queue-root sweep floor in collateral units: when a positive root-policy cut
///        would leave the borrower's remaining collateral below this, the policy requests the full debt
///        instead. Applies only to the queue-root cut, never the personal settlement-LTV cut. 0 disables the
///        sweep.
/// @param ltvStepBps LTV-step term of the root cut: one allowance is the cut that lowers the root's LTV by
///        `ltvStepBps / BPS`. The root cut is the largest of the three terms (debt-fraction, absolute, LTV-step).
struct SettlementConfig {
    uint16 sliceFloorBps;
    uint96 sliceFloorAssets;
    uint96 fullCutBelowCollateral;
    uint16 ltvStepBps;
}
