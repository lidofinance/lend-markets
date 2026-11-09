// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolDeployment} from "./deployment/ProtocolDeployment.sol";
import {ProtocolAddresses, ProtocolPlan} from "./deployment/DeploymentTypes.sol";

import {DeploymentArtifact} from "./deployment/DeploymentArtifact.sol";
import {DeploymentHeader, DeploymentSchema, ProtocolRecord} from "./deployment/DeploymentRecord.sol";

abstract contract DeployProtocolBase is Script, ProtocolDeployment {
    function run() external returns (ProtocolAddresses memory p, string memory artifact) {
        ProtocolPlan memory plan = _protocolPlan();
        DeploymentHeader memory h = DeploymentArtifact.header("protocol", "protocol", msg.sender);
        vm.startBroadcast();
        p = _deployProtocol(plan, msg.sender);
        vm.stopBroadcast();
        artifact = vm.serializeJsonType(
            DeploymentSchema.PROTOCOLRECORD, abi.encode(ProtocolRecord({header: h, addresses: p, plan: plan}))
        );
        console2.log("core:", p.core);
        console2.log("factory:", p.factory);
        console2.log("circuit breaker:", p.circuitBreaker);
    }

    function _protocolPlan() internal view virtual returns (ProtocolPlan memory);
}
