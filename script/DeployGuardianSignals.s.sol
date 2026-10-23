// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {LidoLendMarketFactory} from "../src/periphery/LidoLendMarketFactory.sol";

import {ConfigToml} from "./lib/ConfigToml.sol";
import {GuardianSignalsConfigFile, GuardianSignalsConfig} from "./lib/GuardianSignalsConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";

/// @notice Deploys and records a `GuardianSignals` instance reusable across markets.
contract DeployGuardianSignals is Script {
    error FactoryCoreMismatch(address artifactCore, address factoryCore);
    error FactoryOwnerMismatch(address artifactOwner, address factoryOwner);
    error FactoryAdminMismatch(address expected, address actual);

    function run(string memory config, string memory name) external returns (address guardianSignals) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        string memory toml = vm.readFile(GuardianSignalsConfigFile.configPath(config, name));
        ArtifactMetadata memory metadata = DeployConfigFile.artifactMetadata(deployConfig);
        address factory;
        {
            string memory protocolArtifact =
                ArtifactMetadataFile.requireCompatible(ProtocolConfigFile.protocolPath(), metadata);
            DeployConfigFile.requireRegistryGovernance(deployConfig, protocolArtifact);
            factory = vm.parseTomlAddress(protocolArtifact, ".protocol.factory");
            if (factory == address(0)) revert ConfigToml.MissingConfigValue(".protocol.factory");

            LidoLendMarketFactory deployedFactory = LidoLendMarketFactory(factory);
            address artifactCore = vm.parseTomlAddress(protocolArtifact, ".protocol.core");
            address factoryCore = deployedFactory.LIDO_LEND();
            if (artifactCore != factoryCore) revert FactoryCoreMismatch(artifactCore, factoryCore);

            address artifactOwner = vm.parseTomlAddress(protocolArtifact, ".protocol.owner_facade");
            address factoryOwner = address(deployedFactory.LIDO_LEND_OWNER());
            if (artifactOwner != factoryOwner) revert FactoryOwnerMismatch(artifactOwner, factoryOwner);

            address factoryAdmin = deployedFactory.ADMIN();
            if (factoryAdmin != deployConfig.agent) revert FactoryAdminMismatch(deployConfig.agent, factoryAdmin);
        }

        GuardianSignalsConfig memory cfg = GuardianSignalsConfigFile.parse(toml);
        GuardianSignalsConfigFile.requireUndeployed(name);
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();
        // The group name separates registries whose committees are configured identically.
        guardianSignals = LidoLendMarketFactory(factory)
            .deployGuardianSignals(
                LidoLendMarketFactory.GuardianSpec({
                guardians: cfg.guardians, quorum: cfg.quorum, suspectWindow: cfg.suspectWindow
            }),
                keccak256(bytes(name))
            );
        vm.stopBroadcast();

        console2.log("guardians       :", name);
        console2.log("  guardianSignals :", guardianSignals);
        console2.log(
            "  recorded        :",
            GuardianSignalsConfigFile.writeDeployed(config, name, guardianSignals, deployedBlock, metadata)
        );
    }
}
