// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

struct ArtifactMetadata {
    string deployment;
    uint256 chainId;
    bytes32 configHash;
    bytes32 compatibilityHash;
}

library ArtifactMetadataFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactChainIdMismatch(string path, uint256 expected, uint256 actual);
    error ArtifactCompatibilityHashMismatch(string path, bytes32 expected, bytes32 actual);
    error ArtifactConfigHashMissing(string path);
    error ArtifactConfigHashMismatch(string path, bytes32 expected, bytes32 actual);
    error ArtifactDeploymentMismatch(string path, string expected, string actual);
    error InvalidArtifactsDir(string value);

    function header(ArtifactMetadata memory metadata, string memory kind) internal pure returns (string memory s) {
        s = "[artifact]\n";
        s = string.concat(s, "kind = \"", kind, "\"\n");
        s = string.concat(s, "deployment = \"", metadata.deployment, "\"\n");
        s = string.concat(s, "chain_id = ", vm.toString(metadata.chainId), "\n");
        s = string.concat(s, "config_hash = \"", vm.toString(metadata.configHash), "\"\n");
        s = string.concat(s, "compatibility_hash = \"", vm.toString(metadata.compatibilityHash), "\"\n");
    }

    function requireCompatible(string memory path, ArtifactMetadata memory expected)
        internal
        view
        returns (string memory artifact)
    {
        artifact = vm.readFile(path);

        string memory artifactDeployment = vm.parseTomlString(artifact, ".artifact.deployment");
        if (keccak256(bytes(artifactDeployment)) != keccak256(bytes(expected.deployment))) {
            revert ArtifactDeploymentMismatch(path, expected.deployment, artifactDeployment);
        }

        uint256 chainId = vm.parseTomlUint(artifact, ".artifact.chain_id");
        if (chainId != expected.chainId) revert ArtifactChainIdMismatch(path, expected.chainId, chainId);

        if (!vm.keyExistsToml(artifact, ".artifact.config_hash")) revert ArtifactConfigHashMissing(path);
        vm.parseTomlBytes32(artifact, ".artifact.config_hash");

        bytes32 compatibilityHash = vm.parseTomlBytes32(artifact, ".artifact.compatibility_hash");
        if (compatibilityHash != expected.compatibilityHash) {
            revert ArtifactCompatibilityHashMismatch(path, expected.compatibilityHash, compatibilityHash);
        }
    }

    function requireExact(string memory path, ArtifactMetadata memory expected)
        internal
        view
        returns (string memory artifact)
    {
        artifact = requireCompatible(path, expected);

        bytes32 configHash = vm.parseTomlBytes32(artifact, ".artifact.config_hash");
        if (configHash != expected.configHash) {
            revert ArtifactConfigHashMismatch(path, expected.configHash, configHash);
        }
    }

    function requireRunResourcesCompatible(ArtifactMetadata memory expected) internal view {
        string memory dir = artifactsDir(expected.deployment);
        _requireDirectoryCompatible(string.concat(dir, "/oracles"), expected);
        _requireDirectoryCompatible(string.concat(dir, "/guardians"), expected);
        _requireDirectoryCompatible(string.concat(dir, "/circuit-breakers"), expected);
        _requireDirectoryCompatible(string.concat(dir, "/vaults"), expected);
        _requireDirectoryCompatible(string.concat(dir, "/adapters"), expected);
        _requireDirectoryCompatible(string.concat(dir, "/markets"), expected);

        string memory exitBooks = string.concat(dir, "/exit-books.toml");
        if (vm.exists(exitBooks)) requireCompatible(exitBooks, expected);
    }

    /// @dev `ARTIFACTS_DIR` must be one directory name below `deployed/`.
    function artifactsDir() internal view returns (string memory dir) {
        return artifactsDir(vm.envString("ARTIFACTS_DIR"));
    }

    function artifactsDir(string memory name) internal pure returns (string memory dir) {
        bytes memory raw = bytes(name);
        if (raw.length == 0) revert InvalidArtifactsDir(name);
        if (keccak256(raw) == keccak256(bytes(".")) || keccak256(raw) == keccak256(bytes(".."))) {
            revert InvalidArtifactsDir(name);
        }
        for (uint256 i; i < raw.length; ++i) {
            uint8 c = uint8(raw[i]);
            bool valid = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2E
                || c == 0x5F || c == 0x2D;
            if (!valid) revert InvalidArtifactsDir(name);
        }
        return string.concat("deployed/", name);
    }

    function ensureArtifactsDir() internal {
        string memory dir = artifactsDir();
        if (!vm.exists(dir)) vm.createDir(dir, false);
    }

    function deployment() internal view returns (string memory) {
        return vm.envString("ARTIFACTS_DIR");
    }

    function _requireDirectoryCompatible(string memory dir, ArtifactMetadata memory expected) private view {
        if (!vm.exists(dir)) return;

        Vm.DirEntry[] memory entries = vm.readDir(dir);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || entries[i].isSymlink) continue;
            requireCompatible(entries[i].path, expected);
        }
    }
}
