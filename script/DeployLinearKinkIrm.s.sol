// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LinearKinkIrm} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkIrm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {IrmConfigFile} from "./lib/IrmConfigFile.sol";

/// @notice Deploys a bare `LinearKinkIrm` and records it as `deployed/<RUN>/irms/<name>.toml`.
/// @dev This neither routes any market to the instance nor sets per-market kink params: both are activation
///      calldata. A market opts in by naming this artifact in `market.irm_artifact`.
contract DeployLinearKinkIrm is Script {
    /// @param config The deploy config name (`script/config/<config>.toml`).
    /// @param name The artifact name markets reference as `market.irm_artifact`, e.g. `"linear-kink"`.
    function run(string memory config, string memory name) external returns (address irm) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: deployConfig.chainId,
            configHash: deployConfig.configHash
        });
        IrmConfigFile.requireUndeployed(name);

        vm.startBroadcast();
        irm = address(new LinearKinkIrm(deployConfig.agent, deployConfig.evmScriptExecutor));
        vm.stopBroadcast();

        string memory path = IrmConfigFile.writeDeployed(
            name, "linear-kink", irm, deployConfig.agent, deployConfig.evmScriptExecutor, metadata
        );

        console2.log("linearKinkIrm :", irm);
        console2.log("  artifact    :", name);
        console2.log("  owner       :", deployConfig.agent);
        console2.log("  manager     :", deployConfig.evmScriptExecutor);
        console2.log("  recorded    :", path);
    }
}
