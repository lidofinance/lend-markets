// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {CircuitBreaker} from "@circuit-breaker/src/CircuitBreaker.sol";

import {ArtifactMetadata} from "./lib/ArtifactMetadata.sol";
import {CircuitBreakerConfig, CircuitBreakerConfigFile} from "./lib/CircuitBreakerConfigFile.sol";
import {DeployConfig, DeployConfigFile} from "./lib/DeployConfigFile.sol";

/// @notice Deploys and records a CircuitBreaker reusable across markets in one protocol run.
contract DeployCircuitBreaker is Script {
    function run(string memory config) external returns (address circuitBreaker) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        ArtifactMetadata memory metadata = DeployConfigFile.artifactMetadata(deployConfig);
        DeployConfigFile.requireRunResourcesCompatible(metadata);
        DeployConfigFile.requireExistingProtocolCompatible(deployConfig);
        string memory name = deployConfig.circuitBreakerArtifact;
        CircuitBreakerConfig memory cfg = CircuitBreakerConfigFile.read(config);
        CircuitBreakerConfigFile.requireUndeployed(name);
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();
        circuitBreaker = address(
            new CircuitBreaker(
                deployConfig.evmScriptExecutor,
                cfg.minPauseDuration,
                cfg.maxPauseDuration,
                cfg.minHeartbeatInterval,
                cfg.maxHeartbeatInterval,
                cfg.initialPauseDuration,
                cfg.initialHeartbeatInterval
            )
        );
        vm.stopBroadcast();

        console2.log("circuitBreaker");
        console2.log("  address        :", circuitBreaker);
        console2.log("  admin          :", deployConfig.evmScriptExecutor);
        console2.log(
            "  recorded       :",
            CircuitBreakerConfigFile.writeDeployed(
                name, circuitBreaker, deployConfig.evmScriptExecutor, deployedBlock, cfg, metadata
            )
        );
    }
}
