// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "./TrailingAnchorOracleBase.sol";

interface ICentrifugeSpoke {
    /// @notice Share price in the pool currency, with 18 decimals.
    function pricePoolPerShare(uint64 poolId, bytes16 scId, bool checkValidity) external view returns (uint128);

    /// @notice The time when the share price was computed, the maximum age that the pool sets for it, and the time
    ///         until which it is valid. The last value is `computedAt + maxAge`, or the type maximum if that sum
    ///         overflows.
    function markersPricePoolPerShare(uint64 poolId, bytes16 scId)
        external
        view
        returns (uint64 computedAt, uint64 maxAge, uint64 validUntil);

    /// @notice The token of the share class.
    function shareToken(uint64 poolId, bytes16 scId) external view returns (address);
}

/// @title CentrifugeNavOracle
/// @author Lido
/// @notice NAV oracle for a Centrifuge share class. It reads the share price from the Centrifuge Spoke.
/// @dev The adapter does not use the validity check of the Spoke, because a pool can set an unbounded maximum age.
///      The adapter refuses a price older than its own `MAX_PRICE_AGE`. The issuer supplies the time of the price,
///      so the adapter also refuses a time after the block time.
contract CentrifugeNavOracle layout at erc7201("lido.lend.storage.CentrifugeNavOracle") is TrailingAnchorOracleBase {
    // ---
    // IMMUTABLES
    // ---

    /// @notice Centrifuge Spoke that holds the share prices.
    ICentrifugeSpoke public immutable SPOKE;
    /// @notice Pool of the collateral token.
    uint64 public immutable POOL_ID;
    /// @notice Share class of the collateral token.
    bytes16 public immutable SHARE_CLASS_ID;
    /// @notice Largest age of a share price that the adapter returns, in seconds since the Spoke computed it.
    uint256 public immutable MAX_PRICE_AGE;

    // ---
    // ERRORS
    // ---

    /// @notice The token of the share class on the Spoke is not the collateral token.
    error ShareTokenMismatch(address shareToken, address collateralToken);
    /// @notice `maxPriceAge` is zero.
    error ZeroMaxPriceAge();
    /// @notice The Spoke computed the share price at `computedAt`, which is more than `MAX_PRICE_AGE` ago.
    error StalePrice(uint64 computedAt);
    /// @notice The Spoke gives the share price the time `computedAt`, which is after the block time.
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
        address collateralToken
    ) TrailingAnchorOracleBase(loanToken, collateralToken) {
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
