// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {LidoLendMarketBuilder, GuardianConfig} from "../src/periphery/LidoLendMarketBuilder.sol";

import {ConfigToml} from "./lib/ConfigToml.sol";
import {GuardianSignalsConfigFile, GuardianSignalsConfig} from "./lib/GuardianSignalsConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";

/// @notice Deploys a standalone `GuardianSignals` instance (via the builder) for a committee shared across a
///         group of markets; its address is recorded to `deployed/guardian-<name>.toml` for markets that
///         leave `guardian_signals` zero to resolve.
/// @dev Draft, not production-ready. `GUARDIANS` selects `script/config/guardians/<name>.toml`, which names
///      the builder (`.builder`).
///
/// Usage:
///   forge script script/DeployGuardianSignals.s.sol --sig "run(string,string)" mainnet usdy --rpc-url "$RPC_URL"
/// --broadcast
contract DeployGuardianSignals is Script {
    error UnexpectedAdmin(address expected, address actual);
    error UnexpectedProxyAdmin(address expected, address actual);

    function run(string memory config, string memory name) external returns (address guardianSignals) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        string memory toml = vm.readFile(GuardianSignalsConfigFile.configPath(name));
        address builder = vm.parseTomlAddress(toml, ".builder");
        if (builder == address(0)) revert ConfigToml.MissingConfigValue(".builder");

        GuardianSignalsConfig memory cfg = GuardianSignalsConfigFile.parse(toml);
        if (cfg.admin != deployConfig.agent) revert UnexpectedAdmin(deployConfig.agent, cfg.admin);
        if (cfg.proxyAdmin != deployConfig.agent) revert UnexpectedProxyAdmin(deployConfig.agent, cfg.proxyAdmin);
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: deployConfig.chainId,
            configHash: deployConfig.configHash
        });
        ArtifactMetadataFile.ensureManifest(metadata);
        ArtifactMetadataFile.snapshotInput("deploy", DeployConfigFile.configPath(config));
        ArtifactMetadataFile.snapshotInput(string.concat("guardian-", name), GuardianSignalsConfigFile.configPath(name));
        GuardianSignalsConfigFile.requireUndeployed(name, metadata);
        address[] memory managers = new address[](0);

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
        console2.log("  recorded        :", GuardianSignalsConfigFile.writeDeployed(name, guardianSignals, metadata));
    }
}
