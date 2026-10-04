// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {LidoLendVaultAdapter} from "../src/adapters/LidoLendVaultAdapter.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {BundlerConfig, BundlerConfigFile} from "./lib/BundlerConfigFile.sol";
import {DeployConfig, DeployConfigFile} from "./lib/DeployConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";

/// @notice Deploys this run's own bundler stack — the stock `Bundler3` dispatcher, the vendored
///         `EthereumGeneralAdapter1` bound to the run's core, and the `LidoLendVaultAdapter`, the two adapters
///         bound to that dispatcher — and records them as `bundler.toml`. Both upstream contracts pin solc 0.8.28,
///         so they are created from their `out/` artifacts. Acceptance re-checks the adapters' immutables.
contract DeployBundler is Script {
    error ProtocolDeploymentMismatch(string expected, string actual);
    error RecordedNameMismatch(string expected, string actual);
    error RecordedMorphoMismatch(address expected, address actual);

    /// @param config The deploy config name (`script/config/<config>.toml`).
    /// @param bundlerName The bundler config name (`script/config/bundlers/<bundlerName>.toml`).
    function run(string memory config, string memory bundlerName)
        external
        returns (address bundler3, address generalAdapter, address vaultAdapter)
    {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);

        BundlerConfig memory cfg = BundlerConfigFile.read(bundlerName);
        BundlerConfigFile.requireUndeployed();

        ArtifactMetadata memory metadata = DeployConfigFile.artifactMetadata(deployConfig);
        string memory protocol = ArtifactMetadataFile.requireCompatible(ProtocolConfigFile.protocolPath(), metadata);
        DeployConfigFile.requireRegistryGovernance(deployConfig, protocol);
        DeployConfigFile.requireProtocolBackboneLive(protocol);
        address core = vm.parseTomlAddress(protocol, ".protocol.core");
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();
        bundler3 = vm.deployCode("Bundler3.sol:Bundler3");
        generalAdapter = vm.deployCode(
            "EthereumGeneralAdapter1.sol:EthereumGeneralAdapter1", abi.encode(bundler3, core, cfg.weth, cfg.wsteth)
        );
        vaultAdapter = address(new LidoLendVaultAdapter(bundler3));
        vm.stopBroadcast();

        console2.log("bundler :", bundlerName);
        console2.log("  bundler3        :", bundler3);
        console2.log("  general adapter :", generalAdapter);
        console2.log("  vault adapter   :", vaultAdapter);
        console2.log("  morpho          :", core);
        console2.log(
            "  recorded        :",
            BundlerConfigFile.write(
                bundlerName, cfg, bundler3, generalAdapter, vaultAdapter, core, deployedBlock, metadata
            )
        );
    }

    /// @notice Validates the immutable artifact before an explorer verification retry.
    /// @dev No RPC state is needed: the verification command independently selects the artifact's recorded chain.
    function validateArtifacts(string memory bundlerName) external view {
        _validateArtifacts(ArtifactMetadataFile.deployment(), bundlerName);
    }

    function _validateArtifacts(string memory deployment, string memory bundlerName) internal view {
        string memory artifactsDir = ArtifactMetadataFile.artifactsDir(deployment);
        string memory protocolPath = string.concat(artifactsDir, "/protocol.toml");
        string memory protocol = vm.readFile(protocolPath);
        string memory recordedDeployment = vm.parseTomlString(protocol, ".protocol.deployment");
        if (keccak256(bytes(recordedDeployment)) != keccak256(bytes(deployment))) {
            revert ProtocolDeploymentMismatch(deployment, recordedDeployment);
        }
        DeployConfigFile.requireProtocolArtifactCompatibility(protocol);

        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: deployment,
            chainId: vm.parseTomlUint(protocol, ".protocol.chain_id"),
            configHash: vm.parseTomlBytes32(protocol, ".protocol.config_hash"),
            compatibilityHash: vm.parseTomlBytes32(protocol, ".artifact.compatibility_hash")
        });
        protocol = ArtifactMetadataFile.requireExact(protocolPath, metadata);

        string memory artifact =
            ArtifactMetadataFile.requireCompatible(string.concat(artifactsDir, "/bundler.toml"), metadata);
        string memory recordedName = vm.parseTomlString(artifact, ".bundler.name");
        if (keccak256(bytes(recordedName)) != keccak256(bytes(bundlerName))) {
            revert RecordedNameMismatch(bundlerName, recordedName);
        }

        address core = vm.parseTomlAddress(protocol, ".protocol.core");
        address recordedMorpho = vm.parseTomlAddress(artifact, ".bundler.morpho");
        if (recordedMorpho != core) revert RecordedMorphoMismatch(core, recordedMorpho);
    }
}
