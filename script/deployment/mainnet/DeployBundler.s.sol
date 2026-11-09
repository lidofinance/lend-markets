// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {DeployBundlerBase} from "../../DeployBundlerBase.s.sol";
import {Protocol as MainnetProtocol} from "../generated/mainnet/Protocol.sol";
import {ProtocolAddresses} from "../DeploymentTypes.sol";
import {BundlerPlan} from "../PeripheryDeployment.sol";

contract DeployBundler is DeployBundlerBase, MainnetProtocol {
    function _deploymentProtocol() internal pure override returns (ProtocolAddresses memory) {
        return _protocolAddresses();
    }

    function _bundlerPlan() internal pure override returns (BundlerPlan memory) {
        return BundlerPlan({
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, wstEth: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
        });
    }
}
