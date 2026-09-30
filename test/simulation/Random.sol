// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Seeded pseudo-random stream. Same seed, same sequence, so a failed run replays from the logged
///         `TEST_SEED`.
library Random {
    struct Context {
        bytes32 value;
    }

    function create(uint256 seed) internal pure returns (Context memory c) {
        c.value = bytes32(seed);
    }

    function next(Context storage self) internal returns (uint256) {
        self.value = keccak256(abi.encode(self.value));
        return uint256(self.value);
    }

    /// @notice Uniform in `[min, max]`. An empty range is a sizing bug in the caller.
    function between(Context storage self, uint256 min, uint256 max) internal returns (uint256) {
        require(max >= min, "Random: empty range");
        return min + next(self) % (max - min + 1);
    }

    /// @notice True with probability `bps / 10_000`.
    function chance(Context storage self, uint256 bps) internal returns (bool) {
        return next(self) % 10_000 < bps;
    }

    function index(Context storage self, uint256 length) internal returns (uint256) {
        return next(self) % length;
    }
}
