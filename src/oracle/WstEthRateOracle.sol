// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

interface IWstETH {
    /// @notice stETH backing `wstETHAmount` wstETH, in the same units as the input.
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
}

/// @title WstEthRateOracle
/// @notice Morpho oracle for wstETH quoted in ETH using Lido's accounting rate.
/// @dev    Returns ETH per 1 wstETH scaled by 1e36, assuming stETH/ETH par for protocol accounting.
///         No market-price dependency.
///
///         price() = getStETHByWstETH(1e36)
///                 = stETH backing 1e36 wstETH = ETH per wstETH, scaled 1e36 (under stETH/ETH par)
///
///         Querying at the 1e36 input (rather than `stEthPerToken() * 1e18`) keeps the rate's low-order
///         digits instead of flooring at 1e18 and then scaling.
///
///         This matches Morpho's IOracle convention:
///         "price of 1 collateral asset (wstETH, 18 dec) quoted in 1 loan asset (ETH, 18 dec),
///          scaled by 1e36" — i.e. 36 + 18 - 18 = 36 decimals of precision.
contract WstEthRateOracle is IOracle {
    // ---
    // IMMUTABLES
    // ---

    /// @dev wstETH token queried for its stETH-per-wstETH accounting rate.
    IWstETH public immutable WSTETH;

    // ---
    // ERRORS
    // ---

    /// @notice The wstETH address passed to the constructor was the zero address.
    error ZeroAddress();

    // ---
    // CONSTRUCTOR
    // ---

    /// @param wstETH_ wstETH token whose stETH-per-wstETH rate this oracle returns.
    constructor(address wstETH_) {
        if (wstETH_ == address(0)) revert ZeroAddress();
        WSTETH = IWstETH(wstETH_);
    }

    // ---
    // INITIALIZATION
    // ---

    /// @notice No-op that satisfies the proxy's mandatory init call. The config is immutable in the impl.
    function initialize() external {}

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IOracle
    function price() external view override returns (uint256) {
        return WSTETH.getStETHByWstETH(1e36);
    }
}
