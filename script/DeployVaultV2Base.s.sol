// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {ProtocolAddresses} from "./deployment/DeploymentTypes.sol";
import {PeripheryDeployment, VaultV2Plan, VaultV2Addresses} from "./deployment/PeripheryDeployment.sol";
import {DeploymentArtifact} from "./deployment/DeploymentArtifact.sol";
import {DeploymentHeader, VaultV2Record, DeploymentSchema} from "./deployment/DeploymentRecord.sol";

abstract contract DeployVaultV2Base is Script, PeripheryDeployment {
    function run() external returns (VaultV2Addresses memory deployed, string memory artifact) {
        ProtocolAddresses memory p = _deploymentProtocol();
        DeploymentArtifact.requireProtocol(p.chainId, p.core, true);
        VaultV2Plan memory plan = _vaultPlan();
        DeploymentHeader memory h = DeploymentArtifact.header("vault", plan.name, msg.sender);
        vm.startBroadcast();
        deployed = _deployVaultV2(p, plan);
        vm.stopBroadcast();
        artifact = vm.serializeJsonType(
            DeploymentSchema.VAULTV2RECORD,
            abi.encode(
                VaultV2Record({header: h, core: p.core, irmRouter: p.irmRouter, plan: plan, addresses: deployed})
            )
        );
    }

    function _deploymentProtocol() internal view virtual returns (ProtocolAddresses memory);
    function _vaultPlan() internal view virtual returns (VaultV2Plan memory);
}
