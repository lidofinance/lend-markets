// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {ProtocolAddresses} from "./deployment/DeploymentTypes.sol";
import {PeripheryDeployment, BundlerPlan, BundlerAddresses} from "./deployment/PeripheryDeployment.sol";
import {DeploymentArtifact} from "./deployment/DeploymentArtifact.sol";
import {DeploymentHeader, BundlerRecord, DeploymentSchema} from "./deployment/DeploymentRecord.sol";

abstract contract DeployBundlerBase is Script, PeripheryDeployment {
    function run() external returns (BundlerAddresses memory deployed, string memory artifact) {
        ProtocolAddresses memory p = _deploymentProtocol();
        DeploymentArtifact.requireProtocol(p.chainId, p.core, true);
        BundlerPlan memory plan = _bundlerPlan();
        DeploymentHeader memory h = DeploymentArtifact.header("bundler", "bundler", msg.sender);
        vm.startBroadcast();
        deployed = _deployBundler(p, plan);
        vm.stopBroadcast();
        artifact = vm.serializeJsonType(
            DeploymentSchema.BUNDLERRECORD,
            abi.encode(BundlerRecord({header: h, core: p.core, plan: plan, addresses: deployed}))
        );
    }

    function _deploymentProtocol() internal view virtual returns (ProtocolAddresses memory);
    function _bundlerPlan() internal view virtual returns (BundlerPlan memory);
}
