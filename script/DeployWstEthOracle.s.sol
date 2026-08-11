// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {WstEthRateOracle} from "../src/oracle/WstEthRateOracle.sol";

import {LidoLendPrimitives} from "./lib/LidoLendPrimitives.sol";
import {OracleConfigFile, WstEthOracleConfig} from "./lib/OracleConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";

/// @notice Deploys and records a proxied `WstEthRateOracle`.
contract DeployWstEthOracle is Script, LidoLendPrimitives {
    function run(string memory config, string memory name) external returns (address oracle) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        WstEthOracleConfig memory c = OracleConfigFile.readWstEth(name);
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: deployConfig.chainId,
            configHash: deployConfig.configHash
        });
        OracleConfigFile.requireUndeployed(name);

        vm.startBroadcast();
        address impl = address(new WstEthRateOracle(c.wstETH));
        oracle = _behindProxy(impl, deployConfig.agent, "");
        vm.stopBroadcast();

        console2.log("oracle          :", name);
        console2.log("  wstEthRateOracle :", oracle);
        console2.log("  recorded        :", OracleConfigFile.writeDeployed(name, oracle, metadata));
    }
}
