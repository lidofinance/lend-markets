// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {GuardiansOpinion} from "../types/GuardianSignalsTypes.sol";

/// @title IGuardianSignalsView
/// @notice The minimal read surface of a guardian-signal registry: one bundled per-account read plus the cheap
///         ban bit, both keyed by market.
interface IGuardianSignalsView {
    /// @notice One read of `account`'s bundled signal state in `marketId`: the ban bit, the raw signal
    ///         counters, and the quorum-scan frontier timestamp.
    /// @param marketId The market to read the signal in.
    /// @param account The account to read.
    /// @return The account's bundled signal state.
    function getOpinion(Id marketId, address account) external view returns (GuardiansOpinion memory);

    /// @notice Whether `account` is banned in `marketId`. True when the ban is latched or the flag count is at
    ///         or above the current quorum.
    /// @param marketId The market to read the signal in.
    /// @param account The account to read.
    /// @return Whether the account is banned.
    function isBanned(Id marketId, address account) external view returns (bool);
}
