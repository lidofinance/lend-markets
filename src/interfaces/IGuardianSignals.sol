// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @title IGuardianSignals
/// @notice Guardian-committee signal layer over accounts, keyed per market. Guardians flag accounts they
///         detect as malicious. A `quorum` of distinct flags latches a ban. The market controller reads
///         `getStatus` to scale collateral activation and to hard-block borrowing.
interface IGuardianSignals {
    /* EVENTS */

    /// @notice Emitted when a guardian joins the set.
    event GuardianAdded(address indexed guardian);
    /// @notice Emitted when a guardian leaves the set.
    event GuardianRemoved(address indexed guardian);
    /// @notice Emitted when the quorum changes.
    /// @param quorum The number of distinct flags that latches a ban.
    event QuorumSet(uint256 quorum);
    /// @notice Emitted when a guardian reports liveness, directly or via `flag`/`unflag`.
    event Heartbeat(address indexed guardian);
    /// @notice Emitted when a guardian flags an account.
    /// @param market   The market id.
    /// @param account  The flagged account.
    /// @param guardian The flagging guardian.
    /// @param strikes  The account's flag count after the flag.
    event Flagged(Id indexed market, address indexed account, address indexed guardian, uint16 strikes);
    /// @notice Emitted when a guardian retracts a flag.
    /// @param market   The market id.
    /// @param account  The account.
    /// @param guardian The retracting guardian.
    /// @param strikes  The account's flag count after the retraction.
    event Unflagged(Id indexed market, address indexed account, address indexed guardian, uint16 strikes);
    /// @notice Emitted when an account's ban latches, by quorum or by `ban`.
    event Banned(Id indexed market, address indexed account);
    /// @notice Emitted when an account's ban is lifted.
    /// @param by The `GOVERNANCE_ROLE` holder that unbanned.
    event Unbanned(Id indexed market, address indexed account, address indexed by);
    /// @notice Emitted when an account is exempted.
    /// @param by The `GOVERNANCE_ROLE` holder that granted immunity.
    event ImmunityGranted(Id indexed market, address indexed account, address indexed by);
    /// @notice Emitted when an account's immunity is removed.
    /// @param by The `RISK_STEWARD_ROLE` holder that revoked immunity.
    event ImmunityRevoked(Id indexed market, address indexed account, address indexed by);

    /* ERRORS */

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

    /* MEMBERSHIP & QUORUM (admin) */

    /// @notice The number of distinct flags that latches a ban.
    function getQuorum() external view returns (uint256);
    /// @notice Add a guardian to the set.
    function addGuardian(address guardian) external;
    /// @notice Remove a guardian from the set. Reverts if it would drop the set below the quorum.
    function removeGuardian(address guardian) external;
    /// @notice Set the quorum. Reverts unless `1 <= newQuorum <= guardian count`.
    function setQuorum(uint256 newQuorum) external;
    /// @notice Whether `account` is a guardian.
    function isGuardian(address account) external view returns (bool);
    /// @notice The number of guardians in the set.
    function getGuardianCount() external view returns (uint256);
    /// @notice The current guardian set.
    function getGuardians() external view returns (address[] memory);

    /* LIVENESS */

    /// @notice Record the caller's last-scanned block (clamped to `block.number`). O(1): the quorum frontier
    ///         is recomputed separately by `syncQuorumBlock`.
    function heartbeat(uint256 lastScannedBlock) external;
    /// @notice Recompute the quorum-scan frontier from current heartbeats and ratchet it up. Permissionless
    ///         and monotonic — anyone may advance it (a keeper per scan frame, or a borrower whose activation
    ///         depends on it). Decoupled from `heartbeat` so heartbeats stay O(1).
    function syncQuorumBlock() external;
    /// @notice The last block `guardian` reported scanning.
    function getHeartbeat(address guardian) external view returns (uint256);
    /// @notice The guardian set paired with each guardian's last-scanned block.
    function getHeartbeats() external view returns (address[] memory guardians, uint256[] memory heartbeats);
    /// @notice Highest block at least a quorum of guardians have ever scanned past. Monotonic: a guardian
    ///         rotation cannot lower it.
    function getLastScannedQuorumBlock() external view returns (uint256);

    /* FLAGGING (guardians) */

    /// @notice Flag `accounts` in `market`, then heartbeat. Per account a no-op when the caller already flags
    ///         it or it is immune, so a batch never reverts on a skip.
    function flag(Id market, address[] calldata accounts, uint256 lastScannedBlock) external;
    /// @notice Retract the caller's flags on `accounts` in `market`, then heartbeat. Per account a no-op when
    ///         the caller does not flag it or it is immune. Never lifts a latched ban.
    function unflag(Id market, address[] calldata accounts, uint256 lastScannedBlock) external;

    /* OVERRIDE (committee / governance) */

    /// @notice Force a ban on `account` in `market`, bypassing the quorum. Clears any immunity.
    function ban(Id market, address account) external;
    /// @notice Lift the ban on `account` in `market` and clear its flags, so guardians re-evaluate from
    ///         scratch and can re-ban it. Leaves immunity untouched.
    function unban(Id market, address account) external;
    /// @notice Exempt `account` in `market` from guardian signals. While immune, `flag`/`unflag` no-op and
    ///         `getStatus` reads it as clean. Cleared by `revokeImmunity` or `ban`.
    function grantImmunity(Id market, address account) external;
    /// @notice Remove `account`'s immunity in `market`, re-subjecting it to guardian signals.
    function revokeImmunity(Id market, address account) external;

    /* VIEWS */

    /// @notice Effective status of `account` in `market`, immunity applied: an immune account reads as not
    ///         banned with zero strikes. The view a gate consumes.
    /// @return isBanned Whether borrowing is hard-blocked.
    /// @return strikes  The flag count the reader scales the activation delay by.
    function getStatus(Id market, address account) external view returns (bool isBanned, uint256 strikes);
    /// @notice Raw signal for `account` in `market`. `isImmune` is reported, not applied — use `getStatus`
    ///         for the effective view.
    function getSignal(Id market, address account) external view returns (bool isImmune, bool isBanned, uint256 strikes);
}
