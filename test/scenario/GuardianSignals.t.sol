// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {BlockInfoWithHash} from "../../src/interfaces/GuardianSignalsTypes.sol";

/// @notice Unit tests for the guardian liveness frontier: heartbeats are O(1) and do not move the frontier,
///         `syncQuorumBlock` recomputes the quorum-th-largest and ratchets it up, and the guardian set is capped.
contract GuardianSignalsTest is Test {
    IGuardianSignals internal gs;
    address[] internal guardians;

    function _deploy(uint256 n, uint256 quorum) internal {
        guardians = new address[](n);
        for (uint256 i; i < n; ++i) {
            guardians[i] = address(uint160(0x9000 + i));
        }
        GuardianSignals impl = new GuardianSignals();
        bytes memory data = abi.encodeCall(GuardianSignals.initialize, (address(this), guardians, quorum));
        gs = IGuardianSignals(address(new ERC1967Proxy(address(impl), data)));
    }

    /// @dev A heartbeat for block `n` carrying the block hash the registry validates against.
    function _hb(uint256 n) internal view returns (BlockInfoWithHash memory) {
        return BlockInfoWithHash({hash: blockhash(n), number: uint40(n), timestamp: uint40(block.timestamp)});
    }

    /// @notice A heartbeat only records the caller's block. The quorum frontier stays put until `syncQuorumBlock`.
    function test_heartbeat_isLazy_pokeAdvancesFrontier() public {
        _deploy(3, 2); // quorum 2 of 3
        vm.roll(1000);

        vm.prank(guardians[0]);
        gs.heartbeat(_hb(block.number));
        vm.prank(guardians[1]);
        gs.heartbeat(_hb(block.number));
        assertEq(gs.getLastScannedQuorumBlock().number, 0, "heartbeat alone does not move the frontier");

        gs.syncQuorumBlock(); // permissionless
        assertEq(gs.getLastScannedQuorumBlock().number, 1000, "poke advances to the quorum-th largest block");
    }

    /// @notice The frontier is monotonic: a guardian later reporting a lower block cannot pull it back.
    function test_frontier_monotonic() public {
        _deploy(3, 2);
        vm.roll(1000);
        vm.prank(guardians[0]);
        gs.heartbeat(_hb(block.number));
        vm.prank(guardians[1]);
        gs.heartbeat(_hb(block.number));
        gs.syncQuorumBlock();
        assertEq(gs.getLastScannedQuorumBlock().number, 1000, "frontier at 1000");

        // A guardian regresses to an earlier block; the quorum-th largest drops, but the frontier ratchets.
        vm.prank(guardians[1]);
        gs.heartbeat(_hb(500));
        gs.syncQuorumBlock();
        assertEq(gs.getLastScannedQuorumBlock().number, 1000, "frontier never decreases");
    }

    /// @notice The guardian set is capped at 32: adding the 33rd reverts.
    function test_maxGuardians_cappedAt32() public {
        _deploy(32, 1);
        assertEq(GuardianSignals(address(gs)).MAX_GUARDIANS_COUNT(), 32, "cap is 32");

        vm.expectRevert(IGuardianSignals.MaxGuardiansReached.selector);
        gs.addGuardian(address(0xBEEF));
    }
}
