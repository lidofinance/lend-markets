/* ── MUTATION AdaptiveCurveIrm #26 ──────────────
 * @desc:   Adds a manager surcharge to the quoted rate, so the view answers differently depending on who asks.
 * @rules:  utAciBorrowRateViewIsCallerAgnostic
 * @conf:   certora/confs/AdaptiveCurveIrm/properties.conf
 * @target: lib/lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol
 * Was:     return avgRate;   (in borrowRateView)
 * Now:     return msg.sender == manager ? avgRate + 1 : avgRate;
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IIrm} from "../../lib/lend/src/interfaces/IIrm.sol";
import {IAdaptiveCurveIrm} from "./interfaces/IAdaptiveCurveIrm.sol";
import {IAdaptiveCurveConfig} from "./interfaces/IAdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "./interfaces/IAdaptiveCurveTypes.sol";
import {IConfigurableIrm} from "../common/IConfigurableIrm.sol";
import {OwnerManagerBase} from "../common/OwnerManagerBase.sol";
import {OwnerManagerErrors} from "../common/OwnerManagerErrors.sol";

import {AdaptiveCurveMathLib} from "./libraries/AdaptiveCurveMathLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MarketParamsLib} from "../../lib/lend/src/libraries/MarketParamsLib.sol";
import {Id, MarketParams, Market} from "../../lib/lend/src/interfaces/IMorpho.sol";

/// @title AdaptiveCurveIrm
/// @author Morpho Labs. Modified by Lido.
/// @notice One immutable instance serves many markets keyed by `Id`, each with a config contract and an adapting
/// `rateAtTarget`. It uses the upstream curve and adaptation formulas and is intended to sit behind IrmRouter.
contract AdaptiveCurveIrm is IAdaptiveCurveIrm, OwnerManagerBase {
    using UtilsLib for int256;
    using MarketParamsLib for MarketParams;

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a borrow rate is updated.
    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    // ---
    // IMMUTABLES
    // ---

    /// @inheritdoc IAdaptiveCurveIrm
    address public immutable ROUTER;

    // ---
    // STORAGE
    // ---

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => int256) public rateAtTarget;

    /// @inheritdoc IAdaptiveCurveIrm
    mapping(Id => IAdaptiveCurveConfig) public marketCurveConfig;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param router The IrmRouter in front of this contract, the only caller `borrowRate` accepts.
    constructor(address router, address owner_, address manager_) {
        require(router != address(0), OwnerManagerErrors.ZERO_ADDRESS);

        ROUTER = router;
        _transferOwnership(owner_);
        _setManager(manager_);
    }

    // ---
    // CONFIG MANAGEMENT
    // ---

    /// @inheritdoc IConfigurableIrm
    function applyIrmConfig(MarketParams calldata marketParams, address config) external {
        _checkAuthorized();

        AdaptiveCurveParams memory curveParams = IAdaptiveCurveConfig(config).getCurveParams();
        Id id = marketParams.id();
        marketCurveConfig[id] = IAdaptiveCurveConfig(config);

        // The saved rate must obey the new band immediately — adaptation alone would re-clamp it late or never.
        // 0 means the market was never priced: the first call seeds it, so it must stay 0.
        int256 storedRate = rateAtTarget[id];
        if (storedRate != 0) {
            rateAtTarget[id] = storedRate.bound(curveParams.minRateAtTarget, curveParams.maxRateAtTarget);
        }

        emit IrmConfigApplied(id, config);
    }

    // ---
    // BORROW RATES
    // ---

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market);
        return msg.sender == manager ? avgRate + 1 : avgRate;
    }

    /// @inheritdoc IIrm
    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
        require(msg.sender == ROUTER, ErrorsLib.NOT_ROUTER);

        Id id = marketParams.id();

        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market);

        rateAtTarget[id] = endRateAtTarget;

        // Safe "unchecked" cast because endRateAtTarget >= 0.
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));

        return avgRate;
    }

    /// @dev Returns avgRate and endRateAtTarget for market `id`.
    /// @dev Assumes `market` is market `id`'s current state.
    function _borrowRate(Id id, Market memory market) private view returns (uint256, int256) {
        IAdaptiveCurveConfig curveConfig = marketCurveConfig[id];
        require(address(curveConfig) != address(0), ErrorsLib.CONFIG_NOT_SET);
        AdaptiveCurveParams memory curveParams = curveConfig.getCurveParams();

        return AdaptiveCurveMathLib.computeBorrowRate(curveParams, rateAtTarget[id], market);
    }
}
