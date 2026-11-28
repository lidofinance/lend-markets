/* ── MUTATION IrmRouter #4 ──────────────────────────────
 * @desc:   Inverts the Morpho-only gate on borrowRate, locking Morpho out and letting anyone else drive accrual.
 * @rules:  rvIrrBorrowRateRevertsOnGuardFailure
 * @conf:   certora/confs/IrmRouter/properties.conf
 * @target: lib/lend-irm/src/irm-router/IrmRouter.sol
 * Was:     require(msg.sender == MORPHO, ErrorsLib.NOT_MORPHO);
 * Now:     require(msg.sender != MORPHO, ErrorsLib.NOT_MORPHO);
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IIrm} from "../../lib/lend/src/interfaces/IIrm.sol";
import {IIrmRouter} from "./interfaces/IIrmRouter.sol";
import {Id, MarketParams, Market, IMorpho} from "../../lib/lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "../../lib/lend/src/libraries/MarketParamsLib.sol";
import {OwnerManagerBase} from "../common/OwnerManagerBase.sol";
import {OwnerManagerErrors} from "../common/OwnerManagerErrors.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";

/// @title IrmRouter
/// @author Lido.
/// @notice A market's `irm` can never change in Morpho, so markets are created pointing at this router. It forwards
/// `borrowRate`/`borrowRateView` to a per-market implementation switchable by the `owner` or `manager`, letting a
/// live market migrate between rate models.
/// @dev Runs behind a proxy. Implementations are immutable, constructed with this router as their trusted caller.
contract IrmRouter layout at erc7201("lido.lend.storage.IrmRouter") is IIrmRouter, OwnerManagerBase {
    using MarketParamsLib for MarketParams;

    // ---
    // IMMUTABLES
    // ---

    /// @inheritdoc IIrmRouter
    address public immutable MORPHO;

    // ---
    // STORAGE
    // ---

    /// @inheritdoc IIrmRouter
    bool public isInitialized;

    /// @inheritdoc IIrmRouter
    mapping(Id => IIrm) public marketIrm;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param morpho The address of Morpho.
    constructor(address morpho) {
        require(morpho != address(0), OwnerManagerErrors.ZERO_ADDRESS);

        MORPHO = morpho;
        // Lock the implementation: only a proxy, whose storage starts zeroed, can be initialized.
        isInitialized = true;
    }

    // ---
    // INITIALIZATION
    // ---

    /// @inheritdoc IIrmRouter
    function initialize(address owner_, address manager_) external {
        require(!isInitialized, ErrorsLib.ALREADY_INITIALIZED);

        isInitialized = true;
        _transferOwnership(owner_);
        _setManager(manager_);
    }

    // ---
    // ROUTING
    // ---

    /// @inheritdoc IIrmRouter
    /// @dev A new market is routed without touching the implementation: `createMarket` performs the first
    /// `borrowRate` ping itself and reverts while the implementation is unconfigured or mis-gated, creating nothing.
    /// A live market is accrued first (the old model prices its own period) and the new implementation is probed
    /// with the exact call Morpho will make -- a reverting one would brick the market. Re-attaching a previously
    /// used `AdaptiveCurveIrm` resumes from its frozen `rateAtTarget`, not from `initialRateAtTarget`.
    function setMarketIrm(MarketParams memory marketParams, IIrm irm) external {
        _checkAuthorized();
        require(address(irm) != address(0), OwnerManagerErrors.ZERO_ADDRESS);
        // The id commits to the `irm` field: a foreign address would route a phantom market.
        require(marketParams.irm == address(this), ErrorsLib.NOT_ROUTER_MARKET);

        Id id = marketParams.id();

        // Only a live market is accrued and probed: a pre-creation probe would prematurely write a stateful
        // model's rateAtTarget, and a repeated one would then decay it over the whole epoch.
        Market memory market = IMorpho(MORPHO).market(id);
        if (market.lastUpdate != 0) {
            IMorpho(MORPHO).accrueInterest(marketParams);
            market = IMorpho(MORPHO).market(id);

            irm.borrowRate(marketParams, market);
        }

        marketIrm[id] = irm;
        emit MarketIrmSet(id, address(irm));
    }

    // ---
    // BORROW RATES
    // ---

    /// @inheritdoc IIrm
    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
        require(msg.sender != MORPHO, ErrorsLib.NOT_MORPHO); // MUTATION: inverted trust gate locks Morpho out and lets anyone else in

        IIrm irm = marketIrm[marketParams.id()];
        require(address(irm) != address(0), ErrorsLib.IRM_NOT_SET);

        return irm.borrowRate(marketParams, market);
    }

    /// @inheritdoc IIrm
    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        IIrm irm = marketIrm[marketParams.id()];
        require(address(irm) != address(0), ErrorsLib.IRM_NOT_SET);

        return irm.borrowRateView(marketParams, market);
    }
}
