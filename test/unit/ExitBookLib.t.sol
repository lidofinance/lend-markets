// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ExitBookLib} from "../../src/libs/ExitBookLib.sol";
import {ExitStatus, PriorityRamp} from "../../src/types/ExitBookTypes.sol";

/// @dev Harness over the `State`, exposing the internal request-bookkeeping library plus field getters.
contract EBHarness {
    using ExitBookLib for ExitBookLib.State;

    ExitBookLib.State internal s;

    function add(
        address owner,
        IERC20 asset,
        uint256 shares,
        uint256 price,
        PriorityRamp calldata ramp,
        uint256 deadline,
        bool fullFillOnly
    ) external returns (uint256) {
        return s.add(owner, asset, shares, price, ramp, deadline, fullFillOnly);
    }

    function recordFill(uint256 id, uint256 filled) external {
        s.recordFill(id, filled);
    }

    function cancel(uint256 id, address caller) external {
        s.cancel(id, caller);
    }

    function requireFillable(uint256 id) external view {
        s.requireFillable(id);
    }

    function sizeRemaining(uint256 id) external view returns (uint256) {
        return s.requests[id].sizeRemaining;
    }

    function status(uint256 id) external view returns (ExitStatus) {
        return s.requests[id].status;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return s.requests[id].owner;
    }

    function nextId() external view returns (uint256) {
        return s.nextId;
    }
}

