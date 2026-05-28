// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

/// @title MaxHeapLib
/// @notice Generic binary max-heap over a storage struct, keyed by `(account, key)`.
/// @dev Risk-agnostic: it only orders accounts by an externally supplied `key`. The caller owns
///      the meaning of the key (e.g. a deleverage risk ratio). Nodes live in a 1-indexed array
///      with a zero sentinel at index 0 so parent/child index math (`i*2`, `i*2+1`, `i/2`) works
///      directly. A side mapping tracks each account's 1-indexed slot (0 = absent) so
///      `upsert` / `remove` are O(log N).
library MaxHeapLib {
    error EmptyHeap();
    error IndexOutOfBounds();

    struct Node {
        address account;
        uint256 key;
    }

    struct Heap {
        Node[] nodes; // 1-indexed; nodes[0] is a zero sentinel.
        mapping(address => uint256) slot; // 1-indexed slot per account; 0 means "not in heap".
    }

    /// @notice Pushes the index-0 sentinel. Call once before any other operation.
    function init(Heap storage self) internal {
        self.nodes.push(Node({account: address(0), key: 0}));
    }

    /* VIEWS */

    function size(Heap storage self) internal view returns (uint256) {
        return self.nodes.length - 1;
    }

    function peek(Heap storage self) internal view returns (address account, uint256 key) {
        if (self.nodes.length <= 1) revert EmptyHeap();
        Node storage root = self.nodes[1];
        return (root.account, root.key);
    }

    /// @notice Higher of the root's two children's keys (second-highest key in the heap), or 0 if
    ///         the root has no children.
    function rootRunnerUpKey(Heap storage self) internal view returns (uint256) {
        uint256 len = self.nodes.length;
        if (len <= 2) return 0;
        uint256 leftKey = self.nodes[2].key;
        if (len == 3) return leftKey;
        uint256 rightKey = self.nodes[3].key;
        return leftKey >= rightKey ? leftKey : rightKey;
    }

    /// @notice Account and key at heap-array index (0 = root). Approximate order, not a strict sort.
    function nodeAt(Heap storage self, uint256 index) internal view returns (address account, uint256 key) {
        uint256 idx = index + 1;
        if (idx >= self.nodes.length) revert IndexOutOfBounds();
        Node storage n = self.nodes[idx];
        return (n.account, n.key);
    }

    /* MUTATIONS */

    /// @notice Insert `account` with `key`, or re-key it if already present. Returns the final slot.
    function upsert(Heap storage self, address account, uint256 key) internal returns (uint256 finalSlot) {
        uint256 slot = self.slot[account];

        if (slot == 0) {
            self.nodes.push(Node({account: account, key: key}));
            slot = self.nodes.length - 1;
            self.slot[account] = slot;
            return _siftUp(self, slot);
        }

        uint256 oldKey = self.nodes[slot].key;
        if (key == oldKey) return slot;

        self.nodes[slot].key = key;
        return key > oldKey ? _siftUp(self, slot) : _siftDown(self, slot);
    }

    /// @notice Remove `account` from the heap. No-op if absent. Returns true if it was present.
    function remove(Heap storage self, address account) internal returns (bool) {
        uint256 slot = self.slot[account];
        if (slot == 0) return false;

        uint256 lastIndex = self.nodes.length - 1;
        if (slot != lastIndex) {
            Node memory moved = self.nodes[lastIndex];
            self.nodes[slot] = moved;
            self.slot[moved.account] = slot;
            self.nodes.pop();
            delete self.slot[account];

            // The moved node may need to travel either direction relative to its new neighbours.
            uint256 reSifted = _siftDown(self, slot);
            if (reSifted == slot) _siftUp(self, slot);
        } else {
            self.nodes.pop();
            delete self.slot[account];
        }
        return true;
    }

    /* INTERNAL */

    function _siftUp(Heap storage self, uint256 i) private returns (uint256) {
        while (i > 1) {
            uint256 parent = i >> 1;
            if (self.nodes[i].key <= self.nodes[parent].key) break;
            _swap(self, i, parent);
            i = parent;
        }
        return i;
    }

    function _siftDown(Heap storage self, uint256 i) private returns (uint256) {
        uint256 len = self.nodes.length;
        while (true) {
            uint256 left = i << 1;
            if (left >= len) break;
            uint256 right = left + 1;
            uint256 largest = i;
            if (self.nodes[left].key > self.nodes[largest].key) largest = left;
            if (right < len && self.nodes[right].key > self.nodes[largest].key) largest = right;
            if (largest == i) break;
            _swap(self, i, largest);
            i = largest;
        }
        return i;
    }

    function _swap(Heap storage self, uint256 a, uint256 b) private {
        Node memory tmpA = self.nodes[a];
        Node memory tmpB = self.nodes[b];
        self.nodes[a] = tmpB;
        self.nodes[b] = tmpA;
        self.slot[tmpA.account] = b;
        self.slot[tmpB.account] = a;
    }
}
