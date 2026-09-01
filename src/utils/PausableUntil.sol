// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.36;

import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

import {IPausableUntil} from "../interfaces/IPausableUntil.sol";

/// @title PausableUntil
/// @notice Pauses the contract for a duration or indefinitely.
abstract contract PausableUntil is IPausableUntil {
    using StorageSlot for bytes32;

    // ---
    // CONSTANTS
    // ---

    /// @dev Fixed slot holding the timestamp at which the contract resumes. A `block.timestamp` in the
    ///      future means paused, in the past or present means resumed. Hashed slot keeps it clear of the
    ///      sequential storage layout so it survives across upgrades.
    bytes32 internal constant RESUME_SINCE_TIMESTAMP_POSITION = keccak256("lido.PausableUntil.resumeSinceTimestamp");
    /// @dev Resume timestamp sentinel for an indefinite pause: never reached, so the contract stays paused
    ///      until an explicit resume.
    uint256 public constant PAUSE_INFINITELY = type(uint256).max;

    // ---
    // EVENTS
    // ---

    /// @notice Emitted on pause by `_pauseFor` or `_pauseUntil`. `duration` is the pause length in seconds, or
    ///         `PAUSE_INFINITELY` for an indefinite pause.
    event Paused(uint256 duration);
    /// @notice Emitted when resumed by the `resume` call
    event Resumed();

    // ---
    // ERRORS
    // ---

    /// @notice Thrown when a pause is requested with a zero duration.
    error ZeroPauseDuration();
    /// @notice Thrown when an action requires the contract to be paused but it is resumed.
    error PausedExpected();
    /// @notice Thrown when an action requires the contract to be resumed but it is paused.
    error ResumedExpected();
    /// @notice Thrown when a `pauseUntil` target timestamp is in the past.
    error PauseUntilMustBeInFuture();

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IPausableUntil
    function isPaused() public view override returns (bool) {
        return block.timestamp < RESUME_SINCE_TIMESTAMP_POSITION.getUint256Slot().value;
    }

    /// @inheritdoc IPausableUntil
    function getResumeSinceTimestamp() external view override returns (uint256) {
        return RESUME_SINCE_TIMESTAMP_POSITION.getUint256Slot().value;
    }

    // ---
    // INTERNAL HELPERS
    // ---

    /// @dev Reverts unless the contract is currently paused.
    function _checkPaused() internal view {
        if (!isPaused()) revert PausedExpected();
    }

    /// @dev Reverts unless the contract is currently resumed.
    function _checkResumed() internal view {
        if (isPaused()) revert ResumedExpected();
    }

    /// @dev Resume a paused contract by moving the resume timestamp to now. Reverts if already resumed.
    function _resume() internal {
        _checkPaused();
        RESUME_SINCE_TIMESTAMP_POSITION.getUint256Slot().value = block.timestamp;
        emit Resumed();
    }

    /// @dev Pause for a relative window: resume `_duration` seconds from now, or indefinitely when `_duration`
    ///      is `PAUSE_INFINITELY`. Reverts on a zero duration or when already paused.
    function _pauseFor(uint256 _duration) internal {
        _checkResumed();
        if (_duration == 0) revert ZeroPauseDuration();

        uint256 resumeSince;
        if (_duration == PAUSE_INFINITELY) resumeSince = PAUSE_INFINITELY;
        else resumeSince = block.timestamp + _duration;
        _setPausedState(resumeSince);
    }

    /// @dev Pause until an absolute timestamp: the contract stays paused through `_pauseUntilInclusive` and
    ///      resumes the second after, or stays paused indefinitely when it equals `PAUSE_INFINITELY`. Reverts
    ///      if the target is in the past or when already paused.
    function _pauseUntil(uint256 _pauseUntilInclusive) internal {
        _checkResumed();
        if (_pauseUntilInclusive < block.timestamp) revert PauseUntilMustBeInFuture();

        uint256 resumeSince;
        if (_pauseUntilInclusive != PAUSE_INFINITELY) resumeSince = _pauseUntilInclusive + 1;
        else resumeSince = PAUSE_INFINITELY;
        _setPausedState(resumeSince);
    }

    /// @dev Write the resume timestamp and emit `Paused` with the remaining seconds, or with `PAUSE_INFINITELY`
    ///      for an indefinite pause.
    function _setPausedState(uint256 _resumeSince) internal {
        RESUME_SINCE_TIMESTAMP_POSITION.getUint256Slot().value = _resumeSince;
        if (_resumeSince == PAUSE_INFINITELY) emit Paused(PAUSE_INFINITELY);
        else emit Paused(_resumeSince - block.timestamp);
    }
}
