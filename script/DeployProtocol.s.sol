// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {
    ProtocolConfigFile,
    ProtocolConfig,
    ProtocolDeployment,
    ExitBooksDeployment
} from "./lib/ProtocolConfigFile.sol";
import {ExitBookConfig} from "./lib/ExitBookConfigFile.sol";
import {ArtifactMetadata} from "./lib/ArtifactMetadata.sol";
import {CircuitBreakerConfigFile} from "./lib/CircuitBreakerConfigFile.sol";

/// @notice Deploys and records the protocol backbone and, when the config enables them, the exit books.
/// @dev Markets are not deployed here; each is a separate `AddMarket` run against this backbone.
contract DeployProtocol is Script, ProtocolDeployer {
    function run(string memory config) external returns (ProtocolDeployment memory protocol) {
        DeployConfig memory cfg = DeployConfigFile.read(config);
        _requireChainId(cfg.chainId);
        address deployer = msg.sender;
        DeployConfigFile.requireActorSeparation(cfg, deployer);
        ArtifactMetadata memory artifacts = DeployConfigFile.artifactMetadata(cfg);
        DeployConfigFile.requireRunResourcesCompatible(artifacts);
        address circuitBreaker = CircuitBreakerConfigFile.readDeployed(cfg.circuitBreakerArtifact, artifacts);
        _requireCircuitBreakerPolicy(circuitBreaker, cfg.evmScriptExecutor);
        ProtocolConfigFile.requireProtocolUndeployed();
        if (cfg.exitBooks) ProtocolConfigFile.requireExitBooksUndeployed();

        // Recorded for deployment provenance and later non-enumerable mapping audits.
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();

        protocol = _deployBackbone(
            ProtocolConfig({
                agent: cfg.agent, evmScriptExecutor: cfg.evmScriptExecutor, circuitBreaker: circuitBreaker
            }),
            deployer
        );
        protocol.deployment = artifacts.deployment;
        protocol.network = cfg.network;
        protocol.chainId = cfg.chainId;
        protocol.configHash = cfg.configHash;
        protocol.circuitBreakerArtifact = cfg.circuitBreakerArtifact;
        protocol.deployedBlock = deployedBlock;
        protocol.deployer = deployer;

        ExitBooksDeployment memory exitBooks;

        if (cfg.exitBooks) {
            (address morpho, address erc4626) = _deployExitBooks(
                ExitBookConfig({
                    agent: cfg.agent,
                    evmScriptExecutor: cfg.evmScriptExecutor,
                    pauser: cfg.exitBookPauser,
                    core: protocol.core,
                    maxRequestLifetime: cfg.exitBookMaxRequestLifetime
                }),
                deployer
            );
            exitBooks = ExitBooksDeployment({
                morpho: morpho,
                erc4626: erc4626,
                deployedBlock: deployedBlock,
                pauser: cfg.exitBookPauser,
                maxRequestLifetime: cfg.exitBookMaxRequestLifetime
            });
            console2.log("morphoExitBook  :", morpho);
            console2.log("erc4626ExitBook :", erc4626);
        }

        vm.stopBroadcast();

        string memory protocolPath = ProtocolConfigFile.writeProtocol(protocol, artifacts);
        if (cfg.exitBooks) ProtocolConfigFile.writeExitBooks(exitBooks, artifacts);

        console2.log("=== protocol ===");
        console2.log("core            :", protocol.core);
        console2.log("ownerFacade     :", protocol.ownerFacade);
        console2.log("irmRouter       :", protocol.irmRouter);
        console2.log("irmConfigFactory:", protocol.irmConfigFactory);
        console2.log("factory         :", protocol.factory);
        console2.log("riskStewardDash :", protocol.riskStewardDashboard);
        console2.log("circuitBreaker  :", protocol.circuitBreaker);
        console2.log("protocol        :", protocolPath);
    }
}
