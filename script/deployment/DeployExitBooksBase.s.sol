// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {ExitBookAddresses, ExitBooksConfig, ProtocolAddresses, ProtocolDeployer} from "../lib/ProtocolDeployer.sol";
import {RecordedProtocol} from "../lib/RecordedProtocol.sol";

/// @notice Deploys the exit books over a protocol. A network's exit books script overrides `getConfig()` and, once the
///         books are deployed, `getDeployment()` with their addresses; this contract does the rest. `run()` deploys
///         over the network's protocol inside a broadcast; `getOrDeploy` is the books over a protocol.
abstract contract DeployExitBooksBase is Script, ProtocolDeployer {
    /// @notice `getDeployment()` gives deployed books.
    error AlreadyDeployed();
    error CoreNotContract(address core);
    error MissingGovernanceActor();
    /// @notice The recorded books have no code on the chain in use, such as a fork from before their deployment.
    error MissingCode(address account);

    /// @notice The books' deploy inputs.
    function getConfig() public pure virtual returns (ExitBooksConfig memory);

    /// @notice The deployed books, written by hand; empty until they are deployed.
    function getDeployment() internal pure virtual returns (ExitBookAddresses memory) {}

    function run() external returns (ExitBookAddresses memory books) {
        if (getDeployment().morpho != address(0)) revert AlreadyDeployed();
        ProtocolAddresses memory p = RecordedProtocol.current();
        vm.startBroadcast();
        books = _deploy(p, msg.sender);
        vm.stopBroadcast();
    }

    /// @notice The books: the ones that `getDeployment()` gives, which must have code, else new ones over `p`, without
    ///         the broadcast.
    function getOrDeploy(ProtocolAddresses memory p) external returns (ExitBookAddresses memory books) {
        books = getDeployment();
        if (books.morpho == address(0)) return _deploy(p, address(this));
        if (books.morpho.code.length == 0) revert MissingCode(books.morpho);
    }

    function _deploy(ProtocolAddresses memory p, address deployer) private returns (ExitBookAddresses memory) {
        _requireChainId(p.chainId);
        if (p.core.code.length == 0) revert CoreNotContract(p.core);
        if (p.agent == address(0) || p.executor == address(0)) revert MissingGovernanceActor();
        return _deployExitBooks(p, getConfig(), deployer);
    }
}
