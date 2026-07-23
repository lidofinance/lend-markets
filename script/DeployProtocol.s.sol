// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

import {LidoLendMarketBuilder, MarketRoles} from "../src/periphery/LidoLendMarketBuilder.sol";

import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {
    ProtocolConfigFile,
    ProtocolConfig,
    ProtocolDeployment,
    MarketDeployment,
    ExitBooksDeployment
} from "./lib/ProtocolConfigFile.sol";
import {ExitBookConfig} from "./lib/ExitBookConfigFile.sol";
import {MarketConfigFile} from "./lib/MarketConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {GuardianSignalsConfigFile} from "./lib/GuardianSignalsConfigFile.sol";
import {OracleConfigFile} from "./lib/OracleConfigFile.sol";
import {OraclePreflight} from "./lib/OraclePreflight.sol";

/// @notice Deploys and records the protocol backbone, optional exit books, and configured inert markets.
contract DeployProtocol is Script, ProtocolDeployer {
    error ReusedGuardianSignalsUnsupported(address guardianSignals);
    error OracleArtifactMismatch(address artifactOracle, address configuredOracle);

    struct MarketBuildContext {
        ProtocolDeployment protocol;
        address agent;
        address executor;
        address deployer;
        uint256 deployedBlock;
        string[] guardianGroups;
        address[] guardianSignals;
        uint256 guardianCount;
    }

    function run(string memory config) external returns (ProtocolDeployment memory protocol) {
        DeployConfig memory cfg = DeployConfigFile.read(config);
        _requireChainId(cfg.chainId);
        address deployer = msg.sender;
        DeployConfigFile.requireActorSeparation(cfg, deployer);
        ArtifactMetadata memory artifacts = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(), chainId: cfg.chainId, configHash: cfg.configHash
        });
        _preflight(cfg, deployer);

        // Lower bound for reconstructing roles from events.
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();

        protocol =
            _deployBackbone(ProtocolConfig({agent: cfg.agent, evmScriptExecutor: cfg.evmScriptExecutor}), deployer);
        protocol.deployment = artifacts.deployment;
        protocol.network = cfg.network;
        protocol.chainId = cfg.chainId;
        protocol.configHash = cfg.configHash;
        protocol.deployedBlock = deployedBlock;
        protocol.deployer = deployer;

        ExitBooksDeployment memory exitBooks;

        if (cfg.exitBooks) {
            (address morpho, address erc4626) = _deployExitBooks(
                ExitBookConfig({
                    agent: cfg.agent,
                    evmScriptExecutor: cfg.evmScriptExecutor,
                    core: protocol.core,
                    maxRequestLifetime: cfg.exitBookMaxRequestLifetime
                }),
                deployer
            );
            exitBooks = ExitBooksDeployment({
                morpho: morpho,
                erc4626: erc4626,
                deployedBlock: deployedBlock,
                deployer: deployer,
                agent: cfg.agent,
                evmScriptExecutor: cfg.evmScriptExecutor,
                maxRequestLifetime: cfg.exitBookMaxRequestLifetime
            });
            console2.log("morphoExitBook  :", morpho);
            console2.log("erc4626ExitBook :", erc4626);
        }

        MarketDeployment[] memory markets = new MarketDeployment[](cfg.markets.length);
        string[] memory freshGuardianGroups = new string[](cfg.markets.length);
        address[] memory freshGuardianSignals = new address[](cfg.markets.length);
        MarketBuildContext memory marketContext = MarketBuildContext({
            protocol: protocol,
            agent: cfg.agent,
            executor: cfg.evmScriptExecutor,
            deployer: deployer,
            deployedBlock: deployedBlock,
            guardianGroups: freshGuardianGroups,
            guardianSignals: freshGuardianSignals,
            guardianCount: 0
        });
        for (uint256 i; i < cfg.markets.length; ++i) {
            (markets[i], marketContext.guardianCount) = _addMarket(cfg.markets[i], marketContext);
        }

        vm.stopBroadcast();

        for (uint256 i; i < marketContext.guardianCount; ++i) {
            GuardianSignalsConfigFile.writeDeployed(
                freshGuardianGroups[i], freshGuardianSignals[i], deployedBlock, artifacts
            );
        }
        for (uint256 i; i < markets.length; ++i) {
            address recordedOracle = OracleConfigFile.readDeployed(markets[i].oracleArtifact);
            if (recordedOracle == address(0)) {
                OracleConfigFile.writeReference(markets[i].oracleArtifact, markets[i].market.oracle, artifacts);
            }
        }
        string memory protocolPath = ProtocolConfigFile.writeProtocol(protocol, artifacts);
        if (cfg.exitBooks) ProtocolConfigFile.writeExitBooks(exitBooks, artifacts);
        for (uint256 i; i < markets.length; ++i) {
            ProtocolConfigFile.writeMarket(markets[i], artifacts);
        }

        console2.log("=== protocol ===");
        console2.log("core            :", protocol.core);
        console2.log("ownerFacade     :", protocol.ownerFacade);
        console2.log("irmRouter       :", protocol.irmRouter);
        console2.log("factory         :", protocol.factory);
        console2.log("builder         :", protocol.builder);
        console2.log("riskStewardDash :", protocol.riskStewardDashboard);
        console2.log("protocol        :", protocolPath);
    }

    function _preflight(DeployConfig memory cfg, address deployer) internal {
        ProtocolConfigFile.requireProtocolUndeployed();
        if (cfg.exitBooks) ProtocolConfigFile.requireExitBooksUndeployed();
        string[] memory freshGuardianGroups = new string[](cfg.markets.length);
        LidoLendMarketBuilder.MarketSpec[] memory markets = new LidoLendMarketBuilder.MarketSpec[](cfg.markets.length);
        uint256 freshGuardianGroupsCount;

        for (uint256 i; i < cfg.markets.length; ++i) {
            string memory name = cfg.markets[i];
            ProtocolConfigFile.requireMarketUndeployed(name);
            string memory guardianGroup = MarketConfigFile.guardianGroup(name);
            (, LidoLendMarketBuilder.MarketSpec memory market, MarketRoles memory roles,) = MarketConfigFile.read(name);
            markets[i] = market;
            _requireMarketRolePolicy(roles, cfg.agent, cfg.evmScriptExecutor, deployer);
            string memory oracleArtifact = MarketConfigFile.oracleArtifact(name);
            OraclePreflight.validate(oracleArtifact, market.oracle, market.loanToken, market.collateralToken, cfg.agent);
            address recordedOracle = OracleConfigFile.readDeployed(oracleArtifact);
            if (recordedOracle != address(0) && recordedOracle != market.oracle) {
                revert OracleArtifactMismatch(recordedOracle, market.oracle);
            }
            if (market.guardianSignals != address(0)) {
                revert ReusedGuardianSignalsUnsupported(market.guardianSignals);
            }
            if (
                market.guardianSignals == address(0)
                    && !_contains(freshGuardianGroups, freshGuardianGroupsCount, guardianGroup)
            ) {
                GuardianSignalsConfigFile.requireUndeployed(guardianGroup);
                freshGuardianGroups[freshGuardianGroupsCount++] = guardianGroup;
            }
        }
        _requireUniqueMarketIds(cfg.markets, markets);
        _requireUniqueOracleArtifactAddresses(cfg.markets, markets);
    }

    function _contains(string[] memory values, uint256 length, string memory needle) private pure returns (bool) {
        bytes32 needleHash = keccak256(bytes(needle));
        for (uint256 i; i < length; ++i) {
            if (keccak256(bytes(values[i])) == needleHash) return true;
        }
        return false;
    }

    function _requireUniqueOracleArtifactAddresses(
        string[] memory names,
        LidoLendMarketBuilder.MarketSpec[] memory markets
    ) private view {
        for (uint256 i; i < names.length; ++i) {
            bytes32 current = keccak256(bytes(MarketConfigFile.oracleArtifact(names[i])));
            for (uint256 j; j < i; ++j) {
                if (current != keccak256(bytes(MarketConfigFile.oracleArtifact(names[j])))) continue;
                if (markets[i].oracle != markets[j].oracle) {
                    revert OracleArtifactMismatch(markets[j].oracle, markets[i].oracle);
                }
            }
        }
    }

    function _addMarket(string memory name, MarketBuildContext memory context)
        internal
        returns (MarketDeployment memory md, uint256 updatedGuardianCount)
    {
        string memory guardianGroup = MarketConfigFile.guardianGroup(name);
        (
            ,
            LidoLendMarketBuilder.MarketSpec memory market,
            MarketRoles memory roles,
            AdaptiveCurveParams memory curveParams
        ) = MarketConfigFile.read(name);
        _requireMarketRolePolicy(roles, context.agent, context.executor, context.deployer);

        if (market.guardianSignals == address(0)) {
            market.guardianSignals = _findGuardianSignals(
                guardianGroup, context.guardianGroups, context.guardianSignals, context.guardianCount
            );
            if (market.guardianSignals == address(0)) {
                market.guardianSignals = _buildGuardianSignals(guardianGroup, context.protocol.builder, context.agent);
                context.guardianGroups[context.guardianCount] = guardianGroup;
                context.guardianSignals[context.guardianCount] = market.guardianSignals;
                ++context.guardianCount;
            }
        }

        LidoLendMarketBuilder.MarketContracts memory built =
            LidoLendMarketBuilder(context.protocol.builder).buildMarketContracts(market, roles);

        md = MarketDeployment({
            name: name,
            oracleArtifact: MarketConfigFile.oracleArtifact(name),
            guardianGroup: guardianGroup,
            id: Id.unwrap(built.marketId),
            builder: context.protocol.builder,
            controller: built.controller,
            vault: built.vault,
            irm: context.protocol.irmRouter,
            ownerFacade: context.protocol.ownerFacade,
            riskStewardDashboard: context.protocol.riskStewardDashboard,
            market: market,
            roles: roles,
            curveParams: curveParams,
            deployedBlock: context.deployedBlock
        });

        console2.log("--- market:", name);
        console2.log("  oracle          :", market.oracle);
        console2.log("  guardianSignals :", market.guardianSignals);
        console2.log("  controller      :", built.controller);
        console2.log("  vault           :", built.vault);
        updatedGuardianCount = context.guardianCount;
    }

    function _findGuardianSignals(
        string memory group,
        string[] memory groups,
        address[] memory guardianSignals,
        uint256 length
    ) private pure returns (address) {
        bytes32 groupHash = keccak256(bytes(group));
        for (uint256 i; i < length; ++i) {
            if (keccak256(bytes(groups[i])) == groupHash) return guardianSignals[i];
        }
        return address(0);
    }
}
