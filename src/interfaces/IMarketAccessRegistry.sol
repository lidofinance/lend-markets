// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

/// @title IMarketAccessRegistry
/// @notice Deployment-scoped access restriction registry for Lido Lending markets.
interface IMarketAccessRegistry {
    function addressBlocked(address user) external view returns (bool);

    function positionBlocked(Id id, address user) external view returns (bool);

    function isBlocked(Id id, address user) external view returns (bool);
}
