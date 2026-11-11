// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {Protocol as MainnetProtocol} from "./Protocol.sol";
import {WethWstethMarket} from "./WethWstethMarket.sol";
import {ProtocolAddresses, MarketPlan, MarketDeploymentResult} from "../DeploymentTypes.sol";
import {DeploymentOutput} from "../DeploymentOutput.sol";

contract DeployWethWsteth is Script, WethWstethMarket {
    function run() external returns (MarketDeploymentResult memory deployed) {
        ProtocolAddresses memory p = MainnetProtocol.addresses();
        address[] memory guardians = new address[](1);
        guardians[0] = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E;
        MarketPlan memory plan = _wethWstethPlan(guardians);
        vm.startBroadcast();
        deployed = _deployMarket(p, plan);
        vm.stopBroadcast();

        vm.serializeBytes32(plan.name, "market_id", Id.unwrap(deployed.id));
        vm.serializeAddress(plan.name, "core", p.core);
        vm.serializeAddress(plan.name, "loan_token", deployed.params.loanToken);
        vm.serializeAddress(plan.name, "collateral_token", deployed.params.collateralToken);
        vm.serializeAddress(plan.name, "irm", deployed.params.irm);
        vm.serializeAddress(plan.name, "controller", deployed.controller);
        vm.serializeAddress(plan.name, "vault", deployed.vault);
        vm.serializeAddress(plan.name, "price_feed", deployed.params.oracle);
        vm.serializeAddress(plan.name, "guardian_signals", deployed.guardianSignals);
        DeploymentOutput.write(
            "deployed/mainnet/markets", plan.name, vm.serializeAddress(plan.name, "irm_config", deployed.irmConfig)
        );

        console2.log("market:", plan.name);
        console2.logBytes32(Id.unwrap(deployed.id));
        console2.log("controller:", deployed.controller);
        console2.log("vault:", deployed.vault);
        console2.log("price feed:", deployed.params.oracle);
        console2.log("guardian registry:", deployed.guardianSignals);
        console2.log("IRM config:", deployed.irmConfig);
    }
}
