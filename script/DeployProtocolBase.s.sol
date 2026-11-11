// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolDeployment} from "./deployment/ProtocolDeployment.sol";
import {ProtocolAddresses, ProtocolPlan} from "./deployment/DeploymentTypes.sol";

abstract contract DeployProtocolBase is Script, ProtocolDeployment {
    function run() external returns (ProtocolAddresses memory p) {
        ProtocolPlan memory plan = _protocolPlan();
        vm.startBroadcast();
        p = _deployProtocol(plan, msg.sender);
        vm.stopBroadcast();

        console2.log("core:", p.core);
        console2.log("factory:", p.factory);
        console2.log("circuit breaker:", p.circuitBreaker);
    }

    function _protocolPlan() internal view virtual returns (ProtocolPlan memory);
}
