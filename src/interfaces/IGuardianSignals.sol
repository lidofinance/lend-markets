// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @title IGuardianSignals
/// @notice Guardian-committee signal layer over addresses. Guardians flag accounts per market; a `quorum`
///         of strikes latches a ban. The market controller reads `statusOf` to scale collateral
///         activation and to hard-block borrowing.
interface IGuardianSignals {
    /// @notice Guardian signal for an account in a market, reported raw: amnesty is flagged, not applied, so
    ///         the reader decides how to weigh it.
    /// @param strikes   distinct guardians flagging the account. Drives the activation surcharge while sub-quorum.
    /// @param banned    a guardian quorum latched a ban, or the committee banned.
    /// @param amnestied the committee vouched for the account. While set, a reader treats the strikes and ban
    ///                  as inert.
    struct Signal {
        uint16 strikes;
        bool banned;
        bool amnestied;
    }

    /* EVENTS */

    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event QuorumSet(uint256 quorum);
    event Flagged(Id indexed market, address indexed account, address indexed guardian, uint16 strikes);
    event Unflagged(Id indexed market, address indexed account, address indexed guardian, uint16 strikes);
    event Banned(Id indexed market, address indexed account);
    event Amnestied(Id indexed market, address indexed account, address indexed by);
    event AmnestyRevoked(Id indexed market, address indexed account, address indexed by);

    /* ERRORS */

    error ZeroAddress();
    error BadQuorum();
    error WouldBreakQuorum();
    error AlreadyGuardian();
    error NotGuardian();
    error MaxGuardiansReached();

    /* CONFIG */

    /// @notice Strikes that latch a ban.
    function getQuorum() external view returns (uint256);

    /* MEMBERSHIP (admin) */

    function addGuardian(address guardian) external;
    function removeGuardian(address guardian) external;
    function setQuorum(uint256 newQuorum) external;
    function isGuardian(address account) external view returns (bool);
    function getGuardianCount() external view returns (uint256);
    function getGuardians() external view returns (address[] memory);

    /* FLAGGING (guardians) */

    /// @notice Flag `account` in `market`. Idempotent: re-flagging an account the caller already flags does
    ///         nothing.
    function flag(Id market, address account) external;
    /// @notice Flag several `accounts` in `market` in one call; idempotent per account.
    function flagMany(Id market, address[] calldata accounts) external;
    /// @notice Retract the caller's own flag. Idempotent: unflagging an account the caller does not flag does
    ///         nothing. Does not lift a latched ban.
    function unflag(Id market, address account) external;
    /// @notice Retract the caller's flags on several `accounts` in one call; idempotent per account.
    function unflagMany(Id market, address[] calldata accounts) external;

    /* OVERRIDE (committee ban / amnesty) */

    /// @notice Force a ban on `account` in `market`, bypassing the quorum.
    function ban(Id market, address account) external;
    /// @notice Amnesty `account` in `market`: readers treat its strikes and ban as inert until
    ///         `revokeAmnesty`. Only `ban` can block again.
    function amnesty(Id market, address account) external;
    /// @notice Lift an amnesty, restoring the strikes and any standing ban for `account`.
    function revokeAmnesty(Id market, address account) external;

    /* VIEWS */

    /// @notice Raw guardian signal for `account` in `market`: strike count, ban, and amnesty. Amnesty is
    ///         reported, not applied — use `statusOf` for the effective view.
    function signalOf(Id market, address account) external view returns (Signal memory);
    /// @notice Effective status of `account` in `market` with amnesty applied: an amnestied account reads as
    ///         not banned with zero strikes. This is the view a gate consumes.
    function statusOf(Id market, address account) external view returns (bool isBanned, uint256 strikes);
}
