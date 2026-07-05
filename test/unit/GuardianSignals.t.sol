// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {BlockInfoWithHash, GuardiansOpinion} from "../../src/types/GuardianSignalsTypes.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

/// @notice Unit suite for `GuardianSignals`, modelled from the "Guardian signals" spec:
///         a per-(market,account) registry where each guardian flag is one strike,
///         status latches to `Banned` at quorum (`unflag` below quorum does NOT lift it), and
///         `syncQuorumBlock` advances a monotonic quorum liveness frontier. Deployed
///         behind `OssifiableProxy` (the impl disables initializers).
contract GuardianSignalsTest is Test {
    GuardianSignals internal gs;

    address internal constant G1 = address(0x4001);
    address internal constant G2 = address(0x4002);
    address internal constant G3 = address(0x4003);
    address internal constant BOB = address(0x5001);

    /// @dev The market all signals in this suite are keyed under. GuardianSignals is committee-wide over many
    ///      markets; the unit suite exercises one arbitrary market id.
    Id internal constant MARKET = Id.wrap(bytes32(uint256(0xA11CE)));

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_000_000);

        // `initialize` seeds the default three-guardian committee at quorum 2.
        address impl = address(new GuardianSignals());
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],uint256)", address(this), _defaultGuardians(), uint256(2)
        );
        gs = GuardianSignals(address(new OssifiableProxy(impl, address(this), initData)));

        // Governance roles (not granted by initialize).
        gs.grantRole(gs.MANAGER_ROLE(), address(this));
        gs.grantRole(gs.ACCESS_LIMITER_ROLE(), address(this));
        gs.grantRole(gs.ACCESS_RESTORER_ROLE(), address(this));

        // Activation delays left at 0 for these tests.
        gs.setSuspectWindow(0);
    }

    /// @dev The default three-guardian roster used across the suite.
    function _defaultGuardians() internal pure returns (address[] memory g) {
        g = new address[](3);
        g[0] = G1;
        g[1] = G2;
        g[2] = G3;
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

    function _flagCount(address account) internal view returns (uint256) {
        return gs.getFlaggedBy(MARKET, account).length;
    }

    function _strikes(address account) internal view returns (uint256) {
        return gs.getFlaggedBy(MARKET, account).length;
    }

    // ── mutations ──

    // ── escalation ladder & latch ──

    /// @dev A single flag below quorum is a strike, not a ban: the account stays borrowable.
    function test_flag_belowQuorum_isNormalWithStrikes() public {
        _flag(G1, BOB); // 1 flag, quorum 2
        assertFalse(gs.isBanned(MARKET, BOB), "below quorum stays Normal");
        assertEq(_strikes(BOB), 1, "one strike");
        assertEq(_flagCount(BOB), 1, "flagCount 1");
    }

    /// @dev The flag that reaches quorum latches the ban; strikes keep counting past it, uncapped.
    function test_flag_atQuorum_latchesBanned() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // reaches quorum 2
        assertTrue(gs.isBanned(MARKET, BOB), "quorum bans");
        assertEq(_strikes(BOB), 2, "strikes == flagCount, uncapped");
    }

    /// @dev The latch: once quorum banned, a retraction that drops the count back below quorum does NOT lift
    ///      the ban — only `unban` does.
    function test_latch_unflagBelowQuorum_staysBanned() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned
        _unflag(G1, BOB); // flagCount drops to 1 < quorum
        assertTrue(gs.isBanned(MARKET, BOB), "latched: unflag does not lift the ban");
        assertEq(_flagCount(BOB), 1, "flagCount dropped");
        assertEq(_strikes(BOB), 1, "strikes follow flagCount");
    }

    // ── idempotency / no-op ──

    /// @dev One guardian holds at most one flag per account: re-flagging cannot manufacture strikes.
    function test_flag_sameGuardianTwice_isIdempotent() public {
        _flag(G1, BOB);
        _flag(G1, BOB); // same guardian -> no second strike
        assertEq(_flagCount(BOB), 1, "set semantics: one flag per guardian");
    }

    /// @dev A guardian can only retract its OWN flag: retracting someone else's is a no-op.
    function test_unflag_nonFlagger_isNoop() public {
        _flag(G1, BOB);
        _unflag(G2, BOB); // G2 never flagged -> no-op
        assertEq(_flagCount(BOB), 1, "unflag by a non-flagger is a no-op");
    }

    // ── forced ban / unban ──

    /// @dev `unban` is the one recovery path: it lifts the latched ban AND wipes the flag set, so the account
    ///      restarts from a clean slate — a fresh quorum of flags is needed to re-ban it.
    function test_ban_unban_clearsFlagSet() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned
        gs.unban(MARKET, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "unban returns to Normal");
        assertEq(_flagCount(BOB), 0, "unban clears the flag set");

        // Clean slate is functional: one fresh flag does not re-ban, a fresh quorum does.
        _flag(G1, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "one fresh flag stays below quorum after unban");
        _flag(G2, BOB);
        assertTrue(gs.isBanned(MARKET, BOB), "a fresh quorum re-latches the ban");
    }

    /// @dev The `ACCESS_LIMITER_ROLE` force-ban needs no flags at all and latches immediately.
    function test_forcedBan_latchesRegardlessOfFlags() public {
        gs.ban(MARKET, BOB); // no flags at all
        assertTrue(gs.isBanned(MARKET, BOB), "forced ban latches with zero flags");
        assertEq(_flagCount(BOB), 0, "forced ban does not touch flags");
    }

    // ── liveness frontier ──

    function _heartbeat(address g, uint40 n) internal {
        vm.prank(g);
        gs.heartbeat(_block(n));
    }

    /// @dev The frontier only moves on a quorum of heartbeats: a single scanner cannot advance it.
    function test_frontier_belowQuorumHeartbeats_noAdvance() public {
        _heartbeat(G1, 999); // only one guardian heartbeated; quorum is 2
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 0, "fewer than quorum heartbeats -> frontier stays 0");
    }

    /// @dev The frontier is the quorum-th largest heartbeat: the point a quorum of guardians has provably
    ///      scanned past.
    function test_frontier_atQuorum_advancesToQuorumthLargest() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        _heartbeat(G3, 997);
        gs.syncQuorumBlock();
        // quorum-th largest of {999,998,997} (quorum 2) = 2nd largest = 998 (min of the top-2).
        assertEq(gs.getQuorumFrontier(), 998, "frontier = quorum-th largest heartbeat");
    }

    /// @dev The frontier is a ratchet: a lagging guardian's lower heartbeat can stall it but never pull it back.
    function test_frontier_monotonic_doesNotRegress() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        gs.syncQuorumBlock(); // frontier 998
        // Now a lagging guardian heartbeats at a lower block; the frontier must not move backward.
        _heartbeat(G3, 990);
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 998, "monotonic ratchet: frontier stays at 998, no regress");
    }

    /// @dev Recomputing the frontier is permissionless: it only distills already-attested heartbeats.
    function test_syncQuorumBlock_isPermissionless() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        vm.prank(BOB); // a non-guardian
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 998, "anyone can advance the frontier");
    }

    // ── set / quorum / roles ──

    /// @dev A zero quorum would ban every account (`count >= 0` always) — rejected.
    function testRevert_setQuorum_zero() public {
        vm.expectRevert(IGuardianSignals.BadQuorum.selector);
        gs.setQuorum(0);
    }

    /// @dev A quorum above the roster size would be unreachable (frontier and bans frozen) — rejected.
    function testRevert_setQuorum_aboveGuardianCount() public {
        vm.expectRevert(IGuardianSignals.BadQuorum.selector);
        gs.setQuorum(4); // only 3 guardians
    }

    /// @dev The `quorum == count` boundary is allowed — and it is functional: the old quorum of flags no
    ///      longer bans under the raised one.
    function test_setQuorum_equalsCount() public {
        gs.setQuorum(3);
        assertEq(gs.getQuorum(), 3, "quorum == guardian count is allowed");

        _flag(G1, BOB);
        _flag(G2, BOB); // 2 flags, the OLD quorum
        assertFalse(gs.isBanned(MARKET, BOB), "the raised quorum governs: 2 flags no longer ban");
        _flag(G3, BOB);
        assertTrue(gs.isBanned(MARKET, BOB), "the full roster reaches the raised quorum");
    }

    /// @dev Rotation cannot break liveness: removing a guardian that would leave the roster below quorum is
    ///      rejected (lower the quorum first).
    function testRevert_removeGuardian_wouldBreakQuorum() public {
        gs.setQuorum(3); // quorum == count
        vm.expectRevert(IGuardianSignals.WouldBreakQuorum.selector);
        gs.removeGuardian(G3); // would drop below quorum
    }

    /// @dev The roster is a set: re-adding a member is an explicit error, not a silent no-op.
    function testRevert_addGuardian_existing() public {
        vm.expectRevert(IGuardianSignals.AlreadyGuardian.selector);
        gs.addGuardian(G1);
    }

    /// @dev Signals are guardian-only: a non-guardian cannot flag.
    function testRevert_flag_nonGuardian() public {
        address[] memory a = new address[](1);
        a[0] = BOB;
        vm.prank(BOB); // not a guardian
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.flag(MARKET, a, _validBlock());
    }

    /// @dev The `onlyGuardian` gate inlines per function; sweep the remaining guardian-only mutators so each
    ///      instantiation has its revert side exercised.
    function testRevert_unflag_nonGuardian() public {
        address[] memory a = new address[](1);
        a[0] = BOB;
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.unflag(MARKET, a, _validBlock());
    }

    function testRevert_suspect_nonGuardian() public {
        address[] memory a = new address[](1);
        a[0] = BOB;
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.suspect(MARKET, a, _validBlock());
    }

    function testRevert_unsuspect_nonGuardian() public {
        address[] memory a = new address[](1);
        a[0] = BOB;
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.unsuspect(MARKET, a, _validBlock());
    }

    /// @dev The force-ban is role-gated: guardians flag, but only `ACCESS_LIMITER_ROLE` bans directly.
    function testRevert_ban_wrongRole() public {
        bytes32 role = gs.ACCESS_LIMITER_ROLE();
        vm.prank(BOB); // lacks ACCESS_LIMITER_ROLE
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        gs.ban(MARKET, BOB);
    }

    // ── heartbeat validation ──

    /// @dev A guardian cannot attest a block that does not exist yet.
    function testRevert_heartbeat_blockInTheFuture() public {
        BlockInfoWithHash memory b = _block(uint40(block.number - 1));
        b.number = uint40(block.number + 1); // future
        vm.prank(G1);
        vm.expectRevert(IGuardianSignals.BlockInTheFuture.selector);
        gs.heartbeat(b);
    }

    /// @dev The reported number+hash must match the chain: a fabricated hash cannot feed the frontier.
    function testRevert_heartbeat_invalidBlockHash() public {
        BlockInfoWithHash memory b = _block(uint40(block.number - 1));
        b.hash = bytes32(uint256(0xdead)); // wrong hash
        vm.prank(G1);
        vm.expectRevert(IGuardianSignals.InvalidBlockHash.selector);
        gs.heartbeat(b);
    }

    // ── events / batch ──

    event Flagged(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
    event Banned(Id indexed marketId, address indexed account);
    event QuorumSet(uint256 quorum);

    /// @dev `initialize` seeds the quorum and emits `QuorumSet` for off-chain indexers (guardians emit
    ///      `GuardianAdded` in the same call). The event fires from the proxy during construction.
    function test_initialize_emitsQuorumSet() public {
        address impl = address(new GuardianSignals());
        vm.expectEmit(false, false, false, true);
        emit QuorumSet(2);
        new OssifiableProxy(
            impl,
            address(this),
            abi.encodeWithSignature(
                "initialize(address,address[],uint256)", address(this), _defaultGuardians(), uint256(2)
            )
        );
    }

    /// @dev Every flag emits `Flagged` with the running strike count; the quorum-crossing one adds `Banned`.
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

    /// @dev `Banned` fires exactly once, on the crossing flag: later flags must not re-emit it (indexers
    ///      treat it as a state transition).
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

    /// @dev One call flags a whole batch: each account gets its own strike from the caller.
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

    /// @dev A rotation that adds a never-heartbeated guardian (timestamp 0) can stall the frontier but the
    ///      ratchet keeps it from regressing.
    function test_frontier_freshGuardian_stallsNoRegress() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        gs.syncQuorumBlock(); // frontier 998
        gs.addGuardian(address(0x4099)); // a 4th, never heartbeated (packs as 0)
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 998, "fresh guardian stalls, never regresses the frontier");
    }

    // ── wrong-role reverts (each gated mutator) ──

    /// @dev Roster/quorum management is `MANAGER_ROLE`-gated.
    function testRevert_setQuorum_wrongRole() public {
        bytes32 role = gs.MANAGER_ROLE();
        vm.prank(BOB); // lacks MANAGER_ROLE
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        gs.setQuorum(1);
    }

    /// @dev Heartbeats are guardian-only: an outsider cannot feed the liveness frontier.
    function testRevert_heartbeat_nonGuardian() public {
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.heartbeat(_validBlock());
    }

    /// @dev The roster is capped at `MAX_GUARDIANS_COUNT` (32): the frontier sort stays bounded.
    function testRevert_addGuardian_max32() public {
        // 3 guardians already; add up to 32, then the 33rd reverts.
        for (uint160 i = 4; i <= 32; i++) {
            gs.addGuardian(address(0x4000 + i));
        }
        vm.expectRevert(IGuardianSignals.MaxGuardiansReached.selector);
        gs.addGuardian(address(0x4000 + 33));
    }

    // ── guardian set management: removal ──

    event GuardianRemoved(address indexed guardian);

    /// @dev `removeGuardian` success path: drops the set from 3 to 2 (== quorum), emits `GuardianRemoved` —
    ///      and REVOKES the signal rights: the ex-guardian's flag/heartbeat revert while the remaining
    ///      guardians keep working.
    function test_removeGuardian_succeeds() public {
        assertEq(gs.getGuardianCount(), 3, "starts with three guardians");

        vm.expectEmit(true, false, false, false, address(gs));
        emit GuardianRemoved(G3);
        gs.removeGuardian(G3);

        assertEq(gs.getGuardianCount(), 2, "count drops to two");
        assertFalse(gs.isGuardian(G3), "removed address is no longer a guardian");
        assertTrue(gs.isGuardian(G1), "G1 still a guardian");
        assertTrue(gs.isGuardian(G2), "G2 still a guardian");

        // Revoked in practice: the ex-guardian cannot signal, the rest can.
        address[] memory a = new address[](1);
        a[0] = BOB;
        vm.prank(G3);
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.flag(MARKET, a, _validBlock());
        vm.prank(G3);
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.heartbeat(_validBlock());
        _flag(G1, BOB);
        assertEq(_flagCount(BOB), 1, "remaining guardian still flags");
    }

    /// @dev `addGuardian` GRANTS the signal rights: before the appointment the candidate's flag reverts, after
    ///      it the flag lands and counts toward quorum like any other.
    function test_addGuardian_grantsSignalRights() public {
        address g4 = address(0x4004);
        address[] memory a = new address[](1);
        a[0] = BOB;

        vm.prank(g4);
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.flag(MARKET, a, _validBlock());

        gs.addGuardian(g4);

        _flag(g4, BOB); // the fresh guardian's flag lands...
        assertEq(_flagCount(BOB), 1, "new guardian's flag counted");
        _flag(G1, BOB); // ...and participates in the quorum
        assertTrue(gs.isBanned(MARKET, BOB), "new guardian's flag counts toward the latch");
    }

    /// @dev `removeGuardian` on an address that is not in the set reverts `NotGuardian` (the `remove` returns
    ///      false before the quorum check), and leaves the set untouched.
    function testRevert_removeGuardian_notGuardian() public {
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.removeGuardian(BOB); // never a guardian
        assertEq(gs.getGuardianCount(), 3, "set unchanged after the revert");
    }

    // ── fuzz: latch invariant & frontier == quorum-th largest ──

    /// @dev Property: across any interleaving of flags and retractions (no unban), once Banned always Banned.
    function testFuzz_latchHoldsAcrossSequence(uint256 seed) public {
        address[3] memory gns = [G1, G2, G3];
        bool everBanned;
        for (uint256 i = 0; i < 24; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address g = gns[seed % 3];
            if (seed % 2 == 0) _flag(g, BOB);
            else _unflag(g, BOB);

            if (gs.isBanned(MARKET, BOB)) everBanned = true;
            // No unban is called, so once Banned it must stay Banned.
            if (everBanned) assertTrue(gs.isBanned(MARKET, BOB), "latch holds across the sequence");
        }
    }

    function _sort3(uint40 a, uint40 b, uint40 c) internal pure returns (uint40 mid) {
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        return b; // middle of three = the quorum-th (2nd) largest for quorum 2, 3 guardians
    }

    /// @dev Property: for any heartbeat triple inside the hash window, the frontier lands exactly on the
    ///      quorum-th largest timestamp (recomputed independently by `_sort3`).
    function testFuzz_frontier_isQuorumthLargest(uint40 b1, uint40 b2, uint40 b3) public {
        // All within the 256-block hash window [block.number-256, block.number-1] = [744, 999].
        b1 = uint40(bound(b1, 745, 999));
        b2 = uint40(bound(b2, 745, 999));
        b3 = uint40(bound(b3, 745, 999));
        _heartbeat(G1, b1);
        _heartbeat(G2, b2);
        _heartbeat(G3, b3);
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), _sort3(b1, b2, b3), "frontier = quorum-th largest heartbeat");
    }

    // ── views ──

    // ── guardian set management: views ──

    /// @dev `isGuardian` is a direct membership read: true for a seeded guardian, false for a non-guardian.
    function test_isGuardian_reflectsMembership() public view {
        assertTrue(gs.isGuardian(G1), "seeded guardian reads true");
        assertFalse(gs.isGuardian(BOB), "non-guardian reads false");
    }

    /// @dev `getGuardians` returns the full set; with the seeded 3 it is exactly {G1, G2, G3} (insertion order
    ///      for an untouched EnumerableSet).
    function test_getGuardians_returnsFullSet() public view {
        address[] memory set = gs.getGuardians();
        assertEq(set.length, 3, "three guardians");
        assertEq(set[0], G1, "index 0 is G1");
        assertEq(set[1], G2, "index 1 is G2");
        assertEq(set[2], G3, "index 2 is G3");
    }

    // ── events / batch / getFlaggedBy ──

    /// @dev `getFlaggedBy` exposes the raw flagger set behind the strike count.
    function test_getFlaggedBy_returnsFlaggerSet() public {
        _flag(G1, BOB);
        _flag(G2, BOB);
        address[] memory flaggers = gs.getFlaggedBy(MARKET, BOB);
        assertEq(flaggers.length, 2, "two flaggers");
    }

    // ── liveness reads: getHeartbeat / getHeartbeats ──

    /// @dev `getHeartbeat` returns the exact last-scanned timestamp recorded for a guardian; a guardian
    ///      that never heartbeated reads zero.
    function test_getHeartbeat_recordedAndZero() public {
        _heartbeat(G1, 997); // _block packs timestamp == number == 997

        assertEq(gs.getHeartbeat(G1), 997, "recorded timestamp");

        assertEq(gs.getHeartbeat(G2), 0, "never heartbeated -> zero timestamp");
    }

    /// @dev `getHeartbeats` pairs the guardian set with each guardian's last-scanned timestamp.
    ///      Order matches `getGuardians`; an un-heartbeated guardian carries a zero timestamp.
    function test_getHeartbeats_pairsSetWithBlocks() public {
        _heartbeat(G1, 999);
        _heartbeat(G3, 990);
        // G2 deliberately left without a heartbeat.

        (address[] memory guardians, uint40[] memory heartbeats) = gs.getHeartbeats();

        assertEq(guardians.length, 3, "three guardians returned");
        assertEq(heartbeats.length, 3, "one timestamp per guardian");

        assertEq(guardians[0], G1, "index 0 guardian G1");
        assertEq(heartbeats[0], 999, "G1 heartbeat timestamp");

        assertEq(guardians[1], G2, "index 1 guardian G2");
        assertEq(heartbeats[1], 0, "G2 never heartbeated -> zero");

        assertEq(guardians[2], G3, "index 2 guardian G3");
        assertEq(heartbeats[2], 990, "G3 heartbeat timestamp");
    }

    // ── prune (permissionless) ──

    event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);

    address internal constant CLEANER = address(0xC1EA); // not a guardian, holds no roles

    /// @dev A flag left behind by a removed guardian is pruned by anyone; the flag count drops and the account
    ///      is clean again. Emits `FlagPruned`.
    function test_prune_removesRemovedGuardianFlag() public {
        _flag(G1, BOB); // 1 flag, below quorum -> Normal
        gs.removeGuardian(G1); // G1 no longer a guardian, but still in BOB's flagger set
        assertEq(_flagCount(BOB), 1, "stale flag still counts before prune");

        vm.expectEmit(true, true, true, true, address(gs));
        emit FlagPruned(MARKET, BOB, G1, 0);
        vm.prank(CLEANER); // permissionless
        gs.prune(MARKET, BOB);

        assertEq(_flagCount(BOB), 0, "stale flag pruned");
        assertEq(_strikes(BOB), 0, "no strikes");
        assertFalse(gs.isBanned(MARKET, BOB), "stays Normal");
        assertEq(gs.getFlaggedBy(MARKET, BOB).length, 0, "flagger set empty");
    }

    /// @dev Security: prune lowers the flag count but NEVER lifts a latched ban — else it would be a
    ///      permissionless unban. Only `unban` clears the status.
    function test_prune_doesNotLiftBan() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // reaches quorum 2 -> Banned
        assertTrue(gs.isBanned(MARKET, BOB), "banned at quorum");

        gs.removeGuardian(G1); // 3 -> 2, still >= quorum
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);

        assertTrue(gs.isBanned(MARKET, BOB), "prune does not lift the latched ban");
        assertEq(_flagCount(BOB), 1, "only the current-guardian flag remains");
    }

    /// @dev Prune touches only ex-guardian flags: a flag from a still-active guardian is untouched.
    function test_prune_keepsCurrentGuardianFlags() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // both still guardians
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB); // nothing stale

        assertEq(_flagCount(BOB), 2, "current-guardian flags kept");
        assertTrue(gs.isBanned(MARKET, BOB), "status unchanged");
    }

    // ── suspect snapshot -> counters ──

    function _suspect(address g, address account) internal {
        address[] memory a = new address[](1);
        a[0] = account;
        vm.prank(g);
        gs.suspect(MARKET, a, _validBlock());
    }

    /// @dev `getOpinion` carries the raw counters the activation lib turns into a delay: flag count, the
    ///      snapshotted active suspect count, and when the snapshot lapses (`suspectReportedAt + suspectWindow`).
    function test_suspect_snapshotsCountAndExpiry() public {
        gs.setSuspectWindow(1 days);

        _suspect(G1, BOB);
        GuardiansOpinion memory op = gs.getOpinion(MARKET, BOB);
        assertEq(op.strikeCount, 0, "no flags");
        assertEq(op.suspectCount, 1, "one active suspect snapshotted");
        assertEq(op.suspectExpiryTimestamp, block.timestamp + 1 days, "expiry = reportedAt + suspectWindow");

        _suspect(G2, BOB);
        op = gs.getOpinion(MARKET, BOB);
        assertEq(op.suspectCount, 2, "two active suspects");
        assertEq(op.suspectExpiryTimestamp, block.timestamp + 1 days, "expiry re-anchored to the latest report");
    }

    /// @dev Retracting a suspect re-snapshots the count against a fresh timestamp.
    function test_unsuspect_reSnapshotsCount() public {
        gs.setSuspectWindow(1 days);
        _suspect(G1, BOB);
        _suspect(G2, BOB);
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 2, "two suspects");

        address[] memory a = new address[](1);
        a[0] = BOB;
        vm.prank(G1);
        gs.unsuspect(MARKET, a, _validBlock());
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 1, "retraction re-snapshots to 1 active suspect");
    }

    // ── heartbeat validation: timestamp bounds ──

    /// @dev A guardian cannot fast-forward the frontier: a reported timestamp ahead of `block.timestamp`
    ///      is rejected even when the block number and hash are valid.
    function testRevert_heartbeat_timestampInTheFuture() public {
        BlockInfoWithHash memory b = _block(uint40(block.number - 1));
        b.timestamp = uint40(block.timestamp + 1); // number/hash valid, timestamp ahead of now
        vm.prank(G1);
        vm.expectRevert(IGuardianSignals.TimestampInTheFuture.selector);
        gs.heartbeat(b);
    }

    /// @dev A guardian cannot backdate its own frontier feed: a second heartbeat with a lower timestamp
    ///      than the recorded one is rejected, and the recorded timestamp stays.
    function testRevert_heartbeat_regressesBelowPrevious() public {
        _heartbeat(G1, 999); // records timestamp 999

        BlockInfoWithHash memory b = _block(998); // valid block, timestamp 998 < 999
        vm.prank(G1);
        vm.expectRevert(IGuardianSignals.HeartbeatTimestampRegressed.selector);
        gs.heartbeat(b);

        assertEq(gs.getHeartbeat(G1), 999, "recorded timestamp unchanged after the revert");
    }

    /// @dev Boundary: the per-guardian check is non-decreasing, so re-reporting the SAME timestamp passes
    ///      (only a strictly lower one regresses), and a timestamp equal to `block.timestamp` passes (only
    ///      a strictly future one reverts).
    function test_heartbeat_equalTimestamps_accepted() public {
        _heartbeat(G1, 999);

        BlockInfoWithHash memory b = _block(998);
        b.timestamp = 999; // == recorded: allowed
        vm.prank(G1);
        gs.heartbeat(b);
        assertEq(gs.getHeartbeat(G1), 999, "equal re-report accepted");

        b = _block(uint40(block.number - 1));
        b.timestamp = uint40(block.timestamp); // == now: allowed
        vm.prank(G1);
        gs.heartbeat(b);
        assertEq(gs.getHeartbeat(G1), block.timestamp, "timestamp equal to now accepted");
    }

    // ── suspect window bounds ──

    event SuspectWindowSet(uint256 suspectWindow);

    /// @dev The suspect window is capped at `MAX_SUSPECT_WINDOW`: one wei over the boundary reverts.
    function testRevert_setSuspectWindow_aboveMax() public {
        // Read the constant first: an external call inside the arguments would consume the expectRevert.
        uint256 max = gs.MAX_SUSPECT_WINDOW();
        vm.expectRevert(IGuardianSignals.SuspectWindowTooHigh.selector);
        gs.setSuspectWindow(max + 1);
    }

    /// @dev Boundary: exactly `MAX_SUSPECT_WINDOW` is allowed, and `getSuspectWindow` reflects the setter.
    function test_setSuspectWindow_atMaxOk() public {
        assertEq(gs.getSuspectWindow(), 0, "setUp leaves the window at 0");

        vm.expectEmit(false, false, false, true, address(gs));
        emit SuspectWindowSet(gs.MAX_SUSPECT_WINDOW());
        gs.setSuspectWindow(gs.MAX_SUSPECT_WINDOW());

        assertEq(gs.getSuspectWindow(), gs.MAX_SUSPECT_WINDOW(), "window readback matches the setter");
    }

    // ── zero-address guards ──

    /// @dev A zero admin would deploy an ungovernable registry (no role holder): rejected in `initialize`,
    ///      surfacing through the proxy construction.
    function testRevert_initialize_zeroAdmin() public {
        address impl = address(new GuardianSignals());
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],uint256)", address(0), _defaultGuardians(), uint256(2)
        );
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        new OssifiableProxy(impl, address(this), initData);
    }

    /// @dev The seeding loop applies the same zero-guardian guard as `addGuardian`: one zero entry fails the
    ///      whole deploy.
    function testRevert_initialize_zeroGuardianInSet() public {
        address impl = address(new GuardianSignals());
        address[] memory g = _defaultGuardians();
        g[1] = address(0);
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address[],uint256)", address(this), g, uint256(2));
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        new OssifiableProxy(impl, address(this), initData);
    }

    /// @dev A zero guardian could never signal but would count in the roster size: rejected.
    function testRevert_addGuardian_zeroAddress() public {
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        gs.addGuardian(address(0));
    }

    /// @dev The governance force-ban path rejects the zero account (nothing borrows from address(0), so a
    ///      zero ban could only be a mistake).
    function testRevert_ban_zeroAccount() public {
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        gs.ban(MARKET, address(0));
        assertFalse(gs.isBanned(MARKET, address(0)), "no ban recorded");
    }

    /// @dev A zero address anywhere in a flag batch reverts the WHOLE batch: the valid accounts before it
    ///      are not flagged either.
    function testRevert_flag_zeroAccountInBatch() public {
        address[] memory a = new address[](2);
        a[0] = BOB;
        a[1] = address(0);
        vm.prank(G1);
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        gs.flag(MARKET, a, _validBlock());

        assertEq(_flagCount(BOB), 0, "batch is atomic: the valid account is not flagged");
    }

    /// @dev The suspect batch carries the same zero-address atomicity as the flag batch.
    function testRevert_suspect_zeroAccountInBatch() public {
        gs.setSuspectWindow(1 days);
        address[] memory a = new address[](2);
        a[0] = BOB;
        a[1] = address(0);
        vm.prank(G1);
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        gs.suspect(MARKET, a, _validBlock());

        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 0, "batch is atomic: the valid account is not suspected");
    }

    // ── suspect lifecycle: no-op retraction, expiry window, refresh, prune ──

    event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
    event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian);

    /// @dev Retracting a report the caller never made is a no-op: the other guardian's report stays counted.
    function test_unsuspect_nonSuspecter_isNoop() public {
        gs.setSuspectWindow(1 days);
        _suspect(G1, BOB);

        address[] memory a = new address[](1);
        a[0] = BOB;
        vm.recordLogs();
        vm.prank(G2); // G2 never suspected BOB
        gs.unsuspect(MARKET, a, _validBlock());

        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 1, "G1's report still counted");
        (address[] memory suspecters,) = gs.getSuspectedBy(MARKET, BOB);
        assertEq(suspecters.length, 1, "suspect set untouched");
        assertEq(suspecters[0], G1, "only G1 remains");
        bytes32 clearedSig = keccak256("SuspectCleared(bytes32,address,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != clearedSig, "no SuspectCleared for a no-op retraction");
        }
    }

    /// @dev A suspect report left behind by a removed guardian is pruned by anyone, mirroring flag pruning.
    function test_prune_removesRemovedGuardianSuspect() public {
        gs.setSuspectWindow(1 days);
        _suspect(G1, BOB);
        gs.removeGuardian(G1); // 3 -> 2 == quorum, allowed; G1's report is now stale

        vm.expectEmit(true, true, true, false, address(gs));
        emit SuspectPruned(MARKET, BOB, G1);
        vm.prank(CLEANER); // permissionless
        gs.prune(MARKET, BOB);

        (address[] memory suspecters, uint40[] memory reportedAt) = gs.getSuspectedBy(MARKET, BOB);
        assertEq(suspecters.length, 0, "stale suspect report pruned");
        assertEq(reportedAt.length, 0, "timestamps array follows the set");
    }

    /// @dev Prune on an account with no signals at all is a harmless no-op (permissionless safety).
    function test_prune_noSignals_isNoop() public {
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);
        assertEq(_flagCount(BOB), 0, "nothing to prune, nothing changed");
        assertFalse(gs.isBanned(MARKET, BOB), "status untouched");
    }

    /// @dev A report older than the window is dropped and stops counting: the next report prunes it and
    ///      snapshots only the still-active reporters.
    function test_suspect_expiredReport_prunedAndUncounted() public {
        gs.setSuspectWindow(1 days);
        _suspect(G1, BOB); // reported at t0

        vm.warp(block.timestamp + 1 days + 1); // G1's report lapses

        vm.expectEmit(true, true, true, false, address(gs));
        emit SuspectPruned(MARKET, BOB, G1);
        _suspect(G2, BOB); // prunes G1's lapsed report, then snapshots

        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 1, "only the fresh report counts");
        (address[] memory suspecters,) = gs.getSuspectedBy(MARKET, BOB);
        assertEq(suspecters.length, 1, "lapsed report removed from the set");
        assertEq(suspecters[0], G2, "the fresh reporter remains");
    }

    /// @dev Boundary: a report aged exactly `window` is still active (`reportedAt + window >= now`), so the
    ///      count includes it.
    function test_suspect_atWindowBoundary_stillActive() public {
        gs.setSuspectWindow(1 days);
        _suspect(G1, BOB);

        vm.warp(block.timestamp + 1 days); // exactly at the boundary

        _suspect(G2, BOB);
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 2, "boundary report still counts");
    }

    /// @dev Re-reporting refreshes the reporter's timestamp: the suspicion stays live past the original
    ///      expiry as long as the guardian keeps re-attesting it.
    function test_suspect_reReport_refreshesWindow() public {
        gs.setSuspectWindow(1 days);
        _suspect(G1, BOB); // t0

        vm.warp(block.timestamp + 20 hours);
        _suspect(G1, BOB); // refresh at t0 + 20h

        vm.warp(block.timestamp + 20 hours); // t0 + 40h: past the original expiry, inside the refreshed one
        _suspect(G2, BOB); // prunes lapsed reports (none) and snapshots

        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 2, "refreshed report still active at t0+40h");
    }

    /// @dev Suspicion is advisory (it feeds the activation delay) and never latches a ban, no matter how
    ///      many guardians report it.
    function test_suspect_neverBans() public {
        gs.setSuspectWindow(1 days);
        _suspect(G1, BOB);
        _suspect(G2, BOB);
        _suspect(G3, BOB); // all guardians, over any quorum

        assertFalse(gs.isBanned(MARKET, BOB), "suspects never ban");
        assertEq(_strikes(BOB), 0, "suspects are not strikes");
    }

    /// @dev `getSuspectedBy` pairs the reporter set with each reporter's timestamp, index-aligned; a
    ///      never-suspected account reads empty arrays.
    function test_getSuspectedBy_pairsSetWithTimestamps() public {
        gs.setSuspectWindow(1 days);
        // Read the clock via the cheatcode: under --ir-minimum the compiler rematerializes the
        // `block.timestamp` OPCODE at the use site, which would observe the post-warp clock.
        uint256 t1 = vm.getBlockTimestamp();
        _suspect(G1, BOB);
        vm.warp(t1 + 1 hours);
        _suspect(G2, BOB);

        (address[] memory suspecters, uint40[] memory reportedAt) = gs.getSuspectedBy(MARKET, BOB);
        assertEq(suspecters.length, 2, "two reporters");
        assertEq(reportedAt.length, 2, "one timestamp per reporter");
        assertEq(suspecters[0], G1, "index 0 reporter");
        assertEq(reportedAt[0], t1, "G1's report timestamp");
        assertEq(suspecters[1], G2, "index 1 reporter");
        assertEq(reportedAt[1], t1 + 1 hours, "G2's report timestamp");

        (address[] memory none, uint40[] memory noneAt) = gs.getSuspectedBy(MARKET, address(0x5099));
        assertEq(none.length, 0, "never-suspected account reads empty");
        assertEq(noneAt.length, 0, "empty timestamps too");
    }

    // ── quorum-change and rotation edge cases ──

    /// @dev Pinned behaviour (quorum lowering): dropping the quorum below an existing UNLATCHED flag count
    ///      creates a dynamic ban (`flaggedBy.length() >= quorum`) that a single guardian retraction lifts —
    ///      the latch only fires on a flag ADDITION crossing quorum. This is the documented pre-latch
    ///      retraction path; the test pins the behavior so a silent change is caught.
    function test_quorumLowering_dynamicBanLiftedByUnflag() public {
        gs.setQuorum(3);
        _flag(G1, BOB);
        _flag(G2, BOB); // 2 strikes < 3: no latch
        assertFalse(gs.isBanned(MARKET, BOB), "below quorum: not banned");

        gs.setQuorum(2); // now 2 flags >= quorum 2
        assertTrue(gs.isBanned(MARKET, BOB), "quorum lowering turns the flag count into a dynamic ban");

        _unflag(G1, BOB); // 1 flag < 2
        assertFalse(gs.isBanned(MARKET, BOB), "unlatched: a retraction lifts the dynamic ban");
    }

    /// @dev Pinned behaviour (guardian rotation): a flag left by a since-removed guardian still counts
    ///      toward a LATER latch — the crossing flag latches `banned`, and pruning the stale flag afterwards
    ///      does not lift it. Recovery is `unban` only.
    function test_staleFlagAfterRotation_latchesBan() public {
        _flag(G1, BOB); // 1 strike
        gs.removeGuardian(G1); // G1 leaves, its flag stays in the set

        _flag(G2, BOB); // stale G1 + fresh G2 = 2 >= quorum 2: latches
        assertTrue(gs.isBanned(MARKET, BOB), "stale flag participates in the latch");

        vm.prank(CLEANER);
        gs.prune(MARKET, BOB); // drops the stale G1 flag
        assertEq(_flagCount(BOB), 1, "stale flag pruned");
        assertTrue(gs.isBanned(MARKET, BOB), "latched ban survives the prune");
    }

    /// @dev `unban` clears a DYNAMIC (unlatched) quorum ban too: it wipes the flag set, so the count drops
    ///      below quorum and the account is borrowable again.
    function test_unban_liftsDynamicQuorumBan() public {
        gs.setQuorum(3);
        _flag(G1, BOB);
        _flag(G2, BOB);
        gs.setQuorum(2); // dynamic ban, not latched
        assertTrue(gs.isBanned(MARKET, BOB), "dynamically banned");

        gs.unban(MARKET, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "unban lifts the dynamic ban");
        assertEq(_flagCount(BOB), 0, "flag set cleared: no instant re-ban from stale flags");
    }
}
