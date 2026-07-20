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
    Deployment,
    MarketDeployment,
    ActivationPlan
} from "./lib/ProtocolConfigFile.sol";
import {ExitBookConfig} from "./lib/ExitBookConfigFile.sol";
import {MarketConfigFile} from "./lib/MarketConfigFile.sol";

/// @notice Deploys the full protocol from scratch for the config named by `CONFIG` (`script/config/<name>.toml`):
///         backbone, optional exit books, and each configured market's inert components. Output is INERT;
///         activation is a separate governance motion.
/// @dev Draft, not production-ready. Thin orchestrator over `ProtocolDeployer`.
///
/// Usage:
///   CONFIG=mainnet forge script script/DeployProtocol.s.sol --rpc-url "$RPC_URL" --broadcast --private-key "$PK"
contract DeployProtocol is Script, ProtocolDeployer {
    function run() external returns (ProtocolDeployment memory protocol) {
        string memory config = vm.envOr("CONFIG", string("mainnet"));
        DeployConfig memory cfg = DeployConfigFile.read(config);
        address deployer = msg.sender;

        // Captured before the broadcast: a lower bound for this run's events, where acceptance's scan starts.
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();

        protocol =
            _deployBackbone(ProtocolConfig({agent: cfg.agent, evmScriptExecutor: cfg.evmScriptExecutor}), deployer);
        protocol.deployedBlock = deployedBlock;
        protocol.deployer = deployer;
        protocol.circuitBreaker = cfg.circuitBreaker;

        Deployment memory registry;
        registry.protocol = protocol;

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
            registry.hasExitBooks = true;
            registry.morphoExitBook = morpho;
            registry.erc4626ExitBook = erc4626;
            console2.log("morphoExitBook  :", morpho);
            console2.log("erc4626ExitBook :", erc4626);
        }

        registry.markets = new MarketDeployment[](cfg.markets.length);
        for (uint256 i; i < cfg.markets.length; ++i) {
            registry.markets[i] = _addMarket(cfg.markets[i], protocol, deployedBlock);
        }

        vm.stopBroadcast();

        console2.log("=== protocol ===");
        console2.log("core            :", protocol.core);
        console2.log("ownerFacade     :", protocol.ownerFacade);
        console2.log("irmRouter       :", protocol.irmRouter);
        console2.log("factory         :", protocol.factory);
        console2.log("builder         :", protocol.builder);
        console2.log("riskStewardDash :", protocol.riskStewardDashboard);
        console2.log("registry        :", ProtocolConfigFile.writeDeployment(config, registry));
    }

    /// @dev Deploys one market via the builder, deploying a fresh `GuardianSignals` instance first when the
    ///      config leaves it zero.
    function _addMarket(string memory name, ProtocolDeployment memory protocol, uint256 deployedBlock)
        internal
        returns (MarketDeployment memory md)
    {
        (, LidoLendMarketBuilder.MarketSpec memory market, MarketRoles memory roles, AdaptiveCurveParams memory curve) =
            MarketConfigFile.read(name);

        // One CircuitBreaker for all markets, from the deploy config; granted this controller's PAUSER_ROLE.
        // Zero (template) leaves the market without a pauser.
        if (protocol.circuitBreaker != address(0)) {
            roles.pausers = new address[](1);
            roles.pausers[0] = protocol.circuitBreaker;
        }

        if (market.guardianSignals == address(0)) {
            market.guardianSignals = _buildGuardianSignals(name, protocol.builder);
        }

        LidoLendMarketBuilder.MarketContracts memory built =
            LidoLendMarketBuilder(protocol.builder).buildMarketContracts(market, roles);

        console2.log("--- market:", name);
        console2.log("  oracle          :", market.oracle);
        console2.log("  guardianSignals :", market.guardianSignals);
        console2.log("  controller      :", built.controller);
        console2.log("  vault           :", built.vault);
        console2.log("  activationPlan  :", _writeActivationPlan(name, market, built, protocol.irmRouter, curve));

        md = MarketDeployment({
            name: name,
            id: Id.unwrap(built.marketId),
            controller: built.controller,
            vault: built.vault,
            oracle: market.oracle,
            guardianSignals: market.guardianSignals,
            pausers: roles.pausers,
            deployedBlock: deployedBlock
        });
    }

    /// @dev Writes this market's activation-motion inputs to a per-market artifact.
    function _writeActivationPlan(
        string memory name,
        LidoLendMarketBuilder.MarketSpec memory market,
        LidoLendMarketBuilder.MarketContracts memory built,
        address irmRouter,
        AdaptiveCurveParams memory curve
    ) internal returns (string memory) {
        return ProtocolConfigFile.writeActivationPlan(
            ActivationPlan({
                name: name,
                loanToken: market.loanToken,
                collateralToken: market.collateralToken,
                oracle: market.oracle,
                irm: irmRouter,
                lltv: market.lltv,
                controller: built.controller,
                curveParams: curve
            })
        );
    }
}
