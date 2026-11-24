// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "./TrailingAnchorOracleBase.sol";

interface IChainlinkFeed {
    /// @notice The latest value: `answer`, with `decimals()` decimals, written to the feed at `updatedAt`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Decimals of `answer`.
    function decimals() external view returns (uint8);
}

/// @title ChainlinkNavOracle
/// @author Lido
/// @notice NAV oracle that reads the collateral's price from a feed with Chainlink's aggregator interface.
/// @dev The feed's `updatedAt` is when the feed wrote the value, not when the issuer computed it. The adapter refuses
///      a value older than `MAX_PRICE_AGE` and one written after the block time.
contract ChainlinkNavOracle layout at erc7201("lido.lend.storage.ChainlinkNavOracle") is TrailingAnchorOracleBase {
    // ---
    // IMMUTABLES
    // ---

    /// @notice Feed of the collateral's price in the loan token's currency.
    IChainlinkFeed public immutable FEED;
    /// @notice Largest age of a feed value that the adapter returns, in seconds since the feed wrote it.
    uint256 public immutable MAX_PRICE_AGE;
    /// @notice Factor from the feed's decimals to `PRICE_DECIMALS`.
    uint256 public immutable ANSWER_SCALE;

    // ---
    // ERRORS
    // ---

    /// @notice `maxPriceAge` is zero.
    error MaxPriceAgeIsZero();
    /// @notice The feed has more decimals than `PRICE_DECIMALS`.
    error UnsupportedFeedDecimals(uint8 feedDecimals);
    /// @notice The feed's value is below zero.
    error NegativePrice(int256 answer);
    /// @notice The feed wrote its value at `updatedAt`, which is more than `MAX_PRICE_AGE` ago.
    error StalePrice(uint256 updatedAt);
    /// @notice The feed gives its value the time `updatedAt`, which is after the block time.
    error PriceFromFuture(uint256 updatedAt);

    // ---
    // CONSTRUCTOR
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address feed, uint256 maxPriceAge, address loanToken, address collateralToken)
        TrailingAnchorOracleBase(loanToken, collateralToken)
    {
        if (feed == address(0)) revert ZeroAddress();
        if (maxPriceAge == 0) revert MaxPriceAgeIsZero();
        uint8 feedDecimals = IChainlinkFeed(feed).decimals();
        if (feedDecimals > PRICE_DECIMALS) revert UnsupportedFeedDecimals(feedDecimals);
        FEED = IChainlinkFeed(feed);
        MAX_PRICE_AGE = maxPriceAge;
        ANSWER_SCALE = 10 ** (PRICE_DECIMALS - feedDecimals);
    }

    // ---
    // OVERRIDES
    // ---

    /// @inheritdoc TrailingAnchorOracleBase
    function _currentPrice() internal view override returns (uint256 currentPrice) {
        (, int256 answer,, uint256 updatedAt,) = FEED.latestRoundData();
        if (updatedAt > block.timestamp) revert PriceFromFuture(updatedAt);
        if (block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePrice(updatedAt);
        if (answer < 0) revert NegativePrice(answer);
        return uint256(answer) * ANSWER_SCALE;
    }
}
