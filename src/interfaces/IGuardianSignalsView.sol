// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {GuardiansOpinion} from "../types/GuardianSignalsTypes.sol";

/// @title IGuardianSignalsView
/// @notice The minimal read surface of a guardian-signal registry that the controller depends on: one bundled
///         per-account read plus the cheap ban bit, both keyed by market. The full guardian/committee/governance
///         surface lives in {IGuardianSignals}, which extends this.
interface IGuardianSignalsView {
    /// @notice Everything the controller needs about `account` in `marketId` in one call: the ban gate, the
    ///         activation-delay surcharge, and the quorum-scan frontier timestamp.
    /// @param marketId The market to read the signal in.
    /// @param account  The account to read.
    /// @return The account's bundled signal state.
    function getOpinion(Id marketId, address account) external view returns (GuardiansOpinion memory);
    /// @notice Whether `account` is banned in `marketId`. The cheap single-bit check for the borrow hard-block on
    ///         the caller and receiver (where the full bundle is not needed).
    /// @param marketId The market to read the signal in.
    /// @param account  The account to read.
    /// @return True if the account's status is `Banned`.
    function isBanned(Id marketId, address account) external view returns (bool);
    /// @notice The number of guardians currently flagging `account` in `marketId`. Read on its own by the position
    ///         dashboard; not part of the hot-path `getOpinion` bundle.
    /// @param marketId The market to read the signal in.
    /// @param account  The account to read.
    /// @return The raw flag count.
    function getFlagCount(Id marketId, address account) external view returns (uint256);
}
