// SPDX-License-Identifier: GPL-2.0-or-later
// Matches the core's 0.8.19 pin so the LidoBlue import below shares its compilation unit; the script
// itself only orchestrates deploys, so its compiler version does not affect deployed bytecode.
pragma solidity >=0.8.19;

import {Script, console2} from "forge-std/Script.sol";

import {Id} from "@lido-blue/src/interfaces/IMorpho.sol";

import {LidoBlueDeployer} from "./lib/LidoBlueDeployer.sol";

// The core lives in lib/lido-blue and is deployed via vm.getCode, which needs its artifact in out/.
// forge script compiles src+script (not test), so import the concrete type here to force that artifact
// to build. Unused by name on purpose.
import {LidoBlue} from "@lido-blue/src/LidoBlue.sol";

/// @notice Deploy script for a wstETH/WETH lending market on the lido-lending fork. Delegates the
///         actual deploy steps to `LidoBlueDeployer` so tests can reuse the same logic.
///
/// @dev Draft, not production-ready. The activation parameters and registry bootstrap below are
///      placeholders — tune them (governance values) before any real deploy. See `script/DEPLOYMENT.md`.
///
/// Usage (dry run against a fork):
///   forge script script/DeployMarket.s.sol --fork-url "$MAINNET_RPC_URL" --sender "$DEPLOYER" -vvv
///
/// Usage (broadcast):
///   forge script script/DeployMarket.s.sol --rpc-url "$RPC_URL" --broadcast --private-key "$PK" \
///     --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
contract DeployMarket is Script, LidoBlueDeployer {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    uint256 internal constant LLTV = 0.8e18;

    function run() external returns (Deployed memory d) {
        // Placeholder bootstrap: deployer is the sole guardian, quorum 1 (the registry rejects quorum 0).
        // Replace with the real guardian set + quorum post-deploy.
        address[] memory guardians = new address[](1);
        guardians[0] = msg.sender;

        vm.startBroadcast();
        d = _deployForkStack(
            DeployConfig({
                admin: msg.sender,
                loanToken: WETH,
                collateralToken: WSTETH,
                oracleSource: WSTETH,
                lltv: LLTV,
                deleverageEnabled: true,
                // DRAFT activation parameters — governance values, tune before any real deploy.
                activation: ActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    maxSuspicionDelay: 2 hours,
                    maxDecayDuration: 4 hours,
                    maxDelayLoad: 10_000 ether,
                    minActivationAmount: 10 ether,
                    minDecayAmount: 1_000 ether
                }),
                guardians: guardians,
                quorum: 1,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );
        vm.stopBroadcast();

        _logDeployment(d);
    }

    function _logDeployment(Deployed memory d) internal pure {
        console2.log("core               :", d.core);
        console2.log("suspectsRegistry   :", d.suspectsRegistry);
        console2.log("oracle             :", d.oracle);
        console2.log("irm                :", d.irm);
        console2.log("controller (proxy) :", d.controllerProxy);
        console2.log("controller (impl)  :", d.controllerImpl);
        console2.log("vault              :", d.vault);
        console2.logBytes32(Id.unwrap(d.marketId));
    }
}
