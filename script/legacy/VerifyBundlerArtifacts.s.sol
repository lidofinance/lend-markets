// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "./lib/DeployConfigFile.sol";

contract VerifyBundlerArtifacts is Script {
    error ProtocolDeploymentMismatch(string expected, string actual);
    error RecordedNameMismatch(string expected, string actual);
    error RecordedMorphoMismatch(address expected, address actual);

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
