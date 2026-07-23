// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LinearKinkIrm} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkIrm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";

/// @notice Deploys the optional bare `LinearKinkIrm` and records it in the current deployment run.
/// @dev This does not add the IRM to the protocol registry or route any market to it.
contract DeployLinearKinkIrm is Script {
    error ArtifactAlreadyExists(string path);

    function run(string memory config) external returns (address irm) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: deployConfig.chainId,
            configHash: deployConfig.configHash
        });
        string memory path = _artifactPath();
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);

        ArtifactMetadataFile.snapshotInput("deploy", DeployConfigFile.configPath(config));

        vm.startBroadcast();
        irm = address(new LinearKinkIrm(deployConfig.agent, deployConfig.evmScriptExecutor));
        vm.stopBroadcast();

        string memory artifact = ArtifactMetadataFile.header(metadata, "linear-kink-irm");
        artifact = string.concat(artifact, "\n[irm]\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(irm), "\"\n");
        artifact = string.concat(artifact, "owner = \"", vm.toString(deployConfig.agent), "\"\n");
        artifact = string.concat(artifact, "manager = \"", vm.toString(deployConfig.evmScriptExecutor), "\"\n");
        vm.writeFile(path, artifact);

        console2.log("linearKinkIrm :", irm);
        console2.log("  owner       :", deployConfig.agent);
        console2.log("  manager     :", deployConfig.evmScriptExecutor);
        console2.log("  recorded    :", path);
    }

    function _artifactPath() private view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/linear-kink-irm.toml");
    }
}
