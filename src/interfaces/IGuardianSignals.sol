// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {BlockInfoWithHash} from "../types/GuardianSignalsTypes.sol";
import {IGuardianSignalsView} from "./IGuardianSignalsView.sol";

/// @title IGuardianSignals
/// @notice Guardian-committee signal layer over accounts, keyed per market. Guardians flag accounts they detect
///         as malicious. A `quorum` of distinct flags latches a ban in the market it was raised in. The minimal
///         read surface the market controller depends on (`getOpinion`, `isBanned`, `getFlagCount`) is
///         {IGuardianSignalsView}; this interface adds the full guardian/committee/governance surface on top.
interface IGuardianSignals is IGuardianSignalsView {
    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a guardian joins the set.
    event GuardianAdded(address indexed guardian);
    /// @notice Emitted when a guardian leaves the set.
    event GuardianRemoved(address indexed guardian);
    /// @notice Emitted when the quorum is set.
    event QuorumSet(uint256 quorum);
    /// @notice Emitted when the delay parameters are set.
    /// @param delayPerStrike  The activation-delay surcharge per flag.
    /// @param delayPerSuspect The activation-delay surcharge per fresh suspect report.
    /// @param maxDelay        The cap on the total guardian activation-delay surcharge (0 = uncapped).
    /// @param suspectWindow   The freshness horizon within which a suspect report still counts.
    event DelayParamsSet(uint256 delayPerStrike, uint256 delayPerSuspect, uint256 maxDelay, uint256 suspectWindow);
    /// @notice Emitted when a guardian reports liveness, directly or via `flag`/`unflag`.
    /// @param guardian    The guardian that reported.
    /// @param blockNumber The block number the guardian reports scanning past (carried for off-chain tooling).
    /// @param timestamp   The reported block's timestamp; the quorum-scan frontier orders guardians by this value.
    event Heartbeat(address indexed guardian, uint40 blockNumber, uint40 timestamp);
    /// @notice Emitted when a guardian reports an account as suspect (raises the activation delay, never bans).
    /// @param marketId  The market the report is scoped to.
    /// @param account   The suspected account.
    /// @param guardian  The reporting guardian.
    /// @param timestamp The report time, recorded so the report can be aged out of the suspect window.
    event Suspected(Id indexed marketId, address indexed account, address indexed guardian, uint256 timestamp);
    /// @notice Emitted when a guardian retracts its suspect report on an account.
    event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian);
    /// @notice Emitted when a suspect report cast by an address that is no longer a guardian is pruned.
    event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
    /// @notice Emitted when a guardian flags an account.
    /// @param marketId The market the flag is scoped to.
    /// @param account  The flagged account.
    /// @param guardian The flagging guardian.
    /// @param strikes  The account's flag count after the flag.
    event Flagged(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
    /// @notice Emitted when a guardian retracts a flag.
    event Unflagged(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
    /// @notice Emitted when a flag cast by an address that is no longer a guardian is pruned.
    event FlagPruned(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
    /// @notice Emitted when an account's ban latches, by quorum or by `ban`.
    event Banned(Id indexed marketId, address indexed account);
    /// @notice Emitted when an account's ban is lifted.
    /// @param by The `UNBAN_ROLE` holder that unbanned.
    event Unbanned(Id indexed marketId, address indexed account, address indexed by);
    /// @notice Emitted when an account is exempted.
    /// @param by The `IMMUNITY_GRANTER_ROLE` holder that granted immunity.
    event ImmunityGranted(Id indexed marketId, address indexed account, address indexed by);
    /// @notice Emitted when an account's immunity is removed.
    /// @param by The `IMMUNITY_REVOKER_ROLE` holder that revoked immunity.
    event ImmunityRevoked(Id indexed marketId, address indexed account, address indexed by);

    // ---
    // ERRORS
    // ---

    /// @notice Thrown when a zero address is passed where an account or guardian is required.
    error ZeroAddress();
    /// @notice Thrown when the quorum is zero or exceeds the guardian count.
    error BadQuorum();
    /// @notice Thrown when removing a guardian would drop the set below the quorum.
    error WouldBreakQuorum();
    /// @notice Thrown when adding a guardian already in the set.
    error AlreadyGuardian();
    /// @notice Thrown when the caller or target is not a guardian.
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
    /// @notice Thrown when the per-flag activation delay exceeds `MAX_DELAY_PER_STRIKE`.
    error DelayPerStrikeTooHigh();
    /// @notice Thrown when the per-suspect activation delay exceeds `MAX_DELAY_PER_STRIKE`.
    error DelayPerSuspectTooHigh();
    /// @notice Thrown when the suspect window exceeds `MAX_SUSPECT_WINDOW`.
    error SuspectWindowTooHigh();

    // ---
    // GUARDIANS & CONFIG (admin)
    // ---

    /// @notice Add a guardian to the set.
    /// @param guardian The address to add. Must be non-zero, not already a guardian, and within `MAX_GUARDIANS_COUNT`.
    function addGuardian(address guardian) external;
    /// @notice Remove a guardian from the set. Reverts if it would drop the set below the quorum.
    /// @param guardian The guardian to remove. Reverts if not currently a guardian.
    function removeGuardian(address guardian) external;
    /// @notice Set the quorum — the distinct flags that latch a ban. Reverts if zero or above the guardian count.
    /// @param newQuorum The new quorum.
    function setQuorum(uint256 newQuorum) external;
    /// @notice Set the delay parameters. Reverts if a per-signal delay exceeds `MAX_DELAY_PER_STRIKE` or the
    ///         window exceeds `MAX_SUSPECT_WINDOW`. Never touches the guardian set.
    /// @param delayPerStrike  The activation-delay surcharge per flag.
    /// @param delayPerSuspect The activation-delay surcharge per fresh suspect report.
    /// @param maxDelay        The cap on the total guardian activation-delay surcharge (0 = uncapped).
    /// @param suspectWindow   The freshness horizon within which a suspect report still counts.
    function setDelayParams(uint256 delayPerStrike, uint256 delayPerSuspect, uint256 maxDelay, uint256 suspectWindow)
        external;
    /// @notice The quorum: distinct flags that latch a ban.
    function getQuorum() external view returns (uint256);
    /// @notice The delay parameters: per-flag and per-suspect surcharge, the total-delay cap, and the suspect
    ///         window.
    function getDelayParams()
        external
        view
        returns (uint256 delayPerStrike, uint256 delayPerSuspect, uint256 maxDelay, uint256 suspectWindow);
    /// @notice Whether `account` is a guardian.
    function isGuardian(address account) external view returns (bool);
    /// @notice The number of guardians in the set.
    function getGuardianCount() external view returns (uint256);
    /// @notice The current guardian set.
    function getGuardians() external view returns (address[] memory);

    // ---
    // LIVENESS
    // ---

    /// @notice Record the caller's last-scanned block, validated against its block hash and timestamp. O(1): the
    ///         quorum frontier is recomputed separately by `syncQuorumBlock`. Caller must be a guardian.
    /// @param lastScannedBlock The block the caller reports scanning past. Reverts if `number` exceeds the current
    ///        block, if `hash` does not match `blockhash(number)`, if `timestamp` exceeds the current block, or if
    ///        `timestamp` is below the caller's previous heartbeat.
    function heartbeat(BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Recompute the quorum-scan frontier from current heartbeats and ratchet it up. Permissionless and
    ///         monotonic.
    function syncQuorumBlock() external;
    /// @notice The timestamp of the last block `guardian` reported scanning.
    function getHeartbeat(address guardian) external view returns (uint40);
    /// @notice The guardian set paired with each guardian's last-scanned timestamp.
    function getHeartbeats() external view returns (address[] memory guardians, uint40[] memory heartbeats);
    /// @notice Highest timestamp at least a quorum of guardians have ever scanned past. Monotonic.
    function getQuorumFrontier() external view returns (uint40);

    // ---
    // FLAGGING (guardians)
    // ---

    /// @notice Flag `accounts` in `marketId`, then heartbeat. Per account a no-op when the caller already flags it
    ///         or it is immune, so a batch never reverts on a skip.
    /// @param marketId         The market to flag in.
    /// @param accounts         The accounts to flag. A zero address in the batch reverts.
    /// @param lastScannedBlock The heartbeat recorded for the caller after flagging, validated like `heartbeat`.
    function flag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Retract the caller's flags on `accounts` in `marketId`, then heartbeat. Per account a no-op when the
    ///         caller does not flag it or it is immune. Never lifts a latched ban.
    function unflag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Report `accounts` as suspect in `marketId`, then heartbeat. A suspect report never latches a ban; it
    ///         raises the activation delay like a flag, but only while inside the suspect window. Per account a
    ///         no-op when immune.
    function reportSuspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external;
    /// @notice Retract the caller's suspect reports on `accounts` in `marketId`, then heartbeat. Per account a
    ///         no-op when the caller has no live report on it.
    function clearSuspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external;
    /// @notice Permissionless: prune `account`'s flags and suspect reports in `marketId` cast by addresses that are
    ///         no longer guardians. Lowers the flag/suspect count but never changes status.
    function prune(Id marketId, address account) external;

    // ---
    // OVERRIDE (committee / governance)
    // ---

    /// @notice Force a ban on `account` in `marketId`, bypassing the quorum. Clears any immunity.
    function ban(Id marketId, address account) external;
    /// @notice Lift the ban on `account` in `marketId`: reset its status to `Normal` and clear its flags. Immunity
    ///         is managed with `grantImmunity` / `revokeImmunity`.
    function unban(Id marketId, address account) external;
    /// @notice Exempt `account` from guardian signals in `marketId`. While immune, `flag`/`unflag` no-op and
    ///         readers see it as clean. Cleared by `revokeImmunity` or `ban`.
    function grantImmunity(Id marketId, address account) external;
    /// @notice Remove `account`'s immunity in `marketId`, re-subjecting it to guardian signals.
    function revokeImmunity(Id marketId, address account) external;

    // ---
    // VIEWS
    // ---

    /// @notice The collateral-activation delay surcharge for `account` in `marketId`: `type(uint256).max` when
    ///         banned, 0 when immune, else the capped flag + fresh-suspect surcharge.
    function getActivationDelay(Id marketId, address account) external view returns (uint256);
    /// @notice Whether `account` is immune (exempt from guardian signals) in `marketId`.
    function isImmune(Id marketId, address account) external view returns (bool);
    /// @notice The guardians currently flagging `account` in `marketId`.
    function getFlaggedBy(Id marketId, address account) external view returns (address[] memory);
    /// @notice The guardians with a live suspect report on `account` in `marketId`, paired with each report's
    ///         timestamp.
    /// @param marketId    The market to read the signal in.
    /// @param account     The account to read.
    /// @return guardians  The addresses of guardians currently reporting the account as suspect.
    /// @return reportedAt The timestamp of each guardian's last suspect report, aligned by index with `guardians`.
    function getSuspectedBy(Id marketId, address account)
        external
        view
        returns (address[] memory guardians, uint40[] memory reportedAt);
}
