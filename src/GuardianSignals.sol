// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IGuardianSignals} from "./interfaces/IGuardianSignals.sol";
import {IGuardianSignalsView} from "./interfaces/IGuardianSignalsView.sol";
import {BlockInfoWithHash, GuardiansOpinion, GuardiansSignal} from "./types/GuardianSignalsTypes.sol";

/// @title GuardianSignals
/// @author Lido
/// @notice One guardian committee serving many markets. Guardians flag accounts they suspect; once a quorum of
///         flags is reached, a ban latches for the market it was raised in. A suspect report only raises a
///         borrower's collateral-activation delay; it never bans. Guardians also submit heartbeats reporting
///         how far they have reviewed chain activity, and the registry keeps the timestamp a quorum has
///         reviewed past (the quorum frontier). The market controller reads `getOpinion(marketId, account)` to
///         scale the delay and hard-block borrowing, and holds fresh collateral inactive past its unlock time
///         until the frontier covers that time or the market's guardian-quorum fallback delay elapses.
/// @dev A guardian is a single committee address. It may appoint one delegate: a hot key allowed to act in its
///      place. Signalling and liveness calls name the guardian they act for (`onBehalf`) and accept that
///      guardian or its current delegate. All signals and heartbeats are stored under the guardian, so
///      replacing the delegate keeps the guardian's standing.
///      Governance (`MANAGER_ROLE`) adds and removes guardians and sets the quorum and suspect window.
///      Upgradeable behind a proxy (`initialize`, not a constructor); ERC-7201 namespaced storage. Events and
///      errors live in {IGuardianSignals}.
contract GuardianSignals layout at erc7201("lido.lend.storage.GuardianSignals")
    is
    AccessControlEnumerableUpgradeable,
    IGuardianSignals
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;

    // ---
    // CONSTANTS
    // ---

    /// @notice Maximum number of guardians. Kept low because `syncQuorumFrontier` re-sorts every guardian's
    ///         last-scanned timestamp to recompute the frontier, and that cost grows with the set. 32 keeps it
    ///         bounded and still fits the quorum in a `uint8`.
    uint256 public constant override MAX_GUARDIANS_COUNT = 32;

    /// @notice Ceiling on the suspect window: the horizon within which a suspect report still counts toward the
    ///         activation delay. Reports older than the window are ignored.
    uint256 public constant override MAX_SUSPECT_WINDOW = 30 days;

    // ---
    // ROLES
    // ---

    /// @dev `ban` (fast, risk-reducing).
    bytes32 public constant ACCESS_LIMITER_ROLE = keccak256("ACCESS_LIMITER_ROLE");
    /// @dev `unban` (slow, risk-increasing).
    bytes32 public constant ACCESS_RESTORER_ROLE = keccak256("ACCESS_RESTORER_ROLE");
    /// @dev Manages the guardian set, quorum, and suspect window.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // ---
    // STORAGE
    // ---

    uint8 private _quorum;
    /// @dev Freshness horizon for a suspect snapshot: `suspectReportedAt + suspectWindow` is when it lapses.
    uint40 private _suspectWindow;
    /// @dev Quorum-scan frontier: the highest timestamp a quorum of guardians have ever scanned past. Monotonic.
    uint40 private _quorumFrontierTimestamp;
    /// @dev The committee guardians.
    EnumerableSet.AddressSet private _guardians;
    /// @dev Guardian-appointed delegates. A zero address means the guardian has no delegate.
    mapping(address guardian => address delegate) private _delegates;
    /// @dev Each guardian's last-scanned block timestamp (a Unix timestamp, not a block number).
    mapping(address guardian => uint40 timestamp) private _heartbeats;
    /// @dev Per (market, account) signal. `flaggedBy`/`suspectedBy` hold guardian addresses: a delegate's
    ///      signal is recorded under its guardian, not the raw caller.
    mapping(Id marketId => mapping(address account => GuardiansSignal signal)) private _signals;

    // ---
    // INITIALIZATION
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Set the admin and seed the guardian set and quorum. The suspect window is set afterwards via
    ///         `setSuspectWindow`; guardians appoint their delegates separately via `setDelegate`.
    /// @param admin Holder of `DEFAULT_ADMIN_ROLE`, the default admin of the guardian and override roles.
    /// @param guardians The initial guardian set. Each must be non-zero, unique, and within `MAX_GUARDIANS_COUNT`.
    /// @param quorum The initial quorum. Must satisfy `1 <= quorum <= guardians.length`.
    function initialize(address admin, address[] calldata guardians, uint256 quorum) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        for (uint256 i; i < guardians.length; ++i) {
            _addGuardian(guardians[i]);
        }
        _setQuorum(quorum);
        emit QuorumSet(quorum);
    }

    // ---
    // GUARDIANS & CONFIG
    // ---

    /// @inheritdoc IGuardianSignals
    function addGuardian(address guardian) external onlyRole(MANAGER_ROLE) {
        _addGuardian(guardian);
    }

    /// @inheritdoc IGuardianSignals
    function replaceGuardian(address oldGuardian, address newGuardian) external onlyRole(MANAGER_ROLE) {
        if (newGuardian == address(0)) revert ZeroAddress();
        if (_guardians.contains(newGuardian)) revert AlreadyGuardian();
        _removeGuardian(oldGuardian);
        _addGuardian(newGuardian);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Reverts if removal would drop the set below `quorum`. Clears the guardian's delegate and heartbeat, so
    ///      re-adding it starts fresh. Its existing signals remain stored and counted until a permissionless
    ///      `prune`.
    function removeGuardian(address guardian) external onlyRole(MANAGER_ROLE) {
        _removeGuardian(guardian);
        if (_guardians.length() < _quorum) revert WouldBreakQuorum();
    }

    /// @inheritdoc IGuardianSignals
    function setDelegate(address newDelegate) external {
        if (!_guardians.contains(msg.sender)) revert Unauthorized();
        if (_guardians.contains(newDelegate)) revert DelegateIsGuardian();
        if (newDelegate != address(0)) _requireNotDelegate(newDelegate);
        address oldDelegate = _delegates[msg.sender];
        _delegates[msg.sender] = newDelegate;
        emit DelegateSet(msg.sender, oldDelegate, newDelegate);
    }

    /// @inheritdoc IGuardianSignals
    function setQuorum(uint256 newQuorum) external onlyRole(MANAGER_ROLE) {
        _setQuorum(newQuorum);
        emit QuorumSet(newQuorum);
    }

    /// @inheritdoc IGuardianSignals
    function setSuspectWindow(uint256 suspectWindow) external onlyRole(MANAGER_ROLE) {
        if (suspectWindow > MAX_SUSPECT_WINDOW) revert SuspectWindowTooHigh();
        _suspectWindow = suspectWindow.toUint40();
        emit SuspectWindowSet(suspectWindow);
    }

    /// @inheritdoc IGuardianSignals
    function getQuorum() external view returns (uint256) {
        return _quorum;
    }

    /// @inheritdoc IGuardianSignals
    function getSuspectWindow() external view returns (uint256) {
        return _suspectWindow;
    }

    /// @inheritdoc IGuardianSignals
    function isGuardian(address account) external view returns (bool) {
        return _guardians.contains(account);
    }

    /// @inheritdoc IGuardianSignals
    function getDelegate(address guardian) external view returns (address) {
        return _delegates[guardian];
    }

    /// @inheritdoc IGuardianSignals
    function getGuardianCount() external view returns (uint256) {
        return _guardians.length();
    }

    /// @inheritdoc IGuardianSignals
    function getGuardians() external view returns (address[] memory guardians, address[] memory delegates) {
        guardians = _guardians.values();
        delegates = new address[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            delegates[i] = _delegates[guardians[i]];
        }
    }

    // ---
    // LIVENESS
    // ---

    /// @inheritdoc IGuardianSignals
    function heartbeat(address onBehalf, BlockInfoWithHash calldata lastScannedBlock, bytes calldata data) external {
        if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();

        uint40 previousTimestamp = _heartbeats[onBehalf];
        // a guardian cannot have scanned a block that does not exist yet
        if (lastScannedBlock.number > block.number) revert BlockInTheFuture();
        // The frontier trusts the reported timestamp (the chain can't attest it by number), so bound it to the past
        // and force it non-decreasing per guardian: no backdating or fast-forwarding the frontier it feeds.
        if (lastScannedBlock.timestamp > block.timestamp) revert TimestampInTheFuture();
        if (lastScannedBlock.timestamp < previousTimestamp) revert HeartbeatTimestampRegressed();
        // number + hash only prove the block is real and was not reorged away; the frontier orders by timestamp.
        // Reject a zero hash: `blockhash` returns zero for the current or out-of-window block, which it would
        // spuriously match.
        if (lastScannedBlock.hash == bytes32(0)) revert InvalidBlockHash();
        if (blockhash(lastScannedBlock.number) != lastScannedBlock.hash) revert InvalidBlockHash();

        _heartbeats[onBehalf] = lastScannedBlock.timestamp;
        emit Heartbeat(onBehalf, lastScannedBlock.number, lastScannedBlock.timestamp, data);

        // The frontier is the quorum-th largest heartbeat, so this one can only raise it by crossing from at or below
        // it to above it. The guard skips the O(n log n) resort otherwise; `syncQuorumFrontier` is the fallback for
        // cases it misses (e.g. a quorum change moving the order statistic).
        if (previousTimestamp <= _quorumFrontierTimestamp && lastScannedBlock.timestamp > _quorumFrontierTimestamp) {
            _syncQuorumFrontier();
        }
    }

    /// @inheritdoc IGuardianSignals
    function syncQuorumFrontier() external {
        _syncQuorumFrontier();
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeat(address guardian) external view returns (uint40 timestamp) {
        return _heartbeats[guardian];
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeats() external view returns (address[] memory guardians, uint40[] memory timestamps) {
        guardians = _guardians.values();
        timestamps = new uint40[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            timestamps[i] = _heartbeats[guardians[i]];
        }
    }

    /// @inheritdoc IGuardianSignals
    function getQuorumFrontier() external view returns (uint40) {
        return _quorumFrontierTimestamp;
    }

    // ---
    // GUARDIANS SIGNALLING
    // ---

    /// @inheritdoc IGuardianSignals
    function flag(Id marketId, address onBehalf, address[] calldata accounts) external {
        if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();
        for (uint256 i; i < accounts.length; ++i) {
            _flag(onBehalf, marketId, accounts[i]);
        }
    }

    /// @inheritdoc IGuardianSignals
    function unflag(Id marketId, address onBehalf, address[] calldata accounts) external {
        if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();
        for (uint256 i; i < accounts.length; ++i) {
            _unflag(onBehalf, marketId, accounts[i]);
        }
    }

    /// @inheritdoc IGuardianSignals
    function suspect(Id marketId, address onBehalf, address[] calldata accounts) external {
        if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();
        for (uint256 i; i < accounts.length; ++i) {
            _suspect(onBehalf, marketId, accounts[i]);
        }
    }

    /// @inheritdoc IGuardianSignals
    function unsuspect(Id marketId, address onBehalf, address[] calldata accounts) external {
        if (!_isSenderAuthorized(onBehalf)) revert Unauthorized();
        for (uint256 i; i < accounts.length; ++i) {
            _unsuspect(onBehalf, marketId, accounts[i]);
        }
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Order matters: prune the stale flags first, then re-evaluate the ban against the survivors. The snapshot
    ///      is re-taken only if a suspect report was pruned.
    function prune(Id marketId, address account) external {
        GuardiansSignal storage signal = _signals[marketId][account];

        address[] memory flaggers = signal.flaggedBy.values();
        for (uint256 i; i < flaggers.length; ++i) {
            address flagger = flaggers[i];
            if (!_guardians.contains(flagger)) {
                signal.flaggedBy.remove(flagger);
                emit FlagPruned(marketId, account, flagger, signal.flaggedBy.length());
            }
        }
        // Re-evaluate against the survivors: latch if they still meet quorum. A never-latched derived ban dropped
        // below quorum lapses; a latched ban is untouched.
        if (!signal.banned && signal.flaggedBy.length() >= _quorum) {
            signal.banned = true;
            emit Banned(marketId, account);
        }

        address[] memory suspects = signal.suspectedBy.values();
        bool suspectPruned;
        for (uint256 i; i < suspects.length; ++i) {
            if (!_guardians.contains(suspects[i])) {
                _removeSuspect(signal, suspects[i]);
                emit SuspectPruned(marketId, account, suspects[i]);
                suspectPruned = true;
            }
        }
        if (suspectPruned) _snapshotSuspects(signal);
    }

    // ---
    // COMMITTEE / GOVERNANCE OVERRIDE
    // ---

    /// @inheritdoc IGuardianSignals
    function ban(Id marketId, address account) external onlyRole(ACCESS_LIMITER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _signals[marketId][account].banned = true;
        emit Banned(marketId, account);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Clears the flagger set, so the freshly-unbanned account can be re-flagged and re-banned from scratch.
    function unban(Id marketId, address account) external onlyRole(ACCESS_RESTORER_ROLE) {
        GuardiansSignal storage signal = _signals[marketId][account];
        signal.banned = false;
        signal.flaggedBy.clear();
        emit Unbanned(marketId, account, msg.sender);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IGuardianSignalsView
    function getOpinion(Id marketId, address account) external view returns (GuardiansOpinion memory opinion) {
        opinion.banned = _isBanned(_signals[marketId][account]);
        (opinion.strikeCount, opinion.suspectCount, opinion.suspectExpiryTimestamp) = _signalCounters(marketId, account);
        opinion.quorumFrontierTimestamp = _quorumFrontierTimestamp;
    }

    /// @inheritdoc IGuardianSignalsView
    function isBanned(Id marketId, address account) external view returns (bool) {
        return _isBanned(_signals[marketId][account]);
    }

    /// @dev Effective ban: the latched bit, or a flag count at or above the current quorum.
    function _isBanned(GuardiansSignal storage signal) internal view returns (bool) {
        return signal.banned || signal.flaggedBy.length() >= _quorum;
    }

    /// @inheritdoc IGuardianSignals
    function getFlaggedBy(Id marketId, address account) external view returns (address[] memory) {
        return _signals[marketId][account].flaggedBy.values();
    }

    /// @inheritdoc IGuardianSignals
    function getSuspectedBy(Id marketId, address account)
        external
        view
        returns (address[] memory guardians, uint40[] memory reportedAt)
    {
        GuardiansSignal storage signal = _signals[marketId][account];
        guardians = signal.suspectedBy.values();
        reportedAt = new uint40[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            reportedAt[i] = signal.suspectedAt[guardians[i]];
        }
    }

    // ---
    // INTERNAL METHODS
    // ---

    /// @dev Whether the sender may act for `onBehalf`: it must be a guardian, and the sender must be that guardian
    ///      or its current delegate.
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        if (!_guardians.contains(onBehalf)) return false;
        return msg.sender == onBehalf || msg.sender == _delegates[onBehalf];
    }

    /// @dev Recompute the quorum frontier (the quorum-th largest heartbeat timestamp) and raise the stored
    ///      value when the recomputed one is higher. The stored frontier never decreases: adding guardians with
    ///      zero heartbeats lowers only the recomputed candidate, never the stored value.
    function _syncQuorumFrontier() internal {
        uint256 quorum = _quorum;
        uint256 n = _guardians.length();
        if (quorum == 0 || n < quorum) return;
        address[] memory guardians = _guardians.values();
        uint256[] memory timestamps = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            timestamps[i] = _heartbeats[guardians[i]];
        }
        uint40 frontierTimestamp = Arrays.sort(timestamps)[n - quorum].toUint40();
        if (frontierTimestamp > _quorumFrontierTimestamp) {
            _quorumFrontierTimestamp = frontierTimestamp;
            emit QuorumFrontierAdvanced(msg.sender, frontierTimestamp);
        }
    }

    function _setQuorum(uint256 newQuorum) internal {
        if (newQuorum == 0 || newQuorum > _guardians.length()) revert BadQuorum();
        _quorum = newQuorum.toUint8();
    }

    function _removeGuardian(address guardian) internal {
        if (!_guardians.remove(guardian)) revert NotGuardian();
        address oldDelegate = _delegates[guardian];
        if (oldDelegate != address(0)) {
            delete _delegates[guardian];
            emit DelegateSet(guardian, oldDelegate, address(0));
        }
        delete _heartbeats[guardian];
        emit GuardianRemoved(guardian);
    }

    function _addGuardian(address guardian) internal {
        if (guardian == address(0)) revert ZeroAddress();
        if (_guardians.length() >= MAX_GUARDIANS_COUNT) revert MaxGuardiansReached();
        _requireNotDelegate(guardian);
        if (!_guardians.add(guardian)) revert AlreadyGuardian();
        emit GuardianAdded(guardian);
    }

    /// @dev Reverts when `account` is already some guardian's delegate. Both new delegates and new guardians pass
    ///      through this check, so one address cannot serve two committee identities. `account` must be non-zero:
    ///      zero matches every guardian without a delegate.
    function _requireNotDelegate(address account) internal view {
        address[] memory guardians = _guardians.values();
        for (uint256 i; i < guardians.length; ++i) {
            if (_delegates[guardians[i]] == account) revert AccountIsDelegate();
        }
    }

    function _flag(address guardian, Id marketId, address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signals[marketId][account];
        if (!signal.flaggedBy.add(guardian)) return;

        uint256 strikes = signal.flaggedBy.length();
        if (strikes >= _quorum && !signal.banned) {
            signal.banned = true;
            emit Banned(marketId, account);
        }
        emit Flagged(marketId, account, guardian, msg.sender, strikes);
    }

    /// @dev Never lifts a ban. Before dropping the count, latch any currently-effective ban, including a
    ///      quorum-derived one never written, so a retraction below quorum can't lift a ban that is in effect.
    function _unflag(address guardian, Id marketId, address account) internal {
        GuardiansSignal storage signal = _signals[marketId][account];
        if (!signal.banned && signal.flaggedBy.length() >= _quorum) {
            signal.banned = true;
            emit Banned(marketId, account);
        }
        if (!signal.flaggedBy.remove(guardian)) return;
        emit Unflagged(marketId, account, guardian, msg.sender, signal.flaggedBy.length());
    }

    /// @dev Single-account suspect report. Records (or refreshes) the guardian's timestamp, then snapshots
    ///      `(now, activeSuspectCount)` so the delay read needn't re-scan the suspect set. Never bans.
    function _suspect(address guardian, Id marketId, address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signals[marketId][account];
        _pruneExpiredSuspects(marketId, account, signal);
        signal.suspectedBy.add(guardian);
        signal.suspectedAt[guardian] = block.timestamp.toUint40();
        _snapshotSuspects(signal);
        emit Suspected(marketId, account, guardian, msg.sender, block.timestamp);
    }

    /// @dev Single-account suspect retraction. Rebuilds the snapshot if it clears or prunes any report.
    function _unsuspect(address guardian, Id marketId, address account) internal {
        GuardiansSignal storage signal = _signals[marketId][account];
        bool suspectPruned = _pruneExpiredSuspects(marketId, account, signal);
        bool suspectCleared = _removeSuspect(signal, guardian);
        if (suspectPruned || suspectCleared) _snapshotSuspects(signal);
        if (suspectCleared) emit SuspectCleared(marketId, account, guardian, msg.sender);
    }

    /// @dev Snapshot the active suspect count and latest remaining report so the delay read skips a re-scan.
    function _snapshotSuspects(GuardiansSignal storage signal) internal {
        uint256 count;
        uint40 latestReportedAt;
        uint256 window = _suspectWindow;
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            uint40 reportedAt = signal.suspectedAt[suspects[i]];
            if (uint256(reportedAt) + window >= block.timestamp) {
                ++count;
                if (reportedAt > latestReportedAt) latestReportedAt = reportedAt;
            }
        }
        signal.suspectReportedAt = latestReportedAt;
        signal.suspectCount = count.toUint16();
    }

    /// @dev The raw counters the activation lib turns into a delay: flag count, snapshotted active-suspect count,
    ///      and the snapshot's expiry (`suspectReportedAt + suspectWindow`). Reads the stored snapshot, no scan.
    function _signalCounters(Id marketId, address account)
        internal
        view
        returns (uint256 strikeCount, uint256 suspectCount, uint256 suspectExpiryTimestamp)
    {
        GuardiansSignal storage signal = _signals[marketId][account];
        strikeCount = signal.flaggedBy.length();
        suspectCount = signal.suspectCount;
        suspectExpiryTimestamp = uint256(signal.suspectReportedAt) + _suspectWindow;
    }

    /// @dev Drop suspect reports on `account` whose window has lapsed.
    function _pruneExpiredSuspects(Id marketId, address account, GuardiansSignal storage signal)
        internal
        returns (bool suspectPruned)
    {
        uint256 window = _suspectWindow;
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (uint256(signal.suspectedAt[suspects[i]]) + window < block.timestamp) {
                _removeSuspect(signal, suspects[i]);
                emit SuspectPruned(marketId, account, suspects[i]);
                suspectPruned = true;
            }
        }
    }

    /// @dev Keep the raw reporter set and its timestamp mapping in sync.
    function _removeSuspect(GuardiansSignal storage signal, address guardian) private returns (bool removed) {
        removed = signal.suspectedBy.remove(guardian);
        if (removed) signal.suspectedAt[guardian] = 0;
    }
}
