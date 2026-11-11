// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {Protocol as MainnetProtocol} from "./Protocol.sol";
import {WethWstethMarket} from "./WethWstethMarket.sol";
import {ProtocolAddresses, MarketPlan, MarketDeploymentResult} from "../DeploymentTypes.sol";

contract DeployWethWsteth is Script, WethWstethMarket {
    function run() external returns (MarketDeploymentResult memory deployed) {
        ProtocolAddresses memory p = MainnetProtocol.addresses();
        address[] memory guardians = new address[](1);
        guardians[0] = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E;
        MarketPlan memory plan = _wethWstethPlan(guardians);
        vm.startBroadcast();
        deployed = _deployMarket(p, plan);
        vm.stopBroadcast();

        console2.log("market:", plan.name);
        console2.logBytes32(Id.unwrap(deployed.id));
        console2.log("controller:", deployed.controller);
        console2.log("vault:", deployed.vault);
        console2.log("price feed:", deployed.params.oracle);
        console2.log("guardian registry:", deployed.guardianSignals);
        console2.log("IRM config:", deployed.irmConfig);
    }
}
