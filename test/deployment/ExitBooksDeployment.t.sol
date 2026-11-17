// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {Deployment as MainnetDeployment} from "../../script/deployment/mainnet/artifacts/Deployment.sol";
import {DeploymentSnapshot, ExitBookConfig} from "../../script/deployment/DeploymentTypes.sol";

import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";

contract ExitBooksDeploymentTest is Test, ProtocolDeployer {
    function test_exitBooksDeployIndependentlyOfMarkets() public {
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), pin);
        DeploymentSnapshot memory d = MainnetDeployment.snapshot();
        ExitBookConfig memory parameters = ExitBookConfig({
            agent: d.protocol.agent,
            evmScriptExecutor: d.protocol.executor,
            pauser: d.bookPauser,
            core: d.protocol.core,
            maxRequestLifetime: d.bookLifetime
        });
        assertEq(block.chainid, d.protocol.chainId);
        assertGt(parameters.core.code.length, 0);
        (address morpho, address erc4626) = _deployExitBooks(parameters, address(this));
        assertEq(address(MorphoExitBook(morpho).MORPHO()), parameters.core);
        _assertBook(ExitBookBase(morpho), parameters);
        _assertBook(ExitBookBase(erc4626), parameters);
    }

    function _assertBook(ExitBookBase book, ExitBookConfig memory parameters) private view {
        assertEq(book.MAX_REQUEST_LIFETIME(), parameters.maxRequestLifetime);
        assertEq(book.feeRecipient(), parameters.agent);
        assertEq(book.serviceFee(), 0);
        assertTrue(book.hasRole(book.DEFAULT_ADMIN_ROLE(), parameters.agent));
        assertEq(book.getRoleMemberCount(book.DEFAULT_ADMIN_ROLE()), 1);
        assertFalse(book.hasRole(book.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(book.hasRole(book.ALLOWLIST_MANAGER_ROLE(), parameters.evmScriptExecutor));
        assertEq(book.getRoleMemberCount(book.ALLOWLIST_MANAGER_ROLE()), 1);
        assertTrue(book.hasRole(book.PAUSER_ROLE(), parameters.pauser));
        assertEq(book.getRoleMemberCount(book.PAUSER_ROLE()), 1);
        assertEq(book.getRoleMemberCount(book.RESUMER_ROLE()), 0);
        assertEq(book.getRoleMemberCount(book.FEE_MANAGER_ROLE()), 0);
        assertEq(book.getRoleMemberCount(book.RECOVERER_ROLE()), 0);
    }
}
