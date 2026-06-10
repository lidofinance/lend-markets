// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IIrm} from "@lido-blue/src/interfaces/IIrm.sol";

import {UtilsLib} from "@morpho-blue-irm/src/adaptive-curve-irm/libraries/UtilsLib.sol";
import {ErrorsLib} from "@morpho-blue-irm/src/adaptive-curve-irm/libraries/ErrorsLib.sol";
import {ExpLib} from "@morpho-blue-irm/src/adaptive-curve-irm/libraries/ExpLib.sol";
import {MathLib, WAD_INT as WAD} from "@morpho-blue-irm/src/adaptive-curve-irm/libraries/MathLib.sol";
import {MarketParamsLib} from "@lido-blue/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "@lido-blue/src/interfaces/IMorpho.sol";
import {MathLib as MorphoMathLib} from "@lido-blue/src/libraries/MathLib.sol";

/// @title AdaptiveCurveIrm
/// @notice Adaptive-curve interest-rate model forked from Morpho's reference implementation. The
///         six curve parameters that used to live in `ConstantsLib` are now constructor-set
///         `immutable`s, so each market can pin its own curve at deploy time without touching the
///         library. Designed to live behind an `OssifiableProxy` — the impl bytecode bakes the
///         params, so swapping the impl is the upgrade path for the curve.
/// @dev    Storage is the same single `mapping(Id => int256) rateAtTarget` as upstream, in slot 0
///         of the proxy. Direct calls to the impl write to impl storage (gated by the
///         `msg.sender == MORPHO` check), which is harmless.
contract AdaptiveCurveIrm is IIrm {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MarketParamsLib for MarketParams;

    /* EVENTS */

    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    /* IMMUTABLES — curve params (was `ConstantsLib`), all scaled by WAD; rates are per-second */

    struct CurveParams {
        int256 curveSteepness;
        int256 adjustmentSpeed;
        int256 targetUtilization;
        int256 initialRateAtTarget;
        int256 minRateAtTarget;
        int256 maxRateAtTarget;
    }

    int256 public immutable CURVE_STEEPNESS;
    int256 public immutable ADJUSTMENT_SPEED;
    int256 public immutable TARGET_UTILIZATION;
    int256 public immutable INITIAL_RATE_AT_TARGET;
    int256 public immutable MIN_RATE_AT_TARGET;
    int256 public immutable MAX_RATE_AT_TARGET;

    address public immutable MORPHO;

    /* STORAGE */

    /// @dev Height of the curve per market.
    mapping(Id => int256) public rateAtTarget;

    /* CONSTRUCTOR */

    constructor(address morpho, CurveParams memory params) {
        require(morpho != address(0), ErrorsLib.ZERO_ADDRESS);
        require(params.curveSteepness > 0, "AdaptiveCurveIrm: zero steepness");
        require(params.adjustmentSpeed > 0, "AdaptiveCurveIrm: zero adjustment speed");
        require(params.targetUtilization > 0 && params.targetUtilization < WAD, "AdaptiveCurveIrm: target utilization out of range");
        require(params.minRateAtTarget > 0, "AdaptiveCurveIrm: zero min rate");
        require(params.maxRateAtTarget >= params.minRateAtTarget, "AdaptiveCurveIrm: max < min");
        require(
            params.initialRateAtTarget >= params.minRateAtTarget
                && params.initialRateAtTarget <= params.maxRateAtTarget,
            "AdaptiveCurveIrm: initial out of range"
        );

        MORPHO = morpho;
        CURVE_STEEPNESS = params.curveSteepness;
        ADJUSTMENT_SPEED = params.adjustmentSpeed;
        TARGET_UTILIZATION = params.targetUtilization;
        INITIAL_RATE_AT_TARGET = params.initialRateAtTarget;
        MIN_RATE_AT_TARGET = params.minRateAtTarget;
        MAX_RATE_AT_TARGET = params.maxRateAtTarget;
    }

    /* BORROW RATES */

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market);
        return avgRate;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
        require(msg.sender == MORPHO, ErrorsLib.NOT_MORPHO);

        Id id = marketParams.id();

        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market);

        rateAtTarget[id] = endRateAtTarget;

        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));

        return avgRate;
    }

    function _borrowRate(Id id, Market memory market) private view returns (uint256, int256) {
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);

        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = (utilization - TARGET_UTILIZATION).wDivToZero(errNormFactor);

        int256 startRateAtTarget = rateAtTarget[id];

        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            avgRateAtTarget = INITIAL_RATE_AT_TARGET;
            endRateAtTarget = INITIAL_RATE_AT_TARGET;
        } else {
            int256 speed = ADJUSTMENT_SPEED.wMulToZero(err);
            int256 elapsed = int256(block.timestamp - market.lastUpdate);
            int256 linearAdaptation = speed * elapsed;

            if (linearAdaptation == 0) {
                avgRateAtTarget = startRateAtTarget;
                endRateAtTarget = startRateAtTarget;
            } else {
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        return (uint256(_curve(avgRateAtTarget, err)), endRateAtTarget);
    }

    function _curve(int256 _rateAtTarget, int256 err) private view returns (int256) {
        int256 coeff = err < 0 ? WAD - WAD.wDivToZero(CURVE_STEEPNESS) : CURVE_STEEPNESS - WAD;
        return (coeff.wMulToZero(err) + WAD).wMulToZero(int256(_rateAtTarget));
    }

    function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation) private view returns (int256) {
        return startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET);
    }
}
