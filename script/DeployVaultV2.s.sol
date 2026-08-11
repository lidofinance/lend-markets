// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfig, DeployConfigFile} from "./lib/DeployConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";
import {VaultV2Config, VaultV2AdapterConfig, VaultV2ConfigFile} from "./lib/VaultV2ConfigFile.sol";

/// @notice Deploys an external vault-v2 vault together with its Morpho adapter over this run's protocol, and
///         records them as `vaults/<vaultName>.toml` + `adapters/<adapterName>.toml`.
/// @dev The adapter's parent vault is a constructor immutable, so both are created in one broadcast. Neither
///      is configured here: curator, adapter registration and caps are owner calls, not deployment inputs.
///      Both contracts pin solc 0.8.28 and are deployed from their `out/` artifacts via `vm.deployCode`.
contract DeployVaultV2 is Script {
    error AdapterCoreMismatch(address expected, address actual);
    error AdapterIrmRouterMismatch(address expected, address actual);
    error AdapterVaultMismatch(address expected, address actual);
    error DeployFailed(string what);
    error ProtocolDeploymentMismatch(string expected, string actual);
    error ProtocolIrmRouterNotContract(address irmRouter);
    error RecordedNameMismatch(string expected, string actual);

    /// @param config The deploy config name (`script/config/<config>.toml`).
    function run(string memory config, string memory vaultName, string memory adapterName)
        external
        returns (address vault, address adapter)
    {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);

        VaultV2Config memory vaultCfg = VaultV2ConfigFile.readVault(vaultName);
        VaultV2AdapterConfig memory adapterCfg = VaultV2ConfigFile.readAdapter(adapterName);
        VaultV2ConfigFile.requireVaultArtifact(adapterCfg, vaultName);
        VaultV2ConfigFile.requireUndeployed(vaultName, adapterName);

        ArtifactMetadata memory metadata = DeployConfigFile.artifactMetadata(deployConfig);
        string memory protocol = ArtifactMetadataFile.requireCompatible(ProtocolConfigFile.protocolPath(), metadata);
        DeployConfigFile.requireRegistryGovernance(deployConfig, protocol);
        DeployConfigFile.requireProtocolBackboneLive(protocol);
        (address core, address irmRouter) = _requireAdapterTargets(protocol);

        vm.startBroadcast();
        vault = vm.deployCode("VaultV2.sol:VaultV2", abi.encode(vaultCfg.owner, vaultCfg.asset));
        adapter =
            vm.deployCode("MorphoMarketV1AdapterV2.sol:MorphoMarketV1AdapterV2", abi.encode(vault, core, irmRouter));
        vm.stopBroadcast();

        if (vault.code.length == 0) revert DeployFailed("VaultV2");
        if (adapter.code.length == 0) revert DeployFailed("MorphoMarketV1AdapterV2");

        console2.log("vaultV2 :", vaultName);
        console2.log("  address   :", vault);
        console2.log("  owner     :", vaultCfg.owner);
        console2.log("  asset     :", vaultCfg.asset);
        console2.log("  recorded  :", VaultV2ConfigFile.writeVault(vaultName, vault, vaultCfg, metadata));
        console2.log("adapter :", adapterName);
        console2.log("  address   :", adapter);
        console2.log("  morpho    :", core);
        console2.log("  irmRouter :", irmRouter);
        console2.log(
            "  recorded  :",
            VaultV2ConfigFile.writeAdapter(adapterName, adapter, vaultName, vault, core, irmRouter, metadata)
        );
    }

    function _requireAdapterTargets(string memory protocol) internal view returns (address core, address irmRouter) {
        core = vm.parseTomlAddress(protocol, ".protocol.core");
        irmRouter = vm.parseTomlAddress(protocol, ".protocol.irm_router");
        if (irmRouter.code.length == 0) revert ProtocolIrmRouterNotContract(irmRouter);
    }

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
