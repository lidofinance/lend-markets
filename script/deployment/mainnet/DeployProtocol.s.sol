// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {DeployProtocolBase} from "../../DeployProtocolBase.s.sol";
import {ProtocolPlan, CircuitBreakerPlan} from "../DeploymentTypes.sol";

contract DeployProtocol is DeployProtocolBase {
    function _protocolPlan() internal pure override returns (ProtocolPlan memory plan) {
        plan.chainId = 1;
        plan.agent = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;
        plan.executor = 0xFE5986E06210aC1eCC1aDCafc0cc7f8D63B3F977;
        plan.resealManager = 0x7914b5a1539b97Bd0bbd155757F25FD79A522d24;
        plan.circuitBreakerPlan = CircuitBreakerPlan({
            minPauseDuration: 5 days,
            maxPauseDuration: 60 days,
            minHeartbeatInterval: 30 days,
            maxHeartbeatInterval: 1095 days,
            initialPauseDuration: 21 days,
            initialHeartbeatInterval: 365 days
        });
    }
}
