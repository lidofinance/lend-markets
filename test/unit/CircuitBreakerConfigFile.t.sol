// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {ArtifactMetadata} from "../../script/lib/ArtifactMetadata.sol";
import {CircuitBreakerConfig, CircuitBreakerConfigFile} from "../../script/lib/CircuitBreakerConfigFile.sol";

contract CircuitBreakerConfigFileHarness {
    function writeDeployed(
        string memory name,
        address circuitBreaker,
        address admin,
        uint256 deployedBlock,
        CircuitBreakerConfig memory cfg,
        ArtifactMetadata memory metadata
    ) external returns (string memory) {
        return CircuitBreakerConfigFile.writeDeployed(name, circuitBreaker, admin, deployedBlock, cfg, metadata);
    }

    function readDeployed(string memory name, ArtifactMetadata memory metadata) external view returns (address) {
        return CircuitBreakerConfigFile.readDeployed(name, metadata);
    }
}

contract CircuitBreakerConfigFileTest is Test {
    CircuitBreakerConfigFileHarness internal harness;

    function setUp() external {
        harness = new CircuitBreakerConfigFileHarness();
    }

    function test_writeDeployed_recordsResolvedConfig() external {
        string memory run = "circuit-breaker-config-file-unit";
        string memory dir = string.concat("deployed/", run);
        if (vm.exists(dir)) vm.removeDir(dir, true);

        CircuitBreakerConfig memory cfg = CircuitBreakerConfig({
            minPauseDuration: 5 days,
            maxPauseDuration: 60 days,
            minHeartbeatInterval: 30 days,
            maxHeartbeatInterval: 1095 days,
            initialPauseDuration: 21 days,
            initialHeartbeatInterval: 365 days
        });
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: run,
            chainId: 1,
            configHash: bytes32(uint256(0xCAFE)),
            compatibilityHash: bytes32(uint256(0xBEEF))
        });
        address circuitBreaker = address(0xCB);
        address admin = address(0xA11);
        string memory name = "lido-lend";

        string memory path = harness.writeDeployed(name, circuitBreaker, admin, 123, cfg, metadata);
        string memory artifact = vm.readFile(path);

        assertEq(path, string.concat(dir, "/circuit-breakers/lido-lend.toml"));
        assertEq(vm.parseTomlString(artifact, ".artifact.kind"), "circuit-breaker");
        assertEq(vm.parseTomlString(artifact, ".circuit_breaker.name"), name);
        assertEq(vm.parseTomlAddress(artifact, ".circuit_breaker.address"), circuitBreaker);
        assertEq(vm.parseTomlAddress(artifact, ".circuit_breaker.admin"), admin);
        assertFalse(vm.keyExistsToml(artifact, ".circuit_breaker.deployer"));
        assertEq(vm.parseTomlUint(artifact, ".circuit_breaker.initial_pause_duration"), 21 days);
        assertEq(harness.readDeployed(name, metadata), circuitBreaker);

        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerConfigFile.ArtifactAlreadyExists.selector, path));
        harness.writeDeployed(name, circuitBreaker, admin, 123, cfg, metadata);
        vm.removeDir(dir, true);
    }
}
