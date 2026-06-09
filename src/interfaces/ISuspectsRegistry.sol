// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Id} from "@lido-blue/src/interfaces/IMorpho.sol";

/// @title ISuspectsRegistry
/// @notice Guardian-committee suspect registry. Guardians flag suspect addresses; `quorum` flags
///         latch a ban. The market controller reads `suspicion` and `isBanned` to scale collateral
///         maturation and to hard-block borrowing. `EVERY_MARKET` flags apply to every market.
interface ISuspectsRegistry {
    /* EVENTS */

    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event QuorumSet(uint256 quorum);
    event Flagged(Id indexed market, address indexed suspect, address indexed guardian, uint16 flags);
    event Unflagged(Id indexed market, address indexed suspect, address indexed guardian, uint16 flags);
    event Banned(Id indexed market, address indexed suspect);
    event Unbanned(Id indexed market, address indexed suspect, address indexed by);

    /* ERRORS */

    error ZeroAddress();
    error BadQuorum();
    error WouldBreakQuorum();
    error AlreadyGuardian();
    error NotGuardian();
    error AlreadyFlagged();
    error NotFlagged();

    /* CONFIG */

    /// @notice Flags that take suspicion to 100 and latch a ban.
    function quorum() external view returns (uint256);

    /* MEMBERSHIP (admin) */

    function addGuardian(address guardian) external;
    function removeGuardian(address guardian) external;
    function setQuorum(uint256 newQuorum) external;
    function isGuardian(address account) external view returns (bool);
    function guardianCount() external view returns (uint256);
    function guardians() external view returns (address[] memory);

    /* FLAGGING (guardians) */

    /// @notice Flag `suspect` in `market` (use `EVERY_MARKET` for a global flag).
    function flag(Id market, address suspect) external;
    /// @notice Retract the caller's own flag. Does not lift a latched ban.
    function unflag(Id market, address suspect) external;

    /* OVERRIDE (single-handed ban / unban) */

    /// @notice Force a ban on `suspect` in `market`, bypassing the quorum.
    function ban(Id market, address suspect) external;
    /// @notice Clear the ban and all flags for `suspect` in `market`.
    function unban(Id market, address suspect) external;

    /* VIEWS */

    /// @notice Suspicion of `suspect` for `market`, 0 (clean) to 100 (fully suspect), folding the
    ///         per-market and global (`EVERY_MARKET`) score (dirtier wins). Returns 100 when banned,
    ///         so a single read drives the controller's maturation delay.
    function suspicion(Id market, address suspect) external view returns (uint256);
    /// @notice True if `suspect` is banned for `market`, directly or globally.
    function isBanned(Id market, address suspect) external view returns (bool);
    /// @notice Live flag count on a single `(market, suspect)`, no global folding.
    function flagsOf(Id market, address suspect) external view returns (uint16);
}
