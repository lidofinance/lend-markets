// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

import {IMarketController} from "../../src/interfaces/IMarketController.sol";

/// @notice Minimal admin surface used by scenario tests to configure the controller's deleverage
///         policy under the CONFIGURATOR role. The real controller inherits these from
///         AccessControlUpgradeable + LidoMarketController; this is the smallest typed slice
///         needed by tests so each scenario doesn't re-declare it.
interface IControllerAdmin {
    function CONFIGURATOR_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function setDeleverageConfig(Id id, IMarketController.DeleverageConfig calldata cfg) external;
}
