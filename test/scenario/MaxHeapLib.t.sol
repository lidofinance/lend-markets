// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {MaxHeapLib} from "../../src/libs/MaxHeapLib.sol";

/// @dev Storage harness so the library can operate on a real storage struct.
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

    function size() external view returns (uint256) {
        return _heap.size();
    }

    function peek() external view returns (address, uint256) {
        return _heap.peek();
    }

    function rootChildMaxKey() external view returns (uint256) {
        return _heap.rootChildMaxKey();
    }

    function nodeAt(uint256 i) external view returns (address, uint256) {
        return _heap.nodeAt(i);
    }
}

contract MaxHeapLibTest is Test {
    HeapHarness internal heap;

    function setUp() public {
        heap = new HeapHarness();
    }

    function _addr(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    // ── Basic invariants
    // ────────────────────────────────────────────

    function test_emptyPeekReverts() public {
        vm.expectRevert(MaxHeapLib.EmptyHeap.selector);
        heap.peek();
    }

    function test_sizeTracksUpsertRemove() public {
        assertEq(heap.size(), 0);
        heap.upsert(_addr(1), 10);
        heap.upsert(_addr(2), 20);
        assertEq(heap.size(), 2);
        heap.remove(_addr(1));
        assertEq(heap.size(), 1);
    }

    function test_rootIsMax() public {
        heap.upsert(_addr(1), 10);
        heap.upsert(_addr(2), 50);
        heap.upsert(_addr(3), 30);
        (address top, uint256 key) = heap.peek();
        assertEq(top, _addr(2));
        assertEq(key, 50);
    }

    function test_reKeyMovesRoot() public {
        heap.upsert(_addr(1), 10);
        heap.upsert(_addr(2), 50);
        // Re-key addr1 above addr2.
        heap.upsert(_addr(1), 99);
        (address top,) = heap.peek();
        assertEq(top, _addr(1));
    }

    function test_reKeyDownDemotesRoot() public {
        heap.upsert(_addr(1), 90);
        heap.upsert(_addr(2), 50);
        heap.upsert(_addr(1), 10); // demote former root
        (address top,) = heap.peek();
        assertEq(top, _addr(2));
    }

    function test_removeRootPromotesNext() public {
        heap.upsert(_addr(1), 10);
        heap.upsert(_addr(2), 50);
        heap.upsert(_addr(3), 30);
        heap.remove(_addr(2));
        (address top, uint256 key) = heap.peek();
        assertEq(top, _addr(3));
        assertEq(key, 30);
    }

    function test_removeAbsentIsNoop() public {
        heap.upsert(_addr(1), 10);
        assertFalse(heap.remove(_addr(99)));
        assertEq(heap.size(), 1);
    }

    /// @notice Keys above `type(uint96).max` saturate to that max. Borrowers with saturated keys
    ///         tie at the top of the heap — order among them isn't preserved, but they all rank
    ///         above any non-saturated borrower (the intended deleverage target order).
    function test_keysSaturateToUint96Max() public {
        uint256 huge1 = uint256(type(uint96).max) + 1;
        uint256 huge2 = uint256(type(uint96).max) * 100;
        heap.upsert(_addr(1), huge1);
        heap.upsert(_addr(2), huge2);
        heap.upsert(_addr(3), 50); // far below saturation

        (, uint256 rootKey) = heap.peek();
        assertEq(rootKey, type(uint96).max, "root saturated");

        // Both saturated borrowers tie at the top. The non-saturated one is below.
        heap.remove(_addr(1));
        (address newRoot, uint256 newRootKey) = heap.peek();
        assertEq(newRoot, _addr(2), "second saturated still on top");
        assertEq(newRootKey, type(uint96).max);

        heap.remove(_addr(2));
        (address last, uint256 lastKey) = heap.peek();
        assertEq(last, _addr(3), "non-saturated demoted to root only after saturated drain");
        assertEq(lastKey, 50);
    }

    function test_childMaxKey() public {
        assertEq(heap.rootChildMaxKey(), 0, "empty");
        heap.upsert(_addr(1), 50);
        assertEq(heap.rootChildMaxKey(), 0, "single borrower gives 0");
        heap.upsert(_addr(2), 30);
        assertEq(heap.rootChildMaxKey(), 30, "one child");
        heap.upsert(_addr(3), 40);
        assertEq(heap.rootChildMaxKey(), 40, "higher of two children");
    }

    // ── Fuzz: heap invariant + drain order
    // ──────────────────────────

    function testFuzz_drainIsNonIncreasing(uint256 n, uint256 seed) public {
        n = bound(n, 1, 60);
        for (uint256 i; i < n; ++i) {
            uint256 key = uint256(keccak256(abi.encode(seed, i))) % 1e9 + 1;
            heap.upsert(_addr(i), key);
        }
        assertEq(heap.size(), n);

        // Repeatedly pop the root; keys must come out in non-increasing order.
        uint256 prev = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            (address top, uint256 key) = heap.peek();
            assertLe(key, prev, "root key non-increasing");
            prev = key;
            heap.remove(top);
        }
        assertEq(heap.size(), 0);
    }

    function testFuzz_reKeyKeepsRootMax(uint256 seed) public {
        uint256 n = 30;
        for (uint256 i; i < n; ++i) {
            heap.upsert(_addr(i), uint256(keccak256(abi.encode(seed, i))) % 1e6 + 1);
        }
        // Re-key a few accounts, then check the root is the global max each time.
        for (uint256 r; r < 10; ++r) {
            uint256 idx = uint256(keccak256(abi.encode(seed, "rekey", r))) % n;
            uint256 newKey = uint256(keccak256(abi.encode(seed, "key", r))) % 1e7 + 1;
            heap.upsert(_addr(idx), newKey);

            (, uint256 rootKey) = heap.peek();
            uint256 maxKey;
            for (uint256 i; i < n; ++i) {
                (, uint256 k) = heap.nodeAt(i);
                if (k > maxKey) maxKey = k;
            }
            assertEq(rootKey, maxKey, "root is global max after re-key");
        }
    }
}
