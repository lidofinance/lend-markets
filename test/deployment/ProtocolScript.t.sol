// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {BundlerAddresses, BundlerParameters, DeployBundlerBase} from "../../script/deployment/DeployBundlerBase.s.sol";
import {MarketDeploymentResult} from "../../script/deployment/DeployMarketBase.s.sol";
import {ProtocolAddresses, ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {ForkStack, IEVMScriptExecutor} from "../fork/helpers/ForkStack.sol";

/// @dev An adapter's bundler and, for the general adapter, its core.
interface IAdapterView {
    function BUNDLER3() external view returns (address);
    function MORPHO() external view returns (address);
}

/// @dev The bundler script with no record, so `getOrDeploy` deploys a new bundler.
contract UnrecordedBundlerScript is DeployBundlerBase {
    function getConfig() public pure override returns (BundlerParameters memory c) {
        c.weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        c.wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    }
}

/// @notice The core and bundler scripts' deployments on the default fork, mainnet, from no record: a new protocol that
///         the market script accepts and the activation EVMScript creates a market on, and a new bundler over it.
contract ProtocolScriptTest is ForkStack, ProtocolDeployer {
    function setUp() public {
        _forkTarget(false);
    }

    function test_newProtocol_takesAMarketCreatedThroughTheExecutor() public {
        ProtocolAddresses memory p = _deployProtocol(network.core.getConfig(), address(0), address(this));
        assertTrue(p.core != protocol.core, "a new core");
        MarketDeploymentResult memory d = script.deploy(p, script.getDeployConfig());
        IEVMScriptExecutor executor = IEVMScriptExecutor(p.executor);
        bytes memory evmScript = script.activationScript(p, d);
        vm.prank(executor.easyTrack());
        executor.executeEVMScript(evmScript);
        assertEq(ILidoLend(p.core).marketController(d.id), d.controller, "the market is created on the new core");
    }

    function test_newBundler_overTheProtocol() public {
        BundlerAddresses memory b = new UnrecordedBundlerScript().getOrDeploy(protocol);
        assertGt(b.bundler.code.length, 0, "a new bundler");
        assertEq(IAdapterView(b.generalAdapter).BUNDLER3(), b.bundler, "general adapter's bundler");
        assertEq(IAdapterView(b.generalAdapter).MORPHO(), protocol.core, "its core");
        assertEq(IAdapterView(b.vaultAdapter).BUNDLER3(), b.bundler, "vault adapter's bundler");
    }
}
