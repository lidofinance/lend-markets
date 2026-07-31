// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {BlockInfoWithHash} from "../types/GuardianSignalsTypes.sol";
import {IGuardianSignalsView} from "./IGuardianSignalsView.sol";

/// @title IGuardianSignals
/// @notice Guardian-committee signals over accounts, kept per market. Each guardian is a single committee address
///         that may appoint one **delegate** (at most one at a time) to act on its behalf. A guardian (or its
///         delegate) raises signals (flag, suspect) and retracts them (unflag, unsuspect). Once a `quorum` of
///         distinct guardians flag an account, a ban latches in the market it was raised in. The small read surface
///         the controller depends on (`getOpinion`, `isBanned`) lives in {IGuardianSignalsView}; this interface adds
///         the rest.
interface IGuardianSignals is IGuardianSignalsView {
    /// @notice Maximum number of guardians in the registry.
    function MAX_GUARDIANS_COUNT() external view returns (uint256);

    /// @notice Maximum duration of the suspect window.
    function MAX_SUSPECT_WINDOW() external view returns (uint256);

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a guardian is added.
    event GuardianAdded(address indexed guardian);
    /// @notice Emitted when a guardian is removed.
    event GuardianRemoved(address indexed guardian);
    /// @notice Emitted when a guardian sets or clears its delegate.
    /// @param guardian    The guardian that changed its delegate.
    /// @param oldDelegate The previous delegate (zero if none).
    /// @param newDelegate The new delegate (zero to clear).
    event DelegateSet(address indexed guardian, address indexed oldDelegate, address indexed newDelegate);
    /// @notice Emitted when the quorum changes.
    /// @param quorum The number of distinct guardians' flags that latches a ban.
    event QuorumSet(uint256 quorum);
    /// @notice Emitted when the suspect window is set.
    /// @param suspectWindow The freshness horizon within which a suspect report still counts.
    event SuspectWindowSet(uint256 suspectWindow);
    /// @notice Emitted when a guardian's liveness is recorded.
    /// @param guardian    The guardian the scan is recorded for.
    /// @param blockNumber The block number reported as scanned past (carried for off-chain tooling).
    /// @param timestamp   The reported block's timestamp; the quorum-scan frontier orders guardians by this value.
    event Heartbeat(address indexed guardian, uint256 blockNumber, uint256 timestamp);
    /// @notice Emitted when the quorum-scan frontier advances (the quorum-th largest heartbeat rises).
    /// @param timestamp The new frontier timestamp.
    event QuorumFrontierAdvanced(uint256 timestamp);
    /// @notice Emitted when a guardian reports an account as suspect (raises the activation delay, never bans).
    /// @param marketId  The market the report is scoped to.
    /// @param account   The suspected account.
    /// @param guardian  The reporting guardian.
    /// @param actor     The caller that made the call (the guardian or its delegate).
    /// @param timestamp The report time, recorded so the report can be aged out of the suspect window.
    event Suspected(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 timestamp
    );
    /// @notice Emitted when a guardian's suspect report on an account is retracted.
    event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian, address actor);
    /// @notice Emitted when a suspect report is pruned — its guardian was removed from the committee, or its suspect
    ///         window lapsed.
    event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
    /// @notice Emitted when a guardian flags an account.
    /// @param marketId The market id.
    /// @param account  The flagged account.
    /// @param guardian The flagging guardian.
    /// @param actor    The caller that made the call (the guardian or its delegate).
    /// @param strikes  The account's flag count after the flag.
    event Flagged(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 strikes
    );
    /// @notice Emitted when a guardian's flag is retracted.
    event Unflagged(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 strikes
    );
    /// @notice Emitted when a flag cast by a removed guardian is pruned.
    event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint256 strikes);
    /// @notice Emitted when an account's ban latches, by quorum or by `ban`.
    event Banned(Id indexed marketId, address indexed account);
    /// @notice Emitted when an account's ban is lifted.
    /// @param marketId The market the ban was scoped to.
    /// @param account  The unbanned account.
    /// @param by       The `ACCESS_RESTORER_ROLE` holder that unbanned.
    event Unbanned(Id indexed marketId, address indexed account, address indexed by);

    // ---
    // ERRORS
    // ---

    /// @notice Thrown when a zero address is passed where an account or guardian is required.
    error ZeroAddress();
    /// @notice Thrown when the quorum is zero or exceeds the guardian count.
    error BadQuorum();
    /// @notice Thrown when removing a guardian would drop the set below the quorum.
    error WouldBreakQuorum();
    /// @notice Thrown when adding a guardian that is already in the set.
    error AlreadyGuardian();
    /// @notice Thrown when the caller is neither `onBehalf` nor its delegate, or when a non-guardian appoints a
    /// delegate.
    error Unauthorized();
    /// @notice Thrown when the target of a guardian-only management action is not a guardian.
    error NotGuardian();
    /// @notice Thrown when the guardian set is already at `MAX_GUARDIANS_COUNT`.
    error MaxGuardiansReached();
    /// @notice Thrown when a heartbeat reports a block number ahead of the current block.
    error BlockInTheFuture();
    /// @notice Thrown when a heartbeat reports a timestamp ahead of the current block.
    error TimestampInTheFuture();
    /// @notice Thrown when a heartbeat reports a timestamp below the guardian's previous heartbeat.
    error HeartbeatTimestampRegressed();
    /// @notice Thrown when a heartbeat's reported hash does not match the block's hash.
    error InvalidBlockHash();
    /// @notice Thrown when the suspect window exceeds `MAX_SUSPECT_WINDOW`.
    error SuspectWindowTooHigh();

    // ---
    // GUARDIANS & CONFIG (admin)
    // ---

    /// @notice Add `guardian` to the committee. Must be non-zero, not already a guardian, and within the cap.
    function addGuardian(address guardian) external;
    /// @notice Atomically replace one guardian with another without changing the guardian count or quorum.
    function replaceGuardian(address oldGuardian, address newGuardian) external;
    /// @notice Remove `guardian` from the committee (reverts if it would drop the set below the quorum).
    function removeGuardian(address guardian) external;
    /// @notice Set the caller-guardian's delegate — a hot key that may act on its behalf. The zero address clears
    ///         it. Guardian-only; the guardian's signals and heartbeat are untouched.
    function setDelegate(address newDelegate) external;
    /// @notice Set the quorum — the distinct guardians' flags that latch a ban.
    function setQuorum(uint256 newQuorum) external;
    /// @notice Set the suspect window — how long a suspect report keeps counting. The per-flag and per-suspect
    ///         delays live in the market's activation config.
    function setSuspectWindow(uint256 suspectWindow) external;
    /// @notice The quorum: distinct guardians' flags that latch a ban.
    function getQuorum() external view returns (uint256);
    /// @notice The suspect window: the freshness horizon within which a suspect report still counts.
    function getSuspectWindow() external view returns (uint256);
    /// @notice Whether `account` is a current guardian.
    function isGuardian(address account) external view returns (bool);
    /// @notice The current delegate of `guardian`, or zero if none is set.
    function getDelegate(address guardian) external view returns (address);
    /// @notice The number of guardians.
    function getGuardianCount() external view returns (uint256);
    /// @notice The guardian set paired with each guardian's current delegate (zero if none), aligned by index.
    /// @return guardians The current guardian set.
    /// @return delegates Each guardian's delegate, aligned by index with `guardians`.
    function getGuardians() external view returns (address[] memory guardians, address[] memory delegates);

    // ---
    // LIVENESS
    // ---

    /// @notice Record `onBehalf`'s last-scanned block, validated against its block hash and timestamp; callable by
    ///         the guardian or its delegate, and keyed by the guardian. If the heartbeat raises the quorum frontier,
    ///         it advances it in the same call; `syncQuorumFrontier` is a permissionless fallback.
    /// @param onBehalf         The guardian the scan is recorded for.
    /// @param lastScannedBlock The block reported as scanned past.
    function heartbeat(address onBehalf, BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Recompute the quorum-scan frontier from current heartbeats and ratchet it up. Permissionless and
    ///         monotonic.
    function syncQuorumFrontier() external;
    /// @notice The Unix timestamp of the last block `guardian` reported scanning (0 if never, or not a guardian).
    /// @return timestamp The last-scanned block timestamp.
    function getHeartbeat(address guardian) external view returns (uint40 timestamp);
    /// @notice The guardian set paired with each guardian's last-scanned block timestamp, aligned by index.
    /// @return guardians  The current guardian set.
    /// @return timestamps Each guardian's last-scanned block timestamp, aligned by index with `guardians`.
    function getHeartbeats() external view returns (address[] memory guardians, uint40[] memory timestamps);
    /// @notice Highest block timestamp at least a quorum of guardians have ever scanned past. Monotonic.
    function getQuorumFrontier() external view returns (uint40);

    // ---
    // SIGNALLING
    // ---

    /// @notice Flag `accounts` in `marketId` on behalf of guardian `onBehalf`. Per account a no-op if the guardian
    ///         already flags it, so a batch won't revert on a repeat.
    /// @param marketId The market to flag in.
    /// @param onBehalf The guardian the flags are recorded for.
    /// @param accounts The accounts to flag.
    function flag(Id marketId, address onBehalf, address[] calldata accounts) external;
    /// @notice Retract guardian `onBehalf`'s flags on `accounts` in `marketId`. Per account a no-op if the guardian
    ///         doesn't flag it. Never lifts a ban already in effect (including a quorum-derived one).
    function unflag(Id marketId, address onBehalf, address[] calldata accounts) external;
    /// @notice Report `accounts` as suspect in `marketId` on behalf of guardian `onBehalf`. A suspect report never
    ///         bans; it raises the activation delay like a flag, but only while inside the suspect window.
    /// @param marketId The market to report in.
    /// @param onBehalf The guardian the reports are recorded for.
    /// @param accounts The accounts to report as suspect.
    function suspect(Id marketId, address onBehalf, address[] calldata accounts) external;
    /// @notice Retract guardian `onBehalf`'s suspect reports on `accounts` in `marketId`. Per account a no-op if the
    ///         guardian has no live report on it.
    function unsuspect(Id marketId, address onBehalf, address[] calldata accounts) external;
    /// @notice Permissionless: on `account` in `marketId`, drop the flags and suspect reports left by guardians that
    ///         were since removed. Pruning a suspect report re-takes the active-suspect snapshot, so it stops
    ///         counting toward the delay at once. A latched ban is never lifted; after pruning, if the surviving
    ///         flags still meet quorum the ban latches, otherwise a still-unlatched quorum-derived ban lapses.
    function prune(Id marketId, address account) external;

    // ---
    // OVERRIDE (committee / governance)
    // ---

    /// @notice Force a ban on `account` in `marketId`, bypassing the quorum.
    function ban(Id marketId, address account) external;
    /// @notice Lift the ban on `account` in `marketId` and clear its flags. Suspect reports are left intact
    ///         (they carry no ban), so a suspect-driven delay survives the unban.
    function unban(Id marketId, address account) external;

    // ---
    // VIEWS
    // ---

    /// @notice The guardians currently flagging `account` in `marketId`.
    function getFlaggedBy(Id marketId, address account) external view returns (address[] memory);
    /// @notice The guardians with a live suspect report on `account` in `marketId`, paired with each report's
    ///         timestamp.
    /// @param marketId    The market to read the signal in.
    /// @param account     The account to read.
    /// @return guardians  The guardians currently reporting the account as suspect.
    /// @return reportedAt The timestamp of each guardian's last suspect report, aligned by index with `guardians`.
    function getSuspectedBy(Id marketId, address account)
        external
        view
        returns (address[] memory guardians, uint40[] memory reportedAt);
}
