// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {BlockInfoWithHash, DelayParams} from "../../src/types/GuardianSignalsTypes.sol";
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
        gs.setDelayParams(DelayParams({delayPerStrike: 0, delayPerSuspect: 0, maxDelay: 0, suspectWindow: 0}));
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
        return gs.getFlagCount(MARKET, account);
    }

    function _strikes(address account) internal view returns (uint256) {
        return gs.getFlagCount(MARKET, account);
    }

    // ── mutations ──

    // ── escalation ladder & latch ──

    function test_flag_belowQuorum_isNormalWithStrikes() public {
        _flag(G1, BOB); // 1 flag, quorum 2
        assertFalse(gs.isBanned(MARKET, BOB), "below quorum stays Normal");
        assertEq(_strikes(BOB), 1, "one strike");
        assertEq(_flagCount(BOB), 1, "flagCount 1");
    }

    function test_flag_atQuorum_latchesBanned() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // reaches quorum 2
        assertTrue(gs.isBanned(MARKET, BOB), "quorum bans");
        assertEq(_strikes(BOB), 2, "strikes == flagCount, uncapped");
    }

    function test_latch_unflagBelowQuorum_staysBanned() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned
        _unflag(G1, BOB); // flagCount drops to 1 < quorum
        assertTrue(gs.isBanned(MARKET, BOB), "latched: unflag does not lift the ban");
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

    // ── forced ban / unban ──

    function test_ban_unban_clearsFlagSet() public {
        _flag(G1, BOB);
        _flag(G2, BOB); // Banned
        gs.unban(MARKET, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "unban returns to Normal");
        assertEq(_flagCount(BOB), 0, "unban clears the flag set");
    }

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

    function test_frontier_belowQuorumHeartbeats_noAdvance() public {
        _heartbeat(G1, 999); // only one guardian heartbeated; quorum is 2
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 0, "fewer than quorum heartbeats -> frontier stays 0");
    }

    function test_frontier_atQuorum_advancesToQuorumthLargest() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        _heartbeat(G3, 997);
        gs.syncQuorumBlock();
        // quorum-th largest of {999,998,997} (quorum 2) = 2nd largest = 998 (min of the top-2).
        assertEq(gs.getQuorumFrontier(), 998, "frontier = quorum-th largest heartbeat");
    }

    function test_frontier_monotonic_doesNotRegress() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        gs.syncQuorumBlock(); // frontier 998
        // Now a lagging guardian heartbeats at a lower block; the frontier must not move backward.
        _heartbeat(G3, 990);
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 998, "monotonic ratchet: frontier stays at 998, no regress");
    }

    function test_syncQuorumBlock_isPermissionless() public {
        _heartbeat(G1, 999);
        _heartbeat(G2, 998);
        vm.prank(BOB); // a non-guardian
        gs.syncQuorumBlock();
        assertEq(gs.getQuorumFrontier(), 998, "anyone can advance the frontier");
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
        bytes32 role = gs.ACCESS_LIMITER_ROLE();
        vm.prank(BOB); // lacks ACCESS_LIMITER_ROLE
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
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
        assertEq(gs.getQuorumFrontier(), 998, "fresh guardian stalls, never regresses the frontier");
    }

    // ── wrong-role reverts (each gated mutator) ──

    function testRevert_setQuorum_wrongRole() public {
        bytes32 role = gs.MANAGER_ROLE();
        vm.prank(BOB); // lacks MANAGER_ROLE
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
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

    // ── guardian set management: removal ──

    event GuardianRemoved(address indexed guardian);

    /// @dev `removeGuardian` success path: drops the set from 3 to 2 (== quorum), emits `GuardianRemoved`, and
    ///      the removed address stops being a guardian. Quorum 2 stays reachable with 2 guardians left.
    function test_removeGuardian_succeeds() public {
        assertEq(gs.getGuardianCount(), 3, "starts with three guardians");

        vm.expectEmit(true, false, false, false, address(gs));
        emit GuardianRemoved(G3);
        gs.removeGuardian(G3);

        assertEq(gs.getGuardianCount(), 2, "count drops to two");
        assertFalse(gs.isGuardian(G3), "removed address is no longer a guardian");
        assertTrue(gs.isGuardian(G1), "G1 still a guardian");
        assertTrue(gs.isGuardian(G2), "G2 still a guardian");
    }

    /// @dev `removeGuardian` on an address that is not in the set reverts `NotGuardian` (the `remove` returns
    ///      false before the quorum check), and leaves the set untouched.
    function testRevert_removeGuardian_notGuardian() public {
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.removeGuardian(BOB); // never a guardian
        assertEq(gs.getGuardianCount(), 3, "set unchanged after the revert");
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
}
