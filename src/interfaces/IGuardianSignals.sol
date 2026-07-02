// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {BlockInfo, BlockInfoWithHash, GuardianMarketConfig, GuardiansOpinion} from "../types/GuardianSignalsTypes.sol";
import {IGuardianSignalsView} from "./IGuardianSignalsView.sol";

/// @title IGuardianSignals
/// @notice Guardian-committee signal layer over accounts, keyed per market. Each market has its own guardian
///         set, quorum, and liveness frontier, configured per market. Guardians flag accounts they detect as
///         malicious. A `quorum` of distinct flags latches a ban. The minimal read surface the market controller
///         depends on (`isBanned`, `getActivationSyncInputs`, ...) is {IGuardianSignalsView}; this interface adds
///         the full guardian/committee/governance surface on top.
interface IGuardianSignals is IGuardianSignalsView {
    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a guardian joins a market's set.
    event GuardianAdded(Id indexed marketId, address indexed guardian);
    /// @notice Emitted when a guardian leaves a market's set.
    event GuardianRemoved(Id indexed marketId, address indexed guardian);
    /// @notice Emitted when a market's guardian configuration is set via `setMarketConfig`.
    /// @param marketId       The market id.
    /// @param quorum         The distinct flags that latch a ban.
    /// @param delayPerStrike  The activation-delay surcharge per flag.
    /// @param delayPerSuspect The activation-delay surcharge per fresh suspect report.
    /// @param maxDelay        The cap on the total guardian activation-delay surcharge (0 = uncapped).
    /// @param suspectWindow   The freshness horizon within which a suspect report still counts.
    event MarketConfigSet(
        Id indexed marketId,
        uint256 quorum,
        uint256 delayPerStrike,
        uint256 delayPerSuspect,
        uint256 maxDelay,
        uint256 suspectWindow
    );
    /// @notice Emitted when a guardian reports liveness for a market, directly or via `flag`/`unflag`.
    /// @param marketId    The market id.
    /// @param guardian    The guardian that reported.
    /// @param blockNumber The block number the guardian reports scanning past (carried for off-chain tooling).
    /// @param timestamp   The reported block's timestamp; the quorum-scan frontier orders guardians by this value.
    event Heartbeat(Id indexed marketId, address indexed guardian, uint40 blockNumber, uint40 timestamp);
    /// @notice Emitted when a guardian reports an account as suspect (raises the activation delay, never bans).
    /// @param marketId    The market id.
    /// @param account   The suspected account.
    /// @param guardian  The reporting guardian.
    /// @param timestamp The report time, recorded so the report can be aged out of the suspect window.
    event Suspected(Id indexed marketId, address indexed account, address indexed guardian, uint256 timestamp);
    /// @notice Emitted when a guardian retracts its suspect report on an account.
    event SuspectCleared(Id indexed marketId, address indexed account, address indexed guardian);
    /// @notice Emitted when a suspect report cast by an address that is no longer a guardian is pruned.
    event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);
    /// @notice Emitted when a guardian flags an account.
    /// @param marketId   The market id.
    /// @param account  The flagged account.
    /// @param guardian The flagging guardian.
    /// @param strikes  The account's flag count after the flag.
    event Flagged(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
    /// @notice Emitted when a guardian retracts a flag.
    /// @param marketId   The market id.
    /// @param account  The account.
    /// @param guardian The retracting guardian.
    /// @param strikes  The account's flag count after the retraction.
    event Unflagged(Id indexed marketId, address indexed account, address indexed guardian, uint16 strikes);
    /// @notice Emitted when a flag cast by an address that is no longer a guardian is pruned.
    /// @param marketId   The market id.
    /// @param account  The account.
    /// @param guardian The former guardian whose flag was pruned.
    /// @param strikes  The account's flag count after this flag was pruned.
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
    /// @notice Thrown when a market's per-flag activation delay exceeds `MAX_DELAY_PER_STRIKE`.
    error DelayPerStrikeTooHigh();
    /// @notice Thrown when a market's per-suspect activation delay exceeds `MAX_DELAY_PER_STRIKE`.
    error DelayPerSuspectTooHigh();
    /// @notice Thrown when a market's suspect window exceeds `MAX_SUSPECT_WINDOW`.
    error SuspectWindowTooHigh();

    // ---
    // MEMBERSHIP & QUORUM (admin, per market)
    // ---

    /// @notice The per-market instance of a base role. Granting it to an account authorizes that account for
    ///         `marketId` only; the global base role authorizes every market. The override calls (`ban` →
    ///         `BAN_ROLE`, `unban` → `UNBAN_ROLE`, `grantImmunity` → `IMMUNITY_GRANTER_ROLE`, `revokeImmunity` →
    ///         `IMMUNITY_REVOKER_ROLE`) and the guardian-config calls (`GUARDIANS_MANAGER_ROLE`) all accept the
    ///         global base role or its per-market instance.
    /// @param baseRole The base role (one of the override roles or `GUARDIANS_MANAGER_ROLE`).
    /// @param marketId The market to scope the role to.
    /// @return The derived role id to grant/revoke via `grantRole`/`revokeRole`.
    function marketRole(bytes32 baseRole, Id marketId) external pure returns (bytes32);
    /// @notice Set a market's full guardian configuration in one call: replace the guardian set, then set the
    ///         quorum, the per-flag and per-suspect activation delays, the total-delay cap, and the suspect
    ///         window. Reverts if a per-signal delay exceeds `MAX_DELAY_PER_STRIKE`, the window exceeds
    ///         `MAX_SUSPECT_WINDOW`, or the quorum is out of range for the new roster.
    /// @param marketId The market id to configure.
    /// @param config   The full per-market guardian configuration.
    function setMarketConfig(Id marketId, GuardianMarketConfig calldata config) external;
    /// @notice A market's full guardian configuration.
    /// @param marketId The market id to read.
    /// @return The market's guardian set, quorum, per-flag and per-suspect delays, and suspect window.
    function getMarketConfig(Id marketId) external view returns (GuardianMarketConfig memory);
    /// @notice Add a guardian to a market's set.
    /// @param marketId The market id to add to.
    /// @param guardian The address to add. Must be non-zero, not already a guardian, and within `MAX_GUARDIANS_COUNT`.
    function addGuardian(Id marketId, address guardian) external;
    /// @notice Remove a guardian from a market's set. Reverts if it would drop the set below the market's quorum.
    /// @param marketId The market id to remove from.
    /// @param guardian The guardian to remove. Reverts if not currently a guardian of the market.
    function removeGuardian(Id marketId, address guardian) external;
    /// @notice Whether `account` is a guardian of `marketId`.
    /// @param marketId  The market id to check.
    /// @param account The address to check.
    /// @return True if `account` is in the market's guardian set.
    function isGuardian(Id marketId, address account) external view returns (bool);
    /// @notice The number of guardians in a market's set.
    /// @param marketId The market id to read.
    /// @return The market's guardian count.
    function getGuardianCount(Id marketId) external view returns (uint256);
    /// @notice A market's current guardian set.
    /// @param marketId The market id to read.
    /// @return The list of guardian addresses for the market.
    function getGuardians(Id marketId) external view returns (address[] memory);

    // ---
    // LIVENESS
    // ---

    /// @notice Record the caller's last-scanned block for `marketId`, validated against its block hash and
    ///         timestamp. O(1): the quorum frontier is recomputed separately by `syncQuorumBlock`. Caller must be
    ///         a market guardian.
    /// @param marketId         The market id the caller reports liveness for.
    /// @param lastScannedBlock The block the caller reports scanning past. Reverts if `number` exceeds the current
    ///        block, if `hash` does not match `blockhash(number)`, if `timestamp` exceeds the current block, or if
    ///        `timestamp` is below the caller's previous heartbeat. Only the caller (a guardian) is recorded.
    function heartbeat(Id marketId, BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Recompute a market's quorum-scan frontier from current heartbeats and ratchet it up. Permissionless
    ///         and monotonic — anyone may advance it (an off-chain agent per scan frame, or a borrower whose
    ///         activation depends on it). Decoupled from `heartbeat` so heartbeats stay O(1).
    /// @param marketId The market id whose frontier is recomputed.
    function syncQuorumBlock(Id marketId) external;
    /// @notice The last block `guardian` reported scanning for `marketId`.
    /// @param marketId   The market id to read.
    /// @param guardian The guardian to query.
    /// @return The guardian's last-scanned block. Zero-valued if the guardian has never reported a heartbeat.
    function getHeartbeat(Id marketId, address guardian) external view returns (BlockInfo memory);
    /// @notice A market's guardian set paired with each guardian's last-scanned block.
    /// @param marketId The market id to read.
    /// @return guardians  The market's current guardian set.
    /// @return heartbeats The last-scanned block of each guardian, aligned by index with `guardians`.
    function getHeartbeats(Id marketId)
        external
        view
        returns (address[] memory guardians, BlockInfo[] memory heartbeats);
    /// @notice Highest block at least a quorum of a market's guardians have ever scanned past. Monotonic: a
    ///         guardian rotation cannot lower it.
    /// @param marketId The market id to read.
    /// @return The market's quorum-scan frontier as last ratcheted by `syncQuorumBlock`.
    function getLastScannedQuorumBlock(Id marketId) external view returns (BlockInfo memory);

    // ---
    // FLAGGING (guardians)
    // ---

    /// @notice Flag `accounts` in `marketId`, then heartbeat. Per account a no-op when the caller already flags
    ///         it or it is immune, so a batch never reverts on a skip.
    /// @param marketId           The market id the accounts are flagged in.
    /// @param accounts         The accounts to flag. A zero address in the batch reverts. Each one a no-op when
    ///        already flagged by the caller or immune.
    /// @param lastScannedBlock The heartbeat recorded for the caller after flagging, validated like `heartbeat`.
    function flag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Retract the caller's flags on `accounts` in `marketId`, then heartbeat. Per account a no-op when
    ///         the caller does not flag it or it is immune. Never lifts a latched ban.
    /// @param marketId           The market id the flags are retracted in.
    /// @param accounts         The accounts to unflag. Each one a no-op when not flagged by the caller or immune.
    /// @param lastScannedBlock The heartbeat recorded for the caller after retracting, validated like `heartbeat`.
    function unflag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock) external;
    /// @notice Report `accounts` in `marketId` as suspect, then heartbeat. A suspect report never latches a ban;
    ///         it raises the activation delay like a flag, but only while inside the market's suspect window.
    ///         Records (or refreshes) the caller's report timestamp. Per account a no-op when immune.
    /// @param marketId           The market id the accounts are reported in.
    /// @param accounts         The accounts to report. A zero address in the batch reverts.
    /// @param lastScannedBlock The heartbeat recorded for the caller after reporting, validated like `heartbeat`.
    function reportSuspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external;
    /// @notice Retract the caller's suspect reports on `accounts` in `marketId`, then heartbeat. Per account a
    ///         no-op when the caller has no live report on it.
    /// @param marketId           The market id the reports are retracted in.
    /// @param accounts         The accounts to clear.
    /// @param lastScannedBlock The heartbeat recorded for the caller after clearing, validated like `heartbeat`.
    function clearSuspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external;
    /// @notice Permissionless: prune `account`'s flags and suspect reports cast by addresses that are no longer
    ///         guardians. Lowers the flag/suspect count (and, below quorum, the activation surcharge) but never
    ///         changes status — a latched ban lifts only through `unban`, so this is not a permissionless unban.
    function prune(Id marketId, address account) external;

    // ---
    // OVERRIDE (committee / governance)
    // ---

    /// @notice Force a ban on `account` in `marketId`, bypassing the quorum. Clears any immunity.
    /// @param marketId  The market id the ban applies in.
    /// @param account The account to ban. Reverts on the zero address.
    function ban(Id marketId, address account) external;
    /// @notice Lift the ban on `account` in `marketId`: reset its status to `Normal` and clear its flags, so
    ///         guardians re-evaluate from scratch and can re-ban it. Resetting to `Normal` also clears a
    ///         standing immunity, so manage immunity with `grantImmunity` / `revokeImmunity`.
    /// @param marketId  The market id the ban is lifted in.
    /// @param account The account to unban. Its status returns to `Normal` and its flagger set is cleared.
    function unban(Id marketId, address account) external;
    /// @notice Exempt `account` in `marketId` from guardian signals. While immune, `flag`/`unflag` no-op and
    ///         `getOpinion` reads it as clean. Cleared by `revokeImmunity` or `ban`.
    /// @param marketId  The market id the immunity applies in.
    /// @param account The account to exempt. Reverts on the zero address. Its status is set to `Immune`.
    function grantImmunity(Id marketId, address account) external;
    /// @notice Remove `account`'s immunity in `marketId`, re-subjecting it to guardian signals.
    /// @param marketId  The market id the immunity is revoked in.
    /// @param account The account whose immunity is removed. Its status returns to `Normal`.
    function revokeImmunity(Id marketId, address account) external;

    // ---
    // VIEWS
    // ---

    /// @notice Guardian opinion on `account` in `marketId`: status, strike count, and the quorum-scan frontier.
    ///         The view the controller's activation gate consumes.
    /// @param marketId  The market id to read.
    /// @param account The account to read.
    /// @return The opinion: latched status, effective strikes (forced to 0 while `Immune`), raw flag count, and
    ///         the quorum-scan frontier.
    function getOpinion(Id marketId, address account) external view returns (GuardiansOpinion memory);
    /// @notice The guardians currently flagging `account` in `marketId`.
    /// @param marketId  The market id to read.
    /// @param account The account to read.
    /// @return The addresses of guardians currently flagging the account.
    function getFlaggedBy(Id marketId, address account) external view returns (address[] memory);
    /// @notice The guardians with a live suspect report on `account` in `marketId`, paired with each report's
    ///         timestamp, regardless of window freshness.
    /// @param marketId The market id to read.
    /// @param account  The account to read.
    /// @return guardians  The addresses of guardians currently reporting the account as suspect.
    /// @return reportedAt The timestamp of each guardian's last suspect report, aligned by index with `guardians`.
    function getSuspectedBy(Id marketId, address account)
        external
        view
        returns (address[] memory guardians, uint40[] memory reportedAt);
}
