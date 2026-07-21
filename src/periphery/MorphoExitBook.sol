// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {ExitBookBase} from "./ExitBookBase.sol";
import {IMorphoExitBook} from "../interfaces/IMorphoExitBook.sol";
import {Request, PriorityRamp} from "../types/ExitBookTypes.sol";
import {WAD} from "../libs/Constants.sol";

/// @title MorphoExitBook
/// @author Lido
/// @notice The Morpho exit book: a request is backed by the lender's supply position, and a fill withdraws
///         from it. Governance picks the allowed markets. Works on any Morpho deployment.
contract MorphoExitBook is ExitBookBase, IMorphoExitBook {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    // ---
    // ERRORS
    // ---

    error MarketNotAllowed();
    error MarketNotCreated();
    error NotAuthorizedOnMorpho();
    error InsufficientBacking();
    error ZeroMorpho();

    // ---
    // EVENTS
    // ---

    event MarketAllowedSet(Id indexed marketId, bool allowed);

    // ---
    // IMMUTABLES
    // ---

    /// @inheritdoc IMorphoExitBook
    IMorpho public immutable MORPHO;

    // ---
    // STORAGE
    // ---

    /// @inheritdoc IMorphoExitBook
    mapping(Id marketId => bool) public isMarketAllowed;

    /// @dev Registered params per market id, kept permanently — so requests already placed against a market
    ///      still resolve (and stay fillable) after it is disallowed. The id is the params' hash, so canonical.
    mapping(Id marketId => MarketParams) internal _marketParams;

    /// @dev The market a request was placed against (params via `_marketParams`).
    mapping(uint256 requestId => Id) internal _marketIdOf;

    // ---
    // CONSTRUCTOR
    // ---

    constructor(address morpho, address admin, uint256 maxLifetime_) ExitBookBase(admin, maxLifetime_) {
        if (morpho == address(0)) revert ZeroMorpho();

        MORPHO = IMorpho(morpho);
    }

    // ---
    // CONFIG
    // ---

    /// @inheritdoc IMorphoExitBook
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed)
        external
        onlyRole(ALLOWLIST_MANAGER_ROLE)
    {
        Id marketId = marketParams.id();

        if (MORPHO.market(marketId).lastUpdate == 0) revert MarketNotCreated();

        isMarketAllowed[marketId] = allowed;
        _marketParams[marketId] = marketParams;

        emit MarketAllowedSet(marketId, allowed);
    }

    // ---
    // READS
    // ---

    /// @inheritdoc IMorphoExitBook
    function marketParamsOf(uint256 requestId) external view returns (MarketParams memory) {
        return _requestMarket(requestId);
    }

    // ---
    // PLACE
    // ---

    /// @inheritdoc IMorphoExitBook
    function placeExitRequest(
        Id marketId,
        uint256 shares,
        PriorityRamp calldata ramp,
        uint256 deadline,
        bool fullFillOnly
    ) external returns (uint256 id) {
        if (!isMarketAllowed[marketId]) revert MarketNotAllowed();

        if (!MORPHO.isAuthorized(msg.sender, address(this))) revert NotAuthorizedOnMorpho();

        // Permission-only: shares stay in the lender's position; sanity-check now, the fill re-checks live.
        if (MORPHO.position(marketId, msg.sender).supplyShares < shares) revert InsufficientBacking();

        MarketParams memory marketParams = _marketParams[marketId];
        uint256 pricePerShare = _supplySharesToAssets(marketParams, WAD);

        id = _createRequest(
            msg.sender, IERC20(marketParams.loanToken), shares, pricePerShare, ramp, deadline, fullFillOnly
        );

        _marketIdOf[id] = marketId;
    }

    // ---
    // SOURCE OPERATIONS
    // ---

    /// @dev The registered params of the market request `requestId` was placed against.
    function _requestMarket(uint256 requestId) internal view returns (MarketParams memory) {
        return _marketParams[_marketIdOf[requestId]];
    }

    function _availableShares(uint256 id, Request storage request) internal view override returns (uint256) {
        // The withdraw pulls from the owner's position on their behalf — if they revoked authorization the
        // fill would revert, so report nothing fillable (keeps `previewFill` honest for fillers).
        if (!MORPHO.isAuthorized(request.owner, address(this))) return 0;

        MarketParams memory marketParams = _requestMarket(id);

        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(MORPHO, marketParams);

        uint256 idleAssets = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        uint256 ownerShares = MORPHO.position(marketParams.id(), request.owner).supplyShares;
        uint256 backedShares = Math.min(request.sizeRemaining, ownerShares);

        // A plain `toSharesDown(idleAssets)` cap rounds below what the core's exact-share withdraw actually
        // releases, so a fully redeemable request would be wrongly rejected (or left with dust) at the boundary.
        if (backedShares.toAssetsDown(totalSupplyAssets, totalSupplyShares) <= idleAssets) return backedShares;
        return idleAssets.toSharesDown(totalSupplyAssets, totalSupplyShares);
    }

    function _redeem(uint256 id, address account, uint256 shares) internal override {
        MORPHO.withdraw(_requestMarket(id), 0, shares, account, address(this));
    }

    function _depositLiquidity(uint256 id, IERC20 asset, uint256 depositAssets, address filler) internal override {
        asset.forceApprove(address(MORPHO), depositAssets);
        MORPHO.supply(_requestMarket(id), depositAssets, 0, filler, "");
    }

    function _previewAssets(uint256 id, uint256 shares) internal view override returns (uint256) {
        return _supplySharesToAssets(_requestMarket(id), shares);
    }

    // ---
    // MORPHO MATH
    // ---

    /// @dev Market supply shares to assets at the live supply price, rounding down.
    function _supplySharesToAssets(MarketParams memory marketParams, uint256 shares) internal view returns (uint256) {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(MORPHO, marketParams);
        return shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }
}
