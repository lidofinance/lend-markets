// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

/// @title MaxHeapLib
/// @notice Generic binary max-heap over a storage struct, keyed by `(account, key)`.
/// @dev Risk-agnostic: it only orders accounts by an externally supplied `key`. Callers in this
///      repo derive the key as `borrowShares × 1e18 / rawCollateral` — this NatSpec is the single
///      canonical place where the formula is documented; other contracts reference this rather
///      than restate it.
///
///      Nodes live in a 1-indexed array with a zero sentinel at index 0 so parent/child index
///      math (`idx*2`, `idx*2+1`, `idx/2`) works directly. A side mapping tracks each account's
///      1-indexed slot (0 = absent) so `upsert` / `remove` are O(log N).
library MaxHeapLib {
    error EmptyHeap();
    error IndexOutOfBounds();

    /// @dev account + key packed into a single 32-byte slot. `key` is uint96 (saturating); see
    ///      `_saturateToKey` for the conversion from a uint256 caller-supplied value. Realistic
    ///      `borrowShares × 1e18 / rawCollateral` keys stay well below `type(uint96).max`
    ///      (≈ 7.9e28) under sane market constraints; pathological inputs saturate to the max,
    ///      which ties them at the top of the heap — still the correct settle target order.
    struct Node {
        address account;
        uint96 key;
    }

    function _saturateToKey(uint256 raw) private pure returns (uint96) {
        return raw > type(uint96).max ? type(uint96).max : uint96(raw);
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

    /// @notice Account and key at heap-array index (0 = root). Approximate order, not a strict sort.
    function nodeAt(Heap storage self, uint256 index) internal view returns (address account, uint256 key) {
        uint256 idx = index + 1;
        if (idx >= self.nodes.length) revert IndexOutOfBounds();
        Node storage node = self.nodes[idx];
        return (node.account, node.key);
    }

    /* MUTATIONS */

    /// @notice Insert `account` with `key`, or re-key it if already present.
    /// @dev `key` is saturated to `type(uint96).max` if it overflows the packed slot.
    function upsert(Heap storage self, address account, uint256 key) internal {
        uint96 packedKey = _saturateToKey(key);
        uint256 slot = self.slot[account];

        if (slot == 0) {
            self.nodes.push(Node({account: account, key: packedKey}));
            slot = self.nodes.length - 1;
            self.slot[account] = slot;
            _siftUp(self, slot);
            return;
        }

        uint96 oldKey = self.nodes[slot].key;
        if (packedKey == oldKey) return;

        self.nodes[slot].key = packedKey;
        if (packedKey > oldKey) _siftUp(self, slot);
        else _siftDown(self, slot);
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

    function _siftUp(Heap storage self, uint256 idx) private returns (uint256) {
        while (idx > 1) {
            uint256 parent = idx >> 1;
            if (self.nodes[idx].key <= self.nodes[parent].key) break;
            _swap(self, idx, parent);
            idx = parent;
        }
        return idx;
    }

    function _siftDown(Heap storage self, uint256 idx) private returns (uint256) {
        uint256 len = self.nodes.length;
        while (true) {
            uint256 left = idx << 1;
            if (left >= len) break;
            uint256 right = left + 1;
            uint256 largest = idx;
            if (self.nodes[left].key > self.nodes[largest].key) largest = left;
            if (right < len && self.nodes[right].key > self.nodes[largest].key) largest = right;
            if (largest == idx) break;
            _swap(self, idx, largest);
            idx = largest;
        }
        return idx;
    }

    function _swap(Heap storage self, uint256 indexA, uint256 indexB) private {
        Node memory nodeA = self.nodes[indexA];
        Node memory nodeB = self.nodes[indexB];
        self.nodes[indexA] = nodeB;
        self.nodes[indexB] = nodeA;
        self.slot[nodeA.account] = indexB;
        self.slot[nodeB.account] = indexA;
    }
}
