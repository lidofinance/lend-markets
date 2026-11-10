/* ──── MUTATION AdaptiveCurveConfig #3003 ─────────────────────────────────────────
 * @desc:   Makes getCurveParams report the maximum rate in the minimum field.
 * @rules:  utIcfAdaptiveConfigGetterMirrorsItsImmutables
 * @conf:   certora/confs/IrmConfigFactory/properties.conf
 * @target: lib/lend-irm/src/adaptive-curve-irm/AdaptiveCurveConfig.sol
 * Was:     minRateAtTarget: MIN_RATE_AT_TARGET,
 * Now:     minRateAtTarget: MAX_RATE_AT_TARGET,
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAdaptiveCurveConfig} from "./interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "./interfaces/IAdaptiveCurveTypes.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {WAD_INT as WAD} from "./libraries/MathLib.sol";

/// @title AdaptiveCurveConfig
/// @author Lido.
/// @notice Immutable holder of one curve's parameters, validated at construction.
contract AdaptiveCurveConfig is IAdaptiveCurveConfig {
    /* IMMUTABLES */

    /// @inheritdoc IAdaptiveCurveConfig
    int256 public immutable CURVE_STEEPNESS;
    /// @inheritdoc IAdaptiveCurveConfig
    int256 public immutable ADJUSTMENT_SPEED;
    /// @inheritdoc IAdaptiveCurveConfig
    int256 public immutable TARGET_UTILIZATION;
    /// @inheritdoc IAdaptiveCurveConfig
    int256 public immutable INITIAL_RATE_AT_TARGET;
    /// @inheritdoc IAdaptiveCurveConfig
    int256 public immutable MIN_RATE_AT_TARGET;
    /// @inheritdoc IAdaptiveCurveConfig
    int256 public immutable MAX_RATE_AT_TARGET;
    /// @inheritdoc IAdaptiveCurveConfig
    uint256 public immutable MAX_BORROW_RATE;

    /* CONSTANTS */

    /// @dev Maximum curve steepness = 100 (WAD-scaled ratio).
    int256 private constant MAX_CURVE_STEEPNESS = 100 ether;

    /// @dev Maximum adjustment speed = 10000/year (WAD-scaled, per second).
    int256 private constant MAX_ADJUSTMENT_SPEED = 10_000 ether / int256(365 days);

    /// @dev Maximum rate at target = 10000/year = 1000000%/year (WAD-scaled, per second).
    int256 private constant MAX_RATE_AT_TARGET_LIMIT = 10_000 ether / int256(365 days);

    /// @dev Maximum meaningful borrow-rate cap: the curve's maximum possible output
    /// (`maxRateAtTarget * curveSteepness` at their ceilings). A cap above it could never bind; rejecting such
    /// values catches per-second/per-year unit slips that would silently disable the cap.
    uint256 private constant MAX_BORROW_RATE_LIMIT =
        uint256(MAX_RATE_AT_TARGET_LIMIT) * uint256(MAX_CURVE_STEEPNESS) / 1e18;

    /* CONSTRUCTOR */

    /// @notice Validates `curveParams` and freezes it into immutables.
    constructor(AdaptiveCurveParams memory curveParams) {
        _validateCurveParams(curveParams);

        CURVE_STEEPNESS = curveParams.curveSteepness;
        ADJUSTMENT_SPEED = curveParams.adjustmentSpeed;
        TARGET_UTILIZATION = curveParams.targetUtilization;
        INITIAL_RATE_AT_TARGET = curveParams.initialRateAtTarget;
        MIN_RATE_AT_TARGET = curveParams.minRateAtTarget;
        MAX_RATE_AT_TARGET = curveParams.maxRateAtTarget;
        MAX_BORROW_RATE = curveParams.maxBorrowRate;
    }

    /// @dev Reverts unless `curveParams` is a valid curve configuration, with a per-parameter error message. The
    /// bounds (upper limits included) keep the curve math inside its non-overflowing range, so `borrowRate` returns a
    /// non-negative rate without reverting. They enforce well-formedness only, not economic soundness.
    function _validateCurveParams(AdaptiveCurveParams memory curveParams) private pure {
        require(curveParams.curveSteepness >= WAD, ErrorsLib.INVALID_CURVE_STEEPNESS);
        require(curveParams.curveSteepness <= MAX_CURVE_STEEPNESS, ErrorsLib.INVALID_CURVE_STEEPNESS);

        require(curveParams.adjustmentSpeed >= 0, ErrorsLib.INVALID_ADJUSTMENT_SPEED);
        require(curveParams.adjustmentSpeed <= MAX_ADJUSTMENT_SPEED, ErrorsLib.INVALID_ADJUSTMENT_SPEED);

        require(curveParams.targetUtilization > 0, ErrorsLib.INVALID_TARGET_UTILIZATION);
        require(curveParams.targetUtilization < WAD, ErrorsLib.INVALID_TARGET_UTILIZATION);

        require(curveParams.minRateAtTarget > 0, ErrorsLib.INVALID_RATE_BOUNDS);
        require(curveParams.maxRateAtTarget >= curveParams.minRateAtTarget, ErrorsLib.INVALID_RATE_BOUNDS);
        require(curveParams.maxRateAtTarget <= MAX_RATE_AT_TARGET_LIMIT, ErrorsLib.INVALID_RATE_BOUNDS);

        require(curveParams.initialRateAtTarget >= curveParams.minRateAtTarget, ErrorsLib.INVALID_INITIAL_RATE);
        require(curveParams.initialRateAtTarget <= curveParams.maxRateAtTarget, ErrorsLib.INVALID_INITIAL_RATE);

        require(
            curveParams.maxBorrowRate == 0 || curveParams.maxBorrowRate <= MAX_BORROW_RATE_LIMIT,
            ErrorsLib.INVALID_MAX_BORROW_RATE
        );
    }

    /// @inheritdoc IAdaptiveCurveConfig
    function getCurveParams() external view returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: CURVE_STEEPNESS,
            adjustmentSpeed: ADJUSTMENT_SPEED,
            targetUtilization: TARGET_UTILIZATION,
            initialRateAtTarget: INITIAL_RATE_AT_TARGET,
            minRateAtTarget: MAX_RATE_AT_TARGET,
            maxRateAtTarget: MAX_RATE_AT_TARGET,
            maxBorrowRate: MAX_BORROW_RATE
        });
    }
}
