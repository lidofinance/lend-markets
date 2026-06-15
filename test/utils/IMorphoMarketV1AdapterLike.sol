// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev Minimal surface of `MorphoMarketV1AdapterV2` that our integration tests touch. Local
///      interface so the test file can stay on a different solc version than the adapter's strict
///      0.8.28 pin (the adapter is deployed via `vm.deployCode`, never typed-imported).
interface IMorphoMarketV1AdapterLike {
    function expectedSupplyAssets(bytes32 marketId) external view returns (uint256);
}
