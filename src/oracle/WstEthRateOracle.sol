// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IOracle} from "@lido-blue/src/interfaces/IOracle.sol";

interface IWstETH {
    /// @notice Amount of stETH backing 1 wstETH, scaled by 1e18.
    function stEthPerToken() external view returns (uint256);
}

/// @title WstEthRateOracle
/// @notice Morpho oracle for wstETH quoted in ETH using Lido's accounting rate.
/// @dev    Returns ETH per 1 wstETH scaled by 1e36, assuming stETH/ETH par for protocol accounting.
///         No market-price dependency. Immutable, no governance discretion.
///
///         price() = stEthPerToken() * 1e18
///                 = (stETH per wstETH, scaled 1e18) * 1e18
///                 = ETH per wstETH, scaled 1e36   (under stETH/ETH par)
///
///         This matches Morpho's IOracle convention:
///         "price of 1 collateral asset (wstETH, 18 dec) quoted in 1 loan asset (ETH, 18 dec),
///          scaled by 1e36" — i.e. 36 + 18 - 18 = 36 decimals of precision.
contract WstEthRateOracle is IOracle {
    IWstETH public immutable WSTETH;

    error BadInput();

    constructor(address wstETH_) {
        if (wstETH_ == address(0)) revert BadInput();
        WSTETH = IWstETH(wstETH_);
    }

    function price() external view override returns (uint256) {
        return WSTETH.stEthPerToken() * 1e18;
    }
}
