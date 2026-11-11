// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolDeployment} from "../ProtocolDeployment.sol";
import {ProtocolAddresses, ProtocolPlan} from "../DeploymentTypes.sol";
import {Protocol as MainnetProtocol} from "./Protocol.sol";

contract DeployProtocol is Script, ProtocolDeployment {
    function run() external returns (ProtocolAddresses memory p) {
        ProtocolPlan memory plan = MainnetProtocol.plan();
        vm.startBroadcast();
        p = _deployProtocol(plan, msg.sender);
        vm.stopBroadcast();

        console2.log("core:", p.core);
        console2.log("factory:", p.factory);
        console2.log("circuit breaker:", p.circuitBreaker);
    }
}
