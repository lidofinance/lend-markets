// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {WithdrawalQueueLib} from "../../src/libs/WithdrawalQueueLib.sol";

/// @dev Harness over a `State`, exposing the internal library plus request-field getters for assertions.
contract WQHarness {
    using WithdrawalQueueLib for WithdrawalQueueLib.State;

    WithdrawalQueueLib.State internal s;

    function add(
        address owner,
        WithdrawalQueueLib.Mode mode,
        uint256 shares,
        uint256 price,
        uint256 maxFee,
        uint256 deadline,
        bool fullFillOnly
    ) external returns (uint256) {
        return s.add(owner, mode, shares, price, maxFee, deadline, fullFillOnly);
    }

    function recordFill(uint256 id, uint256 filled) external {
        s.recordFill(id, filled);
    }

    function cancel(uint256 id, address caller) external returns (WithdrawalQueueLib.Mode, uint256) {
        return s.cancel(id, caller);
    }

    function expireIfDue(uint256 id) external returns (bool, WithdrawalQueueLib.Mode, address, uint256) {
        return s.expireIfDue(id);
    }

    function requireOpen(uint256 id) external view {
        s.requireOpen(id);
    }

    function paginate(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return s.paginate(offset, limit);
    }

    function count() external view returns (uint256) {
        return s.count();
    }

    function sizeRemaining(uint256 id) external view returns (uint256) {
        return s.requests[id].sizeRemaining;
    }

    function closed(uint256 id) external view returns (bool) {
        return s.requests[id].closed;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return s.requests[id].owner;
    }
}

