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
import {ProtocolConfigFile, MarketDeployment, ActivationPlan} from "./lib/ProtocolConfigFile.sol";

/// @notice Adds one market (`MARKET`) to an already-deployed protocol, via the same builder steps
///         `DeployProtocol` uses. Output is INERT; activation is a separate motion. With `REGISTRY` set the
///         result is appended there, else a standalone artifact is written.
/// @dev Draft, not production-ready. The builder address is read from the market config; the CircuitBreaker
///      from the deploy config (`CONFIG`, default mainnet).
///
/// Usage:
///   MARKET=weth-wsteth CONFIG=mainnet REGISTRY=deployed/mainnet-<ts>.toml \
///     forge script script/AddMarket.s.sol --rpc-url "$RPC_URL" --broadcast --private-key "$PK"
contract AddMarket is Script, ProtocolDeployer {
    function run() external returns (LidoLendMarketBuilder.MarketContracts memory built) {
        string memory name = vm.envString("MARKET");

        (
            address builder,
            LidoLendMarketBuilder.MarketSpec memory market,
            MarketRoles memory roles,
            AdaptiveCurveParams memory curve
        ) = MarketConfigFile.read(name);
        if (builder == address(0)) revert ConfigToml.MissingConfigValue(".builder");

        // One CircuitBreaker for all markets, from the deploy config (`CONFIG`, default mainnet); granted this
        // controller's PAUSER_ROLE, same as `DeployProtocol`.
        address circuitBreaker = DeployConfigFile.read(vm.envOr("CONFIG", string("mainnet"))).circuitBreaker;
        if (circuitBreaker != address(0)) {
            roles.pausers = new address[](1);
            roles.pausers[0] = circuitBreaker;
        }

        // Fail a doomed record before any contract is deployed, not after the broadcast.
        string memory registryPath = vm.envOr("REGISTRY", string(""));
        if (bytes(registryPath).length != 0) ProtocolConfigFile.requireMarketAbsent(registryPath, name);

        // Captured before the broadcast: a lower bound for this run's events, where acceptance's scan starts.
        uint256 deployedBlock = vm.getBlockNumber();

        vm.startBroadcast();

        if (market.guardianSignals == address(0)) market.guardianSignals = _buildGuardianSignals(name, builder);

        built = LidoLendMarketBuilder(builder).buildMarketContracts(market, roles);
        vm.stopBroadcast();

        address irmRouter = address(LidoLendMarketBuilder(builder).IRM_ROUTER());

        console2.log("market     :", name);
        console2.log("  oracle          :", market.oracle);
        console2.log("  guardianSignals :", market.guardianSignals);
        console2.log("  controller      :", built.controller);
        console2.log("  vault           :", built.vault);
        console2.log("  recorded        :", _record(name, market, roles.pausers, built, registryPath, deployedBlock));
        console2.log("  activationPlan  :", _writeActivationPlan(name, market, built, irmRouter, curve));
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

    /// @dev Append to the `REGISTRY` file, else write a standalone artifact; returns the path.
    function _record(
        string memory name,
        LidoLendMarketBuilder.MarketSpec memory market,
        address[] memory pausers,
        LidoLendMarketBuilder.MarketContracts memory built,
        string memory registryPath,
        uint256 deployedBlock
    ) internal returns (string memory path) {
        MarketDeployment memory md = MarketDeployment({
            name: name,
            id: Id.unwrap(built.marketId),
            controller: built.controller,
            vault: built.vault,
            oracle: market.oracle,
            guardianSignals: market.guardianSignals,
            pausers: pausers,
            deployedBlock: deployedBlock
        });

        if (bytes(registryPath).length != 0) {
            ProtocolConfigFile.appendMarket(registryPath, md);
            path = registryPath;
        } else {
            path = ProtocolConfigFile.writeMarketOnly(md);
        }
    }
}
