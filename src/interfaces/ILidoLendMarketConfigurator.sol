// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";

/// @title ILidoLendMarketConfigurator
/// @notice Configuration surface of a Lido market controller: read and replace its collateral-activation
///         config, and revoke instant activation. The implementation validates the written config and gates
///         access.
interface ILidoLendMarketConfigurator {
    /// @notice The market's current collateral-activation config.
    function collateralActivationConfig() external view returns (CollateralActivationConfig memory);

    /// @notice Replace the collateral-activation config.
    function setCollateralActivationConfig(CollateralActivationConfig calldata cfg) external;

    /// @notice Remove a caller's instant activation, restoring the timer for its supplies.
    function revokeInstantActivation(address caller) external;
}
