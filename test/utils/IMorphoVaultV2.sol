// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @dev Test-only ABI subset for the deployed Morpho Vault V2 factory and its vaults.
interface IMorphoVaultV2Factory {
    function createVaultV2(address owner, address asset, bytes32 salt) external returns (address vault);
    function isVaultV2(address vault) external view returns (bool);
}

interface IMorphoVaultV2 is IERC4626 {
    function owner() external view returns (address);
    function curator() external view returns (address);
    function isSentinel(address account) external view returns (bool);
    function isAdapter(address account) external view returns (bool);
    function adaptersLength() external view returns (uint256);
    function absoluteCap(bytes32 id) external view returns (uint256);
    function relativeCap(bytes32 id) external view returns (uint256);
    function allocation(bytes32 id) external view returns (uint256);
    function firstTotalAssets() external view returns (uint256);
    function _totalAssets() external view returns (uint128);
    function lastUpdate() external view returns (uint64);
    function maxRate() external view returns (uint64);
    function virtualShares() external view returns (uint256);
    function setCurator(address curator) external;
    function setIsSentinel(address account, bool enabled) external;
    function multicall(bytes[] calldata data) external;
    function submit(bytes memory data) external;
    function setIsAllocator(address account, bool enabled) external;
    function addAdapter(address adapter) external;
    function removeAdapter(address adapter) external;
    function increaseAbsoluteCap(bytes memory idData, uint256 cap) external;
    function increaseRelativeCap(bytes memory idData, uint256 cap) external;
    function decreaseAbsoluteCap(bytes memory idData, uint256 cap) external;
    function decreaseRelativeCap(bytes memory idData, uint256 cap) external;
    function setPerformanceFee(uint256 fee) external;
    function setManagementFee(uint256 fee) external;
    function setPerformanceFeeRecipient(address recipient) external;
    function setManagementFeeRecipient(address recipient) external;
    function setForceDeallocatePenalty(address adapter, uint256 penalty) external;
    function setMaxRate(uint256 maxRate) external;
    function setLiquidityAdapterAndData(address adapter, bytes memory data) external;
    function allocate(address adapter, bytes memory data, uint256 assets) external;
    function deallocate(address adapter, bytes memory data, uint256 assets) external;
    function accrueInterest() external;
    function accrueInterestView()
        external
        view
        returns (uint256 totalAssets, uint256 performanceShares, uint256 managementShares);
    function forceDeallocate(address adapter, bytes memory data, uint256 assets, address onBehalf)
        external
        returns (uint256 penaltyShares);
}

interface IMorphoVaultV2Adapter {
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);
    function realAssets() external view returns (uint256 assets);
}
