// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";
import {ConfigToml} from "./ConfigToml.sol";
import {DeployConfigFile} from "./DeployConfigFile.sol";

struct CircuitBreakerConfig {
    uint256 minPauseDuration;
    uint256 maxPauseDuration;
    uint256 minHeartbeatInterval;
    uint256 maxHeartbeatInterval;
    uint256 initialPauseDuration;
    uint256 initialHeartbeatInterval;
}

library CircuitBreakerConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactAlreadyExists(string path);

    /// @notice The deployment's CircuitBreaker config: one per deployment,
    /// `script/config/<config>/circuit-breaker.toml`. The artifact keeps the name `circuit_breaker_artifact` selects.
    function read(string memory config) internal view returns (CircuitBreakerConfig memory cfg) {
        string memory toml = vm.readFile(configPath(config));
        cfg.minPauseDuration = ConfigToml.requireUint(toml, ".min_pause_duration");
        cfg.maxPauseDuration = ConfigToml.requireUint(toml, ".max_pause_duration");
        cfg.minHeartbeatInterval = ConfigToml.requireUint(toml, ".min_heartbeat_interval");
        cfg.maxHeartbeatInterval = ConfigToml.requireUint(toml, ".max_heartbeat_interval");
        cfg.initialPauseDuration = ConfigToml.requireUint(toml, ".initial_pause_duration");
        cfg.initialHeartbeatInterval = ConfigToml.requireUint(toml, ".initial_heartbeat_interval");
    }

    function configPath(string memory config) internal pure returns (string memory) {
        return string.concat(DeployConfigFile.configDir(config), "/circuit-breaker.toml");
    }

    function deployedPath(string memory name) internal view returns (string memory) {
        return deployedPath(ArtifactMetadataFile.deployment(), name);
    }

    function deployedPath(string memory deployment, string memory name) internal pure returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(deployment), "/circuit-breakers/", name, ".toml");
    }

    function readDeployed(string memory name, ArtifactMetadata memory expected) internal view returns (address) {
        string memory path = deployedPath(expected.deployment, name);
        if (!vm.exists(path)) return address(0);
        string memory artifact = ArtifactMetadataFile.requireCompatible(path, expected);
        return vm.parseTomlAddress(artifact, ".circuit_breaker.address");
    }

    function requireUndeployed(string memory name) internal view {
        string memory path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }

    function writeDeployed(
        string memory name,
        address circuitBreaker,
        address admin,
        uint256 deployedBlock,
        CircuitBreakerConfig memory cfg,
        ArtifactMetadata memory metadata
    ) internal returns (string memory path) {
        string memory dir = string.concat(ArtifactMetadataFile.artifactsDir(metadata.deployment), "/circuit-breakers");
        if (!vm.exists(dir)) vm.createDir(dir, true);
        path = deployedPath(metadata.deployment, name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);

        string memory artifact = ArtifactMetadataFile.header(metadata, "circuit-breaker");
        artifact = string.concat(artifact, "\n[circuit_breaker]\n");
        artifact = string.concat(artifact, _kv("name", name));
        artifact = string.concat(artifact, _kv("address", circuitBreaker));
        artifact = string.concat(artifact, _kv("admin", admin));
        artifact = string.concat(artifact, _kv("deployed_block", deployedBlock));
        artifact = string.concat(artifact, _kv("min_pause_duration", cfg.minPauseDuration));
        artifact = string.concat(artifact, _kv("max_pause_duration", cfg.maxPauseDuration));
        artifact = string.concat(artifact, _kv("min_heartbeat_interval", cfg.minHeartbeatInterval));
        artifact = string.concat(artifact, _kv("max_heartbeat_interval", cfg.maxHeartbeatInterval));
        artifact = string.concat(artifact, _kv("initial_pause_duration", cfg.initialPauseDuration));
        artifact = string.concat(artifact, _kv("initial_heartbeat_interval", cfg.initialHeartbeatInterval));
        vm.writeFile(path, artifact);
    }

    function _kv(string memory key, string memory value) private pure returns (string memory) {
        return string.concat(key, " = \"", value, "\"\n");
    }

    function _kv(string memory key, address value) private pure returns (string memory) {
        return string.concat(key, " = \"", vm.toString(value), "\"\n");
    }

    function _kv(string memory key, uint256 value) private pure returns (string memory) {
        return string.concat(key, " = ", vm.toString(value), "\n");
    }
}
