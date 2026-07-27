// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

/// @notice Records and resolves the standalone IRM instances a market may be routed to, as
///         `deployed/<RUN>/irms/<name>.toml`. The protocol-wide `AdaptiveCurveIrm` is deployed with the
///         backbone and recorded in `protocol.toml`, so it has no artifact here: a market names it with the
///         reserved {ADAPTIVE_CURVE} reference. Any other reference is an artifact in this directory.
library IrmConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Reserved `market.irm_artifact` value naming the backbone `AdaptiveCurveIrm` from
    ///         `protocol.toml` rather than an `irms/` artifact.
    string internal constant ADAPTIVE_CURVE = "adaptive-curve";

    error ArtifactAlreadyExists(string path);

    /// @notice Whether `ref` names the backbone adaptive-curve IRM instead of an `irms/` artifact.
    function isAdaptiveCurve(string memory ref) internal pure returns (bool) {
        return keccak256(bytes(ref)) == keccak256(bytes(ADAPTIVE_CURVE));
    }

    /// @notice Record a deployed IRM instance. Immutable: refuses to replace an existing artifact.
    /// @param name The artifact name, i.e. the `market.irm_artifact` reference resolving to it.
    /// @param kind The IRM model, e.g. `"linear-kink"`.
    /// @param irm The deployed instance.
    /// @param owner The instance's high-trust owner.
    /// @param manager The instance's routine manager.
    function writeDeployed(
        string memory name,
        string memory kind,
        address irm,
        address owner,
        address manager,
        ArtifactMetadata memory metadata
    ) internal returns (string memory path) {
        ArtifactMetadataFile.ensureArtifactsDir();
        string memory dir = string.concat(ArtifactMetadataFile.artifactsDir(), "/irms");
        if (!vm.exists(dir)) vm.createDir(dir, false);
        path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);

        string memory artifact = ArtifactMetadataFile.header(metadata, "irm");
        artifact = string.concat(artifact, "\n[irm]\n");
        artifact = string.concat(artifact, "name = \"", name, "\"\n");
        artifact = string.concat(artifact, "kind = \"", kind, "\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(irm), "\"\n");
        artifact = string.concat(artifact, "owner = \"", vm.toString(owner), "\"\n");
        artifact = string.concat(artifact, "manager = \"", vm.toString(manager), "\"\n");
        artifact = string.concat(artifact, "deployed_block = ", vm.toString(block.number), "\n");
        vm.writeFile(path, artifact);
    }

    function requireUndeployed(string memory name) internal view {
        string memory path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }

    /// @notice The recorded instance for `name`, or the zero address when the run has no such artifact.
    function readDeployed(string memory name) internal view returns (address) {
        string memory path = deployedPath(name);
        if (!vm.exists(path)) return address(0);
        return vm.parseTomlAddress(vm.readFile(path), ".irm.address");
    }

    function deployedPath(string memory name) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/irms/", name, ".toml");
    }
}
