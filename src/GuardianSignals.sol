// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {IGuardianSignals} from "./interfaces/IGuardianSignals.sol";
import {IGuardianSignalsView} from "./interfaces/IGuardianSignalsView.sol";
import {
    GuardiansOpinion,
    BlockInfoWithHash,
    DelayParams,
    GuardiansSignal,
    Status
} from "./types/GuardianSignalsTypes.sol";

/// @title GuardianSignals
/// @author Lido
/// @notice One guardian committee over many markets: a registry where guardians flag suspect accounts and a
///         quorum of flags latches a ban. Guardians are bots run by trusted actors. Signal state is keyed per
///         `(market, account)`, so a ban is scoped to the market it was raised in; the guardian set, quorum, and
///         liveness frontier are committee-wide. The market controller reads `getOpinion(marketId, account)` to
///         scale collateral activation and to hard-block borrowing.
/// @dev Upgradeable behind a proxy (`initialize`, not a constructor), with ERC-7201 namespaced storage.
///      Escalation ladder, surfaced by `getOpinion`:
///        - flags == 0             : clean, normal activation.
///        - 0 < flags < quorum     : the surcharge scales the activation delay up by the flag count.
///        - flags >= quorum        : the status latches to `Banned`, the reader hard-blocks borrow.
///
///      The ban latches: retracting a flag never lifts it. `unban` lifts it and clears the flagger set, so
///      guardians re-evaluate from scratch. Both are per `(market, account)`.
///
///      A suspect report (`suspect` / `unsuspect`) never latches a ban but raises the activation delay
///      like a flag, counted only while fresh (its timestamp inside `suspectWindow`).
///
///      Override roles split by risk direction: `ACCESS_LIMITER_ROLE` (fast, risk-reducing) forces `ban`;
///      `ACCESS_RESTORER_ROLE` (slow, risk-increasing) `unban`. `MANAGER_ROLE` manages the guardian set, quorum,
///      and delay parameters. A guardian set is a plain enumerable set, not a role. Every role is standard
///      `AccessControl`, committee-wide across the markets this instance serves.
///
///      Guardians report liveness: `flag`, `unflag`, `suspect`, `unsuspect`, and `heartbeat` each record
///      a last-scanned block (O(1)). `syncQuorumBlock` recomputes the quorum frontier that `getQuorumFrontier`
///      returns — the highest timestamp a quorum have scanned past (monotonic). Only the timestamp is stored; the
///      block number is re-emitted in the `Heartbeat` event for off-chain tooling.
///
///      Events and errors are declared in {IGuardianSignals}.
contract GuardianSignals layout at erc7201("lido.lend.storage.GuardianSignals")
    is
    Initializable,
    AccessControlEnumerableUpgradeable,
    IGuardianSignals
{
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;

    // ---
    // CONSTANTS
    // ---

    /// @notice Maximum number of guardians. Capped low because every `heartbeat` (and the heartbeat inside
    ///         `flag` / `unflag`) re-sorts all guardians' last-scanned timestamps to recompute the quorum
    ///         frontier, an O(n²)-worst-case cost. 32 keeps that bounded and still fits the quorum in `uint8`.
    uint256 public constant MAX_GUARDIANS_COUNT = 32;

    /// @notice Ceiling on the per-flag activation-delay surcharge, so a single misfired flag cannot pin an
    ///         account's collateral for an unreasonable time.
    uint256 public constant MAX_DELAY_PER_STRIKE = 7 days;

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
    /// @dev Manages the guardian set, quorum, and delay parameters.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // ---
    // STORAGE
    // ---

    uint8 private _quorum;
    uint40 private _delayPerStrike;
    uint40 private _delayPerSuspect;
    uint40 private _maxDelay;
    uint40 private _suspectWindow;
    /// @dev Quorum-scan frontier: the highest timestamp a quorum of guardians have ever scanned past. Monotonic.
    uint40 private _quorumFrontier;
    EnumerableSet.AddressSet private _guardians;
    /// @dev Each guardian's last-scanned block timestamp. The block number is not kept — it is re-emitted in the
    ///      `Heartbeat` event for off-chain tooling and only used at call time for the reorg (blockhash) check.
    mapping(address guardian => uint40 timestamp) private _heartbeatAt;
    mapping(Id marketId => mapping(address account => GuardiansSignal)) private _signals;

    // ---
    // MODIFIERS
    // ---

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

    /// @notice Set the admin and seed the guardian set and quorum. The delay parameters are set afterwards via
    ///         `setDelayParams`. Emits `GuardianAdded` per guardian and `QuorumSet`.
    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE`, the default admin of the guardian and override roles.
    /// @param guardians The initial guardian set. Each must be non-zero, unique, and within `MAX_GUARDIANS_COUNT`.
    /// @param quorum    The initial quorum. Must satisfy `1 <= quorum <= guardians.length`.
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
    /// @dev Reverts if removal would drop the set below `quorum`, so the quorum stays reachable.
    function removeGuardian(address guardian) external onlyRole(MANAGER_ROLE) {
        if (!_guardians.remove(guardian)) revert NotGuardian();
        if (_guardians.length() < _quorum) revert WouldBreakQuorum();
        emit GuardianRemoved(guardian);
    }

    /// @inheritdoc IGuardianSignals
    function setQuorum(uint256 newQuorum) external onlyRole(MANAGER_ROLE) {
        _setQuorum(newQuorum);
        emit QuorumSet(newQuorum);
    }

    /// @inheritdoc IGuardianSignals
    function setDelayParams(DelayParams calldata params) external onlyRole(MANAGER_ROLE) {
        if (params.delayPerStrike > MAX_DELAY_PER_STRIKE) revert DelayPerStrikeTooHigh();
        if (params.delayPerSuspect > MAX_DELAY_PER_STRIKE) revert DelayPerSuspectTooHigh();
        if (params.suspectWindow > MAX_SUSPECT_WINDOW) revert SuspectWindowTooHigh();

        _delayPerStrike = params.delayPerStrike.toUint40();
        _delayPerSuspect = params.delayPerSuspect.toUint40();
        _maxDelay = params.maxDelay.toUint40();
        _suspectWindow = params.suspectWindow.toUint40();
        emit DelayParamsSet(params.delayPerStrike, params.delayPerSuspect, params.maxDelay, params.suspectWindow);
    }

    /// @inheritdoc IGuardianSignals
    function getQuorum() external view returns (uint256) {
        return _quorum;
    }

    /// @inheritdoc IGuardianSignals
    function getDelayParams() external view returns (DelayParams memory) {
        return DelayParams({
            delayPerStrike: _delayPerStrike,
            delayPerSuspect: _delayPerSuspect,
            maxDelay: _maxDelay,
            suspectWindow: _suspectWindow
        });
    }

    /// @inheritdoc IGuardianSignals
    function isGuardian(address account) external view returns (bool) {
        return _guardians.contains(account);
    }

    /// @inheritdoc IGuardianSignals
    function getGuardianCount() external view returns (uint256) {
        return _guardians.length();
    }

    /// @inheritdoc IGuardianSignals
    function getGuardians() external view returns (address[] memory) {
        return _guardians.values();
    }

    // ---
    // LIVENESS
    // ---

    /// @inheritdoc IGuardianSignals
    function heartbeat(BlockInfoWithHash calldata lastScannedBlock) external onlyGuardian {
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function syncQuorumBlock() external {
        _syncQuorumBlock();
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeat(address guardian) external view returns (uint40) {
        return _heartbeatAt[guardian];
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeats() external view returns (address[] memory guardians, uint40[] memory heartbeats) {
        guardians = _guardians.values();
        heartbeats = new uint40[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            heartbeats[i] = _heartbeatAt[guardians[i]];
        }
    }

    /// @inheritdoc IGuardianSignals
    function getQuorumFrontier() external view returns (uint40) {
        return _quorumFrontier;
    }

    // ---
    // GUARDIANS SIGNALLING
    // ---

    /// @inheritdoc IGuardianSignals
    function flag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian
    {
        for (uint256 i; i < accounts.length; ++i) {
            _flag(marketId, accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function unflag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian
    {
        for (uint256 i; i < accounts.length; ++i) {
            _unflag(marketId, accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function suspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian
    {
        for (uint256 i; i < accounts.length; ++i) {
            _suspect(marketId, accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function unsuspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian
    {
        for (uint256 i; i < accounts.length; ++i) {
            _unsuspect(marketId, accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Permissionless cleanup: removes flags and suspect reports left behind by removed guardians. Status is
    ///      never touched — the ban latch means a permissionless caller can lower the flag count but cannot unban.
    function prune(Id marketId, address account) external {
        GuardiansSignal storage signal = _signals[marketId][account];

        address[] memory flaggers = signal.flaggedBy.values();
        for (uint256 i; i < flaggers.length; ++i) {
            address flagger = flaggers[i];
            if (!_guardians.contains(flagger)) {
                signal.flaggedBy.remove(flagger);
                emit FlagPruned(marketId, account, flagger, uint16(signal.flaggedBy.length()));
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
    /// @dev Force a ban regardless of the current flag count.
    function ban(Id marketId, address account) external onlyRole(ACCESS_LIMITER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _signals[marketId][account].status = Status.Banned;
        emit Banned(marketId, account);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Clears the flagger set, so the freshly-unbanned account can be re-flagged and re-banned from scratch.
    function unban(Id marketId, address account) external onlyRole(ACCESS_RESTORER_ROLE) {
        GuardiansSignal storage signal = _signals[marketId][account];
        signal.status = Status.Normal;
        signal.flaggedBy.clear();
        emit Unbanned(marketId, account, msg.sender);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IGuardianSignalsView
    function getOpinion(Id marketId, address account) external view returns (GuardiansOpinion memory opinion) {
        opinion.banned = _signals[marketId][account].status == Status.Banned;
        opinion.activationDelay = _activationDelay(marketId, account);
        opinion.quorumFrontierTimestamp = _quorumFrontier;
    }

    /// @inheritdoc IGuardianSignalsView
    function isBanned(Id marketId, address account) external view returns (bool) {
        return _signals[marketId][account].status == Status.Banned;
    }

    /// @inheritdoc IGuardianSignals
    function getActivationDelay(Id marketId, address account) external view returns (uint256) {
        return _activationDelay(marketId, account);
    }

    /// @inheritdoc IGuardianSignalsView
    function getFlagCount(Id marketId, address account) external view returns (uint256) {
        return _signals[marketId][account].flaggedBy.length();
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

    /// @dev Record the caller's last-scanned block. O(1): the quorum frontier is recomputed separately by
    ///      `_syncQuorumBlock`.
    function _heartbeat(BlockInfoWithHash calldata lastScannedBlock) internal {
        // a guardian cannot have scanned a block that does not exist yet
        if (lastScannedBlock.number > block.number) revert BlockInTheFuture();
        // The chain cannot attest an arbitrary block's timestamp by number, so the frontier trusts the
        // guardian-reported timestamp. Bound it to the past and force it non-decreasing per guardian, so a
        // guardian cannot backdate or fast-forward the quorum-scan frontier it feeds.
        if (lastScannedBlock.timestamp > block.timestamp) revert TimestampInTheFuture();
        if (lastScannedBlock.timestamp < _heartbeatAt[msg.sender]) revert HeartbeatTimestampRegressed();
        // number + hash only prove the reported block is real and un-reorged; the frontier orders by timestamp.
        if (blockhash(lastScannedBlock.number) != lastScannedBlock.hash) revert InvalidBlockHash();

        _heartbeatAt[msg.sender] = lastScannedBlock.timestamp;
        emit Heartbeat(msg.sender, lastScannedBlock.number, lastScannedBlock.timestamp);
    }

    /// @dev Recompute the quorum frontier (the quorum-th largest heartbeat timestamp) and ratchet it up.
    ///      Monotonic: a guardian rotation that adds fresh zero-heartbeat members cannot pull it back.
    function _syncQuorumBlock() internal {
        uint256 quorum = _quorum;
        uint256 n = _guardians.length();
        if (quorum == 0 || n < quorum) return;
        address[] memory guardians = _guardians.values();
        uint256[] memory timestamps = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            timestamps[i] = _heartbeatAt[guardians[i]];
        }
        uint40 frontierTimestamp = uint40(Arrays.sort(timestamps)[n - quorum]);
        if (frontierTimestamp > _quorumFrontier) _quorumFrontier = frontierTimestamp;
    }

    function _setQuorum(uint256 newQuorum) internal {
        if (newQuorum == 0 || newQuorum > _guardians.length()) revert BadQuorum();
        _quorum = uint8(newQuorum);
    }

    function _addGuardian(address guardian) internal {
        if (guardian == address(0)) revert ZeroAddress();
        if (_guardians.length() >= MAX_GUARDIANS_COUNT) revert MaxGuardiansReached();
        if (!_guardians.add(guardian)) revert AlreadyGuardian();
        emit GuardianAdded(guardian);
    }

    /// @dev Single-account flag. No-op when the caller already flags it.
    function _flag(Id marketId, address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signals[marketId][account];
        if (!signal.flaggedBy.add(msg.sender)) return;

        uint256 strikes = signal.flaggedBy.length();
        if (strikes >= _quorum && signal.status != Status.Banned) {
            signal.status = Status.Banned;
            emit Banned(marketId, account);
        }
        emit Flagged(marketId, account, msg.sender, uint16(strikes));
    }

    /// @dev Single-account unflag. No-op when the caller does not flag it. Never lifts a latched ban.
    function _unflag(Id marketId, address account) internal {
        GuardiansSignal storage signal = _signals[marketId][account];
        if (!signal.flaggedBy.remove(msg.sender)) return;
        emit Unflagged(marketId, account, msg.sender, uint16(signal.flaggedBy.length()));
    }

    /// @dev Single-account suspect report. Records (or refreshes) the caller's timestamp so a re-report keeps the
    ///      suspicion inside the window. Never latches a ban.
    function _suspect(Id marketId, address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signals[marketId][account];
        _pruneExpiredSuspects(marketId, account);
        signal.suspectedBy.add(msg.sender);
        signal.suspectedAt[msg.sender] = uint40(block.timestamp);
        emit Suspected(marketId, account, msg.sender, block.timestamp);
    }

    /// @dev Single-account suspect retraction. No-op when the caller has no live report on the account.
    function _unsuspect(Id marketId, address account) internal {
        _pruneExpiredSuspects(marketId, account);
        GuardiansSignal storage signal = _signals[marketId][account];
        if (!signal.suspectedBy.remove(msg.sender)) return;
        signal.suspectedAt[msg.sender] = 0;
        emit SuspectCleared(marketId, account, msg.sender);
    }

    /// @dev The collateral-activation delay surcharge: `type(uint256).max` when banned, else
    ///      `min(flags * delayPerStrike + freshSuspects * delayPerSuspect, maxDelay)` (0 = uncapped).
    function _activationDelay(Id marketId, address account) internal view returns (uint256) {
        GuardiansSignal storage signal = _signals[marketId][account];
        if (signal.status == Status.Banned) return type(uint256).max;
        uint256 delay =
            signal.flaggedBy.length() * _delayPerStrike + _activeSuspectCount(marketId, account) * _delayPerSuspect;
        uint256 maxDelay = _maxDelay;
        return maxDelay != 0 && delay > maxDelay ? maxDelay : delay;
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
    function _pruneSuspect(Id marketId, address account, GuardiansSignal storage signal, address suspect) private {
        signal.suspectedBy.remove(suspect);
        signal.suspectedAt[suspect] = 0;
        emit SuspectPruned(marketId, account, suspect);
    }
}
