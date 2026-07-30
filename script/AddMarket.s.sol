// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IIrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/interfaces/IIrmConfigFactory.sol";

import {LidoLendMarketFactory} from "../src/periphery/LidoLendMarketFactory.sol";

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

    error GuardianArtifactMismatch(address artifactGuardianSignals, address configuredGuardianSignals);
    error OracleArtifactMismatch(address artifactOracle, address configuredOracle);
    error FactoryCoreMismatch(address artifactCore, address factoryCore);
    error FactoryOwnerMismatch(address artifactOwner, address factoryOwner);
    error FactoryIrmRouterMismatch(address artifactIrmRouter, address factoryIrmRouter);
    error FactoryDashboardMismatch(address artifactDashboard, address factoryDashboard);

    struct RunContext {
        ArtifactMetadata artifacts;
        address agent;
        address executor;
    }

    struct MarketInput {
        string name;
        string oracleArtifact;
        string guardianGroup;
        string circuitBreakerArtifact;
        address factory;
        address irm;
        address irmConfigFactory;
        address ownerFacade;
        address riskStewardDashboard;
        LidoLendMarketFactory.MarketSpec market;
        LidoLendMarketFactory.MarketRoles roles;
        LidoLendMarketFactory.VaultSpec vaultSpec;
        AdaptiveCurveParams curveParams;
        address recordedOracle;
        address recordedGuardianSignals;
    }

    function run(string memory config, string memory name)
        external
        returns (LidoLendMarketFactory.MarketComponents memory built)
    {
        RunContext memory context;
        {
            DeployConfig memory deployConfig = DeployConfigFile.read(config);
            _requireChainId(deployConfig.chainId);
            DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
            context = RunContext({
                artifacts: ArtifactMetadata({
                    deployment: ArtifactMetadataFile.deployment(),
                    chainId: deployConfig.chainId,
                    configHash: deployConfig.configHash
                }),
                agent: deployConfig.agent,
                executor: deployConfig.evmScriptExecutor
            });
        }

        MarketInput memory input = _loadMarketInput(config, name, context);

        // Lower bound for reconstructing roles from events.
        uint256 deployedBlock = vm.getBlockNumber();
        bool guardianCreated;

        vm.startBroadcast();

        IIrmConfigFactory(input.irmConfigFactory).getOrDeployAdaptiveCurveConfig(input.curveParams);
        if (input.market.guardianSignals == address(0)) {
            input.market.guardianSignals = _deployGuardianSignals(input.guardianGroup, input.factory, context.agent);
            guardianCreated = true;
        }

        built = LidoLendMarketFactory(input.factory).deployMarketComponents(input.market, input.roles, input.vaultSpec);
        vm.stopBroadcast();

        if (guardianCreated) {
            GuardianSignalsConfigFile.writeDeployed(
                input.guardianGroup, input.market.guardianSignals, deployedBlock, context.artifacts
            );
        } else if (input.recordedGuardianSignals == address(0)) {
            GuardianSignalsConfigFile.writeReference(
                input.guardianGroup, input.market.guardianSignals, deployedBlock, context.artifacts
            );
        }
        if (input.recordedOracle == address(0)) {
            OracleConfigFile.writeReference(input.oracleArtifact, input.market.oracle, context.artifacts);
        }

        console2.log("market     :", name);
        console2.log("  oracle          :", input.market.oracle);
        console2.log("  guardianSignals :", input.market.guardianSignals);
        console2.log("  controller      :", built.controller);
        console2.log("  vault           :", built.vault);
        console2.log("  recorded        :", _record(input, built, deployedBlock, context.artifacts));
    }

    function _loadMarketInput(string memory config, string memory name, RunContext memory context)
        internal
        returns (MarketInput memory input)
    {
        input.name = name;
        input.guardianGroup = MarketConfigFile.guardianGroup(name);
        input.oracleArtifact = MarketConfigFile.oracleArtifact(name);
        input.circuitBreakerArtifact = MarketConfigFile.circuitBreakerArtifact(name);
        (input.market, input.roles, input.vaultSpec, input.curveParams) = MarketConfigFile.read(name);

        _requireMarketRolePolicy(input.roles, context.agent, context.executor, msg.sender);
        OraclePreflight.validate(
            input.oracleArtifact,
            input.market.oracle,
            input.market.loanToken,
            input.market.collateralToken,
            context.agent
        );
        input.recordedOracle = OracleConfigFile.readDeployed(input.oracleArtifact);
        if (input.recordedOracle != address(0) && input.recordedOracle != input.market.oracle) {
            revert OracleArtifactMismatch(input.recordedOracle, input.market.oracle);
        }
        if (input.market.guardianSignals != address(0)) {
            _requireProxyAdmin(input.market.guardianSignals, context.agent);
        }
        {
            string memory protocolArtifact = vm.readFile(ProtocolConfigFile.protocolPath());
            DeployConfig memory deployConfig = DeployConfigFile.read(config);
            DeployConfigFile.requireRegistryGovernance(deployConfig, protocolArtifact);
            input.factory = vm.parseTomlAddress(protocolArtifact, ".protocol.factory");
            if (input.factory == address(0)) revert ConfigToml.MissingConfigValue(".protocol.factory");

            LidoLendMarketFactory deployedFactory = LidoLendMarketFactory(input.factory);
            address artifactCore = vm.parseTomlAddress(protocolArtifact, ".protocol.core");
            address factoryCore = address(deployedFactory.CORE());
            if (artifactCore != factoryCore) revert FactoryCoreMismatch(artifactCore, factoryCore);

            address artifactOwner = vm.parseTomlAddress(protocolArtifact, ".protocol.owner_facade");
            input.ownerFacade = address(deployedFactory.LIDO_LEND_OWNER());
            if (artifactOwner != input.ownerFacade) revert FactoryOwnerMismatch(artifactOwner, input.ownerFacade);

            address artifactIrmRouter = vm.parseTomlAddress(protocolArtifact, ".protocol.irm_router");
            input.irm = address(deployedFactory.IRM_ROUTER());
            if (artifactIrmRouter != input.irm) revert FactoryIrmRouterMismatch(artifactIrmRouter, input.irm);

            address artifactDashboard = vm.parseTomlAddress(protocolArtifact, ".protocol.risk_steward_dashboard");
            input.riskStewardDashboard = deployedFactory.RISK_STEWARD_DASHBOARD();
            if (artifactDashboard != input.riskStewardDashboard) {
                revert FactoryDashboardMismatch(artifactDashboard, input.riskStewardDashboard);
            }

            input.irmConfigFactory = vm.parseTomlAddress(protocolArtifact, ".protocol.irm_config_factory");
            if (input.irmConfigFactory == address(0)) {
                revert ConfigToml.MissingConfigValue(".protocol.irm_config_factory");
            }
        }
        if (input.market.guardianSignals != address(0)) {
            _validateReusedGuardianSignals(
                input.guardianGroup, input.factory, input.market.guardianSignals, context.agent
            );
        }
        input.recordedGuardianSignals = GuardianSignalsConfigFile.readDeployed(input.guardianGroup);
        if (
            input.recordedGuardianSignals != address(0) && input.recordedGuardianSignals != input.market.guardianSignals
        ) revert GuardianArtifactMismatch(input.recordedGuardianSignals, input.market.guardianSignals);

        Id proposedId = MarketParams({
                loanToken: input.market.loanToken,
                collateralToken: input.market.collateralToken,
                oracle: input.market.oracle,
                irm: input.irm,
                lltv: input.market.lltv
            }).id();
        ProtocolConfigFile.requireMarketUndeployed(name);
        ProtocolConfigFile.requireMarketIdUndeployed(Id.unwrap(proposedId));
        if (input.market.guardianSignals == address(0)) {
            GuardianSignalsConfigFile.requireUndeployed(input.guardianGroup);
        }
    }

    function _record(
        MarketInput memory input,
        LidoLendMarketFactory.MarketComponents memory built,
        uint256 deployedBlock,
        ArtifactMetadata memory artifacts
    ) internal returns (string memory path) {
        MarketDeployment memory md = MarketDeployment({
            name: input.name,
            oracleArtifact: input.oracleArtifact,
            guardianGroup: input.guardianGroup,
            circuitBreakerArtifact: input.circuitBreakerArtifact,
            id: Id.unwrap(built.marketId),
            factory: input.factory,
            controller: built.controller,
            vault: built.vault,
            irm: input.irm,
            ownerFacade: input.ownerFacade,
            riskStewardDashboard: input.riskStewardDashboard,
            market: input.market,
            roles: input.roles,
            vaultSpec: input.vaultSpec,
            curveParams: input.curveParams,
            deployedBlock: deployedBlock
        });

        path = ProtocolConfigFile.writeMarket(md, artifacts);
    }

    function _validateReusedGuardianSignals(
        string memory guardianGroup,
        address factory,
        address guardianSignals,
        address agent
    ) private view {
        GuardianSignalsConfig memory cfg = GuardianSignalsConfigFile.read(guardianGroup);
        if (cfg.admin != agent) revert UnexpectedAdmin(agent, cfg.admin);
        if (cfg.proxyAdmin != agent) revert UnexpectedProxyAdmin(agent, cfg.proxyAdmin);
        address[] memory managers = new address[](0);
        LidoLendMarketFactory(factory)
            .validateGuardianSignals(
                guardianSignals,
                LidoLendMarketFactory.GuardianSpec({
                    guardians: cfg.guardians, quorum: cfg.quorum, suspectWindow: cfg.suspectWindow
                }),
                LidoLendMarketFactory.GuardianRoles({
                    admin: agent, proxyAdmin: agent, managers: managers, accessLimiter: cfg.accessLimiter
                })
            );
    }
}
