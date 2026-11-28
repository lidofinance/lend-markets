/* ── MUTATION LinearKinkConfig #12 ────────────────────────────
 * @desc:   Swaps the kink and the base rate in getKinkParams, so consumers read a curve the constructor never validated.
 * @rules:  utIcfLinearConfigGetterMirrorsItsImmutables
 * @conf:   certora/confs/IrmConfigFactory/properties.conf
 * @target: lib/lend-irm/src/linear-kink-irm/LinearKinkConfig.sol
 * Was:     optimalUtilization: OPTIMAL_UTILIZATION, baseRate: BASE_RATE, slope1: SLOPE1, slope2: SLOPE2
 * Now:     optimalUtilization: BASE_RATE, baseRate: OPTIMAL_UTILIZATION, slope1: SLOPE1, slope2: SLOPE2
 * ─────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ILinearKinkConfig} from "./interfaces/ILinearKinkConfig.sol";
import {LinearKinkParams} from "./interfaces/ILinearKinkTypes.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {WAD} from "../../lib/lend/src/libraries/MathLib.sol";

/// @title LinearKinkConfig
/// @author Lido.
/// @notice Immutable holder of one linear-kink curve's parameters, validated at construction.
contract LinearKinkConfig is ILinearKinkConfig {
    /* CONSTANTS */

    /// @dev Maximum peak rate (baseRate + slope1 + slope2, reached at full utilization) = 800%/year, WAD-scaled
    /// per second.
    uint256 private constant MAX_BORROW_RATE = 8.0 ether / uint256(365 days);

    /* IMMUTABLES */

    /// @inheritdoc ILinearKinkConfig
    uint64 public immutable OPTIMAL_UTILIZATION;

    /// @inheritdoc ILinearKinkConfig
    uint64 public immutable BASE_RATE;

    /// @inheritdoc ILinearKinkConfig
    uint64 public immutable SLOPE1;

    /// @inheritdoc ILinearKinkConfig
    uint64 public immutable SLOPE2;

    /* CONSTRUCTOR */

    /// @notice Validates `kinkParams` and freezes it into immutables.
    constructor(LinearKinkParams memory kinkParams) {
        require(kinkParams.optimalUtilization > 0, ErrorsLib.INVALID_OPTIMAL_UTILIZATION);
        require(kinkParams.optimalUtilization < WAD, ErrorsLib.INVALID_OPTIMAL_UTILIZATION);
        require(
            uint256(kinkParams.baseRate) + kinkParams.slope1 + kinkParams.slope2 <= MAX_BORROW_RATE,
            ErrorsLib.MAX_RATE_EXCEEDED
        );

        OPTIMAL_UTILIZATION = kinkParams.optimalUtilization;
        BASE_RATE = kinkParams.baseRate;
        SLOPE1 = kinkParams.slope1;
        SLOPE2 = kinkParams.slope2;
    }

    /// @inheritdoc ILinearKinkConfig
    function getKinkParams() external view returns (LinearKinkParams memory) {
        return LinearKinkParams({
            optimalUtilization: BASE_RATE, baseRate: OPTIMAL_UTILIZATION, slope1: SLOPE1, slope2: SLOPE2
        });
    }
}
