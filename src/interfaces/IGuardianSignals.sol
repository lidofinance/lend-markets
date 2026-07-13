// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {BlockInfoWithHash} from "../types/GuardianSignalsTypes.sol";
import {IGuardianSignalsView} from "./IGuardianSignalsView.sol";

/// @title IGuardianSignals
/// @notice Guardian-committee signal layer over accounts, keyed per market. Each committee seat is a *guardian* with a
///         rotatable operator key and an immutable guardian key: the operator only raises signals (flag, suspect), the
///         guardian also retracts them and rotates the operator key. A `quorum` of distinct guardians' flags latches a
///         ban in the market it was raised in. The minimal read surface the market controller depends on (`getOpinion`,
///         `isBanned`) is {IGuardianSignalsView}; this interface adds the full surface on top.
interface IGuardianSignals is IGuardianSignalsView {
    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a guardian is added.
    /// @param guardian The seat's immutable guardian key (its stable id).
    /// @param operator The guardian's rotatable operator key.
    event GuardianAdded(address indexed guardian, address indexed operator);
    /// @notice Emitted when a guardian is removed.
    event GuardianRemoved(address indexed guardian, address indexed operator);
    /// @notice Emitted when a guardian rotates its operator key.
    /// @param guardian    The guardian (its immutable guardian key).
    /// @param oldOperator The retired operator key.
    /// @param newOperator The new operator key.
    event OperatorRotated(address indexed guardian, address indexed oldOperator, address indexed newOperator);
    /// @notice Emitted when the quorum changes.
    /// @param quorum The number of distinct guardians' flags that latches a ban.
    event QuorumSet(uint256 quorum);
    /// @notice Emitted when the suspect window is set.
    /// @param suspectWindow The freshness horizon within which a suspect report still counts.
    event SuspectWindowSet(uint256 suspectWindow);
    /// @notice Emitted when a guardian reports liveness, directly or via `flag`/`suspect`.
    /// @param guardian    The seat (by guardian key) that reported.
    /// @param blockNumber The block number the guardian reports scanning past (carried for off-chain tooling).
    /// @param timestamp   The reported block's timestamp; the quorum-scan frontier orders guardians by this value.
    event Heartbeat(address indexed guardian, uint40 blockNumber, uint40 timestamp);
    /// @notice Emitted when a guardian reports an account as suspect (raises the activation delay, never bans).
    /// @param marketId  The market the report is scoped to.
    /// @param account   The suspected account.
    /// @param guardian  The reporting seat (by guardian key).
    /// @param actor     The key that made the call (the operator, or the guardian itself).
    /// @param timestamp The report time, recorded so the report can be aged out of the suspect window.
    event Suspected(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint256 timestamp
    );
    /// @notice Emitted when a guardian's suspect report on an account is retracted.
    event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian, address actor);
    /// @notice Emitted when a suspect report cast by a removed guardian is pruned.
    event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
    /// @notice Emitted when a guardian flags an account.
    /// @param marketId The market id.
    /// @param account  The flagged account.
    /// @param guardian The flagging seat (by guardian key).
    /// @param actor    The key that made the call (the operator, or the guardian itself).
    /// @param strikes  The account's flag count after the flag.
    event Flagged(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint16 strikes
    );
    /// @notice Emitted when a guardian's flag is retracted.
    event Unflagged(
        Id indexed marketId, address indexed account, address indexed guardian, address actor, uint16 strikes
    );
    /// @notice Emitted when a flag cast by a removed guardian is pruned.
    event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
    /// @notice Emitted when an account's ban latches, by quorum or by `ban`.
    event Banned(Id indexed marketId, address indexed account);
    /// @notice Emitted when an account's ban is lifted.
    /// @param by The `ACCESS_RESTORER_ROLE` holder that unbanned.
    event Unbanned(Id indexed marketId, address indexed account, address indexed by);

    // ---
    // ERRORS
    // ---

    /// @notice Thrown when a zero address is passed where an account, guardian or operator is required.
    error ZeroAddress();
    /// @notice Thrown on malformed input: mismatched guardian/operator arrays, or a guardian equal to its operator.
    error InvalidParams();
    /// @notice Thrown when the quorum is zero or exceeds the guardian count.
    error BadQuorum();
    /// @notice Thrown when removing a guardian would drop the set below the quorum.
    error WouldBreakQuorum();
    /// @notice Thrown when an address already fills a guardian or operator role.
    error AlreadyGuardian();
    /// @notice Thrown when a signal is raised by a caller that is neither a guardian nor an operator.
    error NotOperator();
    /// @notice Thrown when a guardian-only action is called by a non-guardian (an operator key is not a guardian).
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

    /// @notice Add a guardian: an immutable guardian key paired with a rotatable operator key. Both must be non-zero,
    ///         distinct, and not already fill a guardian or operator role.
    function addGuardian(address guardian, address operator) external;
    /// @notice Remove the guardian `guardian`.
    function removeGuardian(address guardian) external;
    /// @notice Rotate the caller-guardian's operator key to `newOperator`. Guardian-only. Keeps the guardian's flags,
    ///         suspect reports and heartbeat, since those are keyed by the immutable guardian id.
    function rotateOperator(address newOperator) external;
    /// @notice Set the quorum — the distinct guardians' flags that latch a ban.
    function setQuorum(uint256 newQuorum) external;
    /// @notice Set the suspect window — the freshness horizon within which a suspect report still counts. Never
    ///         touches the guardian set. The per-flag and per-suspect delays live in the market's activation config.
    function setSuspectWindow(uint256 suspectWindow) external;
    /// @notice The quorum: distinct guardians' flags that latch a ban.
    function getQuorum() external view returns (uint256);
    /// @notice The suspect window: the freshness horizon within which a suspect report still counts.
    function getSuspectWindow() external view returns (uint256);
    /// @notice Whether `account` is a current operator key.
    function isOperator(address account) external view returns (bool);
    /// @notice Whether `account` is a guardian.
    function isGuardian(address account) external view returns (bool);
    /// @notice The guardian of operator key `operator`, or zero if it is not an operator.
    function guardianOf(address operator) external view returns (address);
    /// @notice The current operator key of guardian `guardian`, or zero if `guardian` is not a guardian.
    function operatorOf(address guardian) external view returns (address);
    /// @notice The number of guardians.
    function getGuardianCount() external view returns (uint256);
    /// @notice The guardian keys, one per seat.
    function getGuardians() external view returns (address[] memory);
    /// @notice The current operator keys, one per guardian.
    function getOperators() external view returns (address[] memory);

    // ---
    // LIVENESS
    // ---

    /// @notice Record the caller's last-scanned block, validated against its block hash and timestamp. Operator-only
    ///         (only the operator key reports a scan); the record is keyed by the seat's guardian so it survives an
    ///         operator-key rotation. The quorum frontier is recomputed separately by `syncQuorumBlock`.
    /// @param lastScannedBlock The block the caller reports scanning past.
    function heartbeat(BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Recompute the quorum-scan frontier from current heartbeats and ratchet it up. Permissionless and
    ///         monotonic.
    function syncQuorumBlock() external;
    /// @notice The Unix timestamp of the last block `account`'s guardian reported scanning (0 if never, or not a
    ///         guardian/operator). `account` may be either the operator or the guardian key.
    /// @return timestamp The last-scanned block timestamp.
    function getHeartbeat(address account) external view returns (uint40 timestamp);
    /// @notice The current operator keys paired with each guardian's last-scanned block timestamp.
    /// @return operators  The current operator keys.
    /// @return timestamps Each guardian's last-scanned block timestamp, aligned by index with `operators`.
    function getHeartbeats() external view returns (address[] memory operators, uint40[] memory timestamps);
    /// @notice Highest block timestamp at least a quorum of guardians have ever scanned past. Monotonic.
    function getQuorumFrontier() external view returns (uint40);

    // ---
    // SIGNALLING
    // ---

    /// @notice Flag `accounts` in `marketId`. Callable by the seat's operator or its guardian; both write the same
    ///         seat, so an operator and its guardian flagging one account count as a single strike. Per account a no-op
    ///         when the seat already flags it, so a batch never reverts on a skip. When the caller is the operator,
    ///         `lastScannedBlock` also advances the seat's heartbeat; a guardian flagging does not.
    /// @param marketId         The market to flag in.
    /// @param accounts         The accounts to flag.
    /// @param lastScannedBlock The operator's heartbeat, validated like `heartbeat`; ignored when a guardian calls.
    function flag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Retract the seat's flags on `accounts` in `marketId`. Guardian-only. Per account a no-op when the seat
    ///         does not flag it. Never lifts a latched ban.
    function unflag(Id marketId, address[] calldata accounts) external;
    /// @notice Report `accounts` as suspect in `marketId`. Callable by the seat's operator or its guardian. A suspect
    ///         report never latches a ban; it raises the activation delay like a flag, but only while inside the
    ///         suspect window. When the caller is the operator, `lastScannedBlock` also advances the seat's heartbeat.
    /// @param lastScannedBlock The operator's heartbeat, validated like `heartbeat`; ignored when a guardian calls.
    function suspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Retract the seat's suspect reports on `accounts` in `marketId`. Guardian-only. Per account a no-op when
    ///         the seat has no live report on it.
    function unsuspect(Id marketId, address[] calldata accounts) external;
    /// @notice Permissionless: prune `account`'s flags and suspect reports in `marketId` cast by guardians that were
    ///         since removed, lowering the flag count. The pruned suspect reports leave the set, but the cached
    ///         suspect count the activation delay reads is re-derived only on the next `suspect`/`unsuspect`, not
    ///         here — so a pruned report keeps counting toward the delay until then. Never changes ban status.
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

    /// @notice The seats (by guardian key) currently flagging `account` in `marketId`.
    function getFlaggedBy(Id marketId, address account) external view returns (address[] memory);
    /// @notice The guardians with a live suspect report on `account` in `marketId`, paired with each report's
    /// timestamp. @param marketId    The market to read the signal in.
    /// @param account     The account to read.
    /// @return guardians  The seats (by guardian key) currently reporting the account as suspect.
    /// @return reportedAt The timestamp of each guardian's last suspect report, aligned by index with `guardians`.
    function getSuspectedBy(Id marketId, address account)
        external
        view
        returns (address[] memory guardians, uint40[] memory reportedAt);
}
