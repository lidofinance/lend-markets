// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.35;

/// @title IPausableUntil
/// @notice Pause-state views of `PausableUntil`.
interface IPausableUntil {
    /// @notice Whether the contract is currently paused.
    function isPaused() external view returns (bool);

    /// @notice The timestamp at which the contract resumes: `PAUSE_INFINITELY` when paused indefinitely, a
    ///         future timestamp when paused for a duration, or a past timestamp when not paused.
    function getResumeSinceTimestamp() external view returns (uint256);
}
