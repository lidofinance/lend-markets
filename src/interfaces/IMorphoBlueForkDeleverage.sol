// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";

/// @notice Fork-added single-borrower deleverage primitive on the core. Not part of upstream
///         `IMorpho`; lives here so wrappers can cast core to a typed surface.
interface IMorphoBlueForkDeleverage {
    function deleverage(
        MarketParams memory marketParams,
        uint256 supplyShares,
        address borrower,
        address lender,
        address receiver
    ) external returns (uint256 collateralSeized, uint256 debtCanceled);
}
