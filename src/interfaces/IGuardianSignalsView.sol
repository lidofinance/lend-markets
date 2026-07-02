// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {GuardiansOpinion} from "../types/GuardianSignalsTypes.sol";

/// @title IGuardianSignalsView
/// @notice The minimal read surface of a market's guardian-signal registry that the controller depends on: one
///         bundled per-account read plus the cheap ban bit. The full guardian/committee/governance surface lives
///         in {IGuardianSignals}, which extends this.
interface IGuardianSignalsView {
    /// @notice Everything the controller needs about `account` in one call: the ban gate, the activation-delay
    ///         surcharge, and the quorum-scan frontier timestamp.
    /// @param account The account to read.
    /// @return The account's bundled signal state.
    function getOpinion(address account) external view returns (GuardiansOpinion memory);
    /// @notice Whether `account` is banned. The cheap single-bit check for the borrow hard-block on the caller
    ///         and receiver (where the full bundle is not needed).
    /// @param account The account to read.
    /// @return True if the account's status is `Banned`.
    function isBanned(address account) external view returns (bool);
    /// @notice The number of guardians currently flagging `account`. Read on its own by the position dashboard;
    ///         not part of the hot-path `getOpinion` bundle.
    /// @param account The account to read.
    /// @return The raw flag count.
    function getFlagCount(address account) external view returns (uint256);
}
