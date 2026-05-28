// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

/// @title IDeleverageHeap
/// @notice Binary max-heap of borrower candidates for the deleverage waterfall, keyed by
///         `borrowShares × 1e18 / rawCollateral`. The key is monotonically equivalent to
///         "risk relative to LLTV" in an isolated market with one collateral asset and one
///         loan asset, so no oracle read is needed to maintain the heap order.
/// @dev Mutation entry points are restricted to the controller. View entry points are open.
interface IDeleverageHeap {
    struct HeapNode {
        address borrower;
        uint256 key;
    }

    error Unauthorized();
    error ZeroAddress();
    error EmptyHeap();
    error IndexOutOfBounds();

    event NodeUpserted(address indexed borrower, uint256 key, uint256 index);
    event NodeRemoved(address indexed borrower);

    function CONTROLLER() external view returns (address);

    function MARKET_ID() external view returns (Id);

    /// @notice Total borrowers currently in the heap.
    function size() external view returns (uint256);

    /// @notice Returns the highest-risk borrower and their key. Reverts if heap is empty.
    function peek() external view returns (address borrower, uint256 key);

    /// @notice Returns the key of the borrower with the higher key among the root's children.
    ///         Returns 0 if root has no children. Used by the deleverage iteration to size
    ///         the slice for the current top borrower.
    function rootRunnerUpKey() external view returns (uint256);

    /// @notice Returns borrower and key at a given heap-array index (0 = root).
    function nodeAt(uint256 index) external view returns (address borrower, uint256 key);

    /// @notice Insert `borrower` into the heap or update its key. Computes the key as
    ///         `borrowShares × 1e18 / rawCollateral`. If `borrowShares == 0` or
    ///         `rawCollateral == 0`, removes the borrower instead.
    function upsert(address borrower, uint256 borrowShares, uint256 rawCollateral) external;

    /// @notice Removes `borrower` from the heap. No-op if not present.
    function remove(address borrower) external;
}
