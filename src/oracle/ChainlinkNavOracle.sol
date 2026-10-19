// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IChainlinkAggregator, NavOracleBase} from "./NavOracleBase.sol";

/// @title ChainlinkNavOracle
/// @author Lido
/// @notice NAV oracle for a collateral whose issuer or vendor publishes the NAV through a Chainlink-shaped feed.
/// @dev `updatedAt` is not read: feeds refresh it on every heartbeat even while the value stands still.
contract ChainlinkNavOracle layout at erc7201("lido.lend.storage.NavOracle") is NavOracleBase {
    /// @notice The feed has more than 18 decimals.
    error UnsupportedFeedDecimals(uint8 decimals);
    /// @notice The feed answered zero or a negative value.
    error InvalidAnswer(int256 answer);

    /// @dev NAV feed.
    IChainlinkAggregator public immutable SOURCE;
    /// @dev 10^(18 - feed decimals): the scaling of the feed's answer to 18 decimals.
    uint256 public immutable SOURCE_SCALE;

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address source, address loanToken, address collateralToken, address loanTokenFeed)
        NavOracleBase(loanToken, collateralToken, loanTokenFeed)
    {
        if (source == address(0)) revert ZeroAddress();
        uint8 decimals = IChainlinkAggregator(source).decimals();
        if (decimals > 18) revert UnsupportedFeedDecimals(decimals);
        SOURCE = IChainlinkAggregator(source);
        SOURCE_SCALE = 10 ** (18 - decimals);
    }

    /// @inheritdoc NavOracleBase
    function _readSource() internal view override returns (uint256 nav) {
        (, int256 answer,,,) = SOURCE.latestRoundData();
        if (answer <= 0) revert InvalidAnswer(answer);
        return uint256(answer) * SOURCE_SCALE;
    }
}
