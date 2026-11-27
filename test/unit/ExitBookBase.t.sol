// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {ExitBookLib} from "../../src/libs/ExitBookLib.sol";
import {PriorityRamp} from "../../src/types/ExitBookTypes.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @dev The smallest concrete book: it exposes the base's request validation directly. Both shipped books reject a
///      zero-asset request before they call it, so this is the only path to the base's own guard.
contract ExitBookBaseHarness is ExitBookBase {
    constructor(address admin) ExitBookBase(admin, 30 days) {}

    function createRequest(address receiver, IERC20 asset, uint256 assets, PriorityRamp calldata ramp, uint256 deadline)
        external
        returns (uint256)
    {
        return _createRequest(msg.sender, receiver, asset, assets, 0, 0, 0, ramp, deadline);
    }

    function _withdraw(uint256, address, uint256) internal pure override returns (uint256) {
        return 0;
    }
}

/// @notice `ExitBookBase` on its own: the constructor, request validation the concrete books cannot reach, cancel,
///         the paged owner read and recovery. The concrete books' paths are covered by `ExitBookFeeSplit.t.sol`
///         (ERC-4626 book) and `test/scenario/MorphoExitBook.t.sol`.
contract ExitBookBaseTest is Test {
    ExitBookBaseHarness internal book;

    function setUp() public {
        book = new ExitBookBaseHarness(address(this));
    }

    function testRevert_createRequest_zeroAssets() public {
        PriorityRamp memory ramp;
        IERC20 asset = IERC20(makeAddr("asset"));
        vm.expectRevert(ExitBookBase.ZeroAssets.selector);
        book.createRequest(address(this), asset, 0, ramp, block.timestamp + 1 days);
    }

    function test_constructor_storesAdminAndLifetime() public {
        address admin = makeAddr("admin");
        ExitBookBaseHarness fresh = new ExitBookBaseHarness(admin);
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), admin), "admin holds DEFAULT_ADMIN_ROLE");
        assertFalse(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), address(this)), "the deployer does not");
        assertEq(fresh.MAX_REQUEST_LIFETIME(), 30 days, "lifetime stored");
    }

    function test_createRequest_endRateAtMaxPriorityFee_accepted() public {
        PriorityRamp memory ramp =
            PriorityRamp({startRate: 0, endRate: book.MAX_PRIORITY_FEE(), rampStart: 0, rampEnd: 0});
        uint256 id = book.createRequest(address(this), _asset(), 1 ether, ramp, block.timestamp + 1 days);
        assertEq(book.getExitRequest(id).endRate, book.MAX_PRIORITY_FEE(), "end rate stored at the cap");
    }

    /// @dev The ramp may end exactly at the deadline.
    function test_createRequest_rampEndAtDeadline_accepted() public {
        PriorityRamp memory ramp = PriorityRamp({startRate: 0, endRate: 0.01e18, rampStart: 0, rampEnd: 1 days});
        uint256 id = book.createRequest(address(this), _asset(), 1 ether, ramp, block.timestamp + 1 days);
        assertEq(book.getExitRequest(id).rampEnd, 1 days, "ramp end stored");
    }

    function testRevert_cancelExitRequest_alreadyClosed() public {
        PriorityRamp memory ramp;
        uint256 id = book.createRequest(address(this), _asset(), 1 ether, ramp, block.timestamp + 1 days);
        book.cancelExitRequest(id);

        vm.expectRevert(ExitBookLib.RequestClosed.selector);
        book.cancelExitRequest(id);
    }

    function test_getOwnerRequestIds_truncatesToCount() public {
        PriorityRamp memory ramp;
        uint256[] memory placed = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            placed[i] = book.createRequest(address(this), _asset(), 1 ether, ramp, block.timestamp + 1 days);
        }

        uint256[] memory ids = book.getOwnerRequestIds(address(this), 0, 2);
        assertEq(ids.length, 2, "truncated to count");
        assertEq(ids[0], placed[0], "first id");
        assertEq(ids[1], placed[1], "second id");
    }

    function test_recoverERC20_byRecoverer() public {
        address recoverer = makeAddr("recoverer");
        address recipient = makeAddr("recipient");
        book.grantRole(book.RECOVERER_ROLE(), recoverer);
        MockERC20 token = new MockERC20("T", "T", 18);
        token.mint(address(book), 3 ether);

        vm.prank(recoverer);
        book.recoverERC20(address(token), recipient, 3 ether);

        assertEq(token.balanceOf(recipient), 3 ether, "recipient holds the recovered tokens");
        assertEq(token.balanceOf(address(book)), 0, "book drained");
    }

    function _asset() internal returns (IERC20) {
        return IERC20(makeAddr("asset"));
    }
}
