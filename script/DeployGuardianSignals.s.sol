// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LidoLendMarketFactory} from "../src/periphery/LidoLendMarketFactory.sol";

import {ConfigToml} from "./lib/ConfigToml.sol";
import {GuardianSignalsConfigFile, GuardianSignalsConfig} from "./lib/GuardianSignalsConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";

/// @notice Deploys and records a `GuardianSignals` instance reusable across markets.
contract DeployGuardianSignals is Script {
    error UnexpectedAdmin(address expected, address actual);
    error UnexpectedProxyAdmin(address expected, address actual);
    error FactoryCoreMismatch(address artifactCore, address factoryCore);
    error FactoryOwnerMismatch(address artifactOwner, address factoryOwner);

    function run(string memory config, string memory name) external returns (address guardianSignals) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        string memory toml = vm.readFile(GuardianSignalsConfigFile.configPath(name));
        address factory;
        {
            string memory protocolArtifact = vm.readFile(ProtocolConfigFile.protocolPath());
            DeployConfigFile.requireRegistryGovernance(deployConfig, protocolArtifact);
            factory = vm.parseTomlAddress(protocolArtifact, ".protocol.factory");
            if (factory == address(0)) revert ConfigToml.MissingConfigValue(".protocol.factory");

            LidoLendMarketFactory deployedFactory = LidoLendMarketFactory(factory);
            address artifactCore = vm.parseTomlAddress(protocolArtifact, ".protocol.core");
            address factoryCore = address(deployedFactory.CORE());
            if (artifactCore != factoryCore) revert FactoryCoreMismatch(artifactCore, factoryCore);

            address artifactOwner = vm.parseTomlAddress(protocolArtifact, ".protocol.owner_facade");
            address factoryOwner = address(deployedFactory.LIDO_LEND_OWNER());
            if (artifactOwner != factoryOwner) revert FactoryOwnerMismatch(artifactOwner, factoryOwner);
        }

        GuardianSignalsConfig memory cfg = GuardianSignalsConfigFile.parse(toml);
        if (cfg.admin != deployConfig.agent) revert UnexpectedAdmin(deployConfig.agent, cfg.admin);
        if (cfg.proxyAdmin != deployConfig.agent) revert UnexpectedProxyAdmin(deployConfig.agent, cfg.proxyAdmin);
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: deployConfig.chainId,
            configHash: deployConfig.configHash
        });
        GuardianSignalsConfigFile.requireUndeployed(name);
        address[] memory managers = new address[](0);
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();
        guardianSignals = LidoLendMarketFactory(factory)
            .deployGuardianSignals(
                LidoLendMarketFactory.GuardianSpec({
                    guardians: cfg.guardians, quorum: cfg.quorum, suspectWindow: cfg.suspectWindow
                }),
                LidoLendMarketFactory.GuardianRoles({
                    admin: cfg.admin, proxyAdmin: cfg.proxyAdmin, managers: managers, accessLimiter: cfg.accessLimiter
                })
            );
        vm.stopBroadcast();

        console2.log("guardians       :", name);
        console2.log("  guardianSignals :", guardianSignals);
        console2.log(
            "  recorded        :",
            GuardianSignalsConfigFile.writeDeployed(name, guardianSignals, deployedBlock, metadata)
        );
    }
}
