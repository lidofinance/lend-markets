// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

import {IDeleverageHeap} from "../interfaces/IDeleverageHeap.sol";

interface IDeleverageHeapController {
    function MARKET() external view returns (address);
    function MARKET_ID() external view returns (Id);
}

/// @title DeleverageHeap
/// @notice Binary max-heap of borrower candidates ordered by `borrowShares × 1e18 / rawCollateral`.
/// @dev Heap nodes are stored in a 1-indexed dynamic array. Index 0 is a sentinel that is
///      never read so child/parent index math `(i*2, i*2+1, i/2)` works directly. A side
///      mapping tracks each borrower's slot (1-indexed; 0 means "not in heap") so
///      `upsert` / `remove` are O(log N).
///
///      The key is intentionally cheap: it does not depend on oracle price or LLTV. Both are
///      market-level constants in this isolated market, so they cancel out of the ranking.
///      As a result, heap order survives interest accrual and price movements with no
///      re-sorting work — only the borrower's own `Borrow` / `Repay` / `SupplyCollateral` /
///      `WithdrawCollateral` / `Liquidate` / `Deleverage` actions mutate the key.
contract DeleverageHeap is IDeleverageHeap {
    uint256 internal constant KEY_SCALE = 1e18;

    address public immutable CONTROLLER;
    Id public immutable MARKET_ID;

    /// @dev Slot 0 is unused. Nodes live at indices [1, _nodes.length - 1].
    HeapNode[] internal _nodes;

    /// @dev 1-indexed slot for each borrower in `_nodes`. 0 means "not in heap".
    mapping(address => uint256) internal _slot;

    modifier onlyController() {
        if (msg.sender != CONTROLLER) revert Unauthorized();
        _;
    }

    constructor(address controller) {
        if (controller == address(0)) revert ZeroAddress();
        CONTROLLER = controller;
        MARKET_ID = IDeleverageHeapController(controller).MARKET_ID();
        // Reserve index 0 with a zero sentinel so heap indexing is 1-based.
        _nodes.push(HeapNode({borrower: address(0), key: 0}));
    }

    /* VIEWS */

    /// @inheritdoc IDeleverageHeap
    function size() external view returns (uint256) {
        return _nodes.length - 1;
    }

    /// @inheritdoc IDeleverageHeap
    function peek() external view returns (address borrower, uint256 key) {
        if (_nodes.length <= 1) revert EmptyHeap();
        HeapNode memory root = _nodes[1];
        return (root.borrower, root.key);
    }

    /// @inheritdoc IDeleverageHeap
    function rootRunnerUpKey() external view returns (uint256) {
        uint256 len = _nodes.length;
        if (len <= 2) return 0;
        uint256 leftKey = _nodes[2].key;
        if (len == 3) return leftKey;
        uint256 rightKey = _nodes[3].key;
        return leftKey >= rightKey ? leftKey : rightKey;
    }

    /// @inheritdoc IDeleverageHeap
    function nodeAt(uint256 index) external view returns (address borrower, uint256 key) {
        uint256 slot = index + 1;
        if (slot >= _nodes.length) revert EmptyHeap();
        HeapNode memory n = _nodes[slot];
        return (n.borrower, n.key);
    }

    /* MUTATIONS */

    /// @inheritdoc IDeleverageHeap
    function upsert(address borrower, uint256 borrowShares, uint256 rawCollateral)
        external
        override
        onlyController
    {
        if (borrower == address(0)) revert ZeroAddress();

        if (borrowShares == 0 || rawCollateral == 0) {
            _remove(borrower);
            return;
        }

        uint256 newKey = (borrowShares * KEY_SCALE) / rawCollateral;
        uint256 slot = _slot[borrower];

        if (slot == 0) {
            // Insert at the end, then sift-up.
            _nodes.push(HeapNode({borrower: borrower, key: newKey}));
            slot = _nodes.length - 1;
            _slot[borrower] = slot;
            slot = _siftUp(slot);
            emit NodeUpserted(borrower, newKey, slot);
            return;
        }

        uint256 oldKey = _nodes[slot].key;
        if (newKey == oldKey) {
            // No-op for ordering, but emit so observers see the sync intent.
            emit NodeUpserted(borrower, newKey, slot);
            return;
        }

        _nodes[slot].key = newKey;
        if (newKey > oldKey) {
            slot = _siftUp(slot);
        } else {
            slot = _siftDown(slot);
        }
        emit NodeUpserted(borrower, newKey, slot);
    }

    /// @inheritdoc IDeleverageHeap
    function remove(address borrower) external override onlyController {
        _remove(borrower);
    }

    /* INTERNAL HEAP OPERATIONS */

    function _remove(address borrower) internal {
        uint256 slot = _slot[borrower];
        if (slot == 0) return;

        uint256 lastIndex = _nodes.length - 1;
        if (slot != lastIndex) {
            // Move last node into removed slot, then re-sift.
            HeapNode memory moved = _nodes[lastIndex];
            _nodes[slot] = moved;
            _slot[moved.borrower] = slot;
            _nodes.pop();
            delete _slot[borrower];

            // The moved node may need to go either direction relative to its new neighbours.
            uint256 reSifted = _siftDown(slot);
            if (reSifted == slot) _siftUp(slot);
        } else {
            _nodes.pop();
            delete _slot[borrower];
        }

        emit NodeRemoved(borrower);
    }

    /// @dev Moves the node at `i` up while its key is greater than its parent's. Returns the
    ///      final index.
    function _siftUp(uint256 i) internal returns (uint256) {
        while (i > 1) {
            uint256 parent = i >> 1;
            if (_nodes[i].key <= _nodes[parent].key) break;
            _swap(i, parent);
            i = parent;
        }
        return i;
    }

    /// @dev Moves the node at `i` down while it is smaller than its largest child. Returns
    ///      the final index.
    function _siftDown(uint256 i) internal returns (uint256) {
        uint256 len = _nodes.length;
        while (true) {
            uint256 left = i << 1;
            if (left >= len) break;
            uint256 right = left + 1;
            uint256 largest = i;
            if (_nodes[left].key > _nodes[largest].key) largest = left;
            if (right < len && _nodes[right].key > _nodes[largest].key) largest = right;
            if (largest == i) break;
            _swap(i, largest);
            i = largest;
        }
        return i;
    }

    function _swap(uint256 a, uint256 b) internal {
        HeapNode memory tmpA = _nodes[a];
        HeapNode memory tmpB = _nodes[b];
        _nodes[a] = tmpB;
        _nodes[b] = tmpA;
        _slot[tmpA.borrower] = b;
        _slot[tmpB.borrower] = a;
    }
}
