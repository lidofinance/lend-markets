// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {BlockInfoWithHash} from "../../src/types/GuardianSignalsTypes.sol";

/// @notice Scenario tests for the guardian liveness frontier: heartbeats are O(1) and do not move the frontier,
///         `syncQuorumBlock` recomputes the quorum-th-largest timestamp and ratchets it up, and the guardian set
///         is capped. GuardianSignals is committee-wide; the committee is seeded via `addGuardian` / `setQuorum`.
contract GuardianSignalsTest is Test {
    IGuardianSignals internal gs;
    address[] internal guardians;

    /// @dev The market signals in this suite are keyed under (the committee is shared across markets).
    Id internal constant MARKET = Id.wrap(bytes32(uint256(0xA11CE)));

    function _deploy(uint256 n, uint256 quorum) internal {
        guardians = new address[](n);
        for (uint256 i; i < n; ++i) {
            guardians[i] = address(uint160(0x9000 + i));
        }
        GuardianSignals impl = new GuardianSignals();
        bytes memory data = abi.encodeCall(GuardianSignals.initialize, (address(this), guardians, quorum));
        gs = IGuardianSignals(address(new ERC1967Proxy(address(impl), data)));

        GuardianSignals gsImpl = GuardianSignals(address(gs));
        gsImpl.grantRole(gsImpl.MANAGER_ROLE(), address(this));
    }

    /// @dev A heartbeat for block `n` carrying the block hash the registry validates against. The frontier orders
    ///      guardians by the reported timestamp, so it carries the current block timestamp.
    function _hb(uint256 n) internal view returns (BlockInfoWithHash memory) {
        return BlockInfoWithHash({hash: blockhash(n), number: uint40(n), timestamp: uint40(block.timestamp)});
    }

    /// @notice A heartbeat only records the caller's timestamp. The quorum frontier stays put until `syncQuorumBlock`.
    function test_heartbeat_isLazy_pokeAdvancesFrontier() public {
        _deploy(3, 2); // quorum 2 of 3
        vm.roll(1000);
        vm.warp(5000);

        vm.prank(guardians[0]);
        gs.heartbeat(_hb(block.number - 1));
        vm.prank(guardians[1]);
        gs.heartbeat(_hb(block.number - 1));
        assertEq(gs.getQuorumFrontier(), 0, "heartbeat alone does not move the frontier");

        gs.syncQuorumBlock(); // permissionless
        assertEq(gs.getQuorumFrontier(), 5000, "poke advances to the quorum-th largest timestamp");
    }

    /// @notice The frontier is monotonic: with only one guardian ahead of it, the quorum-th largest stays behind.
    function test_frontier_monotonic() public {
        _deploy(3, 2);
        vm.roll(1000);
        vm.warp(5000);
        vm.prank(guardians[0]);
        gs.heartbeat(_hb(block.number - 1));
        vm.prank(guardians[1]);
        gs.heartbeat(_hb(block.number - 1));
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 5000, "frontier at 5000");

        // A single guardian moves ahead; the quorum-th largest (2nd) is still 5000, so the frontier holds.
        vm.warp(6000);
        vm.prank(guardians[0]);
        gs.heartbeat(_hb(block.number - 1));
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 5000, "frontier never decreases and needs a quorum to advance");
    }

    /// @notice The guardian set is capped at 32: adding the 33rd reverts.
    function test_maxGuardians_cappedAt32() public {
        _deploy(32, 1);
        GuardianSignals gsImpl = GuardianSignals(address(gs));
        assertEq(gsImpl.MAX_GUARDIANS_COUNT(), 32, "cap is 32");

        vm.expectRevert(IGuardianSignals.MaxGuardiansReached.selector);
        gs.addGuardian(address(0xBEEF));
    }

    /// @dev Flag `account` as `guardian`, carrying a valid heartbeat.
    function _flag(address guardian, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(guardian);
        gs.flag(MARKET, accounts, _hb(block.number - 1));
    }
}
