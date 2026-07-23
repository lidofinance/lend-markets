// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ConfigToml} from "./ConfigToml.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

struct GuardianSignalsConfig {
    address admin;
    address proxyAdmin;
    uint256 quorum;
    uint256 suspectWindow;
    address[] guardians;
    address accessLimiter;
}

library GuardianSignalsConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactAlreadyExists(string path);

    function read(string memory name) internal view returns (GuardianSignalsConfig memory) {
        return parse(vm.readFile(configPath(name)));
    }

    function parse(string memory toml) internal view returns (GuardianSignalsConfig memory cfg) {
        cfg.admin = ConfigToml.requireAddress(toml, ".admin");
        cfg.proxyAdmin = ConfigToml.requireAddress(toml, ".proxy_admin");
        cfg.quorum = vm.parseTomlUint(toml, ".quorum");
        cfg.suspectWindow = vm.parseTomlUint(toml, ".suspect_window");
        cfg.guardians = vm.parseTomlAddressArray(toml, ".guardians");
        cfg.accessLimiter =
            vm.keyExistsToml(toml, ".access_limiter") ? vm.parseTomlAddress(toml, ".access_limiter") : address(0);
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
        ArtifactMetadataFile.ensureArtifactsDir();
        path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
        string memory artifact = ArtifactMetadataFile.header(metadata, "guardian-signals");
        artifact = string.concat(artifact, "\n[guardian_signals]\n");
        artifact = string.concat(artifact, "config = \"", name, "\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(guardianSignals), "\"\n");
        artifact = string.concat(artifact, "deployed_block = ", vm.toString(deployedBlock), "\n");
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

    function deployedPath(string memory name) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/guardian-", name, ".toml");
    }
}
