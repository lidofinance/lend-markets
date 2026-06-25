// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {Status, BlockInfoWithHash} from "../../src/interfaces/GuardianSignalsTypes.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

/// @notice Unit suite for `GuardianSignals`, modelled from the "Guardian signals" spec:
///         a per-(market,account) registry where each guardian flag is one strike,
///         status latches to `Banned` at quorum (`unflag` below quorum does NOT lift it), immunity forces
///         strikes to 0, and `syncQuorumBlock` advances a monotonic quorum liveness frontier. Deployed
///         behind `OssifiableProxy` (the impl disables initializers).
contract GuardianSignalsTest is Test {
    GuardianSignals internal gs;

    Id internal constant MARKET = Id.wrap(bytes32(uint256(0xA11CE)));
    address internal constant G1 = address(0x4001);
    address internal constant G2 = address(0x4002);
    address internal constant G3 = address(0x4003);
    address internal constant BOB = address(0x5001);

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_000_000);

        address[] memory guardians = new address[](3);
        guardians[0] = G1;
        guardians[1] = G2;
        guardians[2] = G3;

        address impl = address(new GuardianSignals());
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address[],uint256)", address(this), guardians, uint256(2));
        gs = GuardianSignals(address(new OssifiableProxy(impl, address(this), initData)));

        // Governance roles (not granted by initialize).
        gs.grantRole(gs.ACCESS_LIMITER_ROLE(), address(this));
        gs.grantRole(gs.ACCESS_RESTORER_ROLE(), address(this));
    }

    // ── helpers ──

    function _block(uint40 n) internal view returns (BlockInfoWithHash memory) {
        return BlockInfoWithHash({hash: blockhash(n), number: n, timestamp: n});
    }

    function _validBlock() internal view returns (BlockInfoWithHash memory) {
        return _block(uint40(block.number - 1));
    }

    function _flag(address g, address account) internal {
        address[] memory a = new address[](1);
        a[0] = account;
        vm.prank(g);
        gs.flag(MARKET, a, _validBlock());
    }

    function _unflag(address g, address account) internal {
        address[] memory a = new address[](1);
        a[0] = account;
        vm.prank(g);
        gs.unflag(MARKET, a, _validBlock());
    }

    function _status(address account) internal view returns (Status) {
        return gs.getOpinion(MARKET, account).status;
    }

    function _flagCount(address account) internal view returns (uint256) {
        return gs.getOpinion(MARKET, account).flagCount;
    }

    function _strikes(address account) internal view returns (uint256) {
        return gs.getOpinion(MARKET, account).strikes;
    }

    // ── escalation ladder & latch ──

    function test_flag_belowQuorum_isNormalWithStrikes() public {
        _flag(G1, BOB); // 1 flag, quorum 2
        assertEq(uint8(_status(BOB)), uint8(Status.Normal), "below quorum stays Normal");
        assertEq(_strikes(BOB), 1, "one strike");
        assertEq(_flagCount(BOB), 1, "flagCount 1");
    }

    function test_flag_atQuorum_latchesBanned() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // reaches quorum 2
        assertEq(uint8(_status(BOB)), uint8(Status.Banned), "quorum bans");
        assertEq(_strikes(BOB), 2, "strikes == flagCount, uncapped");
    }

    function test_latch_unflagBelowQuorum_staysBanned() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned
        _unflag(G1, BOB); // flagCount drops to 1 < quorum
        assertEq(uint8(_status(BOB)), uint8(Status.Banned), "latched: unflag does not lift the ban");
        assertEq(_flagCount(BOB), 1, "flagCount dropped");
        assertEq(_strikes(BOB), 1, "strikes follow flagCount");
    }

    // ── idempotency / no-op ──

    function test_flag_sameGuardianTwice_isIdempotent() public {
        _flag(G1, BOB);
        _flag(G1, BOB); // same guardian -> no second strike
        assertEq(_flagCount(BOB), 1, "set semantics: one flag per guardian");
    }

    function test_unflag_nonFlagger_isNoop() public {
        _flag(G1, BOB);
        _unflag(G2, BOB); // G2 never flagged -> no-op
        assertEq(_flagCount(BOB), 1, "unflag by a non-flagger is a no-op");
    }

    // ── immunity ──

    function test_grantImmunity_overBanned_forcesStrikesZero() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned, flagCount 2
        gs.grantImmunity(MARKET, BOB);
        assertEq(uint8(_status(BOB)), uint8(Status.Immune), "immunity overrides Banned");
        assertEq(_strikes(BOB), 0, "immune -> strikes forced to 0");
        assertEq(_flagCount(BOB), 2, "raw flagCount still visible under immunity");
    }

    function test_flag_onImmune_isNoop_frozenSet() public {
        gs.grantImmunity(MARKET, BOB);
        _flag(G1, BOB); // no-op while immune
        assertEq(_flagCount(BOB), 0, "flags are frozen (dropped) while immune");
    }

    /// @dev `revokeImmunity` re-derives the status from the flag set instead of forcing `Normal`: an account
    ///      still carrying a quorum of flags re-latches to `Banned`, so an immunity round-trip cannot silently
    ///      unban it.
    function test_immunityRoundTrip_stillQuorumFlagged_relatchesBanned() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned, flagCount 2 >= quorum
        gs.grantImmunity(MARKET, BOB);
        assertEq(uint8(_status(BOB)), uint8(Status.Immune), "immune during the grant");
        gs.revokeImmunity(MARKET, BOB);
        assertEq(uint8(_status(BOB)), uint8(Status.Banned), "re-latches Banned, still quorum-flagged");
        assertEq(_flagCount(BOB), 2, "flags retained across the round-trip");
        assertEq(_strikes(BOB), 2, "effective strikes restored once no longer immune");
    }

    /// @dev The mirror branch: an account below quorum at revoke returns to `Normal`, not `Banned`.
    function test_immunityRoundTrip_belowQuorum_returnsNormal() public {
        _flag(G1, BOB); // 1 flag < quorum 2
        gs.grantImmunity(MARKET, BOB);
        gs.revokeImmunity(MARKET, BOB);
        assertEq(uint8(_status(BOB)), uint8(Status.Normal), "below quorum -> Normal after revoke");
        assertEq(_flagCount(BOB), 1, "the single flag is retained");
    }

    /// @dev `revokeImmunity` is a no-op on a non-immune account: it must not lift a committee `ban` (a forced
    ///      Banned carries zero flags) — closing the limiter-role unban bypass.
    function test_revokeImmunity_onForcedBan_isNoop() public {
        gs.ban(MARKET, BOB); // forced Banned, zero flags
        gs.revokeImmunity(MARKET, BOB);
        assertEq(uint8(_status(BOB)), uint8(Status.Banned), "forced ban survives revoke (no-op on non-immune)");
    }

    /// @dev ...and it leaves a never-immune Normal account untouched.
    function test_revokeImmunity_onNormal_isNoop() public {
        gs.revokeImmunity(MARKET, BOB);
        assertEq(uint8(_status(BOB)), uint8(Status.Normal), "no-op on a never-immune account");
    }

    // ── forced ban / unban ──

    function test_ban_unban_clearsFlagSet() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned
        gs.unban(MARKET, BOB);
        assertEq(uint8(_status(BOB)), uint8(Status.Normal), "unban returns to Normal");
        assertEq(_flagCount(BOB), 0, "unban clears the flag set");
    }

    function test_forcedBan_latchesRegardlessOfFlags() public {
        gs.ban(MARKET, BOB); // no flags at all
        assertEq(uint8(_status(BOB)), uint8(Status.Banned), "forced ban latches with zero flags");
        assertEq(_flagCount(BOB), 0, "forced ban does not touch flags");
    }

    // ── liveness frontier ──

    function _heartbeat(address g, uint40 n) internal {
        vm.prank(g);
        gs.heartbeat(_block(n));
    }

    function test_frontier_belowQuorumHeartbeats_noAdvance() public {
        _heartbeat(G1, 999); // only one guardian heartbeated; quorum is 2
        gs.syncQuorumBlock();
        assertEq(gs.getLastScannedQuorumBlock().number, 0, "fewer than quorum heartbeats -> frontier stays 0");
    }

    function test_frontier_atQuorum_advancesToQuorumthLargest() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        _heartbeat(G3, 997);
        gs.syncQuorumBlock();
        // quorum-th largest of {999,998,997} (quorum 2) = 2nd largest = 998 (min of the top-2).
        assertEq(gs.getLastScannedQuorumBlock().number, 998, "frontier = quorum-th largest heartbeat");
    }

    function test_frontier_monotonic_doesNotRegress() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        gs.syncQuorumBlock(); // frontier 998
        // Now a lagging guardian heartbeats at a lower block; the frontier must not move backward.
        _heartbeat(G3, 990);
        gs.syncQuorumBlock();
        assertEq(gs.getLastScannedQuorumBlock().number, 998, "monotonic ratchet: frontier stays at 998, no regress");
    }

    function test_syncQuorumBlock_isPermissionless() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        vm.prank(BOB); // a non-guardian
        gs.syncQuorumBlock();
        assertEq(gs.getLastScannedQuorumBlock().number, 998, "anyone can advance the frontier");
    }

    // ── set / quorum / roles ──

    function testRevert_setQuorum_zero() public {
        vm.expectRevert(IGuardianSignals.BadQuorum.selector);
        gs.setQuorum(0);
    }

    function testRevert_setQuorum_aboveGuardianCount() public {
        vm.expectRevert(IGuardianSignals.BadQuorum.selector);
        gs.setQuorum(4); // only 3 guardians
    }

    function test_setQuorum_equalsCount() public {
        gs.setQuorum(3);
        assertEq(gs.getQuorum(), 3, "quorum == guardian count is allowed");
    }

    function testRevert_removeGuardian_wouldBreakQuorum() public {
        gs.setQuorum(3); // quorum == count
        vm.expectRevert(IGuardianSignals.WouldBreakQuorum.selector);
        gs.removeGuardian(G3); // would drop below quorum
    }

    function testRevert_addGuardian_existing() public {
        vm.expectRevert(IGuardianSignals.AlreadyGuardian.selector);
        gs.addGuardian(G1);
    }

    function testRevert_flag_nonGuardian() public {
        address[] memory a = new address[](1);
        a[0] = BOB;
        vm.prank(BOB); // not a guardian
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.flag(MARKET, a, _validBlock());
    }

    function testRevert_ban_wrongRole() public {
        vm.prank(BOB); // lacks ACCESS_LIMITER_ROLE
        vm.expectRevert();
        gs.ban(MARKET, BOB);
    }

    // ── heartbeat validation ──

    function testRevert_heartbeat_blockInTheFuture() public {
        BlockInfoWithHash memory b = _block(uint40(block.number - 1));
        b.number = uint40(block.number + 1); // future
        vm.prank(G1);
        vm.expectRevert(IGuardianSignals.BlockInTheFuture.selector);
        gs.heartbeat(b);
    }

    function testRevert_heartbeat_invalidBlockHash() public {
        BlockInfoWithHash memory b = _block(uint40(block.number - 1));
        b.hash = bytes32(uint256(0xdead)); // wrong hash
        vm.prank(G1);
        vm.expectRevert(IGuardianSignals.InvalidBlockHash.selector);
        gs.heartbeat(b);
    }

    // ── events / batch / getFlaggedBy ──

    event Flagged(Id indexed market, address indexed account, address indexed guardian, uint16 strikes);
    event Banned(Id indexed market, address indexed account);
    event ImmunityGranted(Id indexed market, address indexed account, address indexed by);

    function test_flag_emitsFlaggedAndBannedAtQuorum() public {
        address[] memory a = new address[](1);
        a[0] = BOB;

        vm.expectEmit(true, true, true, true, address(gs));
        emit Flagged(MARKET, BOB, G1, 1);
        vm.prank(G1);
        gs.flag(MARKET, a, _validBlock());

        // The quorum-crossing flag emits Flagged AND Banned.
        vm.expectEmit(true, true, false, false, address(gs));
        emit Banned(MARKET, BOB);
        vm.prank(G2);
        gs.flag(MARKET, a, _validBlock());
    }

    function test_flag_pastQuorum_noSecondBannedEvent() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned latched
        vm.recordLogs();
        _flag(G3, BOB); // a 3rd flag past quorum must NOT re-emit Banned
        bytes32 bannedSig = keccak256("Banned(bytes32,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != bannedSig, "no second Banned event past quorum");
        }
    }

    function test_grantImmunity_overForcedBan() public {
        gs.ban(MARKET, BOB); // forced Banned (no flags)
        gs.grantImmunity(MARKET, BOB);
        assertEq(uint8(_status(BOB)), uint8(Status.Immune), "immunity overrides a forced ban");
        assertEq(_strikes(BOB), 0, "strikes 0 under immunity");
    }

    function test_getFlaggedBy_returnsFlaggerSet() public {
        _flag(G1, BOB);
        _flag(G2, BOB);
        address[] memory flaggers = gs.getFlaggedBy(MARKET, BOB);
        assertEq(flaggers.length, 2, "two flaggers");
    }

    function test_flag_batch_multipleAccounts() public {
        address[] memory accs = new address[](2);
        accs[0] = BOB;
        accs[1] = address(0x5002);
        vm.prank(G1);
        gs.flag(MARKET, accs, _validBlock());
        assertEq(_flagCount(BOB), 1, "first account flagged");
        assertEq(_flagCount(address(0x5002)), 1, "second account flagged");
    }

    // ── frontier: fresh guardian stalls but does not regress ──

    function test_frontier_freshGuardian_stallsNoRegress() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        gs.syncQuorumBlock(); // frontier 998
        gs.addGuardian(address(0x4099)); // a 4th, never heartbeated (packs as 0)
        gs.syncQuorumBlock();
        assertEq(gs.getLastScannedQuorumBlock().number, 998, "fresh guardian stalls, never regresses the frontier");
    }

    // ── wrong-role reverts (each gated mutator) ──

    function testRevert_grantImmunity_wrongRole() public {
        vm.prank(BOB); // lacks ACCESS_RESTORER
        vm.expectRevert();
        gs.grantImmunity(MARKET, BOB);
    }

    function testRevert_revokeImmunity_wrongRole() public {
        vm.prank(BOB); // lacks ACCESS_LIMITER
        vm.expectRevert();
        gs.revokeImmunity(MARKET, BOB);
    }

    function testRevert_setQuorum_wrongRole() public {
        vm.prank(BOB); // lacks DEFAULT_ADMIN
        vm.expectRevert();
        gs.setQuorum(1);
    }

    function testRevert_heartbeat_nonGuardian() public {
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.heartbeat(_validBlock());
    }

    function testRevert_addGuardian_max32() public {
        // 3 guardians already; add up to 32, then the 33rd reverts.
        for (uint160 i = 4; i <= 32; i++) {
            gs.addGuardian(address(0x4000 + i));
        }
        vm.expectRevert(IGuardianSignals.MaxGuardiansReached.selector);
        gs.addGuardian(address(0x4000 + 33));
    }

    // ── fuzz: latch invariant & frontier == quorum-th largest ──

    function testFuzz_latchHoldsAcrossSequence(uint256 seed) public {
        address[3] memory gns = [G1, G2, G3];
        bool everBanned;
        for (uint256 i = 0; i < 24; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address g = gns[seed % 3];
            if (seed % 2 == 0) _flag(g, BOB);
            else _unflag(g, BOB);

            if (uint8(_status(BOB)) == uint8(Status.Banned)) everBanned = true;
            // No unban/immunity is called, so once Banned it must stay Banned.
            if (everBanned) assertEq(uint8(_status(BOB)), uint8(Status.Banned), "latch holds across the sequence");
        }
    }

    function _sort3(uint40 a, uint40 b, uint40 c) internal pure returns (uint40 mid) {
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        return b; // middle of three = the quorum-th (2nd) largest for quorum 2, 3 guardians
    }

    function testFuzz_frontier_isQuorumthLargest(uint40 b1, uint40 b2, uint40 b3) public {
        // All within the 256-block hash window [block.number-256, block.number-1] = [744, 999].
        b1 = uint40(bound(b1, 745, 999));
        b2 = uint40(bound(b2, 745, 999));
        b3 = uint40(bound(b3, 745, 999));
        _heartbeat(G1, b1);
        _heartbeat(G2, b2);
        _heartbeat(G3, b3);
        gs.syncQuorumBlock();
        assertEq(gs.getLastScannedQuorumBlock().number, _sort3(b1, b2, b3), "frontier = quorum-th largest heartbeat");
    }
}
