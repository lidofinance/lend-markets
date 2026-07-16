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

/// @notice Unit suite for `GuardianSignals`. A flat guardian committee: each guardian flag is one strike, status
///         latches to `Banned` at quorum (a retraction never lifts a ban in effect), and a heartbeat advances the
///         monotonic quorum liveness frontier in the same call (`syncQuorumFrontier` is a fallback). A guardian may
///         appoint a delegate to act on its behalf. Deployed behind `OssifiableProxy` (the impl disables initializers).
contract GuardianSignalsTest is Test {
    GuardianSignals internal gs;

    // The committee guardians (a flat set). A guardian may appoint one delegate to act on its behalf.
    address internal constant GUARDIAN_1 = address(0x4001);
    address internal constant GUARDIAN_2 = address(0x4002);
    address internal constant GUARDIAN_3 = address(0x4003);
    address internal constant DELEGATE = address(0x4201);
    address internal constant BOB = address(0x5001);
    address internal constant CLEANER = address(0xC1EA); // not a guardian, holds no roles

    /// @dev The market all signals in this suite are keyed under.
    Id internal constant MARKET = Id.wrap(bytes32(uint256(0xA11CE)));

    // ── events (mirrored for expectEmit) ──
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event DelegateSet(address indexed guardian, address indexed oldDelegate, address indexed newDelegate);
    event QuorumSet(uint256 quorum);
    event SuspectWindowSet(uint256 suspectWindow);
    event Flagged(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint16 strikes
    );
    event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
    event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
    event Banned(Id indexed marketId, address indexed account);
    event QuorumFrontierAdvanced(uint40 timestamp);

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

        gs.setSuspectWindow(0);
    }

    // ── helpers ──

    function _defaultGuardians() internal pure returns (address[] memory guardians) {
        guardians = new address[](3);
        guardians[0] = GUARDIAN_1;
        guardians[1] = GUARDIAN_2;
        guardians[2] = GUARDIAN_3;
    }

    function _block(uint40 blockNumber) internal view returns (BlockInfoWithHash memory) {
        return BlockInfoWithHash({hash: blockhash(blockNumber), number: blockNumber, timestamp: blockNumber});
    }

    function _validBlock() internal view returns (BlockInfoWithHash memory) {
        return _block(uint40(block.number - 1));
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    /// @dev Guardian `guardian` flags `account` on its own behalf.
    function _flag(address guardian, address account) internal {
        vm.prank(guardian);
        gs.flag(MARKET, guardian, _one(account));
    }

    /// @dev Guardian `guardian` retracts its own flag on `account`.
    function _unflag(address guardian, address account) internal {
        vm.prank(guardian);
        gs.unflag(MARKET, guardian, _one(account));
    }

    /// @dev Guardian `guardian` reports `account` as suspect on its own behalf.
    function _suspect(address guardian, address account) internal {
        vm.prank(guardian);
        gs.suspect(MARKET, guardian, _one(account));
    }

    /// @dev Records a heartbeat for `guardian` at block/timestamp `at`.
    function _heartbeat(address guardian, uint40 at) internal {
        vm.prank(guardian);
        gs.heartbeat(guardian, _block(at));
    }

    function _flagCount(address account) internal view returns (uint256) {
        return gs.getFlaggedBy(MARKET, account).length;
    }

    // ── escalation ladder & latch ──

    /// @dev A single flag below quorum is a strike, not a ban.
    function test_flag_belowQuorum_isNormalWithStrikes() public {
        _flag(GUARDIAN_1, BOB); // 1 flag, quorum 2
        assertFalse(gs.isBanned(MARKET, BOB), "below quorum stays Normal");
        assertEq(_flagCount(BOB), 1, "one strike");
    }

    /// @dev The flag that reaches quorum latches the ban; strikes keep counting past it.
    function test_flag_atQuorum_latchesBanned() public {
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB); // reaches quorum 2
        assertTrue(gs.isBanned(MARKET, BOB), "quorum bans");
        assertEq(_flagCount(BOB), 2, "strikes == flagCount, uncapped");
    }

    /// @dev Once quorum-banned, a retraction that drops the count below quorum does NOT lift the ban.
    function test_latch_unflagBelowQuorum_staysBanned() public {
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB); // Banned
        _unflag(GUARDIAN_1, BOB); // flagCount drops to 1 < quorum
        assertTrue(gs.isBanned(MARKET, BOB), "latched: unflag does not lift the ban");
        assertEq(_flagCount(BOB), 1, "flagCount dropped");
    }

    /// @dev One guardian holds at most one flag per account: re-flagging cannot manufacture strikes.
    function test_flag_sameGuardianTwice_isIdempotent() public {
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_1, BOB); // same guardian -> no second strike
        assertEq(_flagCount(BOB), 1, "set semantics: one flag per guardian");
    }

    /// @dev A guardian can only retract its OWN flag: retracting a flag it never cast is a no-op.
    function test_unflag_nonFlagger_isNoop() public {
        _flag(GUARDIAN_1, BOB);
        _unflag(GUARDIAN_2, BOB); // GUARDIAN_2 never flagged -> no-op
        assertEq(_flagCount(BOB), 1, "unflag by a non-flagger is a no-op");
    }

    // ── ban / unban ──

    /// @dev `unban` lifts the latched ban AND wipes the flag set, so the account restarts from a clean slate.
    function test_ban_unban_clearsFlagSet() public {
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB); // Banned
        gs.unban(MARKET, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "unban returns to Normal");
        assertEq(_flagCount(BOB), 0, "unban clears the flag set");

        _flag(GUARDIAN_1, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "one fresh flag stays below quorum after unban");
        _flag(GUARDIAN_2, BOB);
        assertTrue(gs.isBanned(MARKET, BOB), "a fresh quorum re-latches the ban");
    }

    /// @dev The `ACCESS_LIMITER_ROLE` force-ban needs no flags at all and latches immediately.
    function test_forcedBan_latchesRegardlessOfFlags() public {
        gs.ban(MARKET, BOB);
        assertTrue(gs.isBanned(MARKET, BOB), "forced ban latches with zero flags");
        assertEq(_flagCount(BOB), 0, "forced ban does not touch flags");
    }

    /// @dev `ban` is role-gated: guardians flag, only `ACCESS_LIMITER_ROLE` bans directly.
    function testRevert_ban_wrongRole() public {
        bytes32 role = gs.ACCESS_LIMITER_ROLE();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        gs.ban(MARKET, BOB);
    }

    /// @dev The force-ban path rejects the zero account.
    function testRevert_ban_zeroAccount() public {
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        gs.ban(MARKET, address(0));
    }

    // ── unflag ban-latch (a retraction latches an effective ban first) ──

    /// @dev Lowering the quorum below an existing flag count creates a quorum-derived (unlatched) ban, and a
    ///      retraction materializes it into the latch BEFORE dropping the count — so the ban survives. An attacker
    ///      cannot un-flag out of an in-effect ban; only `unban` clears it.
    function test_quorumLowering_unflagLatchesDerivedBan() public {
        gs.setQuorum(3);
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB); // 2 strikes < 3: no latch
        assertFalse(gs.isBanned(MARKET, BOB), "below quorum: not banned");

        gs.setQuorum(2); // now 2 flags >= quorum 2: a quorum-derived, still-unlatched ban
        assertTrue(gs.isBanned(MARKET, BOB), "quorum lowering turns the flag count into a ban");

        _unflag(GUARDIAN_1, BOB); // drops to 1 flag < 2, but the retraction latches the ban first
        assertTrue(gs.isBanned(MARKET, BOB), "the retraction latched the ban -> it survives below quorum");
        assertEq(_flagCount(BOB), 1, "the flag count still dropped");
    }

    /// @dev A purely-derived ban (never latched, no retraction) still tracks the quorum both ways.
    function test_derivedBan_tracksQuorumBothWays() public {
        gs.setQuorum(3);
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB); // 2 strikes, never latched
        assertFalse(gs.isBanned(MARKET, BOB), "below quorum 3");
        gs.setQuorum(2);
        assertTrue(gs.isBanned(MARKET, BOB), "meets quorum 2");
        gs.setQuorum(3);
        assertFalse(gs.isBanned(MARKET, BOB), "back above quorum 3 -> derived ban lifts (was never latched)");
    }

    // ── delegation ──

    /// @dev A guardian appoints a delegate; the delegate may flag on the guardian's behalf, keyed by the guardian.
    function test_delegate_actsOnBehalfOfGuardian() public {
        vm.prank(GUARDIAN_1);
        gs.setDelegate(DELEGATE);
        assertEq(gs.getDelegate(GUARDIAN_1), DELEGATE, "delegate recorded");

        vm.prank(DELEGATE);
        gs.flag(MARKET, GUARDIAN_1, _one(BOB));

        assertEq(_flagCount(BOB), 1, "delegate's flag counted");
        assertEq(gs.getFlaggedBy(MARKET, BOB)[0], GUARDIAN_1, "keyed by the guardian, not the delegate");
    }

    /// @dev The delegate may also retract and report suspects for its guardian.
    function test_delegate_canUnflagAndSuspect() public {
        vm.prank(GUARDIAN_1);
        gs.setDelegate(DELEGATE);
        _flag(GUARDIAN_1, BOB);

        vm.prank(DELEGATE);
        gs.unflag(MARKET, GUARDIAN_1, _one(BOB));
        assertEq(_flagCount(BOB), 0, "delegate retracted the guardian's flag");

        gs.setSuspectWindow(1 days);
        vm.prank(DELEGATE);
        gs.suspect(MARKET, GUARDIAN_1, _one(BOB));
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 1, "delegate's suspect counted");
    }

    /// @dev Re-pointing the delegate revokes the old one: the former delegate can no longer act.
    function test_delegate_reappointRevokesOld() public {
        vm.prank(GUARDIAN_1);
        gs.setDelegate(DELEGATE);
        address newDelegate = address(0x4202);
        vm.prank(GUARDIAN_1);
        gs.setDelegate(newDelegate);
        assertEq(gs.getDelegate(GUARDIAN_1), newDelegate, "delegate re-pointed");

        vm.prank(DELEGATE); // the old delegate
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.flag(MARKET, GUARDIAN_1, _one(BOB));
    }

    /// @dev Clearing the delegate (zero address) revokes it.
    function test_delegate_clear() public {
        vm.prank(GUARDIAN_1);
        gs.setDelegate(DELEGATE);
        vm.prank(GUARDIAN_1);
        gs.setDelegate(address(0));
        assertEq(gs.getDelegate(GUARDIAN_1), address(0), "delegate cleared");

        vm.prank(DELEGATE);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.flag(MARKET, GUARDIAN_1, _one(BOB));
    }

    /// @dev `setDelegate` emits `DelegateSet(guardian, old, new)`.
    function test_setDelegate_emitsEvent() public {
        vm.expectEmit(true, true, true, false, address(gs));
        emit DelegateSet(GUARDIAN_1, address(0), DELEGATE);
        vm.prank(GUARDIAN_1);
        gs.setDelegate(DELEGATE);
    }

    /// @dev Only a guardian may appoint a delegate.
    function testRevert_setDelegate_nonGuardian() public {
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.setDelegate(DELEGATE);
    }

    /// @dev `getDelegate` reads one guardian's delegate; `getGuardians` returns the set paired with each delegate.
    function test_getGuardians_pairsSetWithDelegates() public {
        vm.prank(GUARDIAN_2);
        gs.setDelegate(DELEGATE);
        assertEq(gs.getDelegate(GUARDIAN_2), DELEGATE, "single-guardian getter");
        assertEq(gs.getDelegate(GUARDIAN_1), address(0), "no delegate reads zero");

        (address[] memory guardians, address[] memory delegates) = gs.getGuardians();
        assertEq(guardians.length, 3, "three guardians");
        assertEq(delegates[0], address(0), "GUARDIAN_1 has no delegate");
        assertEq(delegates[1], DELEGATE, "GUARDIAN_2's delegate aligned by index");
        assertEq(delegates[2], address(0), "GUARDIAN_3 has no delegate");
    }

    /// @dev Removing a guardian clears its delegate, so re-adding it starts with none.
    function test_removeGuardian_clearsDelegate() public {
        vm.prank(GUARDIAN_3);
        gs.setDelegate(DELEGATE);
        gs.removeGuardian(GUARDIAN_3);
        assertEq(gs.getDelegate(GUARDIAN_3), address(0), "delegate cleared on removal");
    }

    // ── onBehalf authorization ──

    /// @dev A caller that is neither the guardian nor its delegate cannot act for it.
    function testRevert_flag_unauthorizedCaller() public {
        vm.prank(BOB); // not GUARDIAN_1, not its delegate
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.flag(MARKET, GUARDIAN_1, _one(BOB));
    }

    /// @dev Acting on behalf of a non-guardian reverts even from the caller's own address.
    function testRevert_flag_onBehalfOfNonGuardian() public {
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.flag(MARKET, BOB, _one(BOB));
    }

    /// @dev A guardian cannot flag on behalf of a *different* guardian.
    function testRevert_flag_onBehalfOfAnotherGuardian() public {
        vm.prank(GUARDIAN_1);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.flag(MARKET, GUARDIAN_2, _one(BOB));
    }

    /// @dev unflag/unsuspect/heartbeat share the same authorization gate.
    function testRevert_unflag_unauthorizedCaller() public {
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.unflag(MARKET, GUARDIAN_1, _one(BOB));
    }

    function testRevert_unsuspect_unauthorizedCaller() public {
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.unsuspect(MARKET, GUARDIAN_1, _one(BOB));
    }

    function testRevert_heartbeat_unauthorizedCaller() public {
        vm.prank(BOB);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.heartbeat(GUARDIAN_1, _validBlock());
    }

    // ── events / batch ──

    /// @dev Every flag emits `Flagged` with the running strike count; the quorum-crossing one adds `Banned`.
    function test_flag_emitsFlaggedAndBannedAtQuorum() public {
        vm.expectEmit(true, true, true, true, address(gs));
        emit Flagged(MARKET, BOB, GUARDIAN_1, GUARDIAN_1, 1); // guardian and actor coincide (self-flag)
        vm.prank(GUARDIAN_1);
        gs.flag(MARKET, GUARDIAN_1, _one(BOB));

        vm.expectEmit(true, true, false, false, address(gs));
        emit Banned(MARKET, BOB);
        vm.prank(GUARDIAN_2);
        gs.flag(MARKET, GUARDIAN_2, _one(BOB));
    }

    /// @dev A delegate's flag records the guardian as `guardian` and the delegate as `actor`.
    function test_flag_delegateActorInEvent() public {
        vm.prank(GUARDIAN_1);
        gs.setDelegate(DELEGATE);
        vm.expectEmit(true, true, true, true, address(gs));
        emit Flagged(MARKET, BOB, GUARDIAN_1, DELEGATE, 1);
        vm.prank(DELEGATE);
        gs.flag(MARKET, GUARDIAN_1, _one(BOB));
    }

    /// @dev `Banned` fires exactly once, on the crossing flag.
    function test_flag_pastQuorum_noSecondBannedEvent() public {
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB); // Banned latched
        vm.recordLogs();
        _flag(GUARDIAN_3, BOB);
        bytes32 bannedSig = keccak256("Banned(bytes32,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != bannedSig, "no second Banned event past quorum");
        }
    }

    /// @dev One call flags a whole batch: each account gets its own strike.
    function test_flag_batch_multipleAccounts() public {
        address[] memory accounts = new address[](2);
        accounts[0] = BOB;
        accounts[1] = address(0x5002);
        vm.prank(GUARDIAN_1);
        gs.flag(MARKET, GUARDIAN_1, accounts);
        assertEq(_flagCount(BOB), 1, "first account flagged");
        assertEq(_flagCount(address(0x5002)), 1, "second account flagged");
    }

    /// @dev A zero address anywhere in a flag batch reverts the WHOLE batch.
    function testRevert_flag_zeroAccountInBatch() public {
        address[] memory accounts = new address[](2);
        accounts[0] = BOB;
        accounts[1] = address(0);
        vm.prank(GUARDIAN_1);
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        gs.flag(MARKET, GUARDIAN_1, accounts);
        assertEq(_flagCount(BOB), 0, "batch is atomic");
    }

    /// @dev A flag records no heartbeat: liveness is a standalone `heartbeat` call.
    function test_flag_doesNotHeartbeat() public {
        _flag(GUARDIAN_1, BOB);
        assertEq(gs.getHeartbeat(GUARDIAN_1), 0, "flag leaves the heartbeat untouched");
    }

    /// @dev A suspect report records no heartbeat: liveness is a standalone `heartbeat` call.
    function test_suspect_doesNotHeartbeat() public {
        _suspect(GUARDIAN_1, BOB);
        assertEq(gs.getHeartbeat(GUARDIAN_1), 0, "suspect leaves the heartbeat untouched");
    }

    // ── liveness frontier ──

    /// @dev A heartbeat advances the frontier in the same call once a quorum has reported — no separate sync tx.
    function test_frontier_heartbeatAdvancesEagerly() public {
        _heartbeat(GUARDIAN_1, 999);
        assertEq(gs.getQuorumFrontier(), 0, "one heartbeat is below quorum: frontier stays 0");
        _heartbeat(GUARDIAN_2, 998);
        assertEq(gs.getQuorumFrontier(), 998, "the quorum-th heartbeat advances the frontier without an explicit sync");
    }

    /// @dev A heartbeat that raises the frontier emits `QuorumFrontierAdvanced`; a sub-quorum one emits none.
    function test_frontier_heartbeatEmitsAdvanced() public {
        vm.recordLogs();
        _heartbeat(GUARDIAN_1, 999); // below quorum: frontier holds at 0
        Vm.Log[] memory subQuorum = vm.getRecordedLogs();
        bytes32 advancedSig = keccak256("QuorumFrontierAdvanced(uint40)");
        for (uint256 i; i < subQuorum.length; ++i) {
            assertTrue(subQuorum[i].topics[0] != advancedSig, "a sub-quorum heartbeat emits no advance");
        }

        vm.expectEmit(false, false, false, true, address(gs));
        emit QuorumFrontierAdvanced(998);
        _heartbeat(GUARDIAN_2, 998);
    }

    /// @dev A guardian already above the frontier cannot raise the quorum-th largest, so the frontier holds.
    function test_frontier_heartbeatAboveFrontier_noAdvance() public {
        _heartbeat(GUARDIAN_1, 997);
        _heartbeat(GUARDIAN_2, 996); // frontier 996
        _heartbeat(GUARDIAN_1, 998); // GUARDIAN_1 already at 997 > frontier 996
        assertEq(gs.getQuorumFrontier(), 996, "a leader's heartbeat above the frontier does not raise it");
    }

    /// @dev Fewer than quorum heartbeats keep the frontier at zero.
    function test_frontier_belowQuorumHeartbeats_noAdvance() public {
        _heartbeat(GUARDIAN_1, 999);
        gs.syncQuorumFrontier();
        assertEq(gs.getQuorumFrontier(), 0, "fewer than quorum heartbeats -> frontier stays 0");
    }

    /// @dev The frontier is the quorum-th largest timestamp.
    function test_frontier_atQuorum_advancesToQuorumthLargest() public {
        _heartbeat(GUARDIAN_1, 999);
        _heartbeat(GUARDIAN_2, 998);
        _heartbeat(GUARDIAN_3, 997);
        gs.syncQuorumFrontier();
        assertEq(gs.getQuorumFrontier(), 998, "quorum-th largest of {999,998,997} at quorum 2");
    }

    /// @dev The frontier ratchets: a later lower report cannot pull it back.
    function test_frontier_monotonic_doesNotRegress() public {
        _heartbeat(GUARDIAN_1, 999);
        _heartbeat(GUARDIAN_2, 998);
        gs.syncQuorumFrontier(); // frontier 998
        _heartbeat(GUARDIAN_3, 990);
        gs.syncQuorumFrontier();
        assertEq(gs.getQuorumFrontier(), 998, "monotonic ratchet");
    }

    /// @dev Recomputing the frontier is permissionless.
    function test_syncQuorumFrontier_isPermissionless() public {
        _heartbeat(GUARDIAN_1, 999);
        _heartbeat(GUARDIAN_2, 998);
        vm.prank(BOB);
        gs.syncQuorumFrontier();
        assertEq(gs.getQuorumFrontier(), 998, "anyone can advance the frontier");
    }

    // ── heartbeat validation ──

    function testRevert_heartbeat_blockInTheFuture() public {
        BlockInfoWithHash memory info = _block(uint40(block.number - 1));
        info.number = uint40(block.number + 1);
        vm.prank(GUARDIAN_1);
        vm.expectRevert(IGuardianSignals.BlockInTheFuture.selector);
        gs.heartbeat(GUARDIAN_1, info);
    }

    function testRevert_heartbeat_timestampInTheFuture() public {
        BlockInfoWithHash memory info = _block(uint40(block.number - 1));
        info.timestamp = uint40(block.timestamp + 1);
        vm.prank(GUARDIAN_1);
        vm.expectRevert(IGuardianSignals.TimestampInTheFuture.selector);
        gs.heartbeat(GUARDIAN_1, info);
    }

    function testRevert_heartbeat_regressesBelowPrevious() public {
        _heartbeat(GUARDIAN_1, 999);
        BlockInfoWithHash memory info = _block(998);
        vm.prank(GUARDIAN_1);
        vm.expectRevert(IGuardianSignals.HeartbeatTimestampRegressed.selector);
        gs.heartbeat(GUARDIAN_1, info);
        assertEq(gs.getHeartbeat(GUARDIAN_1), 999, "recorded timestamp unchanged after the revert");
    }

    function testRevert_heartbeat_invalidBlockHash() public {
        BlockInfoWithHash memory info = _block(uint40(block.number - 1));
        info.hash = bytes32(uint256(0xdead));
        vm.prank(GUARDIAN_1);
        vm.expectRevert(IGuardianSignals.InvalidBlockHash.selector);
        gs.heartbeat(GUARDIAN_1, info);
    }

    /// @dev Boundary: a re-report at the same timestamp and one at exactly `now` both pass.
    function test_heartbeat_equalTimestamps_accepted() public {
        _heartbeat(GUARDIAN_1, 999);
        BlockInfoWithHash memory info = _block(998);
        info.timestamp = 999;
        vm.prank(GUARDIAN_1);
        gs.heartbeat(GUARDIAN_1, info);
        assertEq(gs.getHeartbeat(GUARDIAN_1), 999, "equal re-report accepted");
    }

    /// @dev `getHeartbeats` pairs the guardian set with each guardian's last-scanned timestamp.
    function test_getHeartbeats_pairsSetWithTimestamps() public {
        _heartbeat(GUARDIAN_1, 999);
        _heartbeat(GUARDIAN_3, 990);
        (address[] memory guardians, uint40[] memory timestamps) = gs.getHeartbeats();
        assertEq(guardians.length, 3, "three guardians");
        assertEq(guardians[0], GUARDIAN_1, "index 0 guardian");
        assertEq(timestamps[0], 999, "GUARDIAN_1 timestamp");
        assertEq(timestamps[1], 0, "GUARDIAN_2 never heartbeated");
        assertEq(timestamps[2], 990, "GUARDIAN_3 timestamp");
    }

    // ── set / quorum management ──

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
        assertEq(gs.getQuorum(), 3, "quorum == count allowed");
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "2 flags no longer ban at quorum 3");
        _flag(GUARDIAN_3, BOB);
        assertTrue(gs.isBanned(MARKET, BOB), "the full roster reaches quorum 3");
    }

    function testRevert_setQuorum_wrongRole() public {
        bytes32 role = gs.MANAGER_ROLE();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        gs.setQuorum(1);
    }

    function testRevert_addGuardian_existing() public {
        vm.expectRevert(IGuardianSignals.AlreadyGuardian.selector);
        gs.addGuardian(GUARDIAN_1);
    }

    function testRevert_addGuardian_zeroAddress() public {
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        gs.addGuardian(address(0));
    }

    function testRevert_addGuardian_max32() public {
        for (uint160 i = 4; i <= 32; i++) {
            gs.addGuardian(address(0x4000 + i));
        }
        vm.expectRevert(IGuardianSignals.MaxGuardiansReached.selector);
        gs.addGuardian(address(0x4000 + 33));
    }

    /// @dev `addGuardian` GRANTS signal rights; a fresh guardian's flag lands and counts.
    function test_addGuardian_grantsSignalRights() public {
        address guardian4 = address(0x4004);
        vm.prank(guardian4);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.flag(MARKET, guardian4, _one(BOB));

        gs.addGuardian(guardian4);
        _flag(guardian4, BOB);
        assertEq(_flagCount(BOB), 1, "new guardian's flag counted");
    }

    function test_addGuardian_emitsEvent() public {
        vm.expectEmit(true, false, false, false, address(gs));
        emit GuardianAdded(address(0x4004));
        gs.addGuardian(address(0x4004));
    }

    // ── removeGuardian ──

    function test_removeGuardian_succeeds() public {
        assertEq(gs.getGuardianCount(), 3, "starts with three");
        vm.expectEmit(true, false, false, false, address(gs));
        emit GuardianRemoved(GUARDIAN_3);
        gs.removeGuardian(GUARDIAN_3);

        assertEq(gs.getGuardianCount(), 2, "count drops to two");
        assertFalse(gs.isGuardian(GUARDIAN_3), "removed address is no longer a guardian");

        // Revoked in practice: the ex-guardian cannot signal, the rest can.
        vm.prank(GUARDIAN_3);
        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        gs.flag(MARKET, GUARDIAN_3, _one(BOB));
        _flag(GUARDIAN_1, BOB);
        assertEq(_flagCount(BOB), 1, "remaining guardian still flags");
    }

    function testRevert_removeGuardian_notGuardian() public {
        vm.expectRevert(IGuardianSignals.NotGuardian.selector);
        gs.removeGuardian(BOB);
        assertEq(gs.getGuardianCount(), 3, "set unchanged after the revert");
    }

    function testRevert_removeGuardian_wouldBreakQuorum() public {
        gs.setQuorum(3); // quorum == count
        vm.expectRevert(IGuardianSignals.WouldBreakQuorum.selector);
        gs.removeGuardian(GUARDIAN_3);
    }

    // ── views ──

    function test_isGuardian_reflectsMembership() public view {
        assertTrue(gs.isGuardian(GUARDIAN_1), "seeded guardian reads true");
        assertFalse(gs.isGuardian(BOB), "non-guardian reads false");
    }

    function test_getGuardians_returnsFullSet() public view {
        (address[] memory set,) = gs.getGuardians();
        assertEq(set.length, 3, "three guardians");
        assertEq(set[0], GUARDIAN_1, "index 0");
        assertEq(set[1], GUARDIAN_2, "index 1");
        assertEq(set[2], GUARDIAN_3, "index 2");
    }

    function test_getFlaggedBy_returnsFlaggerSet() public {
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB);
        address[] memory flaggers = gs.getFlaggedBy(MARKET, BOB);
        assertEq(flaggers.length, 2, "two flaggers");
    }

    // ── prune (permissionless) ──

    /// @dev A flag left by a removed guardian is pruned by anyone; the count drops. Emits `FlagPruned`.
    function test_prune_removesRemovedGuardianFlag() public {
        _flag(GUARDIAN_1, BOB); // 1 flag, below quorum
        gs.removeGuardian(GUARDIAN_1); // GUARDIAN_1 no longer a guardian, but its flag stays in BOB's set
        assertEq(_flagCount(BOB), 1, "stale flag still counts before prune");

        vm.expectEmit(true, true, true, true, address(gs));
        emit FlagPruned(MARKET, BOB, GUARDIAN_1, 0);
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);

        assertEq(_flagCount(BOB), 0, "stale flag pruned");
        assertFalse(gs.isBanned(MARKET, BOB), "stays Normal");
    }

    /// @dev A never-latched derived ban lapses when prune drops the surviving flags below quorum.
    function test_prune_derivedBan_lapsesWhenBelowQuorum() public {
        gs.setQuorum(3);
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB);
        gs.setQuorum(2); // derived ban: 2 >= 2, not latched
        assertTrue(gs.isBanned(MARKET, BOB), "quorum-derived ban in effect");

        gs.removeGuardian(GUARDIAN_1);
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);

        assertFalse(gs.isBanned(MARKET, BOB), "pruned below quorum -> derived ban lapses");
        assertEq(_flagCount(BOB), 1, "the stale flag was pruned");
    }

    /// @dev A derived ban whose surviving flags still meet quorum after prune is latched (made permanent).
    function test_prune_derivedBan_latchesWhenStillQuorum() public {
        gs.setQuorum(3);
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB);
        gs.setQuorum(1); // derived ban: 2 >= 1, not latched
        gs.removeGuardian(GUARDIAN_1);
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);

        assertTrue(gs.isBanned(MARKET, BOB), "surviving flag still meets quorum -> latched");
        gs.setQuorum(2);
        assertTrue(gs.isBanned(MARKET, BOB), "latched ban survives a quorum raise");
    }

    /// @dev Prune lowers the flag count but NEVER lifts a latched ban.
    function test_prune_doesNotLiftBan() public {
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB); // Banned
        gs.removeGuardian(GUARDIAN_1); // 3 -> 2, still >= quorum
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);
        assertTrue(gs.isBanned(MARKET, BOB), "prune does not lift the latched ban");
        assertEq(_flagCount(BOB), 1, "only the current-guardian flag remains");
    }

    /// @dev Prune touches only ex-guardian flags: a current guardian's flag is untouched.
    function test_prune_keepsCurrentGuardianFlags() public {
        _flag(GUARDIAN_1, BOB);
        _flag(GUARDIAN_2, BOB);
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);
        assertEq(_flagCount(BOB), 2, "current-guardian flags kept");
    }

    /// @dev Prune on an account with no signals is a harmless no-op.
    function test_prune_noSignals_isNoop() public {
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);
        assertEq(_flagCount(BOB), 0, "nothing to prune");
    }

    // ── suspect lifecycle ──

    /// @dev `getOpinion` carries the raw counters: flag count, active suspect count, and snapshot expiry.
    function test_suspect_snapshotsCountAndExpiry() public {
        gs.setSuspectWindow(1 days);
        _suspect(GUARDIAN_1, BOB);
        GuardiansOpinion memory opinion = gs.getOpinion(MARKET, BOB);
        assertEq(opinion.strikeCount, 0, "no flags");
        assertEq(opinion.suspectCount, 1, "one active suspect");
        assertEq(opinion.suspectExpiryTimestamp, block.timestamp + 1 days, "expiry = reportedAt + window");

        _suspect(GUARDIAN_2, BOB);
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 2, "two active suspects");
    }

    /// @dev A suspect report never bans.
    function test_suspect_neverBans() public {
        gs.setSuspectWindow(1 days);
        _suspect(GUARDIAN_1, BOB);
        _suspect(GUARDIAN_2, BOB);
        _suspect(GUARDIAN_3, BOB);
        assertFalse(gs.isBanned(MARKET, BOB), "suspects never ban, whatever the count");
    }

    /// @dev Retracting a suspect re-snapshots the count.
    function test_unsuspect_reSnapshotsCount() public {
        gs.setSuspectWindow(1 days);
        _suspect(GUARDIAN_1, BOB);
        _suspect(GUARDIAN_2, BOB);
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 2, "two suspects");
        vm.prank(GUARDIAN_1);
        gs.unsuspect(MARKET, GUARDIAN_1, _one(BOB));
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 1, "retraction re-snapshots to 1");
    }

    /// @dev `getSuspectedBy` pairs the reporter set with each reporter's timestamp.
    function test_getSuspectedBy_pairsSetWithTimestamps() public {
        gs.setSuspectWindow(1 days);
        uint256 t1 = vm.getBlockTimestamp();
        _suspect(GUARDIAN_1, BOB);
        (address[] memory suspecters, uint40[] memory reportedAt) = gs.getSuspectedBy(MARKET, BOB);
        assertEq(suspecters.length, 1, "one reporter");
        assertEq(suspecters[0], GUARDIAN_1, "reporter is the guardian");
        assertEq(reportedAt[0], t1, "reporter timestamp");
    }

    /// @dev An expired report is pruned and stops counting on the next report.
    function test_suspect_expiredReport_prunedAndUncounted() public {
        gs.setSuspectWindow(1 days);
        _suspect(GUARDIAN_1, BOB); // reported at t0
        vm.warp(block.timestamp + 1 days + 1); // lapses

        vm.expectEmit(true, true, true, false, address(gs));
        emit SuspectPruned(MARKET, BOB, GUARDIAN_1);
        _suspect(GUARDIAN_2, BOB); // prunes GUARDIAN_1's lapsed report, then snapshots

        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 1, "only the fresh report counts");
        (address[] memory suspecters,) = gs.getSuspectedBy(MARKET, BOB);
        assertEq(suspecters.length, 1, "lapsed report removed");
        assertEq(suspecters[0], GUARDIAN_2, "the fresh reporter remains");
    }

    /// @dev A suspect report cast by a removed guardian is pruned permissionlessly, and the active-suspect
    ///      snapshot is re-taken so the pruned report stops counting toward the delay immediately.
    function test_prune_removesRemovedGuardianSuspect() public {
        gs.setSuspectWindow(1 days);
        _suspect(GUARDIAN_1, BOB);
        _suspect(GUARDIAN_2, BOB);
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 2, "two live reports before prune");

        gs.removeGuardian(GUARDIAN_1);
        vm.expectEmit(true, true, true, false, address(gs));
        emit SuspectPruned(MARKET, BOB, GUARDIAN_1);
        vm.prank(CLEANER);
        gs.prune(MARKET, BOB);

        (address[] memory suspecters,) = gs.getSuspectedBy(MARKET, BOB);
        assertEq(suspecters.length, 1, "stale suspect report pruned from the set");
        assertEq(suspecters[0], GUARDIAN_2, "the current guardian's report remains");
        assertEq(gs.getOpinion(MARKET, BOB).suspectCount, 1, "re-snapshot: pruned report no longer counts");
    }

    // ── suspect window bounds ──

    function testRevert_setSuspectWindow_aboveMax() public {
        uint256 max = gs.MAX_SUSPECT_WINDOW();
        vm.expectRevert(IGuardianSignals.SuspectWindowTooHigh.selector);
        gs.setSuspectWindow(max + 1);
    }

    function test_setSuspectWindow_atMaxOk() public {
        vm.expectEmit(false, false, false, true, address(gs));
        emit SuspectWindowSet(gs.MAX_SUSPECT_WINDOW());
        gs.setSuspectWindow(gs.MAX_SUSPECT_WINDOW());
        assertEq(gs.getSuspectWindow(), gs.MAX_SUSPECT_WINDOW(), "window readback matches");
    }

    // ── initialization guards ──

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

    function testRevert_initialize_zeroAdmin() public {
        address impl = address(new GuardianSignals());
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],uint256)", address(0), _defaultGuardians(), uint256(2)
        );
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        new OssifiableProxy(impl, address(this), initData);
    }

    function testRevert_initialize_zeroGuardianInSet() public {
        address impl = address(new GuardianSignals());
        address[] memory guardians = _defaultGuardians();
        guardians[1] = address(0);
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address[],uint256)", address(this), guardians, uint256(2));
        vm.expectRevert(IGuardianSignals.ZeroAddress.selector);
        new OssifiableProxy(impl, address(this), initData);
    }

    // ── fuzz ──

    /// @dev Property: across any interleaving of flags and retractions (no unban), once Banned always Banned.
    function testFuzz_latchHoldsAcrossSequence(uint256 seed) public {
        address[3] memory roster = [GUARDIAN_1, GUARDIAN_2, GUARDIAN_3];
        bool everBanned;
        for (uint256 i; i < 24; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address guardian = roster[seed % 3];
            if (seed % 2 == 0) _flag(guardian, BOB);
            else _unflag(guardian, BOB);

            if (gs.isBanned(MARKET, BOB)) everBanned = true;
            if (everBanned) assertTrue(gs.isBanned(MARKET, BOB), "latch holds across the sequence");
        }
    }

    function _sort3(uint40 a, uint40 b, uint40 c) internal pure returns (uint40 mid) {
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        return b;
    }

    /// @dev Property: the frontier lands on the quorum-th largest heartbeat timestamp.
    function testFuzz_frontier_isQuorumthLargest(uint40 b1, uint40 b2, uint40 b3) public {
        b1 = uint40(bound(b1, 745, 999));
        b2 = uint40(bound(b2, 745, 999));
        b3 = uint40(bound(b3, 745, 999));
        _heartbeat(GUARDIAN_1, b1);
        _heartbeat(GUARDIAN_2, b2);
        _heartbeat(GUARDIAN_3, b3);
        gs.syncQuorumFrontier();
        assertEq(gs.getQuorumFrontier(), _sort3(b1, b2, b3), "frontier = quorum-th largest heartbeat");
    }
}
