// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {WstEthRateOracle} from "../src/oracle/WstEthRateOracle.sol";

import {LidoLendPrimitives} from "./lib/LidoLendPrimitives.sol";
import {OracleConfigFile, WstEthOracleConfig} from "./lib/OracleConfigFile.sol";

/// @notice Deploys a standalone `WstEthRateOracle` behind an `OssifiableProxy`, recording its address to
///         `deployed/oracle-<name>.toml` for a market to resolve.
/// @dev Draft, not production-ready. `ORACLE` selects `script/config/oracles/<name>.toml`.
///
/// Usage:
///   ORACLE=weth-wsteth forge script script/DeployWstEthOracle.s.sol --rpc-url "$RPC_URL" --broadcast
contract DeployWstEthOracle is Script, LidoLendPrimitives {
    function run() external returns (address oracle) {
        string memory name = vm.envString("ORACLE");
        WstEthOracleConfig memory c = OracleConfigFile.readWstEth(name);

        vm.startBroadcast();
        address impl = address(new WstEthRateOracle(c.wstETH));
        oracle = _behindProxy(impl, c.proxyAdmin, "");
        vm.stopBroadcast();

        console2.log("oracle          :", name);
        console2.log("  wstEthRateOracle :", oracle);
        console2.log("  recorded        :", OracleConfigFile.writeDeployed(name, oracle));
    }
}
