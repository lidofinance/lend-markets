// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {TrailingAnchorOracleBase} from "../src/oracle/TrailingAnchorOracleBase.sol";

import {LidoLendPrimitives} from "./lib/LidoLendPrimitives.sol";
import {NavOracleImplementation} from "./lib/NavOracleImplementation.sol";
import {NavOracleConfig, OracleConfigFile} from "./lib/OracleConfigFile.sol";
import {ArtifactMetadata} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";

/// @notice Deploys and records a proxied NAV oracle of the adapter kind its config names, initialized from the live
///         source. The DAO Agent is the proxy admin and the sole `DEFAULT_ADMIN_ROLE` holder, the EVMScriptExecutor
///         and the Agent hold `MANAGER_ROLE`, and the deploy config's price acceptor and the Agent hold
///         `PRICE_ACCEPTOR_ROLE`.
/// @dev The deployer initializes as the temporary admin, grants the final holders and renounces in the same
///      broadcast, so it holds no role once the broadcast ends.
contract DeployNavOracle is Script, LidoLendPrimitives {
    /// @notice The deploy config names no `price_acceptor`.
    error MissingPriceAcceptor();

    function run(string memory config, string memory name) external returns (address oracle) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        if (deployConfig.priceAcceptor == address(0)) revert MissingPriceAcceptor();
        ArtifactMetadata memory metadata = DeployConfigFile.artifactMetadata(deployConfig);
        DeployConfigFile.requireRunResourcesCompatible(metadata);
        DeployConfigFile.requireExistingProtocolCompatible(deployConfig);
        NavOracleConfig memory c = OracleConfigFile.readNav(name);
        OracleConfigFile.requireUndeployed(name);

        vm.startBroadcast();
        address impl = NavOracleImplementation.deploy(c);
        bytes memory init = abi.encodeCall(
            TrailingAnchorOracleBase.initialize,
            (msg.sender, c.maxPriceIncrease, c.maxPriceDecrease, c.anchorLifetime, c.maxAnchorRise, c.maxAnchorFall)
        );
        oracle = _behindProxy(impl, deployConfig.agent, init);
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(oracle);
        bytes32 managerRole = nav.MANAGER_ROLE();
        bytes32 priceAcceptorRole = nav.PRICE_ACCEPTOR_ROLE();
        bytes32 adminRole = nav.DEFAULT_ADMIN_ROLE();
        nav.grantRole(managerRole, deployConfig.evmScriptExecutor);
        nav.grantRole(managerRole, deployConfig.agent);
        nav.grantRole(priceAcceptorRole, deployConfig.priceAcceptor);
        nav.grantRole(priceAcceptorRole, deployConfig.agent);
        nav.grantRole(adminRole, deployConfig.agent);
        nav.renounceRole(adminRole, msg.sender);
        vm.stopBroadcast();

        console2.log("oracle          :", name);
        console2.log("  kind          :", c.kind);
        console2.log("  navOracle     :", oracle);
        console2.log("  source        :", c.source);
        console2.log("  anchor        :", nav.anchorPrice());
        console2.log("  recorded      :", OracleConfigFile.writeDeployed(name, oracle, metadata));
    }
}
