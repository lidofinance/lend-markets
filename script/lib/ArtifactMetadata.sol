// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

/// @notice Identity shared by every generated artifact belonging to one deployment operation.
struct ArtifactMetadata {
    string deployment;
    uint256 chainId;
    bytes32 configHash;
}

/// @notice TOML header writer and verifier for generated deployment artifacts.
library ArtifactMetadataFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactKindMismatch(string expected, string actual);
    error ArtifactChainIdMismatch(uint256 expected, uint256 actual);
    error ArtifactConfigHashMismatch(bytes32 expected, bytes32 actual);
    error ArtifactDeploymentMismatch(string expected, string actual);
    error InvalidArtifactsDir(string value);
    error DeploymentManifestMissing(string path);
    error InputSnapshotMismatch(string path);

    function header(ArtifactMetadata memory metadata, string memory kind) internal pure returns (string memory s) {
        s = "[artifact]\n";
        s = string.concat(s, "kind = \"", kind, "\"\n");
        s = string.concat(s, "deployment = \"", metadata.deployment, "\"\n");
        s = string.concat(s, "chain_id = ", vm.toString(metadata.chainId), "\n");
        s = string.concat(s, "config_hash = \"", vm.toString(metadata.configHash), "\"\n");
    }

    function requireMatch(string memory toml, ArtifactMetadata memory expected, string memory kind) internal view {
        requireKindChain(toml, kind, expected.chainId);

        bytes32 actualConfigHash = vm.parseTomlBytes32(toml, ".artifact.config_hash");
        if (actualConfigHash != expected.configHash) {
            revert ArtifactConfigHashMismatch(expected.configHash, actualConfigHash);
        }

        string memory actualDeployment = vm.parseTomlString(toml, ".artifact.deployment");
        if (keccak256(bytes(actualDeployment)) != keccak256(bytes(expected.deployment))) {
            revert ArtifactDeploymentMismatch(expected.deployment, actualDeployment);
        }
    }

    /// @notice Validate the metadata a registry consumer knows without having the run manifest locally.
    function requireKindChain(string memory toml, string memory kind, uint256 chainId) internal view {
        string memory actualKind = vm.parseTomlString(toml, ".artifact.kind");
        if (keccak256(bytes(actualKind)) != keccak256(bytes(kind))) revert ArtifactKindMismatch(kind, actualKind);

        uint256 actualChainId = vm.parseTomlUint(toml, ".artifact.chain_id");
        if (actualChainId != chainId) revert ArtifactChainIdMismatch(chainId, actualChainId);
    }

    /// @notice The run-local artifact directory. The env value is a single directory name below `deployed/`.
    function artifactsDir() internal view returns (string memory dir) {
        string memory name = vm.envString("ARTIFACTS_DIR");
        bytes memory raw = bytes(name);
        if (raw.length == 0) revert InvalidArtifactsDir(name);
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == "/" || raw[i] == "\\") revert InvalidArtifactsDir(name);
        }
        return string.concat("deployed/", name);
    }

    function ensureArtifactsDir() internal {
        string memory dir = artifactsDir();
        if (!vm.exists(dir)) vm.createDir(dir, false);
    }

    /// @notice The operator-selected directory name is the single identity of a deployment run.
    function deployment() internal view returns (string memory) {
        return vm.envString("ARTIFACTS_DIR");
    }

    function manifestPath() internal view returns (string memory) {
        return string.concat(artifactsDir(), "/manifest.toml");
    }

    /// @notice Establish the immutable metadata contract for a run, or verify the existing one.
    function ensureManifest(ArtifactMetadata memory metadata) internal {
        ensureArtifactsDir();
        string memory path = manifestPath();
        if (vm.exists(path)) {
            requireMatch(vm.readFile(path), metadata, "deployment-manifest");
            return;
        }
        vm.writeFile(path, string.concat(header(metadata, "deployment-manifest"), "\nschema_version = 1\n"));
    }

    function requireManifest(ArtifactMetadata memory metadata) internal view {
        string memory path = manifestPath();
        if (!vm.exists(path)) revert DeploymentManifestMissing(path);
        requireMatch(vm.readFile(path), metadata, "deployment-manifest");
    }

    /// @notice Preserve an exact config input once per run. A changed source file cannot silently replace it.
    function snapshotInput(string memory name, string memory sourcePath) internal {
        string memory source = vm.readFile(sourcePath);
        string memory inputsDir = string.concat(artifactsDir(), "/inputs");
        if (!vm.exists(inputsDir)) vm.createDir(inputsDir, false);
        string memory destination = string.concat(inputsDir, "/", name, ".toml");
        if (vm.exists(destination)) {
            if (keccak256(bytes(vm.readFile(destination))) != keccak256(bytes(source))) {
                revert InputSnapshotMismatch(destination);
            }
            return;
        }
        vm.writeFile(destination, source);
    }
}
