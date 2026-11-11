// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {Protocol as MainnetProtocol} from "./Protocol.sol";
import {ProtocolAddresses} from "../DeploymentTypes.sol";
import {PeripheryDeployment, BundlerPlan, BundlerAddresses} from "../PeripheryDeployment.sol";
import {DeploymentOutput} from "../DeploymentOutput.sol";

contract DeployBundler is Script, PeripheryDeployment {
    function run() external returns (BundlerAddresses memory deployed) {
        ProtocolAddresses memory p = MainnetProtocol.addresses();
        BundlerPlan memory plan = BundlerPlan({
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, wstEth: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
        });
        vm.startBroadcast();
        deployed = _deployBundler(p, plan);
        vm.stopBroadcast();

        vm.serializeAddress("bundler", "bundler", deployed.bundler);
        vm.serializeAddress("bundler", "general_adapter", deployed.generalAdapter);
        DeploymentOutput.write(
            "deployed/mainnet", "bundler", vm.serializeAddress("bundler", "vault_adapter", deployed.vaultAdapter)
        );
    }
}
