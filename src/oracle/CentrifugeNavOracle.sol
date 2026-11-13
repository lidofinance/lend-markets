// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "./TrailingAnchorOracleBase.sol";

interface ICentrifugeSpoke {
    /// @notice Share price in the pool currency, 18-decimal fixed point.
    function pricePoolPerShare(uint64 poolId, bytes16 scId, bool checkValidity) external view returns (uint128);

    /// @notice When the share price was computed, the maximum age the pool sets for it, and the time until which it
    ///         is valid: `computedAt + maxAge`, or the type maximum when that sum overflows.
    function markersPricePoolPerShare(uint64 poolId, bytes16 scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice The token of the share class.
    function shareToken(uint64 poolId, bytes16 scId) external view returns (address);
}

/// @title CentrifugeNavOracle
/// @author Lido
/// @notice NAV oracle for a Centrifuge share class, reading the Spoke's share price.
/// @dev The Spoke's own validity check is not requested, since its maximum age is unbounded on the deployed pools.
///      The adapter refuses a price older than its own `MAX_PRICE_AGE` instead. The issuer supplies the time the
///      price is stamped with, so the adapter also refuses a stamp after the block.
contract CentrifugeNavOracle layout at erc7201("lido.lend.storage.CentrifugeNavOracle") is TrailingAnchorOracleBase {
    // ---
    // IMMUTABLES
    // ---

    /// @dev Centrifuge Spoke holding the price registry.
    ICentrifugeSpoke public immutable SPOKE;
    /// @dev Pool and share class the collateral token belongs to.
    uint64 public immutable POOL_ID;
    bytes16 public immutable SHARE_CLASS_ID;
    /// @notice Oldest share price, in seconds since the Spoke computed it, that the adapter returns.
    uint256 public immutable MAX_PRICE_AGE;

    // ---
    // ERRORS
    // ---

    /// @notice The share class's token on the Spoke is not the collateral token.
    error ShareTokenMismatch(address shareToken, address collateralToken);
    /// @notice `maxPriceAge` is zero.
    error ZeroMaxPriceAge();
    /// @notice The Spoke computed the share price at `computedAt`, more than `MAX_PRICE_AGE` ago.
    error StalePrice(uint64 computedAt);
    /// @notice The Spoke stamps the share price with `computedAt`, a time after this block.
    error PriceFromFuture(uint64 computedAt);

    // ---
    // CONSTRUCTOR
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(
        address spoke,
        uint64 poolId,
        bytes16 scId,
        uint256 maxPriceAge,
        address loanToken,
        address collateralToken,
        uint256 maxLltv
    ) TrailingAnchorOracleBase(loanToken, collateralToken, maxLltv) {
        if (spoke == address(0)) revert ZeroAddress();
        if (maxPriceAge == 0) revert ZeroMaxPriceAge();
        address shareToken = ICentrifugeSpoke(spoke).shareToken(poolId, scId);
        if (shareToken != collateralToken) revert ShareTokenMismatch(shareToken, collateralToken);
        SPOKE = ICentrifugeSpoke(spoke);
        POOL_ID = poolId;
        SHARE_CLASS_ID = scId;
        MAX_PRICE_AGE = maxPriceAge;
    }

    // ---
    // OVERRIDES
    // ---

    /// @inheritdoc TrailingAnchorOracleBase
    function _currentPrice() internal view override returns (uint256 currentPrice) {
        (uint64 computedAt,,) = SPOKE.markersPricePoolPerShare(POOL_ID, SHARE_CLASS_ID);
        if (computedAt > block.timestamp) revert PriceFromFuture(computedAt);
        if (block.timestamp - computedAt > MAX_PRICE_AGE) revert StalePrice(computedAt);
        return SPOKE.pricePoolPerShare(POOL_ID, SHARE_CLASS_ID, false);
    }
}
