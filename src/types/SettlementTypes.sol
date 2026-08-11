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

/// @notice One settlement cut expressed as the executable borrow-share handle plus the supply it burns. For a
///         nonzero cut, `remainingBorrowShares == 0` identifies a full close; an unavailable cut is represented by
///         an all-zero struct. Every field describes the same cut, so a budgeted quote stays self-consistent.
/// @param supplyShares Core supply shares the cut burns, derived from `borrowShares` the way the core derives it.
///        Exact for the market state it was read at — interest accrued before execution raises it.
/// @param borrowShares Borrow shares canceled by the cut.
/// @param remainingBorrowShares Borrow shares left after a nonzero cut, 0 for a full close.
struct SettlementSlice {
    uint256 supplyShares;
    uint256 borrowShares;
    uint256 remainingBorrowShares;
}

/// @notice The two independently sized policy candidates for a borrower at the current position state, each already
///         sized against the requesting caller's supply budget. Both remain subject to the global pause and
///         bad-debt gates.
/// @param personal Cut allowed by the borrower's personal settlement-LTV target, independent of queue membership,
///        market liquidity, and the settling lender's illiquid supply tail.
/// @param queueRoot Prospective queue-policy allowance. Execution requires the borrower to be the live queue root;
///        any executed amount above `personal` must fit the settling lender's live illiquid supply tail.
struct SettlementQuote {
    SettlementSlice personal;
    SettlementSlice queueRoot;
}

/// @notice Settlement slice policy, set together via `setSettlementConfig`. The knobs tune the settlement slice
///         cut. The uint96 amounts are policy bounds, not accounting: for a loan or collateral token whose
///         plausible amounts exceed uint96 (~7.9e28 base units) the configurable floors cannot be set high
///         enough to match — the policy weakens but nothing reverts or loses accounting.
/// @param sliceFloorBps Debt-fraction term of the root cut: one allowance is `debt * sliceFloorBps / BPS`.
/// @param sliceFloorAssets Absolute term of the root cut: one allowance is this many loan assets.
/// @param fullCutBelowCollateral Queue-root sweep floor in collateral units: when the root-policy cut would leave
///        the borrower's remaining collateral below this, the policy requests a full-debt slice. The vault closes
///        the position in one cut only when the exiting lender's settleable budget covers it; otherwise it applies
///        a budgeted partial. The personal settlement-LTV asset cut is never swept, though its borrow-share
///        conversion may still round to a full close. 0 disables the sweep.
/// @param ltvStepBps LTV-step term of the root cut: one allowance is the cut that lowers the root's LTV by
///        `ltvStepBps / BPS`. The root cut is the largest of the three terms (debt-fraction, absolute, LTV-step).
struct SettlementConfig {
    uint16 sliceFloorBps;
    uint96 sliceFloorAssets;
    uint96 fullCutBelowCollateral;
    uint16 ltvStepBps;
}
