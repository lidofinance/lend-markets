// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

struct GuardianSignalsConfig {
    uint256 quorum;
    uint256 suspectWindow;
    address[] guardians;
}

library GuardianSignalsConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactAlreadyExists(string path);
    error InvalidQuorum(uint256 quorum, uint256 guardiansCount);

    function read(string memory name) internal view returns (GuardianSignalsConfig memory) {
        return parse(vm.readFile(configPath(name)));
    }

    function parse(string memory toml) internal view returns (GuardianSignalsConfig memory cfg) {
        cfg.quorum = vm.parseTomlUint(toml, ".quorum");
        cfg.suspectWindow = vm.parseTomlUint(toml, ".suspect_window");
        cfg.guardians = vm.parseTomlAddressArray(toml, ".guardians");
        if (cfg.quorum == 0 || cfg.quorum > cfg.guardians.length) {
            revert InvalidQuorum(cfg.quorum, cfg.guardians.length);
        }
    }

    function configPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/guardians/", name, ".toml");
    }

    function writeDeployed(
        string memory name,
        address guardianSignals,
        uint256 deployedBlock,
        ArtifactMetadata memory metadata
    ) internal returns (string memory path) {
        return _write(name, guardianSignals, deployedBlock, false, metadata);
    }

    function writeReference(
        string memory name,
        address guardianSignals,
        uint256 recordedBlock,
        ArtifactMetadata memory metadata
    ) internal returns (string memory path) {
        return _write(name, guardianSignals, recordedBlock, true, metadata);
    }

    function _write(
        string memory name,
        address guardianSignals,
        uint256 blockNumber,
        bool reused,
        ArtifactMetadata memory metadata
    ) private returns (string memory path) {
        ArtifactMetadataFile.ensureArtifactsDir();
        string memory dir = string.concat(ArtifactMetadataFile.artifactsDir(), "/guardians");
        if (!vm.exists(dir)) vm.createDir(dir, false);
        path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
        GuardianSignalsConfig memory cfg = read(name);
        string memory artifact = ArtifactMetadataFile.header(metadata, "guardian-signals");
        artifact = string.concat(artifact, "\n[guardian_signals]\n");
        artifact = string.concat(artifact, "name = \"", name, "\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(guardianSignals), "\"\n");
        artifact =
            string.concat(artifact, reused ? "reused = true\nrecorded_block = " : "reused = false\ndeployed_block = ");
        artifact = string.concat(artifact, vm.toString(blockNumber), "\n");
        artifact = string.concat(artifact, "quorum = ", vm.toString(cfg.quorum), "\n");
        artifact = string.concat(artifact, "suspect_window = ", vm.toString(cfg.suspectWindow), "\n");
        artifact = string.concat(artifact, _addressArray("guardians", cfg.guardians));
        vm.writeFile(path, artifact);
    }

    function requireUndeployed(string memory name) internal view {
        string memory path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }

    function readDeployed(string memory name) internal view returns (address) {
        string memory path = deployedPath(name);
        if (!vm.exists(path)) return address(0);
        return vm.parseTomlAddress(vm.readFile(path), ".guardian_signals.address");
    }

    function readDeployed(string memory name, ArtifactMetadata memory expected) internal view returns (address) {
        string memory path = deployedPath(name);
        if (!vm.exists(path)) return address(0);
        string memory artifact = ArtifactMetadataFile.requireCompatible(path, expected);
        return vm.parseTomlAddress(artifact, ".guardian_signals.address");
    }

    function deployedPath(string memory name) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/guardians/", name, ".toml");
    }

    function _addressArray(string memory key, address[] memory values) private pure returns (string memory s) {
        s = string.concat(key, " = [");
        for (uint256 i; i < values.length; ++i) {
            s = string.concat(s, i == 0 ? "\"" : ", \"", vm.toString(values[i]), "\"");
        }
        s = string.concat(s, "]\n");
    }
}
