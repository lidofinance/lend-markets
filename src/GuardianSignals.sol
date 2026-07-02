// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";

import {IGuardianSignals} from "./interfaces/IGuardianSignals.sol";
import {IGuardianSignalsView} from "./interfaces/IGuardianSignalsView.sol";
import {
    GuardiansOpinion,
    BlockInfoWithHash,
    GuardianConfig,
    GuardiansSignal,
    Status
} from "./types/GuardianSignalsTypes.sol";

/// @title GuardianSignals
/// @author Lido
/// @notice One instance per market: a registry where guardians flag suspect accounts and a quorum of flags
///         latches a ban. Guardians are bots run by trusted actors. The market controller reads
///         `getOpinion` to scale collateral activation and to hard-block borrowing.
/// @dev Upgradeable behind a proxy (`initialize`, not a constructor), with ERC-7201 namespaced storage. Signal
///      state is per account. Escalation ladder, surfaced by `getOpinion`:
///        - flags == 0             : clean, normal activation.
///        - 0 < flags < quorum     : the surcharge scales the activation delay up by the flag count.
///        - flags >= quorum        : the status latches to `Banned`, the reader hard-blocks borrow.
///
///      The ban latches: retracting a flag never lifts it. `unban` lifts it and clears the flagger set, so
///      guardians re-evaluate from scratch. `Immune` exempts an account: while set, `flag`/`unflag` no-op and
///      readers see it as clean. `ban` clears it.
///
///      A suspect report (`reportSuspect` / `clearSuspect`) never latches a ban but raises the activation delay
///      like a flag, counted only while fresh (its timestamp inside `suspectWindow`).
///
///      Override roles split by concern and risk direction: fast risk-reducing (`BAN_ROLE`: `ban`;
///      `IMMUNITY_REVOKER_ROLE`: `revokeImmunity`), slow risk-increasing (`UNBAN_ROLE`: `unban`;
///      `IMMUNITY_GRANTER_ROLE`: `grantImmunity`). `GUARDIANS_MANAGER_ROLE` manages the guardian set and config.
///      A guardian set is a plain enumerable set, not a role. Every role is standard `AccessControl`, scoped to
///      this contract (i.e. this market) — deploy one instance per market.
///
///      Guardians report liveness: `flag`, `unflag`, `reportSuspect`, `clearSuspect`, and `heartbeat` each record
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
    bytes32 public constant BAN_ROLE = keccak256("BAN_ROLE");
    /// @dev `unban` (slow, risk-increasing).
    bytes32 public constant UNBAN_ROLE = keccak256("UNBAN_ROLE");
    /// @dev `revokeImmunity` (fast, risk-reducing).
    bytes32 public constant IMMUNITY_REVOKER_ROLE = keccak256("IMMUNITY_REVOKER_ROLE");
    /// @dev `grantImmunity` (slow, risk-increasing).
    bytes32 public constant IMMUNITY_GRANTER_ROLE = keccak256("IMMUNITY_GRANTER_ROLE");
    /// @dev Manages the guardian set and config.
    bytes32 public constant GUARDIANS_MANAGER_ROLE = keccak256("GUARDIANS_MANAGER_ROLE");

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
    mapping(address account => GuardiansSignal) private _signals;

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

    /// @notice Set the admin. The guardian set and config are seeded via `setConfig`.
    /// @param admin Holder of `DEFAULT_ADMIN_ROLE`, the default admin of the guardian and override roles.
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---
    // GUARDIANS & CONFIG
    // ---

    /// @inheritdoc IGuardianSignals
    function setConfig(GuardianConfig calldata config) external onlyRole(GUARDIANS_MANAGER_ROLE) {
        if (config.delayPerStrike > MAX_DELAY_PER_STRIKE) revert DelayPerStrikeTooHigh();
        if (config.delayPerSuspect > MAX_DELAY_PER_STRIKE) revert DelayPerSuspectTooHigh();
        if (config.suspectWindow > MAX_SUSPECT_WINDOW) revert SuspectWindowTooHigh();

        // Reset the set to the new roster. Zero the quorum first so re-seeding does not transiently trip the
        // quorum-reachability check while the set is smaller than the old quorum.
        _quorum = 0;
        address[] memory existing = _guardians.values();
        for (uint256 i; i < existing.length; ++i) {
            _guardians.remove(existing[i]);
            emit GuardianRemoved(existing[i]);
        }
        for (uint256 i; i < config.guardians.length; ++i) {
            _addGuardian(config.guardians[i]);
        }
        _setQuorum(config.quorum);

        _delayPerStrike = uint40(config.delayPerStrike);
        _delayPerSuspect = uint40(config.delayPerSuspect);
        _maxDelay = uint40(config.maxDelay);
        _suspectWindow = uint40(config.suspectWindow);
        emit ConfigSet(
            config.quorum, config.delayPerStrike, config.delayPerSuspect, config.maxDelay, config.suspectWindow
        );
    }

    /// @inheritdoc IGuardianSignals
    function addGuardian(address guardian) external onlyRole(GUARDIANS_MANAGER_ROLE) {
        _addGuardian(guardian);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Reverts if removal would drop the set below `quorum`, so the quorum stays reachable.
    function removeGuardian(address guardian) external onlyRole(GUARDIANS_MANAGER_ROLE) {
        if (!_guardians.remove(guardian)) revert NotGuardian();
        if (_guardians.length() < _quorum) revert WouldBreakQuorum();
        emit GuardianRemoved(guardian);
    }

    /// @inheritdoc IGuardianSignals
    function getConfig() external view returns (GuardianConfig memory) {
        return GuardianConfig({
            guardians: _guardians.values(),
            quorum: _quorum,
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
    function flag(address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external onlyGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            _flag(accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function unflag(address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external onlyGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            _unflag(accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function reportSuspect(address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian
    {
        for (uint256 i; i < accounts.length; ++i) {
            _reportSuspect(accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function clearSuspect(address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian
    {
        for (uint256 i; i < accounts.length; ++i) {
            _clearSuspect(accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Permissionless cleanup: removes flags and suspect reports left behind by removed guardians. Status is
    ///      never touched — the ban latch means a permissionless caller can lower the flag count but cannot unban.
    function prune(address account) external {
        GuardiansSignal storage signal = _signals[account];

        address[] memory flaggers = signal.flaggedBy.values();
        for (uint256 i; i < flaggers.length; ++i) {
            address flagger = flaggers[i];
            if (!_guardians.contains(flagger)) {
                signal.flaggedBy.remove(flagger);
                emit FlagPruned(account, flagger, uint16(signal.flaggedBy.length()));
            }
        }

        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (!_guardians.contains(suspects[i])) _pruneSuspect(account, signal, suspects[i]);
        }
    }

    // ---
    // COMMITTEE / GOVERNANCE OVERRIDE
    // ---

    /// @inheritdoc IGuardianSignals
    /// @dev Clears immunity so the block takes effect even on an exempt account.
    function ban(address account) external onlyRole(BAN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _signals[account].status = Status.Banned;
        emit Banned(account);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Clears the flagger set, so the freshly-unbanned account can be re-flagged and re-banned from
    ///      scratch. Immunity is left to `revokeImmunity`.
    function unban(address account) external onlyRole(UNBAN_ROLE) {
        GuardiansSignal storage signal = _signals[account];
        signal.status = Status.Normal;
        signal.flaggedBy.clear();
        emit Unbanned(account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function grantImmunity(address account) external onlyRole(IMMUNITY_GRANTER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _signals[account].status = Status.Immune;
        emit ImmunityGranted(account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function revokeImmunity(address account) external onlyRole(IMMUNITY_REVOKER_ROLE) {
        GuardiansSignal storage signal = _signals[account];
        // Only act on an actually-immune account: revoking is a no-op otherwise, so this never clears a
        // committee `ban` (a forced `Banned` carries no flags) nor disturbs a `Normal` account.
        if (signal.status != Status.Immune) return;
        // Restore the status the flag set implies rather than forcing `Normal`: an account still carrying a
        // quorum of flags re-latches to `Banned`, so revoking immunity never silently unbans it.
        signal.status = signal.flaggedBy.length() >= _quorum ? Status.Banned : Status.Normal;
        emit ImmunityRevoked(account, msg.sender);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IGuardianSignalsView
    function getOpinion(address account) external view returns (GuardiansOpinion memory opinion) {
        opinion.banned = _signals[account].status == Status.Banned;
        opinion.activationDelay = _activationDelay(account);
        opinion.quorumBlockTimestamp = _quorumFrontier;
    }

    /// @inheritdoc IGuardianSignalsView
    function isBanned(address account) external view returns (bool) {
        return _signals[account].status == Status.Banned;
    }

    /// @inheritdoc IGuardianSignals
    function getActivationDelay(address account) external view returns (uint256) {
        return _activationDelay(account);
    }

    /// @inheritdoc IGuardianSignalsView
    function getFlagCount(address account) external view returns (uint256) {
        return _signals[account].flaggedBy.length();
    }

    /// @inheritdoc IGuardianSignals
    function getFlaggedBy(address account) external view returns (address[] memory) {
        return _signals[account].flaggedBy.values();
    }

    /// @inheritdoc IGuardianSignals
    function getSuspectedBy(address account)
        external
        view
        returns (address[] memory guardians, uint40[] memory reportedAt)
    {
        GuardiansSignal storage signal = _signals[account];
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

    /// @dev Single-account flag. No-op when `account` is immune or the caller already flags it.
    function _flag(address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signals[account];
        if (signal.status == Status.Immune || !signal.flaggedBy.add(msg.sender)) return;

        uint256 strikes = signal.flaggedBy.length();
        if (strikes >= _quorum && signal.status != Status.Banned) {
            signal.status = Status.Banned;
            emit Banned(account);
        }
        emit Flagged(account, msg.sender, uint16(strikes));
    }

    /// @dev Single-account unflag. No-op when `account` is immune or the caller does not flag it. Never lifts a
    ///      latched ban.
    function _unflag(address account) internal {
        GuardiansSignal storage signal = _signals[account];
        if (signal.status == Status.Immune || !signal.flaggedBy.remove(msg.sender)) return;
        emit Unflagged(account, msg.sender, uint16(signal.flaggedBy.length()));
    }

    /// @dev Single-account suspect report. No-op while immune. Records (or refreshes) the caller's timestamp so a
    ///      re-report keeps the suspicion inside the window. Never latches a ban.
    function _reportSuspect(address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signals[account];
        if (signal.status == Status.Immune) return;

        _pruneExpiredSuspects(account);
        signal.suspectedBy.add(msg.sender);
        signal.suspectedAt[msg.sender] = uint40(block.timestamp);
        emit Suspected(account, msg.sender, block.timestamp);
    }

    /// @dev Single-account suspect retraction. No-op when the caller has no live report on the account.
    function _clearSuspect(address account) internal {
        _pruneExpiredSuspects(account);
        GuardiansSignal storage signal = _signals[account];
        if (!signal.suspectedBy.remove(msg.sender)) return;
        signal.suspectedAt[msg.sender] = 0;
        emit SuspectCleared(account, msg.sender);
    }

    /// @dev The collateral-activation delay surcharge: `type(uint256).max` when banned, 0 when immune, else
    ///      `min(flags * delayPerStrike + freshSuspects * delayPerSuspect, maxDelay)` (0 = uncapped).
    function _activationDelay(address account) internal view returns (uint256) {
        GuardiansSignal storage signal = _signals[account];
        if (signal.status == Status.Banned) return type(uint256).max;
        if (signal.status == Status.Immune) return 0;
        uint256 delay = signal.flaggedBy.length() * _delayPerStrike + _activeSuspectCount(account) * _delayPerSuspect;
        uint256 maxDelay = _maxDelay;
        return maxDelay != 0 && delay > maxDelay ? maxDelay : delay;
    }

    /// @dev Count the live suspect reports on `account` still inside the suspect window (`t + window >= now`).
    function _activeSuspectCount(address account) internal view returns (uint256 count) {
        GuardiansSignal storage signal = _signals[account];
        uint256 window = _suspectWindow;
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (uint256(signal.suspectedAt[suspects[i]]) + window >= block.timestamp) ++count;
        }
    }

    /// @dev Drop suspect reports on `account` whose window has lapsed. A lapsed report already stopped counting,
    ///      so removing it changes nothing but the set size.
    function _pruneExpiredSuspects(address account) internal {
        GuardiansSignal storage signal = _signals[account];
        uint256 window = _suspectWindow;
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (uint256(signal.suspectedAt[suspects[i]]) + window < block.timestamp) {
                _pruneSuspect(account, signal, suspects[i]);
            }
        }
    }

    /// @dev Remove one guardian's suspect report on `account` and log it.
    function _pruneSuspect(address account, GuardiansSignal storage signal, address suspect) private {
        signal.suspectedBy.remove(suspect);
        signal.suspectedAt[suspect] = 0;
        emit SuspectPruned(account, suspect);
    }
}
