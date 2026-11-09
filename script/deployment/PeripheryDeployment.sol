// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CommonBase} from "forge-std/Base.sol";
import {LidoLendVaultAdapter} from "../../src/adapters/LidoLendVaultAdapter.sol";
import {ProtocolAddresses} from "./DeploymentTypes.sol";

struct BundlerPlan {
    address weth;
    address wstEth;
}

struct BundlerAddresses {
    address bundler;
    address generalAdapter;
    address vaultAdapter;
}

struct VaultV2Plan {
    string name;
    address owner;
    address asset;
}

struct VaultV2Addresses {
    address vault;
    address adapter;
}

/// @notice Shared periphery construction for scripts and fork fixtures.
abstract contract PeripheryDeployment is CommonBase {
    function _deployBundler(ProtocolAddresses memory p, BundlerPlan memory plan)
        internal
        returns (BundlerAddresses memory d)
    {
        _checkPeripheryProtocol(p);
        require(plan.weth.code.length != 0 && plan.wstEth.code.length != 0, "Missing bundler token");
        // The upstream dependencies pin a different compiler from the lending contracts.
        d.bundler = vm.deployCode("Bundler3.sol:Bundler3");
        d.generalAdapter = vm.deployCode(
            "EthereumGeneralAdapter1.sol:EthereumGeneralAdapter1", abi.encode(d.bundler, p.core, plan.weth, plan.wstEth)
        );
        d.vaultAdapter = address(new LidoLendVaultAdapter(d.bundler));
    }

    function _deployVaultV2(ProtocolAddresses memory p, VaultV2Plan memory plan)
        internal
        returns (VaultV2Addresses memory d)
    {
        _checkPeripheryProtocol(p);
        require(plan.owner != address(0) && plan.asset.code.length != 0, "Invalid vault owner or asset");
        d.vault = vm.deployCode("VaultV2.sol:VaultV2", abi.encode(plan.owner, plan.asset));
        d.adapter = vm.deployCode(
            "MorphoMarketV1AdapterV2.sol:MorphoMarketV1AdapterV2", abi.encode(d.vault, p.core, p.irmRouter)
        );
    }

    function _checkPeripheryProtocol(ProtocolAddresses memory p) private view {
        require(block.chainid == p.chainId, "Wrong periphery chain");
        require(p.core.code.length != 0 && p.irmRouter.code.length != 0, "Missing periphery protocol");
    }
}
