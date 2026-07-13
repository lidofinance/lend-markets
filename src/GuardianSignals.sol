// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

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
/// @notice One guardian committee over many markets: guardians flag suspect accounts and a quorum of flags
///         latches a ban, scoped to the market it was raised in; softer suspect reports raise a borrower's
///         collateral-activation delay without banning. The market controller reads `getOpinion(marketId, account)`
///         to scale activation and hard-block borrowing.
/// @dev    Each committee seat is a *guardian* with two keys: an immutable **guardian** key that governs the seat and
///         a rotatable **operator** key (the bot that scans and raises signals). The operator may only raise signals
///         (`flag`, `suspect`); the guardian may raise them, retract them (`unflag`, `unsuspect`) and rotate the
///         operator key (`rotateOperator`). Both keys act on the same seat: flags, suspect reports and heartbeats are
///         keyed by the immutable guardian address, so an operator-key rotation keeps the seat's standing. Governance
///         (`MANAGER_ROLE`) adds/removes guardians and sets quorum and the suspect window. Upgradeable behind a proxy
///         (`initialize`, not a constructor), ERC-7201 namespaced storage. Events and errors are declared in
///         {IGuardianSignals}.
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

    /// @notice Maximum number of guardians. Capped low because `syncQuorumBlock` re-sorts all guardians'
    ///         last-scanned timestamps to recompute the quorum frontier, whose cost grows with the set. 32 keeps
    ///         that bounded and still fits the quorum in `uint8`.
    uint256 public constant MAX_GUARDIANS_COUNT = 32;

    /// @notice Ceiling on the suspect window: the horizon within which a suspect report still counts toward the
    ///         activation delay. Reports older than the window are ignored.
    uint256 public constant MAX_SUSPECT_WINDOW = 30 days;

    // ---
    // ROLES
    // ---

    /// @dev `ban` (fast, risk-reducing).
    bytes32 public constant ACCESS_LIMITER_ROLE = keccak256("ACCESS_LIMITER_ROLE");
    /// @dev `unban` (slow, risk-increasing).
    bytes32 public constant ACCESS_RESTORER_ROLE = keccak256("ACCESS_RESTORER_ROLE");
    /// @dev Governance of the committee: adds/removes guardians and sets quorum and the suspect window.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // ---
    // STORAGE
    // ---

    uint8 private _quorum;
    /// @dev Freshness horizon for a suspect snapshot: `suspectReportedAt + suspectWindow` is when it lapses.
    uint40 private _suspectWindow;
    /// @dev Quorum-scan frontier: the highest timestamp a quorum of guardians have ever scanned past. Monotonic.
    uint40 private _quorumFrontierTimestamp;
    /// @dev The committee guardians — one per seat. Each guardian is its seat's immutable id, so the flags,
    ///      suspect reports and heartbeats keyed by it survive a rotation of the seat's operator key.
    EnumerableSet.AddressSet private _guardians;
    /// @dev Guardian => its current operator key. Rotated by the guardian via `rotateOperator`.
    mapping(address guardian => address operator) private _operatorOf;
    /// @dev Operator key => its guardian. Doubles as the "is an operator" check.
    mapping(address operator => address guardian) private _guardianOf;
    /// @dev Each guardian's last-scanned block timestamp (a Unix timestamp, not a block number). Keyed by guardian id.
    mapping(address guardian => uint40 timestamp) private _heartbeats;
    /// @dev Per (market, account) signal. `flaggedBy`/`suspectedBy` hold guardian ids, not raw callers.
    mapping(Id marketId => mapping(address account => GuardiansSignal)) private _signals;

    // ---
    // MODIFIERS
    // ---

    /// @dev The caller must be a guardian (a guardian id). Guardians may retract signals and rotate the operator key.
    modifier onlyGuardian() {
        if (!_guardians.contains(msg.sender)) revert NotGuardian();
        _;
    }

    // ---
    // INITIALIZATION
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Set the admin and seed the guardians and quorum. The suspect window is set afterwards via
    ///         `setSuspectWindow`. Emits `GuardianAdded` per seat and `QuorumSet`.
    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE`, the default admin of the guardian and override roles.
    /// @param guardians The initial guardian keys. Each must be non-zero and globally unique.
    /// @param operators The per-seat operator keys, aligned 1:1 with `guardians`; each non-zero and globally unique.
    /// @param quorum    The initial quorum. Must satisfy `1 <= quorum <= guardians.length`.
    function initialize(address admin, address[] calldata guardians, address[] calldata operators, uint256 quorum)
        external
        initializer
    {
        if (admin == address(0)) revert ZeroAddress();
        if (guardians.length != operators.length) revert InvalidParams();

        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        for (uint256 i; i < guardians.length; ++i) {
            _addGuardian(guardians[i], operators[i]);
        }
        _setQuorum(quorum);
        emit QuorumSet(quorum);
    }

    // ---
    // GUARDIANS & CONFIG
    // ---

    /// @inheritdoc IGuardianSignals
    function addGuardian(address guardian, address operator) external onlyRole(MANAGER_ROLE) {
        _addGuardian(guardian, operator);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Reverts if removal would drop the set below `quorum`, so the quorum stays reachable. Signals already
    ///      keyed by the removed guardian linger (still counted) until a permissionless `prune` clears them.
    function removeGuardian(address guardian) external onlyRole(MANAGER_ROLE) {
        if (!_guardians.contains(guardian)) revert NotGuardian();
        address operator = _operatorOf[guardian];
        _guardians.remove(guardian);
        if (_guardians.length() < _quorum) revert WouldBreakQuorum();
        delete _operatorOf[guardian];
        delete _guardianOf[operator];
        // Clear the seat's heartbeat so a later re-add of this guardian starts fresh rather than inheriting a stale
        // (possibly future) timestamp that would ratchet the frontier and block earlier heartbeats.
        delete _heartbeats[guardian];
        emit GuardianRemoved(guardian, operator);
    }

    /// @inheritdoc IGuardianSignals
    function rotateOperator(address newOperator) external onlyGuardian {
        if (newOperator == address(0)) revert ZeroAddress();
        _requireFreeAddress(newOperator);
        address guardian = msg.sender;
        address old = _operatorOf[guardian];
        delete _guardianOf[old];
        _operatorOf[guardian] = newOperator;
        _guardianOf[newOperator] = guardian;
        emit OperatorRotated(guardian, old, newOperator);
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
    function isOperator(address account) external view returns (bool) {
        return _guardianOf[account] != address(0);
    }

    /// @inheritdoc IGuardianSignals
    function isGuardian(address account) external view returns (bool) {
        return _guardians.contains(account);
    }

    /// @inheritdoc IGuardianSignals
    function guardianOf(address operator) external view returns (address) {
        return _guardianOf[operator];
    }

    /// @inheritdoc IGuardianSignals
    function operatorOf(address guardian) external view returns (address) {
        return _operatorOf[guardian];
    }

    /// @inheritdoc IGuardianSignals
    function getGuardianCount() external view returns (uint256) {
        return _guardians.length();
    }

    /// @inheritdoc IGuardianSignals
    function getGuardians() external view returns (address[] memory) {
        return _guardians.values();
    }

    /// @inheritdoc IGuardianSignals
    function getOperators() external view returns (address[] memory operators) {
        address[] memory guardians = _guardians.values();
        operators = new address[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            operators[i] = _operatorOf[guardians[i]];
        }
    }

    // ---
    // LIVENESS
    // ---

    /// @inheritdoc IGuardianSignals
    function heartbeat(BlockInfoWithHash calldata lastScannedBlock) external {
        // Liveness reflects the guardian bot's scan, so only the operator key heartbeats — not the guardian. The
        // record is keyed by the guardian (the seat's stable id), so it survives an operator-key rotation.
        address guardian = _guardianOf[msg.sender];
        if (guardian == address(0)) revert NotOperator();
        _heartbeat(guardian, lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function syncQuorumBlock() external {
        _syncQuorumBlock();
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeat(address account) external view returns (uint40 timestamp) {
        address guardian = _guardianFor(account);
        return guardian == address(0) ? 0 : _heartbeats[guardian];
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeats() external view returns (address[] memory operators, uint40[] memory timestamps) {
        address[] memory guardians = _guardians.values();
        operators = new address[](guardians.length);
        timestamps = new uint40[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            operators[i] = _operatorOf[guardians[i]];
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
    function flag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external {
        address guardian = _requireGuardianFor(msg.sender);
        for (uint256 i; i < accounts.length; ++i) {
            _flag(guardian, marketId, accounts[i]);
        }
        _maybeHeartbeat(guardian, lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function unflag(Id marketId, address[] calldata accounts) external onlyGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            _unflag(msg.sender, marketId, accounts[i]);
        }
    }

    /// @inheritdoc IGuardianSignals
    function suspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external {
        address guardian = _requireGuardianFor(msg.sender);
        for (uint256 i; i < accounts.length; ++i) {
            _suspect(guardian, marketId, accounts[i]);
        }
        _maybeHeartbeat(guardian, lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function unsuspect(Id marketId, address[] calldata accounts) external onlyGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            _unsuspect(msg.sender, marketId, accounts[i]);
        }
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Permissionless cleanup: removes flags and suspect reports left behind by removed guardians. The ban is
    ///      never touched — the ban latch means a permissionless caller can lower the flag count but cannot unban.
    function prune(Id marketId, address account) external {
        GuardiansSignal storage signal = _signals[marketId][account];

        address[] memory flaggers = signal.flaggedBy.values();
        for (uint256 i; i < flaggers.length; ++i) {
            address flagger = flaggers[i];
            if (!_guardians.contains(flagger)) {
                signal.flaggedBy.remove(flagger);
                emit FlagPruned(marketId, account, flagger, signal.flaggedBy.length().toUint16());
            }
        }

        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (!_guardians.contains(suspects[i])) _pruneSuspect(marketId, account, signal, suspects[i]);
        }
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

    /// @dev Resolve a caller to its guardian id: a guardian is its own guardian, an operator maps to its guardian.
    ///      Zero when the caller is neither.
    function _guardianFor(address account) internal view returns (address guardian) {
        if (_guardians.contains(account)) return account;
        return _guardianOf[account];
    }

    /// @dev Resolve a caller to its guardian, reverting when it is neither a guardian nor an operator.
    function _requireGuardianFor(address account) internal view returns (address guardian) {
        guardian = _guardianFor(account);
        if (guardian == address(0)) revert NotOperator();
    }

    /// @dev An address may fill at most one role across all seats: not already a guardian and not already an operator.
    function _requireFreeAddress(address account) internal view {
        if (_guardians.contains(account) || _guardianOf[account] != address(0)) revert AlreadyGuardian();
    }

    /// @dev Advance the seat's liveness only when the caller is its operator key — a guardian raising a signal does
    ///      not report a scan, so it silently skips. Keeps the frontier a true guardian-bot liveness signal.
    function _maybeHeartbeat(address guardian, BlockInfoWithHash calldata lastScannedBlock) internal {
        if (msg.sender == _operatorOf[guardian]) _heartbeat(guardian, lastScannedBlock);
    }

    /// @dev Record the guardian's last-scanned block. The quorum frontier is recomputed by `_syncQuorumBlock`.
    function _heartbeat(address guardian, BlockInfoWithHash calldata lastScannedBlock) internal {
        // a guardian cannot have scanned a block that does not exist yet
        if (lastScannedBlock.number > block.number) revert BlockInTheFuture();
        // The chain cannot attest an arbitrary block's timestamp by number, so the frontier trusts the
        // reported timestamp. Bound it to the past and force it non-decreasing per guardian, so a guardian cannot
        // backdate or fast-forward the quorum-scan frontier it feeds.
        if (lastScannedBlock.timestamp > block.timestamp) revert TimestampInTheFuture();
        if (lastScannedBlock.timestamp < _heartbeats[guardian]) revert HeartbeatTimestampRegressed();
        // number + hash only prove the reported block is real and un-reorged; the frontier orders by timestamp.
        // Reject a zero hash: `blockhash` returns zero for the current or out-of-window block, which it would match.
        if (lastScannedBlock.hash == bytes32(0)) revert InvalidBlockHash();
        if (blockhash(lastScannedBlock.number) != lastScannedBlock.hash) revert InvalidBlockHash();

        _heartbeats[guardian] = lastScannedBlock.timestamp;
        emit Heartbeat(guardian, lastScannedBlock.number, lastScannedBlock.timestamp);
    }

    /// @dev Recompute the quorum frontier (the quorum-th largest heartbeat timestamp) and ratchet it up.
    ///      Monotonic: a rotation that adds fresh zero-heartbeat guardians cannot pull it back.
    function _syncQuorumBlock() internal {
        uint256 quorum = _quorum;
        uint256 n = _guardians.length();
        if (quorum == 0 || n < quorum) return;
        address[] memory guardians = _guardians.values();
        uint256[] memory timestamps = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            timestamps[i] = _heartbeats[guardians[i]];
        }
        uint40 frontierTimestamp = Arrays.sort(timestamps)[n - quorum].toUint40();
        if (frontierTimestamp > _quorumFrontierTimestamp) _quorumFrontierTimestamp = frontierTimestamp;
    }

    function _setQuorum(uint256 newQuorum) internal {
        if (newQuorum == 0 || newQuorum > _guardians.length()) revert BadQuorum();
        _quorum = newQuorum.toUint8();
    }

    /// @dev Register a new guardian: an immutable guardian key + its rotatable operator key. Both must be free (each
    ///      address may fill at most one role) and distinct.
    function _addGuardian(address guardian, address operator) internal {
        if (guardian == address(0) || operator == address(0)) revert ZeroAddress();
        if (guardian == operator) revert InvalidParams();
        if (_guardians.length() >= MAX_GUARDIANS_COUNT) revert MaxGuardiansReached();
        _requireFreeAddress(guardian);
        _requireFreeAddress(operator);
        _guardians.add(guardian);
        _operatorOf[guardian] = operator;
        _guardianOf[operator] = guardian;
        emit GuardianAdded(guardian, operator);
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
        emit Flagged(marketId, account, guardian, msg.sender, strikes.toUint16());
    }

    /// @dev Never lifts a ban. Before dropping the flag count, materialize any currently-effective ban into the
    ///      latch — including a quorum-derived one (`flaggedBy.length() >= quorum` from a lowered quorum) that was
    ///      never written — so a retraction that pushes the count below quorum cannot lift a ban that is in effect.
    function _unflag(address guardian, Id marketId, address account) internal {
        GuardiansSignal storage signal = _signals[marketId][account];
        if (!signal.banned && signal.flaggedBy.length() >= _quorum) {
            signal.banned = true;
            emit Banned(marketId, account);
        }
        if (!signal.flaggedBy.remove(guardian)) return;
        emit Unflagged(marketId, account, guardian, msg.sender, signal.flaggedBy.length().toUint16());
    }

    /// @dev Single-account suspect report. Records (or refreshes) the guardian's timestamp so a re-report keeps the
    ///      suspicion inside the window, then snapshots `(now, activeSuspectCount)` so the delay read need not
    ///      re-scan the suspect set. Never latches a ban.
    function _suspect(address guardian, Id marketId, address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signals[marketId][account];
        _pruneExpiredSuspects(marketId, account);
        signal.suspectedBy.add(guardian);
        signal.suspectedAt[guardian] = block.timestamp.toUint40();
        _snapshotSuspects(marketId, account, signal);
        emit Suspected(marketId, account, guardian, msg.sender, block.timestamp);
    }

    /// @dev Single-account suspect retraction. No-op when the guardian has no live report on the account.
    function _unsuspect(address guardian, Id marketId, address account) internal {
        _pruneExpiredSuspects(marketId, account);
        GuardiansSignal storage signal = _signals[marketId][account];
        if (!signal.suspectedBy.remove(guardian)) return;
        signal.suspectedAt[guardian] = 0;
        _snapshotSuspects(marketId, account, signal);
        emit SuspectCleared(marketId, account, guardian, msg.sender);
    }

    /// @dev Snapshot the active suspect count against `block.timestamp`, so `_activationDelay` reads it instead of
    ///      re-scanning the suspect set. Run on every report/retraction (after pruning expired ones).
    function _snapshotSuspects(Id marketId, address account, GuardiansSignal storage signal) internal {
        signal.suspectReportedAt = block.timestamp.toUint40();
        signal.suspectCount = _activeSuspectCount(marketId, account).toUint16();
    }

    /// @dev The raw signal counters the activation lib turns into a delay: the flag count, the snapshotted active
    ///      suspect count, and when that snapshot lapses (`suspectReportedAt + suspectWindow`). Reads the stored
    ///      snapshot rather than scanning the suspect set.
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

    /// @dev Count the live suspect reports on `account` still inside the suspect window (`t + window >= now`).
    function _activeSuspectCount(Id marketId, address account) internal view returns (uint256 count) {
        GuardiansSignal storage signal = _signals[marketId][account];
        uint256 window = _suspectWindow;
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (uint256(signal.suspectedAt[suspects[i]]) + window >= block.timestamp) ++count;
        }
    }

    /// @dev Drop suspect reports on `account` whose window has lapsed. A lapsed report already stopped counting,
    ///      so removing it changes nothing but the set size.
    function _pruneExpiredSuspects(Id marketId, address account) internal {
        GuardiansSignal storage signal = _signals[marketId][account];
        uint256 window = _suspectWindow;
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (uint256(signal.suspectedAt[suspects[i]]) + window < block.timestamp) {
                _pruneSuspect(marketId, account, signal, suspects[i]);
            }
        }
    }

    /// @dev Remove one guardian's suspect report on `account` and log it.
    function _pruneSuspect(Id marketId, address account, GuardiansSignal storage signal, address guardian) private {
        signal.suspectedBy.remove(guardian);
        signal.suspectedAt[guardian] = 0;
        emit SuspectPruned(marketId, account, guardian);
    }
}
