// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LidoLendMarketBuilder, GuardianConfig} from "../src/periphery/LidoLendMarketBuilder.sol";

import {ConfigToml} from "./lib/ConfigToml.sol";
import {GuardianSignalsConfigFile, GuardianSignalsConfig} from "./lib/GuardianSignalsConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";

/// @notice Deploys and records a `GuardianSignals` instance reusable across markets.
contract DeployGuardianSignals is Script {
    error RegistryBuilderMismatch(address registryBuilder, address configBuilder);
    error UnexpectedAdmin(address expected, address actual);
    error UnexpectedProxyAdmin(address expected, address actual);

    function run(string memory config, string memory name) external returns (address guardianSignals) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        string memory toml = vm.readFile(GuardianSignalsConfigFile.configPath(name));
        address builder = vm.parseTomlAddress(toml, ".builder");
        if (builder == address(0)) revert ConfigToml.MissingConfigValue(".builder");
        {
            string memory registry = vm.readFile(ProtocolConfigFile.deployedPath());
            DeployConfigFile.requireRegistryGovernance(deployConfig, registry);
            address registryBuilder = vm.parseTomlAddress(registry, ".protocol.builder");
            if (builder != registryBuilder) revert RegistryBuilderMismatch(registryBuilder, builder);
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
        ArtifactMetadataFile.snapshotInput("deploy", DeployConfigFile.configPath(config));
        ArtifactMetadataFile.snapshotInput(string.concat("guardian-", name), GuardianSignalsConfigFile.configPath(name));
        address[] memory managers = new address[](0);
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();
        guardianSignals = LidoLendMarketBuilder(builder)
            .buildGuardianSignals(
                GuardianConfig({
                    guardians: cfg.guardians,
                    quorum: cfg.quorum,
                    suspectWindow: cfg.suspectWindow,
                    accessLimiter: cfg.accessLimiter
                }),
                cfg.admin,
                managers,
                cfg.proxyAdmin
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
