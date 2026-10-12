// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../../src/interfaces/IGuardianSignals.sol";
import {BlockInfoWithHash, GuardiansOpinion} from "../../../src/types/GuardianSignalsTypes.sol";

/// @notice A handler for the registry alone. It calls each function that changes the state, and it uses two
///         market ids. The account pool includes one guardian address, and a committee member can therefore be
///         the subject of a signal.
/// @dev The shadow model comes from the specification and not from the implementation. The model does not
///      remove a flag when the guardian leaves the committee. The model writes the latch on four edges only.
///      The model rebuilds its own suspect snapshot, and it keeps its own heartbeats and frontier. It reads
///      only the membership, the quorum and the window from the registry, because the handler sets them.
///
///      This contract extends `Test` because some actions assert the result of their own call. The actions use
///      small internal functions because the repository compiles with `via_ir = false`.
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

    /// @dev The size of the address pool. It is larger than the 32-seat limit, so the committee can fill each
    ///      seat and still leave addresses for delegates and rotation.
    uint256 internal constant POOL_SIZE = 40;

    /// @dev The candidate guardians and delegates. One pool serves both roles. The registry does not let one
    ///      address hold both roles at the same time, but an address can move from one role to the other during
    ///      a run. The pool starts with the initial committee of the suite.
    address[POOL_SIZE] internal pool;

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
    mapping(uint256 pair => mapping(address guardian => uint40)) public modelReportedAt;
    /// @dev The suspect snapshot of the last rebuild: the number of reports that were active, and the latest
    ///      timestamp among them. The model computes both values from `modelReportedAt`.
    mapping(uint256 pair => uint256) public modelSuspectCount;
    mapping(uint256 pair => uint40) public modelSuspectReportedAt;
    /// @dev The suspect window at the last snapshot rebuild for the pair.
    mapping(uint256 pair => uint40) internal modelRebuildWindow;
    /// @dev The stored heartbeat of each guardian identity. A removal or a replacement clears it.
    mapping(address guardian => uint40) public modelHeartbeat;
    /// @dev The stored frontier. Only a heartbeat that crosses it and a sync can raise it, and no action lowers
    ///      it.
    uint40 public modelFrontier;
    /// @dev The last delegate that each guardian identity lost by a change of delegate, a removal or a
    ///      replacement. The stale-authority action uses this address.
    mapping(address guardian => address) internal formerDelegate;
    /// @dev The guardian identities that lost a delegate at least once. The stale-authority action picks from
    ///      this list, because few pool addresses have a former delegate.
    address[] internal formerDelegateOwners;
    /// @dev The number of actions on each pair. These counts show a campaign that uses one pair only.
    mapping(uint256 pair => uint256) public pairTouches;

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
    /// @dev The number of replacements that give the seat to the delegate of the outgoing guardian.
    uint256 public delegatePromotions;
    /// @dev The largest committee of the run, and the number of `addGuardian` calls that the full committee
    ///      rejected.
    uint256 public maxCommitteeSize;
    uint256 public capRejections;
    /// @dev The number of rejected calls from each kind of stale actor.
    uint256 public staleGuardianCalls;
    uint256 public staleDelegateCalls;
    uint256 public reassignedDelegateCalls;

    constructor(GuardianSignals gs) {
        GS = gs;
        for (uint256 i; i < POOL_SIZE; ++i) {
            pool[i] = address(uint160(0x6001 + i));
        }
        maxCommitteeSize = gs.getGuardianCount();
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

    /// @notice The number of flags in the model for the pair. The count includes the full address pool.
    function modelStrikes(uint256 pair) external view returns (uint256) {
        return _modelStrikes(pair);
    }

    /// @notice The number of stored reports in the model for the pair, active or expired.
    function modelReportCount(uint256 pair) external view returns (uint256 count) {
        for (uint256 i; i < POOL_SIZE; ++i) {
            if (modelReportedAt[pair][pool[i]] != 0) ++count;
        }
    }

    // ── signalling. Each action sends a batch of one to three accounts in one market ──

    /// @notice A current guardian sends flags. It sometimes uses its delegate.
    function doFlag(uint256 guardianSeed, uint256 marketSeed, uint256 batchSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;
        (Id market, address[] memory accounts, uint256[] memory pairs) = _batch(marketSeed, batchSeed);

        vm.prank(caller);
        GS.flag(market, guardian, accounts);

        // The registry applies the batch in order, and the model does the same. A repeated account is a
        // repeat flag.
        for (uint256 i; i < pairs.length; ++i) {
            _modelFlag(pairs[i], guardian);
        }
        ++flags;
    }

    /// @notice A current guardian removes its flags. The registry must latch an effective ban before each
    ///         removal.
    function doUnflag(uint256 guardianSeed, uint256 marketSeed, uint256 batchSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;
        (Id market, address[] memory accounts, uint256[] memory pairs) = _batch(marketSeed, batchSeed);

        vm.prank(caller);
        GS.unflag(market, guardian, accounts);

        for (uint256 i; i < pairs.length; ++i) {
            _modelUnflag(pairs[i], guardian);
        }
        ++unflags;
    }

    /// @notice A current guardian sends suspect reports. The action then asserts that no expired report
    ///         remains.
    function doSuspect(uint256 guardianSeed, uint256 marketSeed, uint256 batchSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;
        (Id market, address[] memory accounts, uint256[] memory pairs) = _batch(marketSeed, batchSeed);

        vm.prank(caller);
        GS.suspect(market, guardian, accounts);

        for (uint256 i; i < pairs.length; ++i) {
            _modelSuspect(pairs[i], guardian);
            _assertNoLapsedReport(pairs[i], "suspect");
        }
        ++suspects;
    }

    /// @notice A current guardian removes its reports. The action then asserts the same postcondition.
    function doUnsuspect(uint256 guardianSeed, uint256 marketSeed, uint256 batchSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;
        (Id market, address[] memory accounts, uint256[] memory pairs) = _batch(marketSeed, batchSeed);

        vm.prank(caller);
        GS.unsuspect(market, guardian, accounts);

        for (uint256 i; i < pairs.length; ++i) {
            _modelUnsuspect(pairs[i], guardian);
            _assertNoLapsedReport(pairs[i], "unsuspect");
        }
        ++unsuspects;
    }

    /// @notice An address without authority acts for a guardian identity, and the call must revert with
    ///         `Unauthorized`. Without `viaFormerDelegate`, the address acts for itself and is not a guardian:
    ///         a removed guardian or an address that never had a seat. With `viaFormerDelegate`, the address is
    ///         the former delegate of the identity. That address can now be the delegate of another guardian,
    ///         or a guardian itself.
    function doStaleSignal(uint256 identitySeed, uint256 kindSeed, bool viaFormerDelegate) external {
        address onBehalf;
        address caller;
        if (viaFormerDelegate) {
            if (formerDelegateOwners.length == 0) return;
            onBehalf = formerDelegateOwners[identitySeed % formerDelegateOwners.length];
            caller = formerDelegate[onBehalf];
        } else {
            onBehalf = pool[identitySeed % POOL_SIZE];
            caller = onBehalf;
        }
        // The registry accepts the guardian itself and its current delegate only.
        if (GS.isGuardian(onBehalf) && (caller == onBehalf || caller == GS.getDelegate(onBehalf))) return;
        bool reassigned = _isDelegate(caller);
        address[] memory accounts = _one(accountPool[0]);

        vm.expectRevert(IGuardianSignals.Unauthorized.selector);
        vm.prank(caller);
        _signal(kindSeed % 5, onBehalf, accounts);

        if (!viaFormerDelegate) ++staleGuardianCalls;
        else if (reassigned) ++reassignedDelegateCalls;
        else ++staleDelegateCalls;
    }

    // ── the permissionless interface ──

    /// @notice A `prune` call from an address with no role and no seat. The action asserts that the call only
    ///         decreases a restriction. It also asserts that the call returns both sets to the committee size.
    function doPrune(uint256 pairSeed) external {
        uint256 pair = _pair(pairSeed);
        bool rebuilds = _modelHasDepartedReporter(pair);
        PairState memory pre = _snapshot(pair);

        vm.prank(ROLELESS);
        GS.prune(_market(pair), _account(pair));

        _assertPruneOnlyLoosens(pair, pre);
        _assertPruneRestoresBound(pair, pre);

        _modelPrune(pair);
        if (rebuilds) _modelRebuild(pair);

        ++prunes;
        ++pairTouches[pair];
    }

    /// @notice Any caller can recompute the frontier. The model sets the frontier to `max(F, candidate)`.
    function doSyncFrontier() external {
        vm.prank(ROLELESS);
        GS.syncQuorumFrontier();
        _modelSync();
    }

    // ── governance overrides ──

    function doBan(uint256 pairSeed) external {
        uint256 pair = _pair(pairSeed);
        GS.ban(_market(pair), _account(pair));
        modelLatch[pair] = true;
        ++pairTouches[pair];
    }

    function doUnban(uint256 pairSeed) external {
        uint256 pair = _pair(pairSeed);
        GS.unban(_market(pair), _account(pair));
        // The `unban` call clears the latch and each flag. It does not change the suspect reports.
        modelLatch[pair] = false;
        for (uint256 i; i < POOL_SIZE; ++i) {
            modelFlagged[pair][pool[i]] = false;
        }
        ++pairTouches[pair];
    }

    // ── committee and configuration ──

    function doSetQuorum(uint256 quorumSeed) external {
        uint256 count = GS.getGuardianCount();
        if (count == 0) return;
        GS.setQuorum(bound(quorumSeed, 1, count));
        ++quorumChanges;
    }

    function doSetSuspectWindow(uint256 windowSeed) external {
        GS.setSuspectWindow(bound(windowSeed, 0, GS.MAX_SUSPECT_WINDOW()));
        ++windowChanges;
    }

    /// @notice A new seat. When each seat is full, the call must revert with `MaxGuardiansReached`.
    function doAddGuardian(uint256 guardianSeed) external {
        address candidate = _freeAddress(guardianSeed);
        if (candidate == address(0)) return;
        if (GS.getGuardianCount() == GS.MAX_GUARDIANS_COUNT()) {
            vm.expectRevert(IGuardianSignals.MaxGuardiansReached.selector);
            GS.addGuardian(candidate);
            ++capRejections;
            return;
        }
        _addGuardian(candidate);
    }

    function doRemoveGuardian(uint256 guardianSeed) external {
        address guardian = _currentGuardian(guardianSeed);
        if (guardian == address(0)) return;
        if (GS.getGuardianCount() - 1 < GS.getQuorum()) return;
        _removeGuardian(guardian);
    }

    /// @notice A replacement. With `toDelegate`, the delegate of the outgoing guardian gets the seat. The
    ///         specification permits this, because the removal clears the pairing before the registry adds
    ///         the new seat.
    function doReplaceGuardian(uint256 oldSeed, uint256 newSeed, bool toDelegate) external {
        address outgoing = toDelegate ? _delegatedGuardian(oldSeed) : _currentGuardian(oldSeed);
        if (outgoing == address(0)) return;
        address delegate = GS.getDelegate(outgoing);
        address incoming = toDelegate ? delegate : _freeAddress(newSeed);
        if (incoming == address(0)) return;

        GS.replaceGuardian(outgoing, incoming);
        _modelRemoval(outgoing, delegate);

        if (toDelegate) ++delegatePromotions;
        ++rotations;
    }

    /// @notice The action moves the committee to a size between the quorum and the 32-seat limit in one call.
    ///         Single additions and removals cancel out over a run, so without this action the committee stays
    ///         near its initial size. With `fill`, the target is the limit, so a run often fills each seat.
    function doResizeCommittee(uint256 sizeSeed, bool fill) external {
        uint256 target = fill ? GS.MAX_GUARDIANS_COUNT() : bound(sizeSeed, GS.getQuorum(), GS.MAX_GUARDIANS_COUNT());
        while (GS.getGuardianCount() < target) {
            address candidate = _freeAddress(sizeSeed);
            // Delegates can hold each remaining pool address. The committee then stays below the target.
            if (candidate == address(0)) break;
            _addGuardian(candidate);
        }
        while (GS.getGuardianCount() > target) _removeGuardian(_currentGuardian(sizeSeed));
    }

    function doSetDelegate(uint256 guardianSeed, uint256 delegateSeed, bool clear) external {
        address guardian = _currentGuardian(guardianSeed);
        if (guardian == address(0)) return;

        address delegate;
        if (!clear) {
            delegate = _freeAddress(delegateSeed);
            if (delegate == address(0)) return;
        }
        address previous = GS.getDelegate(guardian);

        vm.prank(guardian);
        GS.setDelegate(delegate);

        if (previous != address(0)) _recordFormerDelegate(guardian, previous);
    }

    // ── liveness ──

    /// @notice A heartbeat for a recent block. The scan timestamp is in the past, and it is not smaller than
    ///         the stored timestamp of the guardian. The call therefore meets the four conditions.
    function doHeartbeat(uint256 guardianSeed, uint256 timestampSeed, bool viaDelegate) external {
        (address guardian, address caller) = _actingGuardian(guardianSeed, viaDelegate);
        if (guardian == address(0)) return;

        BlockInfoWithHash memory scanned = _scannedBlock(guardian, timestampSeed);
        if (scanned.hash == bytes32(0)) return;
        uint40 previous = modelHeartbeat[guardian];

        vm.prank(caller);
        GS.heartbeat(guardian, scanned, "");

        modelHeartbeat[guardian] = scanned.timestamp;
        // The specification recomputes the candidate only when this guardian crosses the stored frontier.
        if (previous <= modelFrontier && scanned.timestamp > modelFrontier) _modelSync();
    }

    /// @notice The action moves the time and the block number together. A suspect window can then expire, and
    ///         `blockhash` still returns a value.
    function doWarp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1, 10 days));
        vm.roll(block.number + 1 + (secondsSeed % 4));
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

    // ── the internal model updates ──

    function _snapshot(uint256 pair) internal view returns (PairState memory state) {
        GuardiansOpinion memory opinion = GS.getOpinion(_market(pair), _account(pair));
        state.strikeCount = opinion.strikeCount;
        state.suspectCount = opinion.suspectCount;
        state.banned = GS.isBanned(_market(pair), _account(pair));
        (state.reporters, state.reportedAt) = GS.getSuspectedBy(_market(pair), _account(pair));
    }

    /// @dev Only a new identity adds a strike, and only a new flag reaches the latch. The registry removes a
    ///      repeat flag before the comparison with the quorum. A repeat flag cannot latch a derived ban.
    function _modelFlag(uint256 pair, address guardian) internal {
        ++pairTouches[pair];
        if (modelFlagged[pair][guardian]) return;
        modelFlagged[pair][guardian] = true;
        if (_modelStrikes(pair) >= GS.getQuorum()) modelLatch[pair] = true;
    }

    /// @dev The order is important. The registry compares the count with the quorum before the removal.
    function _modelUnflag(uint256 pair, address guardian) internal {
        ++pairTouches[pair];
        if (_modelStrikes(pair) >= GS.getQuorum()) modelLatch[pair] = true;
        modelFlagged[pair][guardian] = false;
    }

    /// @dev The `suspect` call removes the expired reports, then writes the named report, then always
    ///      rebuilds the snapshot.
    function _modelSuspect(uint256 pair, address guardian) internal {
        ++pairTouches[pair];
        _modelDropExpired(pair);
        modelReportedAt[pair][guardian] = uint40(block.timestamp);
        _modelRebuild(pair);
    }

    /// @dev The `unsuspect` call rebuilds the snapshot if it removes the named report or an expired report.
    function _modelUnsuspect(uint256 pair, address guardian) internal {
        ++pairTouches[pair];
        bool rebuilds = modelReportedAt[pair][guardian] != 0 || _modelHasLapsedReport(pair);
        _modelDropExpired(pair);
        modelReportedAt[pair][guardian] = 0;
        if (rebuilds) _modelRebuild(pair);
    }

    /// @dev The model removes the flags and the reports of the departed identities. It does not remove the
    ///      expired reports, because the `prune` call does not remove them either. The model then compares the
    ///      remaining flags with the quorum. A derived ban that only departed flags support ends. It does not
    ///      latch.
    function _modelPrune(uint256 pair) internal {
        for (uint256 i; i < POOL_SIZE; ++i) {
            address guardian = pool[i];
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
        for (uint256 i; i < POOL_SIZE; ++i) {
            uint40 reportedAt = modelReportedAt[pair][pool[i]];
            if (reportedAt != 0 && uint256(reportedAt) + window < block.timestamp) {
                modelReportedAt[pair][pool[i]] = 0;
            }
        }
    }

    /// @dev The snapshot counts each report that is active under the current window, and it keeps the latest
    ///      timestamp among them. A report is active when `reportedAt + window >= block.timestamp`.
    function _modelRebuild(uint256 pair) internal {
        uint256 window = GS.getSuspectWindow();
        uint256 count;
        uint40 latest;
        for (uint256 i; i < POOL_SIZE; ++i) {
            uint40 reportedAt = modelReportedAt[pair][pool[i]];
            if (reportedAt != 0 && uint256(reportedAt) + window >= block.timestamp) {
                ++count;
                if (reportedAt > latest) latest = reportedAt;
            }
        }
        modelSuspectCount[pair] = count;
        modelSuspectReportedAt[pair] = latest;
        modelRebuildWindow[pair] = uint40(window);
    }

    /// @dev The specification sets the stored frontier to `max(F, candidate)`.
    function _modelSync() internal {
        uint40 candidate = _liveCandidate();
        if (candidate <= modelFrontier) return;
        modelFrontier = candidate;
        ++advances;
    }

    /// @dev A removal or a replacement clears the stored heartbeat and the delegate of the identity. It does
    ///      not change the frontier.
    function _modelRemoval(address guardian, address delegate) internal {
        modelHeartbeat[guardian] = 0;
        if (delegate != address(0)) _recordFormerDelegate(guardian, delegate);
    }

    function _recordFormerDelegate(address guardian, address delegate) internal {
        if (formerDelegate[guardian] == address(0)) formerDelegateOwners.push(guardian);
        formerDelegate[guardian] = delegate;
    }

    function _modelStrikes(uint256 pair) internal view returns (uint256 count) {
        for (uint256 i; i < POOL_SIZE; ++i) {
            if (modelFlagged[pair][pool[i]]) ++count;
        }
    }

    // ── the internal committee updates ──

    function _addGuardian(address guardian) internal {
        GS.addGuardian(guardian);
        uint256 count = GS.getGuardianCount();
        if (count > maxCommitteeSize) maxCommitteeSize = count;
        ++rotations;
    }

    function _removeGuardian(address guardian) internal {
        address delegate = GS.getDelegate(guardian);
        GS.removeGuardian(guardian);
        _modelRemoval(guardian, delegate);
        ++rotations;
    }

    /// @dev One call that checks the authority of the caller first. The heartbeat has an empty block proof,
    ///      because the registry checks the caller before the proof.
    function _signal(uint256 kind, address onBehalf, address[] memory accounts) internal {
        Id market = marketIds[0];
        if (kind == 0) GS.flag(market, onBehalf, accounts);
        else if (kind == 1) GS.unflag(market, onBehalf, accounts);
        else if (kind == 2) GS.suspect(market, onBehalf, accounts);
        else if (kind == 3) GS.unsuspect(market, onBehalf, accounts);
        else GS.heartbeat(onBehalf, BlockInfoWithHash({hash: bytes32(0), number: 0, timestamp: 0}), "");
    }

    // ── the internal state queries ──

    function _modelHasLapsedReport(uint256 pair) internal view returns (bool) {
        uint256 window = GS.getSuspectWindow();
        for (uint256 i; i < POOL_SIZE; ++i) {
            uint40 reportedAt = modelReportedAt[pair][pool[i]];
            if (reportedAt != 0 && uint256(reportedAt) + window < block.timestamp) return true;
        }
        return false;
    }

    function _modelHasDepartedReporter(uint256 pair) internal view returns (bool) {
        for (uint256 i; i < POOL_SIZE; ++i) {
            if (modelReportedAt[pair][pool[i]] != 0 && !GS.isGuardian(pool[i])) return true;
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
    ///      the specification and the model heartbeats, and not the routine or the storage of the registry.
    function _liveCandidate() internal view returns (uint40) {
        (address[] memory guardians,) = GS.getGuardians();
        uint256 quorum = GS.getQuorum();
        uint256 n = guardians.length;
        if (quorum == 0 || n < quorum) return 0;

        uint40[] memory timestamps = new uint40[](n);
        for (uint256 i; i < n; ++i) {
            timestamps[i] = modelHeartbeat[guardians[i]];
        }
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

    // ── the internal selection functions. Each one limits its own result ──

    /// @dev A recent block with a scan timestamp that the registry accepts. The timestamp is not in the future,
    ///      and it is not smaller than the stored heartbeat of the guardian. A hash of zero shows that the
    ///      block is outside the lookback window, and the caller then does nothing.
    function _scannedBlock(address guardian, uint256 seed) internal view returns (BlockInfoWithHash memory scanned) {
        if (block.number < 2) return scanned;
        uint256 number = block.number - 1 - (seed % 8);
        if (number == 0 || number >= block.number) return scanned;

        uint40 stored = modelHeartbeat[guardian];
        if (stored > block.timestamp) return scanned;

        scanned.hash = blockhash(number);
        scanned.number = uint40(number);
        scanned.timestamp = uint40(bound(seed, stored, block.timestamp));
    }

    /// @dev One to three accounts of one market, with repeats, and the pair index of each account in call
    ///      order. Each byte of `batchSeed` above the lowest byte selects one account.
    function _batch(uint256 marketSeed, uint256 batchSeed)
        internal
        view
        returns (Id market, address[] memory accounts, uint256[] memory pairs)
    {
        uint256 marketIndex = marketSeed % marketIds.length;
        market = marketIds[marketIndex];
        uint256 size = 1 + batchSeed % 3;
        accounts = new address[](size);
        pairs = new uint256[](size);
        for (uint256 i; i < size; ++i) {
            uint256 accountIndex = (batchSeed >> (8 * (i + 1))) % accountPool.length;
            accounts[i] = accountPool[accountIndex];
            pairs[i] = marketIndex * accountPool.length + accountIndex;
        }
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
        uint256 start = seed % POOL_SIZE;
        for (uint256 i; i < POOL_SIZE; ++i) {
            address candidate = pool[(start + i) % POOL_SIZE];
            if (GS.isGuardian(candidate)) return candidate;
        }
        return address(0);
    }

    /// @dev A current guardian with a delegate. The value is the zero address if no guardian has a delegate.
    function _delegatedGuardian(uint256 seed) internal view returns (address) {
        (address[] memory guardians, address[] memory delegates) = GS.getGuardians();
        uint256 start = seed % guardians.length;
        for (uint256 i; i < guardians.length; ++i) {
            uint256 index = (start + i) % guardians.length;
            if (delegates[index] != address(0)) return guardians[index];
        }
        return address(0);
    }

    /// @dev A pool address for a new seat or a new delegate. The address is not a guardian and is not the
    ///      delegate of a guardian.
    function _freeAddress(uint256 seed) internal view returns (address) {
        uint256 start = seed % POOL_SIZE;
        for (uint256 i; i < POOL_SIZE; ++i) {
            address candidate = pool[(start + i) % POOL_SIZE];
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
