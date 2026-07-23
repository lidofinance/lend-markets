// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {WstEthRateOracle} from "../src/oracle/WstEthRateOracle.sol";

import {LidoLendPrimitives} from "./lib/LidoLendPrimitives.sol";
import {OracleConfigFile, WstEthOracleConfig} from "./lib/OracleConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";

/// @notice Deploys a standalone `WstEthRateOracle` behind an `OssifiableProxy`, recording its address to
///         `deployed/oracle-<name>.toml` for a market to resolve.
/// @dev Draft, not production-ready. `ORACLE` selects `script/config/oracles/<name>.toml`.
///
/// Usage:
///   forge script script/DeployWstEthOracle.s.sol --sig "run(string,string)" mainnet weth-wsteth --rpc-url "$RPC_URL"
/// --broadcast
contract DeployWstEthOracle is Script, LidoLendPrimitives {
    error UnexpectedProxyAdmin(address expected, address actual);

    function run(string memory config, string memory name) external returns (address oracle) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        WstEthOracleConfig memory c = OracleConfigFile.readWstEth(name);
        if (c.proxyAdmin != deployConfig.agent) revert UnexpectedProxyAdmin(deployConfig.agent, c.proxyAdmin);
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: deployConfig.chainId,
            configHash: deployConfig.configHash
        });
        ArtifactMetadataFile.ensureManifest(metadata);
        ArtifactMetadataFile.snapshotInput("deploy", DeployConfigFile.configPath(config));
        ArtifactMetadataFile.snapshotInput(string.concat("oracle-", name), OracleConfigFile.configPath(name));
        OracleConfigFile.requireUndeployed(name, metadata);

        vm.startBroadcast();
        address impl = address(new WstEthRateOracle(c.wstETH));
        oracle = _behindProxy(impl, c.proxyAdmin, "");
        vm.stopBroadcast();

        console2.log("oracle          :", name);
        console2.log("  wstEthRateOracle :", oracle);
        console2.log("  recorded        :", OracleConfigFile.writeDeployed(name, oracle, metadata));
    }
}
