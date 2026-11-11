// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolDeployment} from "../ProtocolDeployment.sol";
import {ProtocolAddresses, ProtocolPlan} from "../DeploymentTypes.sol";
import {Protocol as MainnetProtocol} from "./Protocol.sol";
import {DeploymentOutput} from "../DeploymentOutput.sol";

contract DeployProtocol is Script, ProtocolDeployment {
    function run() external returns (ProtocolAddresses memory p) {
        ProtocolPlan memory plan = MainnetProtocol.plan();
        vm.startBroadcast();
        p = _deployProtocol(plan, msg.sender);
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
