// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {ProtocolAddresses} from "./deployment/DeploymentTypes.sol";
import {PeripheryDeployment, BundlerPlan, BundlerAddresses} from "./deployment/PeripheryDeployment.sol";

abstract contract DeployBundlerBase is Script, PeripheryDeployment {
    function run() external returns (BundlerAddresses memory deployed) {
        ProtocolAddresses memory p = _deploymentProtocol();
        BundlerPlan memory plan = _bundlerPlan();
        vm.startBroadcast();
        deployed = _deployBundler(p, plan);
        vm.stopBroadcast();
    }

    function _deploymentProtocol() internal view virtual returns (ProtocolAddresses memory);
    function _bundlerPlan() internal view virtual returns (BundlerPlan memory);
}
