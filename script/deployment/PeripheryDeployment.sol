// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CommonBase} from "forge-std/Base.sol";
import {LidoLendVaultAdapter} from "../../src/adapters/LidoLendVaultAdapter.sol";
import {ProtocolAddresses, BundlerParameters, BundlerAddresses} from "./DeploymentTypes.sol";

abstract contract PeripheryDeployment is CommonBase {
    function _deployBundler(ProtocolAddresses memory p, BundlerParameters memory parameters)
        internal
        returns (BundlerAddresses memory d)
    {
        _checkPeripheryProtocol(p);
        require(parameters.weth.code.length != 0 && parameters.wstEth.code.length != 0, "Missing bundler token");
        // The upstream dependencies pin a different compiler from the lending contracts.
        d.bundler = vm.deployCode("Bundler3.sol:Bundler3");
        d.generalAdapter = vm.deployCode(
            "EthereumGeneralAdapter1.sol:EthereumGeneralAdapter1",
            abi.encode(d.bundler, p.core, parameters.weth, parameters.wstEth)
        );
        d.vaultAdapter = address(new LidoLendVaultAdapter(d.bundler));
    }

    function _checkPeripheryProtocol(ProtocolAddresses memory p) private view {
        require(block.chainid == p.chainId, "Wrong periphery chain");
        require(p.core.code.length != 0 && p.irmRouter.code.length != 0, "Missing periphery protocol");
    }
}
