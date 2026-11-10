/* ──── MUTATION AdaptiveCurveMathLib #3002 ────────────────────────────────────────
 * @desc:   Skips adaptation whenever the linear adaptation is not negative.
 * @rules:  rcAciBorrowRateAdaptsUpwardIsReachable
 * @conf:   certora/confs/AdaptiveCurveIrm/properties.conf
 * @target: lib/lend-irm/src/adaptive-curve-irm/libraries/AdaptiveCurveMathLib.sol
 * Was:     if (linearAdaptation == 0) {
 * Now:     if (linearAdaptation >= 0) {
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AdaptiveCurveParams} from "../interfaces/IAdaptiveCurveTypes.sol";
import {ExpLib} from "./ExpLib.sol";
import {MathLib, WAD_INT as WAD} from "./MathLib.sol";
import {UtilsLib} from "./UtilsLib.sol";
import {Market} from "../../../lib/lend/src/interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "../../../lib/lend/src/libraries/MathLib.sol";

/// @title AdaptiveCurveMathLib
/// @author Morpho Labs. Modified by Lido.
/// @notice Shared rate computation for AdaptiveCurveIrm and its periphery library.
library AdaptiveCurveMathLib {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;

    /// @dev Returns the average borrow rate and the ending rate at target for the supplied market state.
    function computeBorrowRate(AdaptiveCurveParams memory curveParams, int256 startRateAtTarget, Market memory market)
        internal
        view
        returns (uint256, int256)
    {
        int256 err = _err(market, curveParams.targetUtilization);

        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            // First interaction.
            avgRateAtTarget = curveParams.initialRateAtTarget;
            endRateAtTarget = curveParams.initialRateAtTarget;
        } else {
            // The speed is assumed constant between two updates, but it is in fact not constant because of interest.
            // So the rate is always underestimated.
            int256 speed = curveParams.adjustmentSpeed.wMulToZero(err);
            // market.lastUpdate != 0 because it is not the first interaction with this market.
            // Safe "unchecked" cast because block.timestamp - market.lastUpdate <= block.timestamp <= type(int256).max.
            int256 elapsed = int256(block.timestamp - market.lastUpdate);
            int256 linearAdaptation = speed * elapsed;

            if (linearAdaptation >= 0) {
                // If linearAdaptation == 0, avgRateAtTarget = endRateAtTarget = startRateAtTarget;
                avgRateAtTarget = startRateAtTarget;
                endRateAtTarget = startRateAtTarget;
            } else {
                // Formula of the average rate that should be returned to the core:
                // avg = 1/T * ∫_0^T curve(startRateAtTarget*exp(speed*x), err) dx
                // The integral is approximated with the trapezoidal rule:
                // avg ~= 1/T * Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / 2 * T/N
                // Where f(x) = startRateAtTarget*exp(speed*x)
                // avg ~= Σ_i=1^N [curve(f((i-1) * T/N), err) + curve(f(i * T/N), err)] / (2 * N)
                // As curve is linear in its first argument:
                // avg ~= curve([Σ_i=1^N [f((i-1) * T/N) + f(i * T/N)] / (2 * N), err)
                // avg ~= curve([(f(0) + f(T))/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
                // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + Σ_i=1^(N-1) f(i * T/N)] / N, err)
                // With N = 2:
                // avg ~= curve([(startRateAtTarget + endRateAtTarget)/2 + startRateAtTarget*exp(speed*T/2)] / 2, err)
                // avg ~= curve([startRateAtTarget + endRateAtTarget + 2*startRateAtTarget*exp(speed*T/2)] / 4, err)
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation, curveParams);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2, curveParams);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        // Safe "unchecked" cast because avgRateAtTarget >= 0.
        uint256 rate = uint256(_curve(avgRateAtTarget, err, curveParams.curveSteepness));

        // The cap bounds only the reported rate. Adaptation is err-driven, not rate-driven, so `endRateAtTarget`
        // stays untouched and the state machine is unchanged.
        if (curveParams.maxBorrowRate != 0 && rate > curveParams.maxBorrowRate) rate = curveParams.maxBorrowRate;

        return (rate, endRateAtTarget);
    }

    /// @dev Returns the normalized distance from the target utilization for a given market.
    function _err(Market memory market, int256 targetUtilization) internal pure returns (int256) {
        // Safe "unchecked" cast because type(uint128).max * WAD < type(int256).max.
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);
        int256 errNormFactor = utilization > targetUtilization ? WAD - targetUtilization : targetUtilization;
        return (utilization - targetUtilization).wDivToZero(errNormFactor);
    }

    /// @dev Returns the rate for a given `_rateAtTarget` and an `err`.
    /// The formula of the curve is the following:
    /// r = ((1-1/C)*err + 1) * rateAtTarget if err < 0
    ///     ((C-1)*err + 1) * rateAtTarget else.
    function _curve(int256 _rateAtTarget, int256 err, int256 curveSteepness) internal pure returns (int256) {
        // Non negative because 1 - 1/C >= 0, C - 1 >= 0.
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(curveSteepness) : curveSteepness - WAD;
        // Non negative if _rateAtTarget >= 0 because if err < 0, coeff <= 1.
        return (coeff.wMulToZero(err) + WAD).wMulToZero(_rateAtTarget);
    }

    /// @dev Returns the new rate at target, for a given `startRateAtTarget` and a given `linearAdaptation`.
    /// The formula is: max(min(startRateAtTarget * exp(linearAdaptation), maxRateAtTarget), minRateAtTarget).
    function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation, AdaptiveCurveParams memory curveParams)
        internal
        pure
        returns (int256)
    {
        // Non negative because minRateAtTarget > 0.
        return startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation))
            .bound(curveParams.minRateAtTarget, curveParams.maxRateAtTarget);
    }
}
