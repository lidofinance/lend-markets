// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {BlockInfoWithHash} from "../types/GuardianSignalsTypes.sol";
import {IGuardianSignalsView} from "./IGuardianSignalsView.sol";

/// @title IGuardianSignals
/// @notice Guardian-committee signals over accounts, kept per market. Each guardian is a single committee address
///         that may appoint one delegate (at most one at a time, unique across the committee) to act on its
///         behalf. A guardian (or its delegate) raises signals (flag, suspect) and retracts them (unflag,
///         unsuspect). Once a `quorum` of distinct guardians flag an account, a ban latches in the market it was
///         raised in.
interface IGuardianSignals is IGuardianSignalsView, IAccessControlEnumerable {
    // ---
    // CONSTANTS
    // ---

    /// @notice Maximum number of guardians in the registry.
    function MAX_GUARDIANS_COUNT() external view returns (uint256);

    /// @notice Maximum duration of the suspect window.
    function MAX_SUSPECT_WINDOW() external view returns (uint256);

    // ---
    // ROLES
    // ---

    /// @notice Role allowed to add and remove guardians and update committee configuration.
    function MANAGER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to force-ban accounts.
    function ACCESS_LIMITER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to lift account bans.
    function ACCESS_RESTORER_ROLE() external view returns (bytes32);

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a guardian is added.
    /// @param guardian The added guardian.
    event GuardianAdded(address indexed guardian);

    /// @notice Emitted when a guardian is removed.
    /// @param guardian The removed guardian.
    event GuardianRemoved(address indexed guardian);

    /// @notice Emitted when a guardian sets or clears its delegate.
    /// @param guardian The guardian that changed its delegate.
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
    /// @param guardian The guardian the scan is recorded for.
    /// @param blockNumber The block number reported as scanned past.
    /// @param timestamp Guardian-reported scan timestamp; the quorum-scan frontier orders guardians by this value.
    /// @param data Guardian-supplied payload the registry does not read.
    event Heartbeat(address indexed guardian, uint256 blockNumber, uint256 timestamp, bytes data);

    /// @notice Emitted when the quorum-scan frontier advances (the quorum-th largest heartbeat rises).
    /// @param caller The account whose call advanced the frontier.
    /// @param timestamp The new frontier timestamp.
    event QuorumFrontierAdvanced(address indexed caller, uint256 timestamp);

    /// @notice Emitted when a guardian reports an account as suspect (raises the activation delay, never bans).
    /// @param marketId The market the report is scoped to.
    /// @param account The suspected account.
    /// @param guardian The reporting guardian.
    /// @param actor The caller that made the call (the guardian or its delegate).
    /// @param timestamp The report time, recorded so the report can be aged out of the suspect window.
    event Suspected(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 timestamp
    );

