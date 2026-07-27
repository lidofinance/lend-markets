// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";
import {ConfigToml} from "./ConfigToml.sol";

/// @param owner The vault's initial owner, i.e. the account that appoints its curator.
/// @param asset The vault's ERC-20 asset. Must be the loan token of every market it allocates into.
struct VaultV2Config {
    address owner;
    address asset;
}

/// @param vaultArtifact The `vaults/<name>` this adapter's parent vault is recorded as. The adapter's parent
///        vault is immutable, so the pairing is fixed at deploy time and asserted against it.
struct VaultV2AdapterConfig {
    string vaultArtifact;
}

/// @notice Configs and run artifacts for an external vault-v2 vault and its Morpho adapter. The two are one
///         deploy operation (the adapter's parent vault is a constructor immutable) but keep separate configs
///         and artifacts, so several adapters can sit over different vaults in one run.
/// @dev The adapter takes no economic inputs of its own: besides its parent vault, its immutables are the
///      protocol core and IRM router, which the deploy reads from the run's `protocol.toml`. Its config
///      therefore carries only the parent-vault reference — deliberately thin, so the pairing is stated in a
///      committed file rather than inferred from the invocation.
library VaultV2ConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactAlreadyExists(string path);
    error VaultArtifactMismatch(string expected, string actual);

    // ---
    // CONFIG
    // ---

    function readVault(string memory name) internal view returns (VaultV2Config memory cfg) {
        string memory toml = vm.readFile(vaultConfigPath(name));
        cfg.owner = ConfigToml.requireAddress(toml, ".owner");
        cfg.asset = ConfigToml.requireAddress(toml, ".asset");
    }

    function readAdapter(string memory name) internal view returns (VaultV2AdapterConfig memory cfg) {
        string memory toml = vm.readFile(adapterConfigPath(name));
        cfg.vaultArtifact = ConfigToml.requireString(toml, ".vault_artifact");
    }

    /// @notice Assert the adapter config's declared parent vault is the vault being deployed with it.
    function requireVaultArtifact(VaultV2AdapterConfig memory cfg, string memory vaultName) internal pure {
        if (keccak256(bytes(cfg.vaultArtifact)) != keccak256(bytes(vaultName))) {
            revert VaultArtifactMismatch(cfg.vaultArtifact, vaultName);
        }
    }

    function vaultConfigPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/vaults/", name, ".toml");
    }

    function adapterConfigPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/adapters/", name, ".toml");
    }

    // ---
    // ARTIFACTS
    // ---

    function writeVault(string memory name, address vault, VaultV2Config memory cfg, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        path = _prepare("vaults", vaultDeployedPath(name));

        string memory artifact = ArtifactMetadataFile.header(metadata, "vault-v2");
        artifact = string.concat(artifact, "\n[vault]\n");
        artifact = string.concat(artifact, "name = \"", name, "\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(vault), "\"\n");
        artifact = string.concat(artifact, "owner = \"", vm.toString(cfg.owner), "\"\n");
        artifact = string.concat(artifact, "asset = \"", vm.toString(cfg.asset), "\"\n");
        artifact = string.concat(artifact, "deployed_block = ", vm.toString(block.number), "\n");
        vm.writeFile(path, artifact);
    }

    /// @param vaultArtifact The `vaults/<name>` holding `vault`.
    /// @param core The protocol core the adapter allocates into (its `morpho` immutable).
    /// @param irmRouter The protocol IRM router (its `adaptiveCurveIrm` immutable — every market's `params.irm`).
    function writeAdapter(
        string memory name,
        address adapter,
        string memory vaultArtifact,
        address vault,
        address core,
        address irmRouter,
        ArtifactMetadata memory metadata
    ) internal returns (string memory path) {
        path = _prepare("adapters", adapterDeployedPath(name));

        string memory artifact = ArtifactMetadataFile.header(metadata, "vault-v2-adapter");
        artifact = string.concat(artifact, "\n[adapter]\n");
        artifact = string.concat(artifact, "name = \"", name, "\"\n");
        artifact = string.concat(artifact, "kind = \"morpho-market-v1\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(adapter), "\"\n");
        artifact = string.concat(artifact, "vault_artifact = \"", vaultArtifact, "\"\n");
        artifact = string.concat(artifact, "vault = \"", vm.toString(vault), "\"\n");
        artifact = string.concat(artifact, "morpho = \"", vm.toString(core), "\"\n");
        artifact = string.concat(artifact, "adaptive_curve_irm = \"", vm.toString(irmRouter), "\"\n");
        artifact = string.concat(artifact, "deployed_block = ", vm.toString(block.number), "\n");
        vm.writeFile(path, artifact);
    }

    function requireUndeployed(string memory vaultName, string memory adapterName) internal view {
        string memory vaultPath = vaultDeployedPath(vaultName);
        if (vm.exists(vaultPath)) revert ArtifactAlreadyExists(vaultPath);
        string memory adapterPath = adapterDeployedPath(adapterName);
        if (vm.exists(adapterPath)) revert ArtifactAlreadyExists(adapterPath);
    }

    function readDeployedVault(string memory name) internal view returns (address) {
        string memory path = vaultDeployedPath(name);
        if (!vm.exists(path)) return address(0);
        return vm.parseTomlAddress(vm.readFile(path), ".vault.address");
    }

    function readDeployedAdapter(string memory name) internal view returns (address) {
        string memory path = adapterDeployedPath(name);
        if (!vm.exists(path)) return address(0);
        return vm.parseTomlAddress(vm.readFile(path), ".adapter.address");
    }

    function vaultDeployedPath(string memory name) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/vaults/", name, ".toml");
    }

    function adapterDeployedPath(string memory name) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/adapters/", name, ".toml");
    }

    /// @dev Create the artifact subdirectory and refuse to replace an existing record.
    function _prepare(string memory subdir, string memory path) private returns (string memory) {
        ArtifactMetadataFile.ensureArtifactsDir();
        string memory dir = string.concat(ArtifactMetadataFile.artifactsDir(), "/", subdir);
        if (!vm.exists(dir)) vm.createDir(dir, false);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
        return path;
    }
}
