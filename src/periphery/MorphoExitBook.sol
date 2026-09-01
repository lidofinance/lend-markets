// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IMorpho, Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMorphoExitBook} from "../interfaces/IMorphoExitBook.sol";
import {PriorityRamp} from "../types/ExitBookTypes.sol";
import {ExitBookBase} from "./ExitBookBase.sol";

/// @title MorphoExitBook
/// @author Lido
/// @notice The Morpho exit book: a request is backed by the lender's supply position, and a fill withdraws
///         from it. Governance picks the allowed markets. Works with compatible Morpho deployments.
contract MorphoExitBook is ExitBookBase, IMorphoExitBook {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    // ---
    // ERRORS
    // ---

    /// @notice The market is not allowed for new requests.
    error MarketNotAllowed();

    /// @notice The market params do not name a live Morpho market.
    error MarketNotCreated();

    /// @notice The caller has not authorized this book on Morpho.
    error NotAuthorizedOnMorpho();

    /// @notice The caller's supply position cannot back the request.
    error InsufficientBacking();

    /// @notice The Morpho address passed to the constructor is the zero address.
    error ZeroMorpho();

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a market is allowed or disallowed for new requests.
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
    mapping(Id marketId => bool isAllowed) public isMarketAllowed;

    /// @dev Registered params per market id, kept permanently so existing requests still resolve after the market
    ///      is disallowed. The id is the hash of the params, so one id maps to one parameter set.
    mapping(Id marketId => MarketParams marketParams) internal _marketParams;

    /// @dev The market a request was placed against (params via `_marketParams`).
    mapping(uint256 requestId => Id marketId) internal _marketIdOf;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param morpho Non-zero Morpho deployment used as the source.
    /// @param admin Non-zero initial holder of `DEFAULT_ADMIN_ROLE`.
    /// @param maxLifetime_ Non-zero maximum request lifetime in seconds.
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
        uint256 assets,
        address receiver,
        uint256 minFillAssets,
        uint256 maxShareBurn,
        PriorityRamp calldata ramp,
        uint256 deadline
    ) external returns (uint256 id) {
        if (paused) revert EnforcedPause();

        if (!isMarketAllowed[marketId]) revert MarketNotAllowed();
        if (assets == 0) revert ZeroAssets();

        if (!MORPHO.isAuthorized(msg.sender, address(this))) revert NotAuthorizedOnMorpho();

        MarketParams memory marketParams = _marketParams[marketId];
        uint256 requiredShares = _supplyAssetsToShares(marketParams, assets);
        if (MORPHO.position(marketId, msg.sender).supplyShares < requiredShares) revert InsufficientBacking();

        IERC20 asset = IERC20(marketParams.loanToken);
        id = _createRequest(
            msg.sender, receiver, asset, assets, minFillAssets, requiredShares, maxShareBurn, ramp, deadline
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

    function _withdraw(uint256 id, address account, uint256 assets) internal override returns (uint256 sharesBurned) {
        (, sharesBurned) = MORPHO.withdraw(_requestMarket(id), assets, 0, account, address(this));
    }

    // ---
    // MORPHO MATH
    // ---

    /// @dev Market supply assets to shares at the live supply price, rounding up.
    function _supplyAssetsToShares(MarketParams memory marketParams, uint256 assets) internal view returns (uint256) {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            MorphoBalancesLib.expectedMarketBalances(MORPHO, marketParams);
        return assets.toSharesUp(totalSupplyAssets, totalSupplyShares);
    }
}