/// @notice Unit suite for `ExitBookLib` — the request bookkeeping behind the lender exit book (the renamed
///         WithdrawalQueueLib). State machine: Open → (full fill | cancel | expiry-at-read) → closed. Covers
///         the 1-indexed monotonic ids, fill/cancel transitions, the fillability reverts, the SafeCast packing
///         bounds, and the unguarded `recordFill` precondition.
contract ExitBookLibTest is Test {
    EBHarness internal h;

    IERC20 internal constant ASSET = IERC20(address(0xA55E7));
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        h = new EBHarness();
        vm.warp(1_000_000);
    }

    function _ramp() internal pure returns (PriorityRamp memory) {
        return PriorityRamp({startRate: 0, endRate: 0.1e18, rampStart: 0, rampEnd: 1 days});
    }

    function _add(address owner, uint256 shares) internal returns (uint256) {
        return h.add(owner, ASSET, shares, 1e18, _ramp(), block.timestamp + 1 days, false);
    }

    // ── mutations ──

    // ── add / ids ──

    /// @dev A new request is issued with id 1, status Open, sizeRemaining equal to the requested shares, and the
    /// caller-owner stored.
    function test_add_createsOpenRequest() public {
        uint256 id = _add(ALICE, 100 ether);
        assertEq(id, 1, "ids are 1-indexed");
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Open), "starts Open");
        assertEq(h.sizeRemaining(id), 100 ether, "sizeRemaining == shares");
        assertEq(h.ownerOf(id), ALICE, "owner stored");
    }

    /// @dev Ids increment strictly across adds and are never recycled, even after an earlier request is closed by
    /// cancel.
    function test_add_idsMonotonic_neverReused() public {
        uint256 id1 = _add(ALICE, 100 ether);
        uint256 id2 = _add(BOB, 50 ether);
        h.cancel(id1, ALICE);
        uint256 id3 = _add(ALICE, 10 ether);
        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3, "id not reused after close");
    }

    // ── recordFill ──

    /// @dev A partial fill debits sizeRemaining by the filled amount and leaves the request Open.
    function test_recordFill_partial_staysOpen() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 40 ether);
        assertEq(h.sizeRemaining(id), 60 ether, "remaining debited");
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Open), "still open");
    }

    /// @dev A fill that drains sizeRemaining to zero transitions the request to Filled.
    function test_recordFill_full_marksFilled() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 100 ether);
        assertEq(h.sizeRemaining(id), 0, "fully drained");
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Filled), "Filled at zero remaining");
    }

    /// @dev A fill exceeding sizeRemaining reverts on arithmetic underflow rather than over-draining the request.
    function testRevert_recordFill_overfill() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.expectRevert(stdError.arithmeticError); // sizeRemaining -= filled underflows
        h.recordFill(id, 101 ether);
    }

    // ── cancel ──

    /// @dev Cancelling a partially-filled Open request moves it to Cancelled and zeroes its remaining size.
    function test_cancel_open_marksCancelled() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 30 ether);
        h.cancel(id, ALICE);
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Cancelled), "Cancelled");
        assertEq(h.sizeRemaining(id), 0, "remaining zeroed on cancel");
    }

    /// @dev Only the recorded owner may cancel; a non-owner caller reverts NotOwner.
    function testRevert_cancel_notOwner() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.expectRevert(ExitBookLib.NotOwner.selector);
        h.cancel(id, BOB);
    }

    /// @dev Cancelling an already-closed request reverts RequestClosed rather than re-cancelling.
    function testRevert_cancel_alreadyClosed() public {
        uint256 id = _add(ALICE, 100 ether);
        h.cancel(id, ALICE);
        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        h.cancel(id, ALICE);
    }

    /// @dev `recordFill` only fills an OPEN request: on a cancelled (or filled) request it reverts
    ///      `RequestClosed` rather than re-closing it. This guards the status from corruption (a zero-share
    ///      call on a cancelled request would otherwise flip Cancelled → Filled). Both a zero and a positive
    ///      fill revert identically.
    function testRevert_recordFill_onCancelled_revertsClosed() public {
        uint256 id = _add(ALICE, 100 ether);
        h.cancel(id, ALICE);
        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        h.recordFill(id, 0);
    }

    /// @dev recordFill on an already-Filled request reverts RequestClosed and does not reopen or re-close it.
    function testRevert_recordFill_onFilled_revertsClosed() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 100 ether); // fully drained -> Filled
        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        h.recordFill(id, 0);
    }

    // ── SafeCast packing bounds ──

    /// @dev A shares amount above uint128 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_sharesOverflowUint128() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, 128, uint256(type(uint128).max) + 1
            )
        );
        h.add(ALICE, ASSET, uint256(type(uint128).max) + 1, 1e18, _ramp(), block.timestamp + 1, false);
    }

    /// @dev A deadline above uint40 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_deadlineOverflowsUint40() public {
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 40, uint256(type(uint40).max) + 1)
        );
        h.add(ALICE, ASSET, 1 ether, 1e18, _ramp(), uint256(type(uint40).max) + 1, false);
    }

    /// @dev A ramp rate above uint96 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_rampRateOverflowsUint96() public {
        PriorityRamp memory r =
            PriorityRamp({startRate: uint256(type(uint96).max) + 1, endRate: 0, rampStart: 0, rampEnd: 1});
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, uint256(type(uint96).max) + 1)
        );
        h.add(ALICE, ASSET, 1 ether, 1e18, r, block.timestamp + 1, false);
    }

    // ── fuzz: id monotonicity & remaining bound ──

    /// @dev Across a sequence of adds and arbitrary fills, ids increment from 1 and sizeRemaining never exceeds the
    /// total.
    function testFuzz_addThenFills_remainingNeverExceedsTotal(uint256 n, uint256 fillSeed) public {
        n = bound(n, 1, 20);
        for (uint256 i; i < n; i++) {
            uint256 id = _add(ALICE, 100 ether);
            assertEq(id, i + 1, "ids strictly increment from 1");
            uint256 fill = bound(uint256(keccak256(abi.encode(fillSeed, i))), 0, 100 ether);
            h.recordFill(id, fill);
            assertLe(h.sizeRemaining(id), 100 ether, "remaining <= total");
        }
        assertEq(h.nextId(), n, "nextId == count issued");
    }

    // ── views ──

    // ── requireFillable (3 reverts + boundary) ──

    /// @dev At exactly the deadline the request is still fillable (expiry check is strict `>`), so requireFillable
    /// passes.
    function test_requireFillable_atDeadline_ok() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.warp(block.timestamp + 1 days); // now == deadline; `>` is strict so still fillable
        h.requireFillable(id);
    }

    /// @dev One second past the deadline requireFillable reverts RequestExpired.
    function testRevert_requireFillable_pastDeadline() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(ExitBookLib.RequestExpired.selector);
        h.requireFillable(id);
    }

    /// @dev A closed (cancelled) request is not fillable; requireFillable reverts RequestClosed.
    function testRevert_requireFillable_closed() public {
        uint256 id = _add(ALICE, 100 ether);
        h.cancel(id, ALICE);
        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        h.requireFillable(id);
    }

    /// @dev A never-created id reads as a default (non-Open) request, so requireFillable reverts RequestClosed.
    function testRevert_requireFillable_uncreated() public {
        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        h.requireFillable(999);
    }
}
