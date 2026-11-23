// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "./TrailingAnchorOracleBase.sol";

interface IOndoPriceGetter {
    /// @notice USDY redemption value in USD, with 18 decimals.
    function getPrice() external view returns (uint256);
}

/// @title UsdyNavOracle
/// @author Lido
/// @notice NAV oracle for USDY. It reads the price from the price getter of Ondo.
contract UsdyNavOracle layout at erc7201("lido.lend.storage.UsdyNavOracle") is TrailingAnchorOracleBase {
    // ---
    // IMMUTABLES
    // ---

    /// @notice Price getter of Ondo for USDY.
    IOndoPriceGetter public immutable SOURCE;

    // ---
    // CONSTRUCTOR
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address source, address loanToken, address collateralToken)
        TrailingAnchorOracleBase(loanToken, collateralToken)
    {
        if (source == address(0)) revert ZeroAddress();
        SOURCE = IOndoPriceGetter(source);
    }

    // ---
    // OVERRIDES
    // ---

    /// @inheritdoc TrailingAnchorOracleBase
    function _currentPrice() internal view override returns (uint256 currentPrice) {
        return SOURCE.getPrice();
    }
}
