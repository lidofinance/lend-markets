// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {LidoLendVaultAdapter} from "../../src/adapters/LidoLendVaultAdapter.sol";
import {ProtocolAddresses} from "../lib/ProtocolDeployer.sol";
import {RecordedProtocol} from "../lib/RecordedProtocol.sol";

struct BundlerParameters {
    address weth;
    address wstEth;
}

struct BundlerAddresses {
    address bundler;
    address generalAdapter;
    address vaultAdapter;
}

/// @notice Deploys the bundler and its adapters over the network's protocol. A network's bundler script overrides
///         `getConfig()` and, once the bundler is deployed, `getDeployment()`; this contract does the rest. `run()`
///         deploys inside a broadcast; `getOrDeploy` is the bundler over a protocol.
abstract contract DeployBundlerBase is Script {
    /// @notice `getDeployment()` gives a deployed bundler.
    error AlreadyDeployed();
    /// @notice The recorded bundler has no code on the chain in use, such as a fork from before its deployment.
    error MissingCode(address account);

    /// @notice The tokens the general adapter wraps: WETH, and wstETH, whose `stETH()` is the adapter's stETH.
    function getConfig() public pure virtual returns (BundlerParameters memory);

    /// @notice The deployed bundler, written by hand; empty until it is deployed.
    function getDeployment() internal pure virtual returns (BundlerAddresses memory) {}

    function run() external returns (BundlerAddresses memory deployed) {
        if (getDeployment().bundler != address(0)) revert AlreadyDeployed();
        ProtocolAddresses memory p = RecordedProtocol.current();
        vm.startBroadcast();
        deployed = _deployBundler(p, getConfig());
        vm.stopBroadcast();
    }

    /// @notice The bundler: the one that `getDeployment()` gives, which must have code, else a new one over `p`,
    ///         without the broadcast.
    function getOrDeploy(ProtocolAddresses memory p) external returns (BundlerAddresses memory d) {
        d = getDeployment();
        if (d.bundler == address(0)) return _deployBundler(p, getConfig());
        if (d.bundler.code.length == 0) revert MissingCode(d.bundler);
    }

    function _deployBundler(ProtocolAddresses memory p, BundlerParameters memory parameters)
        private
        returns (BundlerAddresses memory d)
    {
        require(block.chainid == p.chainId, "Wrong bundler chain");
        require(p.core.code.length != 0, "Missing bundler protocol");
        require(parameters.weth.code.length != 0 && parameters.wstEth.code.length != 0, "Missing bundler token");
        // The upstream dependencies pin a different compiler from the lending contracts.
        d.bundler = vm.deployCode("Bundler3.sol:Bundler3");
        d.generalAdapter = vm.deployCode(
            "EthereumGeneralAdapter1.sol:EthereumGeneralAdapter1",
            abi.encode(d.bundler, p.core, parameters.weth, parameters.wstEth)
        );
        d.vaultAdapter = address(new LidoLendVaultAdapter(d.bundler));
    }
}
