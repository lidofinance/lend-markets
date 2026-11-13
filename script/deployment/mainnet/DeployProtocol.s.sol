// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolDeployment} from "../ProtocolDeployment.sol";
import {ProtocolAddresses, ProtocolParameters, CircuitBreakerParameters} from "../DeploymentTypes.sol";
import {DeploymentOutput} from "../DeploymentOutput.sol";

contract DeployProtocol is Script, ProtocolDeployment {
    function parameters() public pure returns (ProtocolParameters memory p) {
        p.chainId = 1;
        p.agent = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;
        p.executor = 0xFE5986E06210aC1eCC1aDCafc0cc7f8D63B3F977;
        p.resealManager = 0x7914b5a1539b97Bd0bbd155757F25FD79A522d24;
        p.circuitBreakerParameters = CircuitBreakerParameters({
            minPauseDuration: 5 days,
            maxPauseDuration: 60 days,
            minHeartbeatInterval: 30 days,
            maxHeartbeatInterval: 1095 days,
            initialPauseDuration: 21 days,
            initialHeartbeatInterval: 365 days
        });
    }

    function run() external returns (ProtocolAddresses memory p) {
        ProtocolParameters memory inputs = parameters();
        vm.startBroadcast();
        p = _deployProtocol(inputs, msg.sender);
        vm.stopBroadcast();

        vm.serializeAddress("protocol", "core", p.core);
        vm.serializeAddress("protocol", "factory", p.factory);
        vm.serializeAddress("protocol", "owner_facade", p.ownerFacade);
        vm.serializeAddress("protocol", "irm_router", p.irmRouter);
        vm.serializeAddress("protocol", "adaptive_curve_irm", p.adaptiveCurveIrm);
        vm.serializeAddress("protocol", "irm_config_factory", p.irmConfigFactory);
        vm.serializeAddress("protocol", "dashboard", p.dashboard);
        vm.serializeAddress("protocol", "circuit_breaker", p.circuitBreaker);
        vm.serializeAddress("protocol", "reseal_manager", p.resealManager);
        vm.serializeAddress("protocol", "agent", p.agent);
        DeploymentOutput.write("deployed/mainnet", "protocol", vm.serializeAddress("protocol", "executor", p.executor));

        console2.log("core:", p.core);
        console2.log("factory:", p.factory);
        console2.log("circuit breaker:", p.circuitBreaker);
    }
}
