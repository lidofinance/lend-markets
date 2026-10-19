// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {NavOracleCheckParams} from "../../src/types/NavOracleTypes.sol";

/// @notice What a NAV oracle stores, as the spec names it. The model derives every price from these values and the
///         time, never from the oracle's own computed outputs.
struct NavOracleState {
    uint256 referencePrice;
    uint256 referencePriceSetAt;
    uint256 checkpointPrice;
    uint256 checkpointAt;
    uint256 protectedGrowthTolerance;
    NavOracleCheckParams params;
}

/// @notice The NAV oracle's formulas from the specification, WAD fixed point, every product rounded down. The unit,
///         invariant and scenario suites share this one copy so their expectations cannot drift apart.
library NavOracleModel {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    /// @dev 16% a year per second, the borrow rate ceiling the working defaults are sized for.
    uint256 internal constant MAX_BORROW_RATE = 0.16e18 / uint256(365 days);

    /// @dev Working defaults of the calibration for a market at 98% LLTV whose interest rate model charges at most
    ///      16% a year, with the asset's yearly growth rate.
    function workingDefaults(uint256 yearlyGrowthRate) internal pure returns (NavOracleCheckParams memory) {
        return NavOracleCheckParams({
            yearlyGrowthRate: yearlyGrowthRate,
            growthTolerance: 0.002e18,
            maxFallPerInterval: 0.0025e18,
            maxDrawdown: 0.008e18,
            maxOvershoot: 0.03e18,
            maxLoanTokenDeviation: 0.005e18,
            minPriceRatio: minPriceRatioAt(0.98e18),
            maxBorrowRate: MAX_BORROW_RATE,
            fallInterval: 1 days,
            referenceInterval: 90 days
        });
    }

    /// @dev The stored state through the oracle's getters.
    function read(NavOracleBase oracle) internal view returns (NavOracleState memory s) {
        s.referencePrice = oracle.referencePrice();
        s.referencePriceSetAt = oracle.referencePriceSetAt();
        s.checkpointPrice = oracle.checkpointPrice();
        s.checkpointAt = oracle.checkpointAt();
        s.protectedGrowthTolerance = oracle.protectedGrowthTolerance();
        s.params = oracle.checkParams();
    }

    /// @dev LLTV × LIF rounded up, with LIF = 1 / (1 − 0.3 × (1 − LLTV)) taken as an exact fraction.
    function minPriceRatioAt(uint256 lltv) internal pure returns (uint256) {
        uint256 lifDenominator = WAD - Math.mulDiv(0.3e18, WAD - lltv, WAD);
        return Math.mulDiv(lltv, WAD, lifDenominator, Math.Rounding.Ceil);
    }

    /// @dev referencePrice × (1 + yearlyGrowthRate × elapsed / 365 days).
    function expectedPrice(NavOracleState memory s, uint256 time) internal pure returns (uint256) {
        uint256 growth = Math.mulDiv(s.params.yearlyGrowthRate, time - s.referencePriceSetAt, YEAR);
        return Math.mulDiv(s.referencePrice, WAD + growth, WAD);
    }

    /// @dev expectedPrice × (1 + growthTolerance).
    function upperBound(NavOracleState memory s, uint256 time) internal pure returns (uint256) {
        return Math.mulDiv(expectedPrice(s, time), WAD + s.params.growthTolerance, WAD);
    }

    /// @dev expectedPrice × (1 − maxDrawdown).
    function bandLow(NavOracleState memory s, uint256 time) internal pure returns (uint256) {
        return Math.mulDiv(expectedPrice(s, time), WAD - s.params.maxDrawdown, WAD);
    }

    /// @dev expectedPrice × (1 + maxOvershoot).
    function bandHigh(NavOracleState memory s, uint256 time) internal pure returns (uint256) {
        return Math.mulDiv(expectedPrice(s, time), WAD + s.params.maxOvershoot, WAD);
    }

    /// @dev checkpointPrice × (1 − n × maxFallPerInterval) for n whole intervals, zero once the steps reach one.
    function floor(NavOracleState memory s, uint256 time) internal pure returns (uint256) {
        uint256 fall = (time - s.checkpointAt) / s.params.fallInterval * s.params.maxFallPerInterval;
        if (fall >= WAD) return 0;
        return Math.mulDiv(s.checkpointPrice, WAD - fall, WAD);
    }

    function inBand(NavOracleState memory s, uint256 sourcePrice, uint256 time) internal pure returns (bool) {
        return sourcePrice >= bandLow(s, time) && sourcePrice <= bandHigh(s, time);
    }

    /// @dev min(upperBound, max(sourcePrice, floor)), the value `price()` returns once no revert applies.
    function boundedPrice(NavOracleState memory s, uint256 sourcePrice, uint256 time) internal pure returns (uint256) {
        return Math.min(upperBound(s, time), Math.max(sourcePrice, floor(s, time)));
    }

    /// @dev (1 − maxDrawdown)(1 − growthTolerance) / (1 + protectedTolerance), each step rounded down.
    function corridorRatio(uint256 maxDrawdown, uint256 growthTolerance, uint256 protectedTolerance)
        internal
        pure
        returns (uint256)
    {
        uint256 lowest = Math.mulDiv(WAD - maxDrawdown, WAD - growthTolerance, WAD);
        return Math.mulDiv(lowest, WAD, WAD + protectedTolerance);
    }

    /// @dev ceil((maxDrawdown + growthTolerance) / maxFallPerInterval) × fallInterval: the longest the floor can hold
    ///      the price above a source at the band's lower edge.
    function corridorCrossing(NavOracleCheckParams memory p) internal pure returns (uint256) {
        return Math.ceilDiv(p.maxDrawdown + p.growthTolerance, p.maxFallPerInterval) * p.fallInterval;
    }

    /// @dev max(fallInterval, corridorCrossing).
    function leastReferenceInterval(NavOracleCheckParams memory p) internal pure returns (uint256) {
        return Math.max(p.fallInterval, corridorCrossing(p));
    }

    /// @dev The interest the core accrues on one unit of debt over the corridor crossing at `maxBorrowRate`: its
    ///      three-term Taylor expansion of `e^(rate × time) − 1`, each term rounded down.
    function heldInterest(NavOracleCheckParams memory p) internal pure returns (uint256) {
        uint256 first = p.maxBorrowRate * corridorCrossing(p);
        uint256 second = first * first / (2 * WAD);
        uint256 third = second * first / (3 * WAD);
        return first + second + third;
    }

    /// @dev minPriceRatio × (1 + heldInterest), rounded up: the corridor ratio the validator requires.
    function leastPriceRatio(NavOracleCheckParams memory p) internal pure returns (uint256) {
        return Math.mulDiv(p.minPriceRatio, WAD + heldInterest(p), WAD, Math.Rounding.Ceil);
    }

    /// @dev The answer is off peg when it sits outside 1 USD ± maxLoanTokenDeviation, edges inclusive in the peg.
    function isOffPeg(int256 answer, uint256 oneUsd, uint256 maxLoanTokenDeviation) internal pure returns (bool) {
        if (answer <= 0) return false;
        uint256 allowed = Math.mulDiv(maxLoanTokenDeviation, oneUsd, WAD);
        return uint256(answer) < oneUsd - allowed || uint256(answer) > oneUsd + allowed;
    }
}
