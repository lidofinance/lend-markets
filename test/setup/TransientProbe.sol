// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Tells a test whether its top-level calls share one transaction: a transient value `set` in one call is
///         still there for `get` in the next only inside the same transaction.
contract TransientProbe {
    /// @notice Writes `value` to transient slot 0.
    function set(uint256 value) external {
        assembly ("memory-safe") {
            tstore(0, value)
        }
    }

    /// @notice What the last `set` in this transaction wrote, or zero.
    function get() external view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(0)
        }
    }
}
