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
        uint256 assets,
        PriorityRamp calldata ramp,
        uint256 deadline,
        uint256 minFillAssets,
        uint256 maxShareBurn
    ) external returns (uint256) {
        return s.add(owner, owner, asset, assets, minFillAssets, maxShareBurn, ramp, deadline);
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

    function assetsRemaining(uint256 id) external view returns (uint256) {
        return s.requests[id].assetsRemaining;
    }

    function assetsTotal(uint256 id) external view returns (uint256) {
        return s.requests[id].assetsTotal;
    }

    function minFillAssets(uint256 id) external view returns (uint256) {
        return s.requests[id].minFillAssets;
    }

    function maxShareBurn(uint256 id) external view returns (uint256) {
        return s.requests[id].maxShareBurn;
    }

    function assetOf(uint256 id) external view returns (IERC20) {
        return s.requests[id].asset;
    }

    function receiverOf(uint256 id) external view returns (address) {
        return s.requests[id].receiver;
    }

    function status(uint256 id) external view returns (ExitStatus) {
        return s.requests[id].status;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return s.requests[id].owner;
    }
}

/// @notice Unit suite for `ExitBookLib`, the request bookkeeping behind the lender exit book. `NotCreated` is the
///         default sentinel; stored requests move from Open to Filled or Cancelled. Covers the 1-indexed monotonic
///         ids, fill/cancel transitions, the fillability reverts, the SafeCast packing bounds, and the unguarded
///         `recordFill` precondition.
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

    function _add(address owner, uint256 assets) internal returns (uint256) {
        return h.add(owner, ASSET, assets, _ramp(), block.timestamp + 1 days, 0, 0);
    }

    // ── mutations ──

    // ── add / ids ──

    function test_uncreatedId_hasNotCreatedStatus() public view {
        assertEq(uint8(h.status(999)), uint8(ExitStatus.NotCreated));
    }

    /// @dev A new request is issued with id 1, status Open, assetsRemaining equal to the requested amount, and the
    /// caller-owner stored.
    function test_add_createsOpenRequest() public {
        uint256 id = _add(ALICE, 100 ether);
        assertEq(id, 1, "ids are 1-indexed");
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Open), "starts Open");
        assertEq(h.assetsRemaining(id), 100 ether, "assets stored");
        assertEq(h.assetsTotal(id), 100 ether, "original assets stored");
        assertEq(h.ownerOf(id), ALICE, "owner stored");
        assertEq(h.receiverOf(id), ALICE, "receiver stored");
        assertEq(address(h.assetOf(id)), address(ASSET), "asset stored");
        assertEq(h.minFillAssets(id), 0, "minimum stored");
        assertEq(h.maxShareBurn(id), 0, "share protection stored");
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

    /// @dev A partial fill debits assetsRemaining by the filled amount and leaves the request Open.
    function test_recordFill_partial_staysOpen() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 40 ether);
        assertEq(h.assetsRemaining(id), 60 ether, "remaining debited");
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Open), "still open");
    }

    /// @dev A fill that drains assetsRemaining to zero transitions the request to Filled.
    function test_recordFill_full_marksFilled() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 100 ether);
        assertEq(h.assetsRemaining(id), 0, "fully drained");
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Filled), "Filled at zero remaining");
    }

    /// @dev A fill exceeding assetsRemaining reverts on arithmetic underflow rather than over-draining the request.
    function testRevert_recordFill_overfill() public {
        uint256 id = _add(ALICE, 100 ether);
        vm.expectRevert(stdError.arithmeticError); // assetsRemaining -= filled underflows
        h.recordFill(id, 101 ether);
    }

    // ── cancel ──

    /// @dev Cancelling a partially-filled Open request moves it to Cancelled and zeroes its remaining size.
    function test_cancel_open_marksCancelled() public {
        uint256 id = _add(ALICE, 100 ether);
        h.recordFill(id, 30 ether);
        h.cancel(id, ALICE);
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Cancelled), "Cancelled");
        assertEq(h.assetsRemaining(id), 0, "remaining zeroed on cancel");
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
    ///      `RequestClosed` rather than re-closing it. This guards the status from corruption (a zero-asset
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

    /// @dev Every packed field accepts its exact unsigned-integer maximum.
    function test_add_packedFieldsAcceptExactMaxima() public {
        vm.warp(type(uint40).max);
        PriorityRamp memory r = PriorityRamp({
            startRate: type(uint96).max,
            endRate: type(uint96).max,
            rampStart: type(uint32).max,
            rampEnd: type(uint32).max
        });

        uint256 id = h.add(ALICE, ASSET, type(uint128).max, r, type(uint40).max, type(uint128).max, type(uint128).max);

        assertEq(id, 1);
        assertEq(uint8(h.status(id)), uint8(ExitStatus.Open));
        assertEq(h.minFillAssets(id), type(uint128).max);
        assertEq(h.maxShareBurn(id), type(uint128).max);
    }

    /// @dev An asset amount above uint128 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_assetsOverflowUint128() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SafeCast.SafeCastOverflowedUintDowncast.selector, 128, uint256(type(uint128).max) + 1
            )
        );
        h.add(ALICE, ASSET, uint256(type(uint128).max) + 1, _ramp(), block.timestamp + 1, 0, 0);
    }

    function testRevert_add_minFillAssetsOverflowsUint128() public {
        uint256 overflow = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, overflow));
        h.add(ALICE, ASSET, 1 ether, _ramp(), block.timestamp + 1, overflow, 0);
    }

    function testRevert_add_maxShareBurnOverflowsUint128() public {
        uint256 overflow = uint256(type(uint128).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, overflow));
        h.add(ALICE, ASSET, 1 ether, _ramp(), block.timestamp + 1, 0, overflow);
    }

    /// @dev A deadline above uint40 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_deadlineOverflowsUint40() public {
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 40, uint256(type(uint40).max) + 1)
        );
        h.add(ALICE, ASSET, 1 ether, _ramp(), uint256(type(uint40).max) + 1, 0, 0);
    }

    /// @dev A creation timestamp above uint40 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_createdAtOverflowsUint40() public {
        uint256 overflowingTimestamp = uint256(type(uint40).max) + 1;
        vm.warp(overflowingTimestamp);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 40, overflowingTimestamp)
        );
        h.add(ALICE, ASSET, 1 ether, _ramp(), type(uint40).max, 0, 0);
    }

    /// @dev A ramp rate above uint96 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_rampRateOverflowsUint96() public {
        PriorityRamp memory r =
            PriorityRamp({startRate: uint256(type(uint96).max) + 1, endRate: 0, rampStart: 0, rampEnd: 1});
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, uint256(type(uint96).max) + 1)
        );
        h.add(ALICE, ASSET, 1 ether, r, block.timestamp + 1, 0, 0);
    }

    /// @dev An end rate above uint96 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_endRateOverflowsUint96() public {
        uint256 overflowingRate = uint256(type(uint96).max) + 1;
        PriorityRamp memory r = PriorityRamp({startRate: 0, endRate: overflowingRate, rampStart: 0, rampEnd: 1});
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 96, overflowingRate));
        h.add(ALICE, ASSET, 1 ether, r, block.timestamp + 1, 0, 0);
    }

    /// @dev A ramp-start offset above uint32 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_rampStartOverflowsUint32() public {
        uint256 overflowingOffset = uint256(type(uint32).max) + 1;
        PriorityRamp memory r = PriorityRamp({startRate: 0, endRate: 0, rampStart: overflowingOffset, rampEnd: 0});
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, overflowingOffset));
        h.add(ALICE, ASSET, 1 ether, r, block.timestamp + 1, 0, 0);
    }

    /// @dev A ramp-end offset above uint32 max reverts on the SafeCast downcast when packing the request.
    function testRevert_add_rampEndOverflowsUint32() public {
        uint256 overflowingOffset = uint256(type(uint32).max) + 1;
        PriorityRamp memory r = PriorityRamp({startRate: 0, endRate: 0, rampStart: 0, rampEnd: overflowingOffset});
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 32, overflowingOffset));
        h.add(ALICE, ASSET, 1 ether, r, block.timestamp + 1, 0, 0);
    }

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

    /// @dev A never-created id reads as NotCreated, so requireFillable reverts RequestClosed.
    function testRevert_requireFillable_uncreated() public {
        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        h.requireFillable(999);
    }
}
