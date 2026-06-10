// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.35;

import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

/**
 * @title PausableUntil
 * @notice allows to pause the contract for a specific duration or indefinitely
 */
abstract contract PausableUntil {
    using StorageSlot for bytes32;

    bytes32 internal constant RESUME_SINCE_TIMESTAMP_POSITION = keccak256("lido.PausableUntil.resumeSinceTimestamp");
    /// Special value for the infinite pause
    uint256 public constant PAUSE_INFINITELY = type(uint256).max;

    event Paused(uint256 duration);
    event Resumed();

    error ZeroPauseDuration();
    error PausedExpected();
    error ResumedExpected();
    error PauseUntilMustBeInFuture();

    modifier whenResumed() {
        _checkResumed();
        _;
    }

    function isPaused() public view returns (bool) {
        return block.timestamp < RESUME_SINCE_TIMESTAMP_POSITION.getUint256Slot().value;
    }

    /// @notice Returns one of:
    ///  - PAUSE_INFINITELY if paused infinitely returns
    ///  - the timestamp when the contract get resumed if paused for specific duration
    ///  - some timestamp in past if not paused
    function getResumeSinceTimestamp() external view returns (uint256) {
        return RESUME_SINCE_TIMESTAMP_POSITION.getUint256Slot().value;
    }

    function _checkPaused() internal view {
        if (!isPaused()) {
            revert PausedExpected();
        }
    }

    function _checkResumed() internal view {
        if (isPaused()) {
            revert ResumedExpected();
        }
    }

    function _resume() internal {
        _checkPaused();
        RESUME_SINCE_TIMESTAMP_POSITION.getUint256Slot().value = block.timestamp;
        emit Resumed();
    }

    function _pauseFor(uint256 _duration) internal {
        _checkResumed();
        if (_duration == 0) revert ZeroPauseDuration();

        uint256 resumeSince;
        if (_duration == PAUSE_INFINITELY) {
            resumeSince = PAUSE_INFINITELY;
        } else {
            resumeSince = block.timestamp + _duration;
        }
        _setPausedState(resumeSince);
    }

    function _pauseUntil(uint256 _pauseUntilInclusive) internal {
        _checkResumed();
        if (_pauseUntilInclusive < block.timestamp) revert PauseUntilMustBeInFuture();

        uint256 resumeSince;
        if (_pauseUntilInclusive != PAUSE_INFINITELY) {
            resumeSince = _pauseUntilInclusive + 1;
        } else {
            resumeSince = PAUSE_INFINITELY;
        }
        _setPausedState(resumeSince);
    }

    function _setPausedState(uint256 _resumeSince) internal {
        RESUME_SINCE_TIMESTAMP_POSITION.getUint256Slot().value = _resumeSince;
        if (_resumeSince == PAUSE_INFINITELY) {
            emit Paused(PAUSE_INFINITELY);
        } else {
            emit Paused(_resumeSince - block.timestamp);
        }
    }
}