/// @notice Unit/fuzz for `WithdrawalQueueLib`: request bookkeeping with the state
///         machine open -> (full fill | cancel | expire) -> closed, where `activeIds` mirrors exactly the open
///         set. Covers the lifecycle, the swap-pop close, the cancel/expire revert-vs-no-op asymmetry,
///         pagination boundaries, SafeCast overflow, and the open-set/count invariant under fuzzed sequences.
contract WithdrawalQueueLibTest is Test {
    WQHarness internal h;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        h = new WQHarness();
        vm.warp(1_000_000);
    }

    function _add(address owner, uint256 shares) internal returns (uint256) {
        return h.add(owner, WithdrawalQueueLib.Mode.Vault, shares, 1e18, 1 ether, block.timestamp + 1 days, false);
    }

    // ── add / ids ──

    function test_add_createsActiveRequest() public {
        uint256 id = _add(ALICE, 100 ether);
        assertEq(id, 0, "first id is 0");
        assertEq(h.count(), 1, "one active request");
        assertEq(h.sizeRemaining(id), 100 ether, "sizeRemaining == shares");
        assertEq(h.ownerOf(id), ALICE, "owner stored");
    }

    function test_add_idsAreMonotonic_neverReused() public {
        uint256 id0 = _add(ALICE, 100 ether);
        uint256 id1 = _add(BOB, 50 ether);
        h.cancel(id0, ALICE); // close id0
        uint256 id2 = _add(ALICE, 10 ether);
        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(id2, 2, "id is not reused after close");
    }

    // ── recordFill ──

    function test_recordFill_partial_staysOpen() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 40 ether);
        assertEq(h.sizeRemaining(id), 60 ether, "remaining debited");
        assertFalse(h.closed(id), "still open");
        assertEq(h.count(), 1, "still active");
    }

    function test_recordFill_full_closesAndDropsFromActive() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 100 ether);
        assertEq(h.sizeRemaining(id), 0, "fully drained");
        assertTrue(h.closed(id), "closed at zero remaining");
        assertEq(h.count(), 0, "dropped from the active set");
    }

    function testRevert_recordFill_overfill() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.expectRevert(); // sizeRemaining -= filled underflows
        h.recordFill(id, 101 ether);
    }

    // ── cancel (reverts on misuse) ──

    function test_cancel_open_returnsLeftover_andCloses() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 30 ether); // 70 remaining
        (WithdrawalQueueLib.Mode mode, uint256 leftover) = h.cancel(id, ALICE);
        assertEq(uint8(mode), uint8(WithdrawalQueueLib.Mode.Vault), "mode returned");
        assertEq(leftover, 70 ether, "leftover == remaining at cancel");
        assertTrue(h.closed(id), "closed");
        assertEq(h.count(), 0, "removed from active");
    }

    function testRevert_cancel_notOwner() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.expectRevert(WithdrawalQueueLib.NotOwner.selector);
        h.cancel(id, BOB);
    }

    function testRevert_cancel_alreadyClosed() public {
        uint256 id = _add(ALICE, 100 ether);
        h.cancel(id, ALICE);
        vm.expectRevert(WithdrawalQueueLib.RequestClosed.selector);
        h.cancel(id, ALICE);
    }

    // ── expireIfDue (no-op on misuse, batch-prune friendly) ──

    function test_expireIfDue_pastDeadline_prunes() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.warp(block.timestamp + 2 days); // past the 1-day deadline
        (bool pruned, WithdrawalQueueLib.Mode mode, address owner, uint256 leftover) = h.expireIfDue(id);
        assertTrue(pruned, "pruned past deadline");
        assertEq(uint8(mode), uint8(WithdrawalQueueLib.Mode.Vault));
        assertEq(owner, ALICE, "owner returned for escrow refund");
        assertEq(leftover, 100 ether, "full leftover");
        assertEq(h.count(), 0, "removed from active");
    }

    function test_expireIfDue_notDue_isNoop() public {
        uint256 id = _add(ALICE, 100 ether); // deadline +1 day, not yet due
        (bool pruned,,, uint256 leftover) = h.expireIfDue(id);
        assertFalse(pruned, "no-op before the deadline");
        assertEq(leftover, 0, "no leftover reported");
        assertEq(h.count(), 1, "still active, no revert");
    }

    function test_expireIfDue_closed_isNoop() public {
        uint256 id = _add(ALICE, 100 ether);
        h.cancel(id, ALICE);
        vm.warp(block.timestamp + 2 days);
        (bool pruned,,,) = h.expireIfDue(id);
        assertFalse(pruned, "closed request is a no-op, not a revert");
    }

    // ── requireOpen (3 reverts + boundary) ──

    function test_requireOpen_openAtDeadline_ok() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.warp(block.timestamp + 1 days); // now == deadline; `>` is strict so still open
        h.requireOpen(id);
    }

    function testRevert_requireOpen_pastDeadline() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(WithdrawalQueueLib.RequestExpired.selector);
        h.requireOpen(id);
    }

    function testRevert_requireOpen_closed() public {
        uint256 id = _add(ALICE, 100 ether);
        h.cancel(id, ALICE);
        vm.expectRevert(WithdrawalQueueLib.RequestClosed.selector);
        h.requireOpen(id);
    }

    function testRevert_requireOpen_uncreated() public {
        vm.expectRevert(WithdrawalQueueLib.RequestClosed.selector);
        h.requireOpen(999);
    }

    // ── _close swap-pop + paginate ──

    function test_close_swapPopMiddle_reordersActive() public {
        uint256 id0 = _add(ALICE, 1 ether);
        uint256 id1 = _add(ALICE, 1 ether);
        uint256 id2 = _add(ALICE, 1 ether);
        h.cancel(id1, ALICE); // close the middle: activeIds [0,1,2] -> swap last in -> [0,2]
        assertEq(h.count(), 2, "two left");
        uint256[] memory ids = h.paginate(0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], id0, "id0 stays at index 0");
        assertEq(ids[1], id2, "id2 swapped into the freed middle slot");
    }

    function test_paginate_offsetBeyondLength_empty() public {
        _add(ALICE, 1 ether);
        assertEq(h.paginate(5, 10).length, 0, "offset past the end -> empty");
    }

    function test_paginate_clampsToLength() public {
        _add(ALICE, 1 ether);
        _add(ALICE, 1 ether);
        _add(ALICE, 1 ether);
        uint256[] memory ids = h.paginate(1, 10); // 3 active, offset 1 -> [id1, id2]
        assertEq(ids.length, 2, "end clamped to length");
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    // ── add SafeCast overflow ──

    function testRevert_add_maxFeeOverflowsUint96() public {
        vm.expectRevert(); // SafeCast.toUint96
        h.add(
            ALICE,
            WithdrawalQueueLib.Mode.Vault,
            1 ether,
            1e18,
            uint256(type(uint96).max) + 1,
            block.timestamp + 1,
            false
        );
    }

    function testRevert_add_deadlineOverflowsUint40() public {
        vm.expectRevert(); // SafeCast.toUint40
        h.add(ALICE, WithdrawalQueueLib.Mode.Vault, 1 ether, 1e18, 1 ether, uint256(type(uint40).max) + 1, false);
    }

    // ── fuzz: open-set integrity ──

    function testFuzz_countEqualsOpenSet(uint256 n, uint256 closeSeed) public {
        n = bound(n, 1, 20);
        for (uint256 i; i < n; i++) {
            _add(ALICE, 1 ether);
        }
        assertEq(h.count(), n, "all added are active");

        // Close a pseudo-random subset by cancelling; count must track the open set exactly.
        uint256 closedCount;
        for (uint256 i; i < n; i++) {
            if (uint256(keccak256(abi.encode(closeSeed, i))) % 2 == 0) {
                h.cancel(i, ALICE);
                closedCount++;
            }
        }
        assertEq(h.count(), n - closedCount, "count == number of still-open requests");
        // paginate returns exactly `count` ids, all open.
        uint256[] memory ids = h.paginate(0, n);
        assertEq(ids.length, n - closedCount, "paginate length == open count");
        for (uint256 i; i < ids.length; i++) {
            assertFalse(h.closed(ids[i]), "every paginated id is open");
        }
    }

    // ── additional cases ──

    /// @dev FINDING: recordFill has NO open/closed guard. On a CLOSED request
    ///      (sizeRemaining 0), filled==0 is a silent no-op (the swap-pop re-close is idempotent), while any
    ///      filled>0 underflows. Safe only because the embedding contract calls requireOpen first.
    function test_FINDING_recordFill_onClosed_noopOrReverts() public {
        uint256 id = _add(ALICE, 100 ether);
        h.cancel(id, ALICE); // closed, sizeRemaining 0
        h.recordFill(id, 0); // silent no-op, no revert, no state change
        assertEq(h.count(), 0, "no-op recordFill leaves the active set unchanged");
        vm.expectRevert(); // any positive fill underflows (remaining is 0)
        h.recordFill(id, 1);
    }

    function test_paginate_limitZero_empty() public {
        _add(ALICE, 1 ether);
        assertEq(h.paginate(0, 0).length, 0, "limit 0 -> empty");
    }

    /// @dev Asymmetry vs requireOpen (which reverts RequestClosed for an uncreated id): cancel checks the
    ///      owner first, and an uncreated request has owner 0 != caller -> NotOwner.
    function testRevert_cancel_uncreated_isNotOwner() public {
        vm.expectRevert(WithdrawalQueueLib.NotOwner.selector);
        h.cancel(999, ALICE);
    }
}
