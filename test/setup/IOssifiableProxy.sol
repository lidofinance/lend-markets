// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Admin surface of `OssifiableProxy`. Paired with each proxied contract's typed handle in
///         `Protocol`, so a test reaches both the implementation's methods (typed handle) and the proxy's
///         admin methods (this handle) at one address.
interface IOssifiableProxy {
    function proxy__ossify() external;
    function proxy__changeAdmin(address newAdmin) external;
    function proxy__upgradeTo(address newImplementation) external;
    function proxy__upgradeToAndCall(address newImplementation, bytes calldata setupCalldata) external;
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
    function proxy__getIsOssified() external view returns (bool);
}