    /// @notice Emitted when a guardian's suspect report on an account is retracted.
    /// @param marketId The market the report was scoped to.
    /// @param account The account the report was on.
    /// @param guardian The guardian whose report was retracted.
    /// @param actor The caller that made the call (the guardian or its delegate).
    event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian, address actor);

    /// @notice Emitted when a suspect report is pruned: its guardian was removed from the committee, or its suspect
    ///         window lapsed.
    /// @param marketId The market the report was scoped to.
    /// @param account The account the report was on.
    /// @param guardian The guardian whose report was pruned.
    event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);

    /// @notice Emitted when a guardian flags an account.
    /// @param marketId The market id.
    /// @param account The flagged account.
    /// @param guardian The flagging guardian.
    /// @param actor The caller that made the call (the guardian or its delegate).
    /// @param strikes The account's flag count after the flag.
    event Flagged(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 strikes
    );

    /// @notice Emitted when a guardian's flag is retracted.
    /// @param marketId The market id.
    /// @param account The unflagged account.
    /// @param guardian The guardian whose flag was retracted.
    /// @param actor The caller that made the call (the guardian or its delegate).
    /// @param strikes The account's flag count after the retraction.
    event Unflagged(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 strikes
    );

    /// @notice Emitted when a flag cast by a removed guardian is pruned.
    /// @param marketId The market id.
    /// @param account The account the flag was on.
    /// @param guardian The removed guardian whose flag was pruned.
    /// @param strikes The account's flag count after the prune.
    event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint256 strikes);

    /// @notice Emitted when an account's ban latches, by quorum or by `ban`.
    /// @param marketId The market the ban is scoped to.
    /// @param account The banned account.
    event Banned(Id indexed marketId, address indexed account);

    /// @notice Emitted when an account's ban is lifted.
    /// @param marketId The market the ban was scoped to.
    /// @param account The unbanned account.
    /// @param by The `ACCESS_RESTORER_ROLE` holder that unbanned.
    event Unbanned(Id indexed marketId, address indexed account, address indexed by);

    // ---
    // ERRORS
    // ---

    /// @notice A zero address was passed where an account or guardian is required.
    error ZeroAddress();

    /// @notice The quorum is zero or exceeds the guardian count.
    error BadQuorum();

    /// @notice Removing the guardian would drop the set below the quorum.
    error WouldBreakQuorum();

    /// @notice The added guardian is already in the set.
    error AlreadyGuardian();

    /// @notice `onBehalf` is not a guardian, the caller is neither `onBehalf` nor its delegate, or a
    ///         non-guardian appointed a delegate.
    error Unauthorized();

    /// @notice The target of a guardian-only management action is not a guardian.
    error NotGuardian();

    /// @notice The guardian set is already at `MAX_GUARDIANS_COUNT`.
    error MaxGuardiansReached();

    /// @notice The heartbeat reports a block number ahead of the current block.
    error BlockInTheFuture();

    /// @notice The heartbeat reports a timestamp ahead of the current block.
    error TimestampInTheFuture();

    /// @notice The heartbeat reports a timestamp below the guardian's previous heartbeat.
    error HeartbeatTimestampRegressed();

    /// @notice The heartbeat's reported hash does not match the block's hash.
    error InvalidBlockHash();

    /// @notice The suspect window exceeds `MAX_SUSPECT_WINDOW`.
    error SuspectWindowTooHigh();

    /// @notice The appointed delegate is a guardian.
    error DelegateIsGuardian();

    /// @notice An address that is a guardian's delegate (the caller's own included) was appointed as a
    ///         delegate or added as a guardian.
    error AccountIsDelegate();

    // ---
    // GUARDIANS & CONFIG (admin)
    // ---

    /// @notice Add `guardian` to the committee. Must be non-zero, not already a guardian, not a current guardian's
    ///         delegate, and within the cap.
    function addGuardian(address guardian) external;

    /// @notice Atomically replace one guardian with another without changing the guardian count or quorum. The new
    ///         guardian must be non-zero and not a current guardian, checked before the removal; the delegate check
    ///         runs after it, so a guardian can be replaced with its own delegate.
    function replaceGuardian(address oldGuardian, address newGuardian) external;

    /// @notice Remove `guardian` from the committee (reverts if it would drop the set below the quorum).
    function removeGuardian(address guardian) external;

    /// @notice Set the caller-guardian's delegate: a hot key that may act on its behalf. The zero address clears
    ///         it. Guardian-only. A non-zero delegate must not be a guardian or any current delegate, the caller's
    ///         own included, so one address cannot sign for two committee identities. The guardian's signals and
    ///         heartbeat are untouched.
    function setDelegate(address newDelegate) external;

    /// @notice Set the quorum: the distinct guardians' flags that latch a ban.
    function setQuorum(uint256 newQuorum) external;

    /// @notice Set the suspect window: how long a suspect report keeps counting.
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

    /// @notice Record `onBehalf`'s last-scanned block identity and scan timestamp. The block hash is validated; the
    ///         guardian-reported timestamp is independently required not to regress or exceed `block.timestamp`.
    ///         Callable by the guardian or its delegate and keyed by the guardian. If the heartbeat raises the
    ///         quorum frontier, it advances it in the same call; `syncQuorumFrontier` is a permissionless fallback.
    /// @param onBehalf The guardian the scan is recorded for.
    /// @param lastScannedBlock The block reported as scanned past.
    /// @param data Payload the registry does not read, validate, or store; only emitted in `Heartbeat`. May
    ///        be empty.
    function heartbeat(address onBehalf, BlockInfoWithHash calldata lastScannedBlock, bytes calldata data) external;

    /// @notice Recompute the quorum-scan frontier from current heartbeats and ratchet it up. Permissionless and
    ///         monotonic.
    function syncQuorumFrontier() external;

    /// @notice The last scan timestamp reported by `guardian` (0 if never, or not a guardian).
    /// @return timestamp The guardian-reported scan timestamp.
    function getHeartbeat(address guardian) external view returns (uint40 timestamp);

    /// @notice The guardian set paired with each guardian's last reported scan timestamp, aligned by index.
    /// @return guardians The current guardian set.
    /// @return timestamps Each guardian's last reported scan timestamp, aligned by index with `guardians`.
    function getHeartbeats() external view returns (address[] memory guardians, uint40[] memory timestamps);

    /// @notice The stored quorum frontier: the highest timestamp a quorum of guardians has reported reviewing
    ///         past. It never decreases; membership and quorum changes do not lower it.
    function getQuorumFrontier() external view returns (uint40);

    // ---
    // SIGNALLING
    // ---

    /// @notice Flag `accounts` in `marketId` on behalf of guardian `onBehalf`. Per account a no-op if the guardian
    ///         already flags it, so a batch will not revert on a repeat.
    /// @param marketId The market to flag in.
    /// @param onBehalf The guardian the flags are recorded for.
    /// @param accounts The accounts to flag.
    function flag(Id marketId, address onBehalf, address[] calldata accounts) external;

    /// @notice Retract guardian `onBehalf`'s flags on `accounts` in `marketId`. Per account a no-op if the guardian
    ///         does not flag it. Never lifts a ban already in effect (including a quorum-derived one).
    function unflag(Id marketId, address onBehalf, address[] calldata accounts) external;

    /// @notice Report `accounts` as suspect in `marketId` on behalf of guardian `onBehalf`. A suspect report never
    ///         bans; it raises the activation delay like a flag, but only while inside the suspect window.
    /// @param marketId The market to report in.
    /// @param onBehalf The guardian the reports are recorded for.
    /// @param accounts The accounts to report as suspect.
    function suspect(Id marketId, address onBehalf, address[] calldata accounts) external;

    /// @notice Retract guardian `onBehalf`'s live suspect reports on `accounts` in `marketId`, pruning expired
    ///         reports and rebuilding affected snapshots.
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

    /// @notice The raw stored set of guardians flagging `account` in `marketId`. It may include a removed guardian
    ///         until `prune` is called; `unban` clears the set.
    function getFlaggedBy(Id marketId, address account) external view returns (address[] memory);

    /// @notice The raw stored suspect-report set for `account` in `marketId`, paired with report timestamps. It may
    ///         include a removed guardian until `prune`, or an expired report until a later report/retraction cleans
    ///         it up. Use `getOpinion` for the active snapshotted count.
    /// @param marketId The market to read the signal in.
    /// @param account The account to read.
    /// @return guardians The guardians still present in the raw stored suspect set.
    /// @return reportedAt The timestamp of each guardian's last suspect report, aligned by index with `guardians`.
    function getSuspectedBy(Id marketId, address account)
        external
        view
        returns (address[] memory guardians, uint40[] memory reportedAt);
}
