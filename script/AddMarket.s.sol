// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

import {LidoLendMarketBuilder, MarketRoles} from "../src/periphery/LidoLendMarketBuilder.sol";

import {ConfigToml} from "./lib/ConfigToml.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {MarketConfigFile} from "./lib/MarketConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {ProtocolConfigFile, MarketDeployment, ActivationPlan} from "./lib/ProtocolConfigFile.sol";
import {GuardianSignalsConfigFile} from "./lib/GuardianSignalsConfigFile.sol";
import {OracleConfigFile} from "./lib/OracleConfigFile.sol";

/// @notice Adds one market to an already-deployed protocol, via the same builder steps
///         `DeployProtocol` uses. Output is INERT; activation is a separate motion. With `REGISTRY` set the
///         result is appended to the deployment's registry.
/// @dev Draft, not production-ready. The builder address is read from the market config; the CircuitBreaker
///      from the deploy config (`CONFIG`, default mainnet).
///
/// Usage:
///   forge script script/AddMarket.s.sol --sig "run(string,string)" mainnet weth-wsteth \
///     --rpc-url "$RPC_URL" --broadcast --private-key "$PK"
contract AddMarket is Script, ProtocolDeployer {
    error RegistryBuilderMismatch(address registryBuilder, address configBuilder);

    struct RunContext {
        string deployment;
        string network;
        uint256 chainId;
        bytes32 configHash;
    }

    struct MarketRecordInput {
        string name;
        LidoLendMarketBuilder.MarketSpec market;
        address[] pausers;
        LidoLendMarketBuilder.MarketContracts built;
        string registryPath;
        uint256 deployedBlock;
        RunContext context;
    }

    struct ActivationPlanInput {
        string name;
        LidoLendMarketBuilder.MarketSpec market;
        LidoLendMarketBuilder.MarketContracts built;
        address irmRouter;
        AdaptiveCurveParams curve;
        RunContext context;
    }

    function run(string memory config, string memory name)
        external
        returns (LidoLendMarketBuilder.MarketContracts memory built)
    {
        // One CircuitBreaker for all markets, from the deploy config (`CONFIG`, default mainnet); granted this
        // controller's PAUSER_ROLE, same as `DeployProtocol`.
        RunContext memory context;
        address circuitBreaker;
        {
            DeployConfig memory deployConfig = DeployConfigFile.read(config);
            _requireChainId(deployConfig.chainId);
            context = RunContext({
                deployment: ArtifactMetadataFile.deployment(),
                network: deployConfig.network,
                chainId: deployConfig.chainId,
                configHash: deployConfig.configHash
            });
            circuitBreaker = deployConfig.circuitBreaker;
        }

        string memory guardianGroup = MarketConfigFile.guardianGroup(name);
        (
            address builder,
            LidoLendMarketBuilder.MarketSpec memory market,
            MarketRoles memory roles,
            AdaptiveCurveParams memory curve
        ) = MarketConfigFile.read(
            name,
            ArtifactMetadata({
                deployment: context.deployment,
                chainId: context.chainId,
                configHash: context.configHash
            })
        );
        if (builder == address(0)) revert ConfigToml.MissingConfigValue(".builder");
        if (circuitBreaker != address(0)) {
            roles.pausers = new address[](1);
            roles.pausers[0] = circuitBreaker;
        }

        // Fail a doomed record before any contract is deployed, not after the broadcast.
        ArtifactMetadata memory artifacts = ArtifactMetadata({
            deployment: context.deployment,
            chainId: context.chainId,
            configHash: context.configHash
        });
        ArtifactMetadataFile.requireManifest(artifacts);
        ArtifactMetadataFile.snapshotInput("deploy", DeployConfigFile.configPath(config));
        ArtifactMetadataFile.snapshotInput(string.concat("market-", name), MarketConfigFile.marketPath(name));
        ArtifactMetadataFile.snapshotInput(
            string.concat("guardian-", guardianGroup), GuardianSignalsConfigFile.configPath(guardianGroup)
        );
        ArtifactMetadataFile.snapshotInput(
            string.concat("oracle-", MarketConfigFile.oracleArtifact(name)),
            OracleConfigFile.configPath(MarketConfigFile.oracleArtifact(name))
        );
        string memory registryPath = ProtocolConfigFile.deployedPath();
        {
            string memory registry = vm.readFile(registryPath);
            ArtifactMetadataFile.requireMatch(registry, artifacts, "protocol-registry");
            address registryBuilder = vm.parseTomlAddress(registry, ".protocol.builder");
            if (builder != registryBuilder) revert RegistryBuilderMismatch(registryBuilder, builder);
        }
        ProtocolConfigFile.requireMarketAbsent(registryPath, name);
        ProtocolConfigFile.requireActivationPlanUndeployed(name);
        if (market.guardianSignals == address(0)) {
            GuardianSignalsConfigFile.requireUndeployed(guardianGroup, artifacts);
        }

        // Captured before the broadcast: a lower bound for this run's events, where acceptance's scan starts.
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();

        if (market.guardianSignals == address(0)) {
            market.guardianSignals = _buildGuardianSignals(guardianGroup, builder);
            GuardianSignalsConfigFile.writeDeployed(guardianGroup, market.guardianSignals, artifacts);
        }

        built = LidoLendMarketBuilder(builder).buildMarketContracts(market, roles);
        vm.stopBroadcast();

        address irmRouter = address(LidoLendMarketBuilder(builder).IRM_ROUTER());

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
            record.context = context;
            console2.log("  recorded        :", _record(record));
        }
        {
            ActivationPlanInput memory activation;
            activation.name = name;
            activation.market = market;
            activation.built = built;
            activation.irmRouter = irmRouter;
            activation.curve = curve;
            activation.context = context;
            console2.log("  activationPlan  :", _writeActivationPlan(activation));
        }
    }

    /// @dev Writes this market's activation-motion inputs to a per-market artifact.
    function _writeActivationPlan(ActivationPlanInput memory input) internal returns (string memory) {
        return ProtocolConfigFile.writeActivationPlan(
            ActivationPlan({
                name: input.name,
                deployment: input.context.deployment,
                network: input.context.network,
                chainId: input.context.chainId,
                configHash: input.context.configHash,
                loanToken: input.market.loanToken,
                collateralToken: input.market.collateralToken,
                oracle: input.market.oracle,
                irm: input.irmRouter,
                lltv: input.market.lltv,
                controller: input.built.controller,
                curveParams: input.curve
            })
        );
    }

    /// @dev Append to the `REGISTRY` file, else write a standalone artifact; returns the path.
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
}
