// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {UsdyStableOracle} from "../src/oracle/UsdyStableOracle.sol";

import {LidoLendPrimitives} from "./lib/LidoLendPrimitives.sol";
import {OracleConfigFile, UsdyOracleConfig} from "./lib/OracleConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";

/// @notice Deploys a standalone `UsdyStableOracle` behind an `OssifiableProxy`, recording its address to
///         `deployed/oracle-<name>.toml` for a market to resolve. The loan token bakes into the price at
///         `initialize`, so each market needs its own instance.
/// @dev Draft, not production-ready. `ORACLE` selects `script/config/oracles/<name>.toml`.
///
/// Usage:
///   forge script script/DeployUsdyOracle.s.sol --sig "run(string,string)" mainnet usdy-usdt --rpc-url "$RPC_URL"
/// --broadcast
contract DeployUsdyOracle is Script, LidoLendPrimitives {
    error UnexpectedProxyAdmin(address expected, address actual);

    function run(string memory config, string memory name) external returns (address oracle) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        UsdyOracleConfig memory c = OracleConfigFile.readUsdy(name);
        if (c.proxyAdmin != deployConfig.agent) revert UnexpectedProxyAdmin(deployConfig.agent, c.proxyAdmin);
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: deployConfig.chainId,
            configHash: deployConfig.configHash
        });
        ArtifactMetadataFile.ensureManifest(metadata);
        ArtifactMetadataFile.snapshotInput("deploy", DeployConfigFile.configPath(config));
        ArtifactMetadataFile.snapshotInput(string.concat("oracle-", name), OracleConfigFile.configPath(name));
        OracleConfigFile.requireUndeployed(name, metadata);

        vm.startBroadcast();
        address impl = address(new UsdyStableOracle(c.usdyOracle));
        bytes memory init = abi.encodeCall(UsdyStableOracle.initialize, (c.feed, c.loanToken));
        oracle = _behindProxy(impl, c.proxyAdmin, init);
        vm.stopBroadcast();

        console2.log("oracle          :", name);
        console2.log("  usdyStableOracle :", oracle);
        console2.log("  recorded        :", OracleConfigFile.writeDeployed(name, oracle, metadata));
    }
}
