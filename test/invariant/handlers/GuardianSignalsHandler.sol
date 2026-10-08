// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../../src/GuardianSignals.sol";
import {BlockInfoWithHash, GuardiansOpinion} from "../../../src/types/GuardianSignalsTypes.sol";

/// @notice A handler for the registry alone. It calls each function that changes the state, and it uses two
///         market ids. The account pool includes one guardian address, and a committee member can therefore be
///         the subject of a signal.
/// @dev The shadow model comes from the specification and not from the implementation. The model does not
///      remove a flag when the guardian leaves the committee. The model writes the latch on four edges only.
///      The model keeps the timestamp and the window of the last rebuild.
///
///      This contract extends `Test` because it asserts three properties. Each of these properties compares
///      the state before a call with the state after the call. The actions use small internal functions
///      because the repository compiles with `via_ir = false`.
///
///      Each action tests its own preconditions and returns early. A revert is therefore a defect.
contract GuardianSignalsHandler is Test {
    /// @dev The state of one pair before a call. The handler compares a permissionless call against these
    ///      values.
    struct PairState {
        uint256 strikeCount;
        uint256 suspectCount;
        bool banned;
        address[] reporters;
        uint40[] reportedAt;
    }

    GuardianSignals internal immutable GS;

    /// @dev The candidate committee members. The pool is larger than the initial committee to permit rotation.
    address[6] internal guardianPool =
        [address(0x6001), address(0x6002), address(0x6003), address(0x6004), address(0x6005), address(0x6006)];

    /// @dev The candidate delegates. No address is in the guardian pool, because one address cannot hold both
    ///      roles.
    address[3] internal delegatePool = [address(0x7001), address(0x7002), address(0x7003)];

    /// @dev The subjects of the signals. The third address is a guardian, and a committee member can therefore
    ///      receive a flag.
    address[3] internal accountPool = [address(0x8001), address(0x8002), address(0x6001)];

    /// @dev Two market ids for one registry. The specification permits this, and no other test uses two ids.
    Id[2] internal marketIds = [Id.wrap(bytes32(uint256(0xA11CE))), Id.wrap(bytes32(uint256(0xB0B)))];

    /// @dev This address holds no role and no committee seat. It sends each `prune` call and each frontier
    ///      sync.
    address internal constant ROLELESS = address(0x9001);

    // ── the shadow model. The pair index is marketIndex * accountPool.length + accountIndex ──

    /// @dev The guardian identities that hold a flag on the pair. The model keeps the flag of a departed
    ///      guardian until a prune call or an unban call. The registry must do the same.
    mapping(uint256 pair => mapping(address guardian => bool)) internal modelFlagged;
    /// @dev The latched ban. The model writes it in four conditions:
    ///      - a new flag reaches the quorum;
    ///      - an `unflag` call finds an effective ban;
    ///      - a `prune` call finds an effective ban;
    ///      - a `ban` call occurs.
    ///      Only `unban` clears the latch.
    mapping(uint256 pair => bool) internal modelLatch;
    /// @dev The timestamp of the suspect report for each guardian identity. The value is zero if the model
    ///      holds no report.
    mapping(uint256 pair => mapping(address guardian => uint40)) internal modelReportedAt;
    /// @dev The block timestamp of the last snapshot rebuild for the pair.
    mapping(uint256 pair => uint40) internal modelRebuildAt;
    /// @dev The suspect window at the last snapshot rebuild for the pair.
    mapping(uint256 pair => uint40) internal modelRebuildWindow;
    /// @dev The number of actions on each pair. These counts show a campaign that uses one pair only.
    mapping(uint256 pair => uint256) public pairTouches;
    /// @dev The cached suspect count after the last `suspect` call on the pair. Only a new report can increase
    ///      the count, so no other action can take the count above this value.
    mapping(uint256 pair => uint256) public suspectCeiling;

    /// @dev The largest frontier candidate in each block that the handler observes. The stored frontier can be
    ///      smaller than this value, because the registry does not record a candidate between two syncs. The
    ///      stored frontier must never be larger.
    uint40 public candidateMax;

    // ── the campaign counters. These counts show an empty run ──

    uint256 public flags;
    uint256 public unflags;
    uint256 public suspects;
    uint256 public unsuspects;
    uint256 public prunes;
    uint256 public rotations;
    uint256 public quorumChanges;
    uint256 public windowChanges;
    uint256 public advances;
    /// @dev The number of `prune` calls that met the guard and tested the suspect count.
    uint256 public pruneCountChecks;

    constructor(GuardianSignals gs) {
        GS = gs;
        _observeCandidate();
    }

    // ── the pool and model values that the `invariant_` functions of the suite read ──

    function pairCount() external view returns (uint256) {
        return marketIds.length * accountPool.length;
    }

    function pairMarket(uint256 pair) external view returns (Id) {
        return _market(pair);
    }

    function pairAccount(uint256 pair) external view returns (address) {
        return _account(pair);
    }

    function modelIsFlagged(uint256 pair, address guardian) external view returns (bool) {
        return modelFlagged[pair][guardian];
    }

    function modelLatched(uint256 pair) external view returns (bool) {
        return modelLatch[pair];
    }

    /// @notice The number of flags in the model for the pair. The count includes the full candidate pool.
    function modelStrikes(uint256 pair) external view returns (uint256) {
        return _modelStrikes(pair);
    }

    /// @notice The value that the cached suspect count of the registry must match. It is the number of stored
    ///         reports that were active at the last rebuild of the pair. The suspect window at that time decides
    ///         which reports were active.
    function modelSnapshotCount(uint256 pair) external view returns (uint256 count) {
        uint40 rebuiltAt = modelRebuildAt[pair];
        if (rebuiltAt == 0) return 0;
        uint256 window = modelRebuildWindow[pair];
        (, uint40[] memory reportedAt) = GS.getSuspectedBy(_market(pair), _account(pair));
        for (uint256 i; i < reportedAt.length; ++i) {
            if (uint256(reportedAt[i]) + window >= rebuiltAt) ++count;
        }
    }

    // ── signalling ──

    /// @notice A current guardian sends a flag for an account. It sometimes uses its delegate.
    function doFlag(uint256 guardianSeed, uint256 pairSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;
        uint256 pair = _pair(pairSeed);

        // Only a new identity adds a strike, and only a new flag reaches the latch. The registry removes a
        // repeat flag before the comparison with the quorum. A repeat flag cannot latch a derived ban.
        bool isNewFlag = !modelFlagged[pair][guardian];

        vm.prank(caller);
        GS.flag(_market(pair), guardian, _one(_account(pair)));

        if (isNewFlag) {
            modelFlagged[pair][guardian] = true;
            if (_modelStrikes(pair) >= GS.getQuorum()) modelLatch[pair] = true;
        }

        ++flags;
        ++pairTouches[pair];
        _observeCandidate();
    }

    /// @notice A current guardian removes its flag. The registry must latch an effective ban before the
    ///         removal.
    function doUnflag(uint256 guardianSeed, uint256 pairSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;
        uint256 pair = _pair(pairSeed);

        // The order is important. The registry compares the count with the quorum before the removal.
        if (modelLatch[pair] || _modelStrikes(pair) >= GS.getQuorum()) modelLatch[pair] = true;

        vm.prank(caller);
        GS.unflag(_market(pair), guardian, _one(_account(pair)));

        modelFlagged[pair][guardian] = false;

        ++unflags;
        ++pairTouches[pair];
        _observeCandidate();
    }

    /// @notice A current guardian sends a suspect report. The action then asserts that no expired report
    ///         remains.
    function doSuspect(uint256 guardianSeed, uint256 pairSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;
        uint256 pair = _pair(pairSeed);

        vm.prank(caller);
        GS.suspect(_market(pair), guardian, _one(_account(pair)));

        // Both calls remove the expired reports, then change the named report, then rebuild the snapshot.
        _modelDropExpired(pair);
        modelReportedAt[pair][guardian] = uint40(block.timestamp);
        // The `suspect` call always rebuilds. The model records this block and the current window.
        _recordRebuild(pair);

        ++suspects;
        ++pairTouches[pair];
        // A new report is the one action that can increase the count, so the ceiling moves here only.
        suspectCeiling[pair] = GS.getOpinion(_market(pair), _account(pair)).suspectCount;
        _assertNoLapsedReport(pair, "suspect");
        _observeCandidate();
    }

    /// @notice A current guardian removes its report. The action then asserts the same postcondition.
    function doUnsuspect(uint256 guardianSeed, uint256 pairSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;
        uint256 pair = _pair(pairSeed);

        // The registry rebuilds the snapshot if it removes the named report or if a stored report has
        // expired.
        bool rebuilds = modelReportedAt[pair][guardian] != 0 || _hasLapsedReport(pair);

        vm.prank(caller);
        GS.unsuspect(_market(pair), guardian, _one(_account(pair)));

        _modelDropExpired(pair);
        modelReportedAt[pair][guardian] = 0;
        if (rebuilds) _recordRebuild(pair);

        ++unsuspects;
        ++pairTouches[pair];
        _assertNoLapsedReport(pair, "unsuspect");
        _observeCandidate();
    }

    // ── the permissionless interface ──

    /// @notice A `prune` call from an address with no role and no seat. The action asserts that the call only
    ///         decreases a restriction. It also asserts that the call returns both sets to the committee size.
    function doPrune(uint256 pairSeed) external {
        uint256 pair = _pair(pairSeed);
        bool rebuilds = _hasDepartedReporter(pair);
        PairState memory pre = _snapshot(pair);

        vm.prank(ROLELESS);
        GS.prune(_market(pair), _account(pair));

        _assertPruneOnlyLoosens(pair, pre);
        _assertPruneRestoresBound(pair, pre);

        _modelPrune(pair);
        if (rebuilds) _recordRebuild(pair);

        ++prunes;
        ++pairTouches[pair];
        _observeCandidate();
    }

    /// @notice Any caller can recompute the frontier. The action asserts the exact value of the write.
    function doSyncFrontier() external {
        uint40 before = GS.getQuorumFrontier();
        uint40 candidate = _liveCandidate();

        vm.prank(ROLELESS);
        GS.syncQuorumFrontier();

        assertEq(
            GS.getQuorumFrontier(),
            candidate > before ? candidate : before,
            "sync must set the frontier to max(stored, candidate)"
        );
        _assertEagerAdvance(before);
        _observeCandidate();
    }

    // ── governance overrides ──

    function doBan(uint256 pairSeed) external {
        uint256 pair = _pair(pairSeed);
        GS.ban(_market(pair), _account(pair));
        modelLatch[pair] = true;
        ++pairTouches[pair];
        _observeCandidate();
    }

    function doUnban(uint256 pairSeed) external {
        uint256 pair = _pair(pairSeed);
        GS.unban(_market(pair), _account(pair));
        // The `unban` call clears the latch and each flag. It does not change the suspect reports.
        modelLatch[pair] = false;
        for (uint256 i; i < guardianPool.length; ++i) {
            modelFlagged[pair][guardianPool[i]] = false;
        }
        ++pairTouches[pair];
        _observeCandidate();
    }

    // ── committee and configuration ──

    function doSetQuorum(uint256 quorumSeed) external {
        uint256 count = GS.getGuardianCount();
        if (count == 0) return;
        GS.setQuorum(bound(quorumSeed, 1, count));
        ++quorumChanges;
        _observeCandidate();
    }

    function doSetSuspectWindow(uint256 windowSeed) external {
        GS.setSuspectWindow(bound(windowSeed, 0, GS.MAX_SUSPECT_WINDOW()));
        ++windowChanges;
        _observeCandidate();
    }

    function doAddGuardian(uint256 guardianSeed) external {
        if (GS.getGuardianCount() >= GS.MAX_GUARDIANS_COUNT()) return;
        address candidate = _freeGuardianSeat(guardianSeed);
        if (candidate == address(0)) return;
        GS.addGuardian(candidate);
        ++rotations;
        _observeCandidate();
    }

    function doRemoveGuardian(uint256 guardianSeed) external {
        address guardian = _currentGuardian(guardianSeed);
        if (guardian == address(0)) return;
        if (GS.getGuardianCount() - 1 < GS.getQuorum()) return;
        GS.removeGuardian(guardian);
        ++rotations;
        _observeCandidate();
    }

    function doReplaceGuardian(uint256 oldSeed, uint256 newSeed) external {
        address outgoing = _currentGuardian(oldSeed);
        address incoming = _freeGuardianSeat(newSeed);
        if (outgoing == address(0) || incoming == address(0)) return;
        GS.replaceGuardian(outgoing, incoming);
        ++rotations;
        _observeCandidate();
    }

    function doSetDelegate(uint256 guardianSeed, uint256 delegateSeed, bool clear) external {
        address guardian = _currentGuardian(guardianSeed);
        if (guardian == address(0)) return;

        address delegate;
        if (!clear) {
            delegate = _freeDelegate(delegateSeed);
            if (delegate == address(0)) return;
        }

        vm.prank(guardian);
        GS.setDelegate(delegate);
        _observeCandidate();
    }

    // ── liveness ──

    /// @notice A heartbeat for a recent block. The scan timestamp is in the past, and it is not smaller than
    ///         the stored timestamp of the guardian. The call therefore meets the four conditions.
    function doHeartbeat(uint256 guardianSeed, uint256 timestampSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;

        BlockInfoWithHash memory scanned = _scannedBlock(guardian, timestampSeed);
        if (scanned.hash == bytes32(0)) return;

        uint40 before = GS.getQuorumFrontier();

        vm.prank(caller);
        GS.heartbeat(guardian, scanned, "");

        _assertEagerAdvance(before);
        _observeCandidate();
    }

    /// @notice The action moves the time and the block number together. A suspect window can then expire, and
    ///         `blockhash` still returns a value.
    function doWarp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 10 days));
        vm.roll(block.number + 1 + (secondsSeed % 4));
        _observeCandidate();
    }

    // ── internal assertions. Each one is adjacent to its action ──

    /// @dev A caller with no role and no seat must only decrease a restriction. The specification gives the
    ///      permissionless interface no power to increase a restriction. An increase is a privilege
    ///      escalation.
    ///
    ///      The suspect count needs a guard. The `prune` call does not remove the expired reports before it
    ///      rebuilds, so a larger window makes a stored expired report active again and the rebuild counts it.
    ///      That behaviour is accepted. This check therefore applies when the window did not grow since the
    ///      last rebuild of the pair. Under that condition each stored report is harder to count than before,
    ///      so the count cannot rise.
    function _assertPruneOnlyLoosens(uint256 pair, PairState memory pre) internal {
        GuardiansOpinion memory post = GS.getOpinion(_market(pair), _account(pair));
        assertLe(post.strikeCount, pre.strikeCount, "prune increased the strike count");
        assertFalse(!pre.banned && GS.isBanned(_market(pair), _account(pair)), "prune created a ban");
        if (GS.getSuspectWindow() <= modelRebuildWindow[pair]) {
            ++pruneCountChecks;
            assertLe(post.suspectCount, pre.suspectCount, "prune increased the suspect count");
        }
    }

    /// @dev Each set holds one entry for each current guardian at most. The 32-seat limit alone does not give
    ///      this result after a rotation. The call removes the reports of the departed guardians, and each
    ///      other report keeps its timestamp.
    function _assertPruneRestoresBound(uint256 pair, PairState memory pre) internal view {
        uint256 serving = GS.getGuardianCount();
        (address[] memory reporters, uint40[] memory reportedAt) = GS.getSuspectedBy(_market(pair), _account(pair));
        assertLe(
            GS.getFlaggedBy(_market(pair), _account(pair)).length, serving, "the flag set is larger than the committee"
        );
        assertLe(reporters.length, serving, "the report set is larger than the committee");

        for (uint256 i; i < pre.reporters.length; ++i) {
            uint40 survived = _reportedAtIn(reporters, reportedAt, pre.reporters[i]);
            if (GS.isGuardian(pre.reporters[i])) {
                assertEq(survived, pre.reportedAt[i], "prune changed the timestamp of a remaining report");
            } else {
                assertEq(survived, 0, "prune did not remove the report of a departed guardian");
            }
        }
    }

    /// @dev After these two calls, each stored report is active under the current window. This assertion
    ///      excludes `prune`, because `prune` is the one cleanup path that can leave an expired report. A later
    ///      rebuild can then count that report again.
    function _assertNoLapsedReport(uint256 pair, string memory action) internal view {
        uint256 window = GS.getSuspectWindow();
        (, uint40[] memory reportedAt) = GS.getSuspectedBy(_market(pair), _account(pair));
        for (uint256 i; i < reportedAt.length; ++i) {
            assertGe(
                uint256(reportedAt[i]) + window,
                block.timestamp,
                string.concat(action, " left an expired report in storage")
            );
        }
    }

    /// @dev The registry advances the frontier in `heartbeat` or in an explicit sync. Both paths must give the
    ///      same value. A quorum of current guardians must support that value in this block.
    function _assertEagerAdvance(uint40 before) internal {
        uint40 post = GS.getQuorumFrontier();
        if (post <= before) return;
        ++advances;
        assertEq(post, _liveCandidate(), "advance != the heartbeat at the quorum position");
        assertGe(_attestingCount(post), GS.getQuorum(), "frontier advanced without a quorum of heartbeats");
    }

    // ── the internal model updates ──

    function _snapshot(uint256 pair) internal view returns (PairState memory state) {
        GuardiansOpinion memory opinion = GS.getOpinion(_market(pair), _account(pair));
        state.strikeCount = opinion.strikeCount;
        state.suspectCount = opinion.suspectCount;
        state.banned = GS.isBanned(_market(pair), _account(pair));
        (state.reporters, state.reportedAt) = GS.getSuspectedBy(_market(pair), _account(pair));
    }

    /// @dev The model removes the flags and the reports of the departed identities. It does not remove the
    ///      expired reports, because the `prune` call does not remove them either. The model then compares the
    ///      remaining flags with the quorum. A derived ban that only departed flags support ends. It does not
    ///      latch.
    function _modelPrune(uint256 pair) internal {
        for (uint256 i; i < guardianPool.length; ++i) {
            address guardian = guardianPool[i];
            if (GS.isGuardian(guardian)) continue;
            modelFlagged[pair][guardian] = false;
            modelReportedAt[pair][guardian] = 0;
        }
        if (_modelStrikes(pair) >= GS.getQuorum()) modelLatch[pair] = true;
    }

    /// @dev The model removes the reports that expired under the current window. The `suspect` call and the
    ///      `unsuspect` call do this before they change the named report. The `prune` call does not, and this
    ///      difference permits the privilege escalation.
    function _modelDropExpired(uint256 pair) internal {
        uint256 window = GS.getSuspectWindow();
        for (uint256 i; i < guardianPool.length; ++i) {
            uint40 reportedAt = modelReportedAt[pair][guardianPool[i]];
            if (reportedAt != 0 && uint256(reportedAt) + window < block.timestamp) {
                modelReportedAt[pair][guardianPool[i]] = 0;
            }
        }
    }

    function _modelStrikes(uint256 pair) internal view returns (uint256 count) {
        for (uint256 i; i < guardianPool.length; ++i) {
            if (modelFlagged[pair][guardianPool[i]]) ++count;
        }
    }

    function _recordRebuild(uint256 pair) internal {
        modelRebuildAt[pair] = uint40(block.timestamp);
        modelRebuildWindow[pair] = uint40(GS.getSuspectWindow());
    }

    // ── the internal state queries ──

    function _hasLapsedReport(uint256 pair) internal view returns (bool) {
        uint256 window = GS.getSuspectWindow();
        (, uint40[] memory reportedAt) = GS.getSuspectedBy(_market(pair), _account(pair));
        for (uint256 i; i < reportedAt.length; ++i) {
            if (uint256(reportedAt[i]) + window < block.timestamp) return true;
        }
        return false;
    }

    function _hasDepartedReporter(uint256 pair) internal view returns (bool) {
        (address[] memory reporters,) = GS.getSuspectedBy(_market(pair), _account(pair));
        for (uint256 i; i < reporters.length; ++i) {
            if (!GS.isGuardian(reporters[i])) return true;
        }
        return false;
    }

    /// @dev The stored timestamp for `guardian` in a `getSuspectedBy` result. The value is zero if the guardian
    ///      holds no report.
    function _reportedAtIn(address[] memory reporters, uint40[] memory reportedAt, address guardian)
        internal
        pure
        returns (uint40)
    {
        for (uint256 i; i < reporters.length; ++i) {
            if (reporters[i] == guardian) return reportedAt[i];
        }
        return 0;
    }

    /// @dev The heartbeat at the quorum position, from the largest value down, across the current committee.
    ///      The value is zero if the committee is smaller than the quorum. This function uses the formula of
    ///      the specification and not the routine of the registry.
    function _liveCandidate() internal view returns (uint40) {
        (, uint40[] memory timestamps) = GS.getHeartbeats();
        uint256 quorum = GS.getQuorum();
        uint256 n = timestamps.length;
        if (quorum == 0 || n < quorum) return 0;

        for (uint256 i = 1; i < n; ++i) {
            uint40 key = timestamps[i];
            uint256 j = i;
            while (j > 0 && timestamps[j - 1] > key) {
                timestamps[j] = timestamps[j - 1];
                --j;
            }
            timestamps[j] = key;
        }
        return timestamps[n - quorum];
    }

    /// @dev The number of current guardians with a heartbeat at `timestamp` or later, in the current block.
    ///      The evidence for an advance must come from one committee in one block. This count therefore
    ///      includes the current members only.
    function _attestingCount(uint40 timestamp) internal view returns (uint256 count) {
        (, uint40[] memory timestamps) = GS.getHeartbeats();
        for (uint256 i; i < timestamps.length; ++i) {
            if (timestamps[i] >= timestamp) ++count;
        }
    }

    function _observeCandidate() internal {
        uint40 candidate = _liveCandidate();
        if (candidate > candidateMax) candidateMax = candidate;
    }

    // ── the internal selection functions. Each one limits its own result ──

    /// @dev A recent block with a scan timestamp that the registry accepts. The timestamp is not in the future,
    ///      and it is not smaller than the stored heartbeat of the guardian. A hash of zero shows that the
    ///      block is outside the lookback window, and the caller then does nothing.
    function _scannedBlock(address guardian, uint256 seed) internal view returns (BlockInfoWithHash memory scanned) {
        if (block.number < 2) return scanned;
        uint256 number = block.number - 1 - (seed % 8);
        if (number == 0 || number >= block.number) return scanned;

        uint40 stored = GS.getHeartbeat(guardian);
        if (stored > block.timestamp) return scanned;

        scanned.hash = blockhash(number);
        scanned.number = uint40(number);
        scanned.timestamp = uint40(bound(seed, stored, block.timestamp));
    }

    /// @dev A current committee member and the address that acts for it. The function returns the zero address
    ///      if the committee is empty. The action then does nothing and does not revert.
    function _actingGuardian(uint256 seed, bool viaDelegate) internal view returns (address guardian, address caller) {
        guardian = _currentGuardian(seed);
        if (guardian == address(0)) return (address(0), address(0));
        caller = guardian;
        if (viaDelegate) {
            address delegate = GS.getDelegate(guardian);
            if (delegate != address(0)) caller = delegate;
        }
    }

    function _currentGuardian(uint256 seed) internal view returns (address) {
        uint256 start = seed % guardianPool.length;
        for (uint256 i; i < guardianPool.length; ++i) {
            address candidate = guardianPool[(start + i) % guardianPool.length];
            if (GS.isGuardian(candidate)) return candidate;
        }
        return address(0);
    }

    /// @dev A pool address for a new seat. The address is not a guardian and is not a delegate.
    function _freeGuardianSeat(uint256 seed) internal view returns (address) {
        uint256 start = seed % guardianPool.length;
        for (uint256 i; i < guardianPool.length; ++i) {
            address candidate = guardianPool[(start + i) % guardianPool.length];
            if (!GS.isGuardian(candidate) && !_isDelegate(candidate)) return candidate;
        }
        return address(0);
    }

    /// @dev A pool address for a new delegate. The address is not a guardian and is not the delegate of
    ///      another guardian.
    function _freeDelegate(uint256 seed) internal view returns (address) {
        uint256 start = seed % delegatePool.length;
        for (uint256 i; i < delegatePool.length; ++i) {
            address candidate = delegatePool[(start + i) % delegatePool.length];
            if (!GS.isGuardian(candidate) && !_isDelegate(candidate)) return candidate;
        }
        return address(0);
    }

    function _isDelegate(address account) internal view returns (bool) {
        (address[] memory guardians, address[] memory delegates) = GS.getGuardians();
        for (uint256 i; i < guardians.length; ++i) {
            if (delegates[i] == account) return true;
        }
        return false;
    }

    function _pair(uint256 seed) internal view returns (uint256) {
        return seed % (marketIds.length * accountPool.length);
    }

    function _market(uint256 pair) internal view returns (Id) {
        return marketIds[pair / accountPool.length];
    }

    function _account(uint256 pair) internal view returns (address) {
        return accountPool[pair % accountPool.length];
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
