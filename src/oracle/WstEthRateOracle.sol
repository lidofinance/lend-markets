// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
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
contract WstEthRateOracle layout at erc7201("lido.lending.storage.WstEthRateOracle") is IOracle, Initializable {
    IWstETH public wstEth;

    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Sets the wstETH token.
    /// @param wstETH_ wstETH token whose stETH-per-wstETH rate this oracle returns.
    function initialize(address wstETH_) external initializer {
        if (wstETH_ == address(0)) revert ZeroAddress();
        wstEth = IWstETH(wstETH_);
    }

    function price() external view override returns (uint256) {
        return wstEth.getStETHByWstETH(1e36);
    }
}
