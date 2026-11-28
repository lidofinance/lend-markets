/* ── MUTATION LinearKinkIrm #4 ──────────────────────────
 * @desc:   Adds the kink to utilization in the steep leg instead of subtracting it, so the rate overshoots the peak cap.
 * @rules:  hlLkiRateWithinBaseAndPeak
 * @conf:   certora/confs/LinearKinkIrm/properties.conf
 * @target: lib/lend-irm/src/linear-kink-irm/LinearKinkIrm.sol
 * Was:     uint256 excess = (utilization - p.optimalUtilization).wDivDown(WAD - p.optimalUtilization);
 * Now:     uint256 excess = (utilization + p.optimalUtilization).wDivDown(WAD - p.optimalUtilization);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IIrm} from "../../lib/lend/src/interfaces/IIrm.sol";
import {ILinearKinkIrm} from "./interfaces/ILinearKinkIrm.sol";
import {ILinearKinkConfig} from "./interfaces/ILinearKinkConfig.sol";
import {LinearKinkParams} from "./interfaces/ILinearKinkTypes.sol";
import {OwnerManagerBase} from "../common/OwnerManagerBase.sol";
import {IConfigurableIrm} from "../common/IConfigurableIrm.sol";

import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MarketParamsLib} from "../../lib/lend/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../../lib/lend/src/interfaces/IMorpho.sol";
import {MathLib, WAD} from "../../lib/lend/src/libraries/MathLib.sol";

/// @title LinearKinkIrm
/// @author Lido.
/// @notice A stateless kinked IRM: the per-second borrow rate is a piecewise-linear function of utilization that
/// steepens past the kink. One immutable instance serves many markets, each with its own params set by the `owner`
/// or `manager`. Meant to sit behind IrmRouter.
contract LinearKinkIrm is ILinearKinkIrm, OwnerManagerBase {
    using MathLib for uint256;
    using MarketParamsLib for MarketParams;

    // ---
    // STORAGE
    // ---

    /// @inheritdoc ILinearKinkIrm
    mapping(Id => LinearKinkParams) public marketKinkParams;

    // ---
    // CONSTRUCTOR
    // ---

    constructor(address owner_, address manager_) {
        _transferOwnership(owner_);
        _setManager(manager_);
    }

    // ---
    // CONFIG MANAGEMENT
    // ---

    /// @inheritdoc IConfigurableIrm
    function applyIrmConfig(MarketParams calldata marketParams, address config) external {
        _checkAuthorized();

        LinearKinkParams memory params = ILinearKinkConfig(config).getKinkParams();

        Id id = marketParams.id();
        marketKinkParams[id] = params;

        emit IrmConfigApplied(id, config);
    }

    // ---
    // BORROW RATES
    // ---

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        return _borrowRate(marketParams.id(), market);
    }

    /// @inheritdoc IIrm
    /// @dev Stateless: identical to `borrowRateView`.
    function borrowRate(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        return _borrowRate(marketParams.id(), market);
    }

    /// @dev Computes the linear-kink per-second borrow rate for market `id` from its current utilization. The curve
    /// is piecewise-linear in utilization `U`:
    ///   U <= optimalUtilization: baseRate + slope1 * U / optimalUtilization
    ///   U >  optimalUtilization: baseRate + slope1 + slope2 * (U - optimalUtilization) / (WAD - optimalUtilization)
    function _borrowRate(Id id, Market memory market) private view returns (uint256) {
        LinearKinkParams memory p = marketKinkParams[id];
        require(p.optimalUtilization != 0, ErrorsLib.CONFIG_NOT_SET);

        uint256 utilization =
            market.totalSupplyAssets > 0 ? uint256(market.totalBorrowAssets).wDivDown(market.totalSupplyAssets) : 0;
        // Utilization cannot exceed 100% in Morpho. Clamping defends the rate math against adversarial view inputs and
        // caps the returned rate at the curve's peak.
        if (utilization > WAD) utilization = WAD;

        if (utilization <= p.optimalUtilization) {
            return p.baseRate + uint256(p.slope1).wMulDown(utilization.wDivDown(p.optimalUtilization));
        } else {
            uint256 excess = (utilization + p.optimalUtilization).wDivDown(WAD - p.optimalUtilization);
            return uint256(p.baseRate) + p.slope1 + uint256(p.slope2).wMulDown(excess);
        }
    }
}
