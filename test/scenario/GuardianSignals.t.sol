// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {BlockInfoWithHash, GuardiansOpinion, Status} from "../../src/types/GuardianSignalsTypes.sol";

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

    /// @dev Flag `account` in `market` as `guardian`, carrying a valid heartbeat.
    function _flag(address guardian, Id market, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(guardian);
        gs.flag(market, accounts, _hb(block.number));
    }

    /// @notice Immunity exempts an account from its strike surcharge without erasing the raw flags: `getOpinion`
    ///         zeroes effective `strikes` while `Immune`, keeps `flagCount` visible, and restores `strikes` on
    ///         revoke. A further flag is a no-op while immune, so an immune account can never latch a ban.
    function test_immunity_zeroesEffectiveStrikesButKeepsFlagCount() public {
        _deploy(3, 3); // quorum 3, so two flags stay below the ban threshold
        GuardianSignals gsImpl = GuardianSignals(address(gs));
        gsImpl.grantRole(gsImpl.ACCESS_RESTORER_ROLE(), address(this));
        gsImpl.grantRole(gsImpl.ACCESS_LIMITER_ROLE(), address(this));
        vm.roll(1000);

        Id market = Id.wrap(bytes32(uint256(1)));
        address account = address(0xCAFE);

        _flag(guardians[0], market, account);
        _flag(guardians[1], market, account);

        GuardiansOpinion memory op = gs.getOpinion(market, account);
        assertTrue(op.status == Status.Normal, "not banned below quorum");
        assertEq(op.strikes, 2, "effective strikes = flags when normal");
        assertEq(op.flagCount, 2, "raw flag count");

        gs.grantImmunity(market, account);
        op = gs.getOpinion(market, account);
        assertTrue(op.status == Status.Immune, "immune");
        assertEq(op.strikes, 0, "immune zeroes effective strikes");
        assertEq(op.flagCount, 2, "immune keeps the raw flag count");

        _flag(guardians[2], market, account); // no-op while immune
        op = gs.getOpinion(market, account);
        assertTrue(op.status == Status.Immune, "still immune, never banned");
        assertEq(op.flagCount, 2, "flag is a no-op while immune");
        assertEq(op.strikes, 0, "effective strikes stay zero");

        gs.revokeImmunity(market, account);
        op = gs.getOpinion(market, account);
        assertTrue(op.status == Status.Normal, "normal after revoke");
        assertEq(op.strikes, 2, "strikes restored on revoke");
        assertEq(op.flagCount, 2, "flag count unchanged");
    }
}
