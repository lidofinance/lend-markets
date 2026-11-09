// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketDeployment} from "./deployment/MarketDeployment.sol";
import {ProtocolAddresses, MarketPlan, MarketDeploymentResult} from "./deployment/DeploymentTypes.sol";

import {DeploymentArtifact} from "./deployment/DeploymentArtifact.sol";
import {DeploymentHeader, DeploymentSchema, MarketRecord} from "./deployment/DeploymentRecord.sol";

abstract contract DeployMarketBase is Script, MarketDeployment {
    function run() external returns (MarketDeploymentResult memory deployed, string memory artifact) {
        ProtocolAddresses memory p = _deploymentProtocol();
        DeploymentArtifact.requireProtocol(p.chainId, p.core, true);
        MarketPlan memory plan = _deploymentPlan();
        DeploymentHeader memory h = DeploymentArtifact.header("market", plan.name, msg.sender);
        _checkPlan(p, plan);
        vm.startBroadcast();
        deployed = _deployMarket(p, plan);
        vm.stopBroadcast();
        artifact = vm.serializeJsonType(
            DeploymentSchema.MARKETRECORD,
            abi.encode(MarketRecord({header: h, core: p.core, role: plan.name, plan: plan, addresses: deployed}))
        );
        console2.log("market:", plan.name);
        console2.logBytes32(Id.unwrap(deployed.id));
        console2.log("controller:", deployed.controller);
        console2.log("vault:", deployed.vault);
        console2.log("price feed:", deployed.params.oracle);
        console2.log("guardian registry:", deployed.guardianSignals);
        console2.log("IRM config:", deployed.irmConfig);
    }

    function _deploymentProtocol() internal view virtual returns (ProtocolAddresses memory);
    function _deploymentPlan() internal view virtual returns (MarketPlan memory);
}
