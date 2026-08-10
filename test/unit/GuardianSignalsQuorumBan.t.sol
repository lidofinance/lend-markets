// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

/// @notice Regression for audit finding M1: the effective ban must track the CURRENT quorum, so lowering it bans
///         accounts whose existing strikes now meet it (`isBanned`/`getOpinion` derive `strikes >= quorum`, not
///         just the write-time latch).
contract GuardianSignalsQuorumBanTest is Test {
    GuardianSignals internal gs;

    address internal constant G1 = address(0x4001);
    address internal constant G2 = address(0x4002);
    address internal constant G3 = address(0x4003);
    address internal constant BOB = address(0x5001);

    Id internal constant MARKET = Id.wrap(bytes32(uint256(0xA11CE)));

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_000_000);
        address impl = address(new GuardianSignals());
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address[],uint256)", address(this), _guardians(), uint256(2));
        gs = GuardianSignals(address(new OssifiableProxy(impl, address(this), initData)));
        gs.grantRole(gs.MANAGER_ROLE(), address(this));
        gs.grantRole(gs.ACCESS_LIMITER_ROLE(), address(this));
        gs.grantRole(gs.ACCESS_RESTORER_ROLE(), address(this));
    }

    function _guardians() internal pure returns (address[] memory guardians) {
        guardians = new address[](3);
        (guardians[0], guardians[1], guardians[2]) = (G1, G2, G3);
    }

    function _flag(address guardian, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(guardian);
        gs.flag(MARKET, guardian, accounts);
    }

    /// Two strikes below a quorum of 3 do not ban; lowering the quorum to 2 bans immediately, without a re-flag.
    function test_M1_loweringQuorumBansExistingStrikes() public {
        gs.setQuorum(3);
        _flag(G1, BOB);
        _flag(G2, BOB); // 2 strikes < quorum 3
        assertFalse(gs.isBanned(MARKET, BOB), "not banned at quorum 3 with 2 strikes");
        assertFalse(gs.getOpinion(MARKET, BOB).banned, "getOpinion agrees");

        gs.setQuorum(2); // governance lowers the quorum

        assertTrue(gs.isBanned(MARKET, BOB), "M1: strikes now meet the quorum -> effectively banned");
        assertTrue(gs.getOpinion(MARKET, BOB).banned, "getOpinion agrees");
    }

    /// Raising the quorum back above the strike count lifts the (non-latched) derived ban.
    function test_M1_raisingQuorumLiftsDerivedBan() public {
        gs.setQuorum(2);
        _flag(G1, BOB);
        _flag(G2, BOB); // 2 strikes == quorum 2 -> latched banned
        assertTrue(gs.isBanned(MARKET, BOB), "banned at quorum 2");

        // A latched ban is sticky: raising the quorum does not lift it.
        gs.setQuorum(3);
        assertTrue(gs.isBanned(MARKET, BOB), "latched ban survives a quorum raise");
    }

    /// A purely-derived ban (never latched) tracks the quorum both ways.
    function test_M1_derivedBanTracksQuorumBothWays() public {
        gs.setQuorum(3);
        _flag(G1, BOB);
        _flag(G2, BOB); // 2 strikes, never latched
        assertFalse(gs.isBanned(MARKET, BOB), "below quorum 3");

        gs.setQuorum(2);
        assertTrue(gs.isBanned(MARKET, BOB), "meets quorum 2");

        gs.setQuorum(3);
        assertFalse(gs.isBanned(MARKET, BOB), "back above quorum 3 -> derived ban lifts (was never latched)");
    }

    /// Governance `unban` clears the flags, so the derived ban does not immediately re-apply.
    function test_M1_unbanClearsDerivedBan() public {
        gs.setQuorum(2);
        _flag(G1, BOB);
        _flag(G2, BOB);
        assertTrue(gs.isBanned(MARKET, BOB), "banned");

        gs.unban(MARKET, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "unban clears flags -> no residual derived ban");
    }
}
