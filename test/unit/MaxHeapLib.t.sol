// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {MaxHeapLib} from "../../src/libs/MaxHeapLib.sol";

/// @dev Harness exposing the internal max-heap library over a storage heap (L0: pure library via harness).
contract HeapHarness {
    using MaxHeapLib for MaxHeapLib.Heap;

    MaxHeapLib.Heap internal _heap;

    constructor() {
        _heap.init();
    }

    function upsert(address account, uint256 key) external {
        _heap.upsert(account, key);
    }

    function remove(address account) external returns (bool) {
        return _heap.remove(account);
    }

    function peek() external view returns (address account, uint256 key) {
        return _heap.peek();
    }

    function size() external view returns (uint256) {
        return _heap.size();
    }

    function nodeAt(uint256 index) external view returns (address account, uint256 key) {
        return _heap.nodeAt(index);
    }
}

/// @notice L0 unit/fuzz for `MaxHeapLib`, modelled from max-heap **requirements** (not the implementation):
///         it keys distinct accounts, the root is the global maximum, every node's key is ≥ its children's,
///         `upsert` inserts-or-rekeys (an account appears at most once), `remove` is a no-op on an absent
///         account, and `peek` reverts on empty. The heap property is re-checked after every mutation, so a
///         re-heapify bug in either direction (sift up / sift down) surfaces — including the sift-up-after-
///         remove path.
contract MaxHeapLibTest is Test {
    HeapHarness internal h;

    function setUp() public {
        h = new HeapHarness();
    }

    // ── helpers ──

    /// @dev Distinct, non-zero actor address for index `i`.
    function _a(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    /// @dev Asserts the full heap contract: parent.key ≥ child.key everywhere, the root is the global max,
    ///      and `peek` agrees with the root.
    function _assertHeap() internal view {
        uint256 n = h.size();
        if (n == 0) return;

        (, uint256 rootKey) = h.nodeAt(0);
        for (uint256 i = 1; i < n; ++i) {
            (, uint256 ki) = h.nodeAt(i);
            (, uint256 kParent) = h.nodeAt((i - 1) / 2);
            assertGe(kParent, ki, "heap property: parent >= child");
            assertGe(rootKey, ki, "root is not the global max");
        }
        (, uint256 peekKey) = h.peek();
        assertEq(peekKey, rootKey, "peek != root");
    }

    /// @dev Key of `account` by scanning the heap (independent of the lib's index map).
    function _keyOf(address account) internal view returns (uint256) {
        uint256 n = h.size();
        for (uint256 i = 0; i < n; ++i) {
            (address acc, uint256 k) = h.nodeAt(i);
            if (acc == account) return k;
        }
        revert("account not in heap");
    }

    /// @dev Reference-set membership by scanning the heap (independent of the lib's index map).
    function _present(address actor) internal view returns (bool) {
        uint256 n = h.size();
        for (uint256 i = 0; i < n; ++i) {
            (address acc,) = h.nodeAt(i);
            if (acc == actor) return true;
        }
        return false;
    }

    // ── mutations ──

    // ── requirements: root is max, upsert is insert-or-rekey ──

    function test_upsertExisting_rekeysNotDuplicates() public {
        h.upsert(_a(1), 10);
        h.upsert(_a(2), 20);
        assertEq(h.size(), 2, "size before re-key");
        h.upsert(_a(1), 99); // same account, new key
        assertEq(h.size(), 2, "size unchanged on re-key");
        (address acc, uint256 key) = h.peek();
        assertEq(acc, _a(1), "re-keyed account is now root");
        assertEq(key, 99, "new key");
        _assertHeap();
    }

    function test_rekeyUp_promotesToRoot() public {
        h.upsert(_a(1), 100);
        h.upsert(_a(2), 40);
        h.upsert(_a(3), 30);
        h.upsert(_a(2), 200); // promote a non-root above the root
        (address acc,) = h.peek();
        assertEq(acc, _a(2), "promoted to root");
        _assertHeap();
    }

    function test_rekeyDown_demotesRoot() public {
        h.upsert(_a(1), 100);
        h.upsert(_a(2), 90);
        h.upsert(_a(3), 80);
        h.upsert(_a(1), 1); // demote the root below its children
        (address acc,) = h.peek();
        assertEq(acc, _a(2), "old root demoted");
        _assertHeap();
    }

    // ── requirements: remove ──

    function test_removeRoot_promotesNextMax() public {
        h.upsert(_a(1), 50);
        h.upsert(_a(2), 90);
        h.upsert(_a(3), 70);
        assertTrue(h.remove(_a(2)), "remove returns true when present");
        assertEq(h.size(), 2, "size");
        (address acc, uint256 key) = h.peek();
        assertEq(acc, _a(3), "next max is root");
        assertEq(key, 70, "next max key");
        _assertHeap();
    }

    function test_removeAbsent_isNoop() public {
        h.upsert(_a(1), 50);
        assertFalse(h.remove(_a(9)), "remove returns false when absent");
        assertEq(h.size(), 1, "size unchanged");
        _assertHeap();
    }

    /// @notice Edge case: a removal whose hole is back-filled by the (large) last element sitting under
    ///         a small parent must **sift up**, not down. Insertion order below yields the heap array
    ///         `[100, 20, 90, 15, 10, 85, 80]`; removing key-15 (index 3) moves 80 into a slot whose parent
    ///         is 20 — the re-heapify must bubble 80 up. A sift-down-only `remove` leaves a broken heap.
    function test_removeTriggersSiftUp_maintainsHeap() public {
        h.upsert(_a(1), 100);
        h.upsert(_a(2), 20);
        h.upsert(_a(3), 90);
        h.upsert(_a(4), 15);
        h.upsert(_a(5), 10);
        h.upsert(_a(6), 85);
        h.upsert(_a(7), 80);
        _assertHeap();

        assertTrue(h.remove(_a(4)), "removed key-15");
        _assertHeap(); // fails here if remove only sifts down
        (, uint256 rootKey) = h.peek();
        assertEq(rootKey, 100, "root still the global max");
    }

    // ── edge cases: saturation, zero key, ties, fresh-insert sift-up, bounds ──

    function test_tiedKeys_heapHolds() public {
        h.upsert(_a(1), 50);
        h.upsert(_a(2), 50);
        h.upsert(_a(3), 50);
        assertEq(h.size(), 3, "all present");
        _assertHeap(); // equal keys must still satisfy parent >= child
    }

    function test_upsertFreshInsert_siftsUp() public {
        // Ascending inserts: each new node is the new global max and must climb to the root on insert.
        h.upsert(_a(1), 10);
        h.upsert(_a(2), 20);
        h.upsert(_a(3), 30);
        (address acc, uint256 key) = h.peek();
        assertEq(acc, _a(3), "newest max climbed to root");
        assertEq(key, 30, "key");
        _assertHeap();
    }

    function test_removeOnlyElement_emptiesAndPeekReverts() public {
        h.upsert(_a(1), 7);
        assertTrue(h.remove(_a(1)), "removed");
        assertEq(h.size(), 0, "empty");
        vm.expectRevert(MaxHeapLib.EmptyHeap.selector);
        h.peek();
    }

    function test_rekeySameValue_isNoop() public {
        h.upsert(_a(1), 100);
        h.upsert(_a(2), 90);
        h.upsert(_a(1), 100); // identical re-key
        assertEq(h.size(), 2, "size unchanged");
        (address acc,) = h.peek();
        assertEq(acc, _a(1), "root unchanged");
        _assertHeap();
    }

    // ── property: heap holds after any mutation sequence ──

    function testFuzz_heapPropertyHoldsAcrossSequence(uint256 seed) public {
        address[12] memory actors =
            [_a(1), _a(2), _a(3), _a(4), _a(5), _a(6), _a(7), _a(8), _a(9), _a(10), _a(11), _a(12)];
        uint256 live; // reference size

        for (uint256 step = 0; step < 100; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address actor = actors[seed % actors.length];

            if (seed % 4 == 0) {
                bool present = _present(actor);
                bool removed = h.remove(actor);
                assertEq(removed, present, "remove return tracks presence");
                if (removed) live--;
            } else {
                bool present = _present(actor);
                uint256 key = (uint256(keccak256(abi.encode(seed, "key"))) % 1_000_000) + 1; // non-zero
                h.upsert(actor, key);
                if (!present) live++;
            }

            assertEq(h.size(), live, "size tracks the reference set");
            _assertHeap();
        }
    }

    // ── views ──

    // ── requirements: empty / singleton ──

    function testRevert_peekOnEmpty() public {
        vm.expectRevert(MaxHeapLib.EmptyHeap.selector);
        h.peek();
    }

    function test_singleton() public {
        h.upsert(_a(1), 42);
        assertEq(h.size(), 1, "size");
        (address acc, uint256 key) = h.peek();
        assertEq(acc, _a(1), "account");
        assertEq(key, 42, "key");
    }

    // ── requirements: root is max, upsert is insert-or-rekey ──

    function test_rootIsMax() public {
        h.upsert(_a(1), 30);
        h.upsert(_a(2), 90);
        h.upsert(_a(3), 50);
        h.upsert(_a(4), 70);
        (address acc, uint256 key) = h.peek();
        assertEq(acc, _a(2), "max account");
        assertEq(key, 90, "max key");
        _assertHeap();
    }

    // ── edge cases: saturation, zero key, ties, fresh-insert sift-up, bounds ──

    function test_saturatesKeysAboveUint96() public {
        h.upsert(_a(1), type(uint256).max); // saturates to type(uint96).max
        h.upsert(_a(2), uint256(type(uint96).max)); // already the cap
        h.upsert(_a(3), 50);
        assertEq(_keyOf(_a(1)), uint256(type(uint96).max), "key saturates to uint96 max");
        assertEq(_keyOf(_a(2)), uint256(type(uint96).max), "cap stored as-is");
        (address root,) = h.peek();
        assertTrue(root == _a(1) || root == _a(2), "a saturated account is root");
        _assertHeap();
    }

    function test_keyZero_isPresentNotAbsent() public {
        h.upsert(_a(1), 0); // key 0 is a valid key; only slot==0 marks an absent account
        assertEq(h.size(), 1, "present");
        (address acc, uint256 key) = h.peek();
        assertEq(acc, _a(1), "key-0 account is the only root");
        assertEq(key, 0, "key is 0");
        assertTrue(h.remove(_a(1)), "removable");
        assertEq(h.size(), 0, "removed");
    }

    function testRevert_nodeAtOutOfRange() public {
        h.upsert(_a(1), 5);
        vm.expectRevert(MaxHeapLib.IndexOutOfBounds.selector);
        h.nodeAt(1); // size is 1; the only valid index is 0
    }

    /// @dev Sequential root-drain: after N random upserts, repeatedly removing the peeked root yields keys
    ///      in non-increasing order (each root is the max of what remains) and empties the heap.
    function testFuzz_drainIsNonIncreasing(uint256 n, uint256 seed) public {
        n = bound(n, 1, 60);
        for (uint256 i; i < n; ++i) {
            uint256 key = uint256(keccak256(abi.encode(seed, i))) % 1e9 + 1;
            h.upsert(_a(i), key);
        }
        assertEq(h.size(), n);

        uint256 prev = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            (address top, uint256 key) = h.peek();
            assertLe(key, prev, "root key non-increasing");
            prev = key;
            h.remove(top);
        }
        assertEq(h.size(), 0);
    }
}
