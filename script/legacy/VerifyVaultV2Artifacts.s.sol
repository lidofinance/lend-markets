// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "./lib/DeployConfigFile.sol";

/// @notice Read-only compatibility validation for historical TOML artifacts.
contract VerifyVaultV2Artifacts is Script {
    error AdapterCoreMismatch(address expected, address actual);
    error AdapterIrmRouterMismatch(address expected, address actual);
    error AdapterVaultMismatch(address expected, address actual);
    error ProtocolDeploymentMismatch(string expected, string actual);
    error RecordedNameMismatch(string expected, string actual);

    /// @notice Validates the immutable artifact pair before an explorer verification retry.
    /// @dev No RPC state is needed: the verification command independently selects the artifact's recorded chain.
    function validateArtifacts(string memory vaultName, string memory adapterName) external view {
        _validateArtifacts(ArtifactMetadataFile.deployment(), vaultName, adapterName);
    }

    function _validateArtifacts(string memory deployment, string memory vaultName, string memory adapterName)
        internal
        view
    {
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

        string memory vaultArtifact = ArtifactMetadataFile.requireCompatible(
            string.concat(artifactsDir, "/vaults/", vaultName, ".toml"), metadata
        );
        string memory adapterArtifact = ArtifactMetadataFile.requireCompatible(
            string.concat(artifactsDir, "/adapters/", adapterName, ".toml"), metadata
        );

        _requireRecordedName(vaultName, vm.parseTomlString(vaultArtifact, ".vault.name"));
        _requireRecordedName(adapterName, vm.parseTomlString(adapterArtifact, ".adapter.name"));
        _requireRecordedName(vaultName, vm.parseTomlString(adapterArtifact, ".adapter.vault_artifact"));

        address vault = vm.parseTomlAddress(vaultArtifact, ".vault.address");
        address adapterVault = vm.parseTomlAddress(adapterArtifact, ".adapter.vault");
        if (adapterVault != vault) revert AdapterVaultMismatch(vault, adapterVault);

        address core = vm.parseTomlAddress(protocol, ".protocol.core");
        address adapterCore = vm.parseTomlAddress(adapterArtifact, ".adapter.morpho");
        if (adapterCore != core) revert AdapterCoreMismatch(core, adapterCore);

        address irmRouter = vm.parseTomlAddress(protocol, ".protocol.irm_router");
        address adapterIrmRouter = vm.parseTomlAddress(adapterArtifact, ".adapter.adaptive_curve_irm");
        if (adapterIrmRouter != irmRouter) revert AdapterIrmRouterMismatch(irmRouter, adapterIrmRouter);
    }

    function _requireRecordedName(string memory expected, string memory actual) private pure {
        if (keccak256(bytes(actual)) != keccak256(bytes(expected))) revert RecordedNameMismatch(expected, actual);
    }
}
