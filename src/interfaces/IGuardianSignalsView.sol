// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @title IGuardianSignalsView
/// @notice The minimal read surface of the guardian-signal registry that the market controller depends on:
///         the ban gate and the activation-gate inputs. The full guardian/committee/governance surface lives in
///         {IGuardianSignals}, which extends this.
interface IGuardianSignalsView {
    /// @notice The two guardian-owned inputs the controller's activation gate needs, in one call: the account's
    ///         activation-delay surcharge and the market's quorum-scan frontier timestamp.
    /// @param marketId The market id to read.
    /// @param account  The account to read.
    /// @return activationDelay      The activation-delay surcharge (`type(uint256).max` when banned).
    /// @return quorumBlockTimestamp The market's quorum-scan frontier timestamp.
    function getActivationSyncInputs(Id marketId, address account)
        external
        view
        returns (uint256 activationDelay, uint256 quorumBlockTimestamp);
    /// @notice The collateral-activation delay surcharge for `account` in `marketId`: `type(uint256).max` when
    ///         banned, 0 when immune, else the capped flag + fresh-suspect surcharge.
    /// @param marketId The market id to read.
    /// @param account  The account to read.
    /// @return The activation-delay surcharge in seconds (or `type(uint256).max` for a banned account).
    function getActivationDelay(Id marketId, address account) external view returns (uint256);
    /// @notice Whether `account` is banned in `marketId`. Consumed by the controller's borrow hard-block.
    /// @param marketId The market id to read.
    /// @param account  The account to read.
    /// @return True if the account's status is `Banned`.
    function isBanned(Id marketId, address account) external view returns (bool);
    /// @notice The number of guardians currently flagging `account` in `marketId`.
    /// @param marketId The market id to read.
    /// @param account  The account to read.
    /// @return The raw flag count.
    function getFlagCount(Id marketId, address account) external view returns (uint256);
}
