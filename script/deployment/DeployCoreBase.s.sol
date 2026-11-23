// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CoreConfig, ProtocolAddresses, ProtocolDeployer} from "../lib/ProtocolDeployer.sol";

/// @notice Deploys a protocol with its CircuitBreaker. A network's core script overrides `getConfig()` and, once the
///         protocol is deployed, `getDeployment()` with its addresses; this contract does the rest. `run()` deploys
///         inside a broadcast and reuses a CircuitBreaker that `getDeployment()` gives; `getOrDeploy()` is the
///         protocol.
abstract contract DeployCoreBase is Script, ProtocolDeployer {
    /// @notice `getDeployment()` gives a deployed protocol.
    error AlreadyDeployed();
    /// @notice A script outside a test asks for a protocol that is not deployed.
    error ProtocolNotDeployed();
    /// @notice The recorded core has no code on the chain in use, such as a fork from before its deployment.
    error MissingCode(address account);

    /// @notice The protocol's deploy inputs.
    function getConfig() public pure virtual returns (CoreConfig memory);

    /// @notice The deployed protocol, written by hand; empty until it is deployed, except a CircuitBreaker to reuse.
    function getDeployment() internal pure virtual returns (ProtocolAddresses memory) {}

    function run() external returns (ProtocolAddresses memory p) {
        if (getDeployment().core != address(0)) revert AlreadyDeployed();
        vm.startBroadcast();
        p = _deployProtocol(getConfig(), getDeployment().circuitBreaker, msg.sender);
        vm.stopBroadcast();
    }

    /// @notice The protocol: the one that `getDeployment()` gives, which must have code, else, only in a test, a new
    ///         protocol and CircuitBreaker from `getConfig()`, without a broadcast.
    function getOrDeploy() external returns (ProtocolAddresses memory p) {
        p = getDeployment();
        if (p.core != address(0)) {
            if (p.core.code.length == 0) revert MissingCode(p.core);
            return p;
        }
        if (!vm.isContext(VmSafe.ForgeContext.TestGroup)) revert ProtocolNotDeployed();
        p = _deployProtocol(getConfig(), address(0), address(this));
    }
}
