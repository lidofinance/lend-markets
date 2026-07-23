// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {LidoLendMarketBuilder, MarketRoles, GuardianConfig} from "../src/periphery/LidoLendMarketBuilder.sol";

import {ConfigToml} from "./lib/ConfigToml.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {MarketConfigFile} from "./lib/MarketConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {ProtocolConfigFile, MarketDeployment} from "./lib/ProtocolConfigFile.sol";
import {GuardianSignalsConfigFile, GuardianSignalsConfig} from "./lib/GuardianSignalsConfigFile.sol";
import {OracleConfigFile} from "./lib/OracleConfigFile.sol";
import {OraclePreflight} from "./lib/OraclePreflight.sol";

/// @notice Deploys and records inert components for one market in an existing protocol.
contract AddMarket is Script, ProtocolDeployer {
    using MarketParamsLib for MarketParams;

    error RegistryBuilderMismatch(address registryBuilder, address configBuilder);

    struct RunContext {
        string deployment;
        uint256 chainId;
        bytes32 configHash;
        address agent;
        address executor;
    }

    struct MarketRecordInput {
        string name;
        LidoLendMarketBuilder.MarketSpec market;
        address[] pausers;
        LidoLendMarketBuilder.MarketContracts built;
        string registryPath;
        uint256 deployedBlock;
    }

    function run(string memory config, string memory name)
        external
        returns (LidoLendMarketBuilder.MarketContracts memory built)
    {
        RunContext memory context;
        {
            DeployConfig memory deployConfig = DeployConfigFile.read(config);
            _requireChainId(deployConfig.chainId);
            DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
            context = RunContext({
                deployment: ArtifactMetadataFile.deployment(),
                chainId: deployConfig.chainId,
                configHash: deployConfig.configHash,
                agent: deployConfig.agent,
                executor: deployConfig.evmScriptExecutor
            });
        }

        string memory guardianGroup = MarketConfigFile.guardianGroup(name);
        (address builder, LidoLendMarketBuilder.MarketSpec memory market, MarketRoles memory roles,) =
            MarketConfigFile.read(name);
        _requireMarketRolePolicy(roles, context.agent, context.executor, msg.sender);
        OraclePreflight.validate(
            MarketConfigFile.oracleArtifact(name),
            market.oracle,
            market.loanToken,
            market.collateralToken,
            context.agent
        );
        if (market.guardianSignals != address(0)) _requireProxyAdmin(market.guardianSignals, context.agent);
        if (builder == address(0)) revert ConfigToml.MissingConfigValue(".builder");

        ArtifactMetadata memory artifacts = ArtifactMetadata({
            deployment: context.deployment, chainId: context.chainId, configHash: context.configHash
        });
        address irmRouter = address(LidoLendMarketBuilder(builder).IRM_ROUTER());
        Id proposedId = MarketParams({
                loanToken: market.loanToken,
                collateralToken: market.collateralToken,
                oracle: market.oracle,
                irm: irmRouter,
                lltv: market.lltv
            }).id();
        string memory registryPath = ProtocolConfigFile.deployedPath();
        {
            string memory registry = vm.readFile(registryPath);
            DeployConfig memory deployConfig = DeployConfigFile.read(config);
            DeployConfigFile.requireRegistryGovernance(deployConfig, registry);
            address registryBuilder = vm.parseTomlAddress(registry, ".protocol.builder");
            if (builder != registryBuilder) revert RegistryBuilderMismatch(registryBuilder, builder);
        }
        if (market.guardianSignals != address(0)) {
            _validateReusedGuardianSignals(guardianGroup, builder, market.guardianSignals, context.agent);
        }
        ProtocolConfigFile.requireMarketAbsent(registryPath, name);
        ProtocolConfigFile.requireMarketIdAbsent(registryPath, Id.unwrap(proposedId));
        if (market.guardianSignals == address(0)) GuardianSignalsConfigFile.requireUndeployed(guardianGroup);
        ArtifactMetadataFile.snapshotInput("deploy", DeployConfigFile.configPath(config));
        ArtifactMetadataFile.snapshotInput(string.concat("market-", name), MarketConfigFile.marketPath(name));
        ArtifactMetadataFile.snapshotInput(
            string.concat("guardian-", guardianGroup), GuardianSignalsConfigFile.configPath(guardianGroup)
        );
        ArtifactMetadataFile.snapshotInput(
            string.concat("oracle-", MarketConfigFile.oracleArtifact(name)),
            OracleConfigFile.configPath(MarketConfigFile.oracleArtifact(name))
        );

        // Lower bound for reconstructing roles from events.
        uint256 deployedBlock = vm.getBlockNumber();
        bool guardianCreated;

        vm.startBroadcast();

        if (market.guardianSignals == address(0)) {
            market.guardianSignals = _buildGuardianSignals(guardianGroup, builder, context.agent);
            guardianCreated = true;
        }

        built = LidoLendMarketBuilder(builder).buildMarketContracts(market, roles);
        vm.stopBroadcast();

        if (guardianCreated) {
            GuardianSignalsConfigFile.writeDeployed(guardianGroup, market.guardianSignals, deployedBlock, artifacts);
        }

        console2.log("market     :", name);
        console2.log("  oracle          :", market.oracle);
        console2.log("  guardianSignals :", market.guardianSignals);
        console2.log("  controller      :", built.controller);
        console2.log("  vault           :", built.vault);
        {
            MarketRecordInput memory record;
            record.name = name;
            record.market = market;
            record.pausers = roles.pausers;
            record.built = built;
            record.registryPath = registryPath;
            record.deployedBlock = deployedBlock;
            console2.log("  recorded        :", _record(record));
        }
    }

    function _record(MarketRecordInput memory input) internal returns (string memory path) {
        MarketDeployment memory md = MarketDeployment({
            name: input.name,
            id: Id.unwrap(input.built.marketId),
            controller: input.built.controller,
            vault: input.built.vault,
            oracle: input.market.oracle,
            guardianSignals: input.market.guardianSignals,
            pausers: input.pausers,
            deployedBlock: input.deployedBlock
        });

        ProtocolConfigFile.appendMarket(input.registryPath, md);
        path = input.registryPath;
    }

    function _validateReusedGuardianSignals(
        string memory guardianGroup,
        address builder,
        address guardianSignals,
        address agent
    ) private view {
        GuardianSignalsConfig memory cfg = GuardianSignalsConfigFile.read(guardianGroup);
        if (cfg.admin != agent) revert UnexpectedAdmin(agent, cfg.admin);
        if (cfg.proxyAdmin != agent) revert UnexpectedProxyAdmin(agent, cfg.proxyAdmin);
        address[] memory managers = new address[](0);
        LidoLendMarketBuilder(builder)
            .validateGuardianSignals(
                guardianSignals,
                builder,
                agent,
                agent,
                managers,
                GuardianConfig({
                    guardians: cfg.guardians,
                    quorum: cfg.quorum,
                    suspectWindow: cfg.suspectWindow,
                    accessLimiter: cfg.accessLimiter
                })
            );
    }
}
