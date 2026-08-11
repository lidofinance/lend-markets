// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IIrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/interfaces/IIrmConfigFactory.sol";

import {LidoLendMarketFactory} from "../src/periphery/LidoLendMarketFactory.sol";

import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {MarketConfigFile} from "./lib/MarketConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {ProtocolConfigFile, MarketDeployment} from "./lib/ProtocolConfigFile.sol";
import {GuardianSignalsConfigFile, GuardianSignalsConfig} from "./lib/GuardianSignalsConfigFile.sol";
import {ConfigToml} from "./lib/ConfigToml.sol";
import {OracleConfigFile} from "./lib/OracleConfigFile.sol";
import {OraclePreflight} from "./lib/OraclePreflight.sol";

/// @notice Deploys and records inert components for one market in an existing protocol.
contract AddMarket is Script, ProtocolDeployer {
    using MarketParamsLib for MarketParams;

    error GuardianArtifactMismatch(address artifactGuardianSignals, address configuredGuardianSignals);
    error MissingGuardianSignals(string guardianGroup);
    error OracleArtifactMismatch(address artifactOracle, address configuredOracle);
    error FactoryCoreMismatch(address artifactCore, address factoryCore);
    error FactoryOwnerMismatch(address artifactOwner, address factoryOwner);
    error FactoryIrmRouterMismatch(address artifactIrmRouter, address factoryIrmRouter);
    error FactoryDashboardMismatch(address artifactDashboard, address factoryDashboard);
    error FactoryAdminMismatch(address expected, address actual);
    error FactoryCircuitBreakerMismatch(address expected, address actual);

    struct RunContext {
        ArtifactMetadata artifacts;
        address agent;
    }

    struct MarketInput {
        string name;
        string role;
        string oracleArtifact;
        string guardianGroup;
        address factory;
        address irmRouter;
        address irmConfigFactory;
        address irmConfig;
        address ownerFacade;
        address riskStewardDashboard;
        address controllerAdmin;
        address circuitBreaker;
        LidoLendMarketFactory.MarketSpec market;
        LidoLendMarketFactory.ERC4626WrapperSpec erc4626WrapperSpec;
        AdaptiveCurveParams curveParams;
        address recordedOracle;
        address recordedGuardianSignals;
    }

    function run(string memory config, string memory name)
        external
        returns (Id marketId, address controller, address erc4626Wrapper)
    {
        RunContext memory context;
        {
            DeployConfig memory deployConfig = DeployConfigFile.read(config);
            _requireChainId(deployConfig.chainId);
            DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
            context =
                RunContext({artifacts: DeployConfigFile.artifactMetadata(deployConfig), agent: deployConfig.agent});
        }

        MarketInput memory input = _loadMarketInput(config, name, context);

        // Lower bound for auditing the controller's non-enumerable instant-activation mapping.
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();
        input.irmConfig = IIrmConfigFactory(input.irmConfigFactory).getOrDeployAdaptiveCurveConfig(input.curveParams);

        (marketId, controller, erc4626Wrapper) =
            LidoLendMarketFactory(input.factory).deployMarketComponents(input.market, input.erc4626WrapperSpec);
        vm.stopBroadcast();

        // A registry belongs to a guardian committee, not to a market, and several markets may share one, so it
        // is its own deploy step. Recorded here only when the market names an instance this run did not deploy.
        if (input.recordedGuardianSignals == address(0)) {
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
        console2.log("  controller      :", controller);
        console2.log("  vault           :", erc4626Wrapper);
        console2.log(
            "  recorded        :",
            _record(input, marketId, controller, erc4626Wrapper, deployedBlock, context.artifacts)
        );
    }

    function _loadMarketInput(string memory config, string memory name, RunContext memory context)
        internal
        returns (MarketInput memory input)
    {
        input.name = name;
        input.role = MarketConfigFile.role(name);
        input.guardianGroup = MarketConfigFile.guardianGroup(name);
        input.oracleArtifact = MarketConfigFile.oracleArtifact(name);
        (input.market, input.erc4626WrapperSpec, input.curveParams) = MarketConfigFile.read(name);
        input.recordedOracle = OracleConfigFile.readDeployed(input.oracleArtifact, context.artifacts);
        input.recordedGuardianSignals = GuardianSignalsConfigFile.readDeployed(input.guardianGroup, context.artifacts);

        OraclePreflight.validate(
            input.oracleArtifact,
            input.market.oracle,
            input.market.loanToken,
            input.market.collateralToken,
            context.agent
        );
        if (input.recordedOracle != address(0) && input.recordedOracle != input.market.oracle) {
            revert OracleArtifactMismatch(input.recordedOracle, input.market.oracle);
        }
        // Zero means neither the config nor the run names a registry for the group: deploy-guardian first. A
        // registry belongs to a guardian committee and may serve several markets, so it is its own deploy step.
        if (input.market.guardianSignals == address(0)) revert MissingGuardianSignals(input.guardianGroup);
        {
            string memory protocolArtifact =
                ArtifactMetadataFile.requireCompatible(ProtocolConfigFile.protocolPath(), context.artifacts);
            DeployConfig memory deployConfig = DeployConfigFile.read(config);
            DeployConfigFile.requireRegistryGovernance(deployConfig, protocolArtifact);
            input.factory = vm.parseTomlAddress(protocolArtifact, ".protocol.factory");
            if (input.factory == address(0)) revert ConfigToml.MissingConfigValue(".protocol.factory");

            LidoLendMarketFactory deployedFactory = LidoLendMarketFactory(input.factory);
            address artifactCore = vm.parseTomlAddress(protocolArtifact, ".protocol.core");
            address factoryCore = deployedFactory.LIDO_LEND();
            if (artifactCore != factoryCore) revert FactoryCoreMismatch(artifactCore, factoryCore);

            address artifactOwner = vm.parseTomlAddress(protocolArtifact, ".protocol.owner_facade");
            input.ownerFacade = address(deployedFactory.LIDO_LEND_OWNER());
            if (artifactOwner != input.ownerFacade) revert FactoryOwnerMismatch(artifactOwner, input.ownerFacade);

            address artifactIrmRouter = vm.parseTomlAddress(protocolArtifact, ".protocol.irm_router");
            input.irmRouter = address(deployedFactory.IRM_ROUTER());
            if (artifactIrmRouter != input.irmRouter) {
                revert FactoryIrmRouterMismatch(artifactIrmRouter, input.irmRouter);
            }

            address artifactDashboard = vm.parseTomlAddress(protocolArtifact, ".protocol.risk_steward_dashboard");
            input.riskStewardDashboard = deployedFactory.RISK_STEWARD_DASHBOARD();
            if (artifactDashboard != input.riskStewardDashboard) {
                revert FactoryDashboardMismatch(artifactDashboard, input.riskStewardDashboard);
            }

            input.controllerAdmin = deployedFactory.ADMIN();
            if (input.controllerAdmin != context.agent) {
                revert FactoryAdminMismatch(context.agent, input.controllerAdmin);
            }

            address artifactCircuitBreaker = vm.parseTomlAddress(protocolArtifact, ".protocol.circuit_breaker");
            input.circuitBreaker = deployedFactory.CIRCUIT_BREAKER();
            if (input.circuitBreaker != artifactCircuitBreaker) {
                revert FactoryCircuitBreakerMismatch(artifactCircuitBreaker, input.circuitBreaker);
            }
            _requireCircuitBreakerPolicy(input.circuitBreaker, deployConfig.evmScriptExecutor);

            input.irmConfigFactory = vm.parseTomlAddress(protocolArtifact, ".protocol.irm_config_factory");
            if (input.irmConfigFactory == address(0)) {
                revert ConfigToml.MissingConfigValue(".protocol.irm_config_factory");
            }
        }
        if (input.market.guardianSignals != address(0)) {
            _validateReusedGuardianSignals(input.guardianGroup, input.factory, input.market.guardianSignals);
        }
        if (
            input.recordedGuardianSignals != address(0) && input.recordedGuardianSignals != input.market.guardianSignals
        ) revert GuardianArtifactMismatch(input.recordedGuardianSignals, input.market.guardianSignals);

        Id proposedId = MarketParams({
            loanToken: input.market.loanToken,
            collateralToken: input.market.collateralToken,
            oracle: input.market.oracle,
            irm: input.irmRouter,
            lltv: input.market.lltv
        }).id();
        ProtocolConfigFile.requireMarketsCompatible(context.artifacts);
        ProtocolConfigFile.requireMarketUndeployed(name);
        ProtocolConfigFile.requireMarketIdUndeployed(Id.unwrap(proposedId));
        ProtocolConfigFile.requireMarketRoleUndeployed(input.role);
    }

    function _record(
        MarketInput memory input,
        Id marketId,
        address controller,
        address erc4626Wrapper,
        uint256 deployedBlock,
        ArtifactMetadata memory artifacts
    ) internal returns (string memory path) {
        MarketDeployment memory md = MarketDeployment({
            name: input.name,
            role: input.role,
            oracleArtifact: input.oracleArtifact,
            guardianGroup: input.guardianGroup,
            id: Id.unwrap(marketId),
            factory: input.factory,
            controller: controller,
            vault: erc4626Wrapper,
            irm: input.irmRouter,
            market: input.market,
            erc4626WrapperSpec: input.erc4626WrapperSpec,
            curveParams: input.curveParams,
            irmConfig: input.irmConfig,
            deployedBlock: deployedBlock
        });

        path = ProtocolConfigFile.writeMarket(md, artifacts);
    }

    function _validateReusedGuardianSignals(string memory guardianGroup, address factory, address guardianSignals)
        private
        view
    {
        GuardianSignalsConfig memory cfg = GuardianSignalsConfigFile.read(guardianGroup);
        LidoLendMarketFactory(factory)
            .validateGuardianSignals(
                guardianSignals,
                LidoLendMarketFactory.GuardianSpec({
                guardians: cfg.guardians, quorum: cfg.quorum, suspectWindow: cfg.suspectWindow
            })
            );
    }
}
