// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {ProtocolAddresses} from "./deployment/DeploymentTypes.sol";
import {PeripheryDeployment, VaultV2Plan, VaultV2Addresses} from "./deployment/PeripheryDeployment.sol";

abstract contract DeployVaultV2Base is Script, PeripheryDeployment {
    function run() external returns (VaultV2Addresses memory deployed) {
        ProtocolAddresses memory p = _deploymentProtocol();
        VaultV2Plan memory plan = _vaultPlan();
        vm.startBroadcast();
        deployed = _deployVaultV2(p, plan);
        vm.stopBroadcast();
    }

    function _deploymentProtocol() internal view virtual returns (ProtocolAddresses memory);
    function _vaultPlan() internal view virtual returns (VaultV2Plan memory);
}
