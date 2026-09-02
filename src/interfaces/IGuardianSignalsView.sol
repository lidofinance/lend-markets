// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {GuardiansOpinion} from "../types/GuardianSignalsTypes.sol";

/// @title IGuardianSignalsView
/// @notice The minimal read surface of a guardian-signal registry that the controller depends on: one bundled
///         per-account read plus the cheap ban bit, both keyed by market. The full guardian/committee/governance
///         surface lives in `IGuardianSignals`, which extends this.
interface IGuardianSignalsView {
    /// @notice Everything the controller needs about `account` in `marketId` in one call: the ban gate, the raw
    ///         signal counters the activation lib turns into a delay, and the quorum-scan frontier timestamp.
    /// @param marketId The market to read the signal in.
    /// @param account The account to read.
    /// @return The account's bundled signal state.
    function getOpinion(Id marketId, address account) external view returns (GuardiansOpinion memory);
    /// @notice Whether `account` is banned in `marketId`: the hard block on borrowing. True when the ban is
    ///         latched or the flag count is at or above the current quorum.
    /// @param marketId The market to read the signal in.
    /// @param account The account to read.
    /// @return Whether the account is banned.
    function isBanned(Id marketId, address account) external view returns (bool);
}
