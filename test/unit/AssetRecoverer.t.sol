// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AssetRecoverer} from "../../src/utils/AssetRecoverer.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @dev Concrete instance of the abstract recoverer, owner wired via `Ownable`. `ERC1155Holder` only lets the
///      test place an ERC-1155 balance on the contract (OZ's mint runs the acceptance check) — the recovery
///      logic under test is unaffected.
contract AssetRecovererHarness is AssetRecoverer, ERC1155Holder {
    constructor(address owner) Ownable(owner) {}
}

/// @dev Reverts on any incoming Ether (no `receive`/payable fallback), to exercise `EtherTransferFailed`.
contract RejectEther {}

contract MockERC721 is ERC721 {
    constructor() ERC721("Mock721", "M721") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @notice Unit coverage for `AssetRecoverer`: every recovery path sends the asset to `owner()` and is gated
///         by `onlyOwner`; the Ether path reverts on a failed transfer. Mixed into the periphery contracts
///         (exit books, deposit gateway), which hold no funds between transactions.
contract AssetRecovererTest is Test {
    // mirror of AssetRecoverer's events for expectEmit
    event EtherRecovered(address indexed recipient, uint256 amount);
    event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);
    event ERC721Recovered(address indexed token, uint256 tokenId, address indexed recipient);
    event ERC1155Recovered(address indexed token, uint256 tokenId, address indexed recipient, uint256 amount);

    address internal owner = makeAddr("owner");
    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");

    AssetRecovererHarness internal rec;

    function setUp() public {
        rec = new AssetRecovererHarness(owner);
    }

    // ── Ether ──

    function test_recoverEther_toRecipient() public {
        vm.deal(address(rec), 3 ether);

        vm.expectEmit(true, true, true, true, address(rec));
        emit EtherRecovered(recipient, 3 ether);

        vm.prank(owner);
        rec.recoverEther(recipient);

        assertEq(recipient.balance, 3 ether, "recipient received all Ether");
        assertEq(address(rec).balance, 0, "contract drained");
    }

    function testRevert_recoverEther_notOwner() public {
        vm.deal(address(rec), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rec.recoverEther(recipient);
    }

    function testRevert_recoverEther_zeroRecipient() public {
        vm.deal(address(rec), 1 ether);
        vm.prank(owner);
        vm.expectRevert(AssetRecoverer.ZeroRecipient.selector);
        rec.recoverEther(address(0));
    }

    function testRevert_recoverEther_transferFailed() public {
        address rejector = address(new RejectEther());
        vm.deal(address(rec), 1 ether);

        vm.prank(owner);
        vm.expectRevert(AssetRecoverer.EtherTransferFailed.selector);
        rec.recoverEther(rejector);
    }

    // ── ERC-20 ──

    function test_recoverERC20_toRecipient() public {
        MockERC20 token = new MockERC20("T", "T", 18);
        token.mint(address(rec), 100 ether);

        vm.expectEmit(true, true, true, true, address(rec));
        emit ERC20Recovered(address(token), recipient, 40 ether);

        vm.prank(owner);
        rec.recoverERC20(address(token), recipient, 40 ether);

        assertEq(token.balanceOf(recipient), 40 ether, "recipient received the recovered amount");
        assertEq(token.balanceOf(address(rec)), 60 ether, "only the requested amount left");
    }

    function testRevert_recoverERC20_notOwner() public {
        MockERC20 token = new MockERC20("T", "T", 18);
        token.mint(address(rec), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rec.recoverERC20(address(token), recipient, 1 ether);
    }

    function testRevert_recoverERC20_zeroRecipient() public {
        MockERC20 token = new MockERC20("T", "T", 18);
        token.mint(address(rec), 1 ether);
        vm.prank(owner);
        vm.expectRevert(AssetRecoverer.ZeroRecipient.selector);
        rec.recoverERC20(address(token), address(0), 1 ether);
    }

    // ── ERC-721 ──

    function test_recoverERC721_toRecipient() public {
        MockERC721 nft = new MockERC721();
        nft.mint(address(rec), 7);

        vm.expectEmit(true, true, true, true, address(rec));
        emit ERC721Recovered(address(nft), 7, recipient);

        vm.prank(owner);
        rec.recoverERC721(address(nft), recipient, 7);

        assertEq(nft.ownerOf(7), recipient, "recipient holds the token");
    }

    function testRevert_recoverERC721_notOwner() public {
        MockERC721 nft = new MockERC721();
        nft.mint(address(rec), 7);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rec.recoverERC721(address(nft), recipient, 7);
    }

    function testRevert_recoverERC721_zeroRecipient() public {
        MockERC721 nft = new MockERC721();
        nft.mint(address(rec), 7);
        vm.prank(owner);
        vm.expectRevert(AssetRecoverer.ZeroRecipient.selector);
        rec.recoverERC721(address(nft), address(0), 7);
    }

    // ── ERC-1155 ──

    function test_recoverERC1155_toRecipient() public {
        MockERC1155 multi = new MockERC1155();
        multi.mint(address(rec), 5, 90);

        vm.expectEmit(true, true, true, true, address(rec));
        emit ERC1155Recovered(address(multi), 5, recipient, 90);

        vm.prank(owner);
        rec.recoverERC1155(address(multi), recipient, 5);

        assertEq(multi.balanceOf(recipient, 5), 90, "recipient received the full balance");
        assertEq(multi.balanceOf(address(rec), 5), 0, "contract drained for the id");
    }

    function testRevert_recoverERC1155_notOwner() public {
        MockERC1155 multi = new MockERC1155();
        multi.mint(address(rec), 5, 90);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rec.recoverERC1155(address(multi), recipient, 5);
    }

    function testRevert_recoverERC1155_zeroRecipient() public {
        MockERC1155 multi = new MockERC1155();
        multi.mint(address(rec), 5, 90);
        vm.prank(owner);
        vm.expectRevert(AssetRecoverer.ZeroRecipient.selector);
        rec.recoverERC1155(address(multi), address(0), 5);
    }
}
