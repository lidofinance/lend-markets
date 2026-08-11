// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {UsdyStableOracle} from "../src/oracle/UsdyStableOracle.sol";

import {LidoLendPrimitives} from "./lib/LidoLendPrimitives.sol";
import {OracleConfigFile, UsdyOracleConfig} from "./lib/OracleConfigFile.sol";
import {ArtifactMetadata} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";

/// @notice Deploys and records a proxied `UsdyStableOracle`.
/// @dev Initialization binds the loan token, so each loan token needs its own instance.
contract DeployUsdyOracle is Script, LidoLendPrimitives {
    function run(string memory config, string memory name) external returns (address oracle) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        ArtifactMetadata memory metadata = DeployConfigFile.artifactMetadata(deployConfig);
        DeployConfigFile.requireRunResourcesCompatible(metadata);
        DeployConfigFile.requireExistingProtocolCompatible(deployConfig);
        UsdyOracleConfig memory c = OracleConfigFile.readUsdy(name);
        OracleConfigFile.requireUndeployed(name);

        vm.startBroadcast();
        address impl = address(new UsdyStableOracle(c.usdyOracle));
        bytes memory init = abi.encodeCall(UsdyStableOracle.initialize, (c.feed, c.loanToken));
        oracle = _behindProxy(impl, deployConfig.agent, init);
        vm.stopBroadcast();

        console2.log("oracle          :", name);
        console2.log("  usdyStableOracle :", oracle);
        console2.log("  recorded        :", OracleConfigFile.writeDeployed(name, oracle, metadata));
    }
}
