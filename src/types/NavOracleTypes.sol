// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Check parameters of one NAV oracle market that the configurator can change. The two intervals come
///         last so that they share one storage slot.
/// @param yearlyGrowthRate Yearly rate the expected price grows at from the reference price, WAD.
/// @param growthTolerance Fraction above the expected price the upper price bound sits at, WAD.
/// @param maxFallPerInterval Fraction of the checkpoint price the floor falls by per elapsed interval, WAD.
/// @param maxDrawdown Fraction below the expected price the source price may sit before `price()` reverts, WAD.
/// @param maxOvershoot Fraction above the expected price the source price may sit before `price()` reverts, WAD.
/// @param maxLoanTokenDeviation Fraction around 1 USD inside which the loan token's feed answer is ignored, WAD.
/// @param minPriceRatio Lowest allowed ratio between the lowest and the highest price the rules can return
///        across one reference price move, `(1 − maxDrawdown) × (1 − growthTolerance) / (1 +
///        protectedGrowthTolerance)`, before the interest allowance, WAD.
/// @param maxBorrowRate Highest borrow rate per second the market's interest rate model can charge, WAD. Debt
///        accrues at most this much while the floor holds the price above the source.
/// @param fallInterval Seconds per floor step, and the least time between two checkpoints.
/// @param referenceInterval Seconds after a reference price move before anyone may move it again.
struct NavOracleCheckParams {
    uint256 yearlyGrowthRate;
    uint256 growthTolerance;
    uint256 maxFallPerInterval;
    uint256 maxDrawdown;
    uint256 maxOvershoot;
    uint256 maxLoanTokenDeviation;
    uint256 minPriceRatio;
    uint256 maxBorrowRate;
    uint40 fallInterval;
    uint40 referenceInterval;
}
