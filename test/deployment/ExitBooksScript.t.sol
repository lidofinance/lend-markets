// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {
    ExitBookAddresses,
    ExitBooksConfig,
    ProtocolAddresses,
    ProtocolDeployer
} from "../../script/lib/ProtocolDeployer.sol";
import {ForkStack} from "../fork/helpers/ForkStack.sol";

import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";

/// @notice The exit books script on the default fork, mainnet: new books over the deployed core, with no market, hand
///         every role to governance and the pauser.
contract ExitBooksScriptTest is ForkStack, ProtocolDeployer {
    function test_newBooks_handedToGovernance() public {
        _forkTarget(false);
        ProtocolAddresses memory p = protocol;
        ExitBooksConfig memory config = network.books.getConfig();
        assertEq(block.chainid, p.chainId);
        assertGt(p.core.code.length, 0);
        ExitBookAddresses memory deployed = _deployExitBooks(p, config, address(this));
        assertEq(address(MorphoExitBook(deployed.morpho).MORPHO()), p.core);
        _assertBook(ExitBookBase(deployed.morpho), p, config);
        _assertBook(ExitBookBase(deployed.erc4626), p, config);
    }

    function _assertBook(ExitBookBase book, ProtocolAddresses memory p, ExitBooksConfig memory config) private view {
        assertEq(book.MAX_REQUEST_LIFETIME(), config.maxRequestLifetime);
        assertEq(book.feeRecipient(), p.agent);
        assertEq(book.serviceFee(), 0);
        assertTrue(book.hasRole(book.DEFAULT_ADMIN_ROLE(), p.agent));
        assertEq(book.getRoleMemberCount(book.DEFAULT_ADMIN_ROLE()), 1);
        assertFalse(book.hasRole(book.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(book.hasRole(book.ALLOWLIST_MANAGER_ROLE(), p.executor));
        assertEq(book.getRoleMemberCount(book.ALLOWLIST_MANAGER_ROLE()), 1);
        assertTrue(book.hasRole(book.PAUSER_ROLE(), config.pauser));
        assertEq(book.getRoleMemberCount(book.PAUSER_ROLE()), 1);
        assertEq(book.getRoleMemberCount(book.RESUMER_ROLE()), 0);
        assertEq(book.getRoleMemberCount(book.FEE_MANAGER_ROLE()), 0);
        assertEq(book.getRoleMemberCount(book.RECOVERER_ROLE()), 0);
    }
}
