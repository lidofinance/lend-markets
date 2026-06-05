// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

import {MorphoForkDeployer} from "./lib/MorphoForkDeployer.sol";

/// @notice Deploy script for a wstETH/WETH lending market on the lido-lending fork. Delegates
///         the actual deploy steps to `MorphoForkDeployer` so tests can reuse the same logic.
///
/// @dev See `script/DEPLOYMENT.md` for the matching runbook.
///
/// Usage (dry run against a fork):
///   forge script script/DeployMarket.s.sol --fork-url "$MAINNET_RPC_URL" --sender "$DEPLOYER" -vvv
///
/// Usage (broadcast):
///   forge script script/DeployMarket.s.sol --rpc-url "$RPC_URL" --broadcast --private-key "$PK" \
///     --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
contract DeployMarket is Script, MorphoForkDeployer {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    uint256 internal constant LLTV = 0.8e18;

    function run() external returns (Deployed memory d) {
        vm.startBroadcast();
        d = _deployForkStack(
            DeployConfig({
                admin: msg.sender,
                loanToken: WETH,
                collateralToken: WSTETH,
                oracleSource: WSTETH,
                lltv: LLTV,
                fallbackEnabled: true
            })
        );
        vm.stopBroadcast();

        _logDeployment(d);
    }

    function _logDeployment(Deployed memory d) internal pure {
        console2.log("core               :", d.core);
        console2.log("accessRegistry     :", d.accessRegistry);
        console2.log("oracle             :", d.oracle);
        console2.log("irm                :", d.irm);
        console2.log("controller (proxy) :", d.controllerProxy);
        console2.log("controller (impl)  :", d.controllerImpl);
        console2.logBytes32(Id.unwrap(d.marketId));
    }
}
