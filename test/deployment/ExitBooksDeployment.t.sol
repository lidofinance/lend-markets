// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {ExitBookPlan} from "../../script/deployment/mainnet/ExitBookPlan.sol";
import {ExitBookConfig} from "../../script/deployment/ExitBookPlan.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";

contract ExitBooksDeploymentTest is Test, ProtocolDeployer {
    function test_exitBooksDeployIndependentlyOfMarkets() public {
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), pin);
        (uint256 chainId, ExitBookConfig memory plan) = ExitBookPlan.get();
        assertEq(block.chainid, chainId);
        assertGt(plan.core.code.length, 0);
        (address morpho, address erc4626) = _deployExitBooks(plan, address(this));
        assertEq(address(MorphoExitBook(morpho).MORPHO()), plan.core);
        _assertBook(ExitBookBase(morpho), plan);
        _assertBook(ExitBookBase(erc4626), plan);
    }

    function _assertBook(ExitBookBase book, ExitBookConfig memory plan) private view {
        assertEq(book.MAX_REQUEST_LIFETIME(), plan.maxRequestLifetime);
        assertEq(book.feeRecipient(), plan.agent);
        assertEq(book.serviceFee(), 0);
        assertTrue(book.hasRole(book.DEFAULT_ADMIN_ROLE(), plan.agent));
        assertEq(book.getRoleMemberCount(book.DEFAULT_ADMIN_ROLE()), 1);
        assertFalse(book.hasRole(book.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(book.hasRole(book.ALLOWLIST_MANAGER_ROLE(), plan.evmScriptExecutor));
        assertEq(book.getRoleMemberCount(book.ALLOWLIST_MANAGER_ROLE()), 1);
        assertTrue(book.hasRole(book.PAUSER_ROLE(), plan.pauser));
        assertEq(book.getRoleMemberCount(book.PAUSER_ROLE()), 1);
        assertEq(book.getRoleMemberCount(book.RESUMER_ROLE()), 0);
        assertEq(book.getRoleMemberCount(book.FEE_MANAGER_ROLE()), 0);
        assertEq(book.getRoleMemberCount(book.RECOVERER_ROLE()), 0);
    }
}
