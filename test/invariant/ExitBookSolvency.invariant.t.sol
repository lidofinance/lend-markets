// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {Request, ExitStatus} from "../../src/types/ExitBookTypes.sol";
import {ExitBookHandler} from "./handlers/ExitBookHandler.sol";

contract MockAsset is ERC20 {
    constructor() ERC20("Asset", "AST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Vault", "vAST") ERC4626(asset_) {}
}

/// @notice L4 stateful invariant for the ERC-4626 exit book. A small fixed set of lenders place exit requests
///         against one OZ ERC-4626 vault; one filler fills them; the owner cancels; yield donations move the
///         share price; time advances over the ramp/deadline window. Under any bounded action sequence the book
///         stays a clean pass-through and the request state machine stays sound:
///           1. the book custodies no assets at rest (every fill distributes the full redeem),
///           2. the book custodies no vault shares (Erc4626 is permission-only),
///           3. three-way conservation holds on every fill (lender + filler + service == assetsOut),
///           4. ids are monotonic — a closed request never reopens and `sizeRemaining` never grows,
///           5. statuses partition Open/Filled/Cancelled and closed/expired requests are not fillable.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 250
contract ExitBookSolvencyInvariant is Test {
    uint256 internal constant MAX_LIFETIME = 365 days;

    MockAsset internal asset;
    MockVault internal vault;
    Erc4626ExitBook internal book;
    ExitBookHandler internal handler;

    address internal constant FILLER = address(0xF111E7);
    address internal constant FEE_RECIPIENT = address(0xFEE);
    address internal constant L1 = address(0x1E11dE701);
    address internal constant L2 = address(0x1E11dE702);
    address internal constant L3 = address(0x1E11dE703);

    function setUp() public {
        vm.warp(1_000_000);
        asset = new MockAsset();
        vault = new MockVault(IERC20(address(asset)));
        book = new Erc4626ExitBook(address(this), MAX_LIFETIME);
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), address(this));
        book.grantRole(book.FEE_MANAGER_ROLE(), address(this));
        book.setVaultAllowed(IERC4626(address(vault)), true);
        // A non-zero service fee so the service leg participates in the conservation identity.
        book.setServiceFee(FEE_RECIPIENT, 0.2e18);

        address[] memory lenders = new address[](3);
        lenders[0] = L1;
        lenders[1] = L2;
        lenders[2] = L3;
        handler = new ExitBookHandler(
            book, IERC4626(address(vault)), IERC20(address(asset)), MAX_LIFETIME, FILLER, FEE_RECIPIENT, lenders
        );

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = ExitBookHandler.place.selector;
        selectors[1] = ExitBookHandler.fill.selector;
        selectors[2] = ExitBookHandler.cancel.selector;
        selectors[3] = ExitBookHandler.donateYield.selector;
        selectors[4] = ExitBookHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // 1. The book is a pass-through: it holds no underlying assets at rest.
    function invariant_bookHoldsNoAssets() public view {
        assertEq(asset.balanceOf(address(book)), 0, "book holds no assets at rest");
    }

    // 2. The book never custodies vault shares (Erc4626 is permission-only; shares stay with the lender).
    function invariant_bookHoldsNoShares() public view {
        assertEq(vault.balanceOf(address(book)), 0, "book holds no vault shares");
    }

    // 3. Three-way conservation, accumulated over every fill: the legs reconstruct the redeem proceeds exactly.
    function invariant_threeWayConservation() public view {
        // Recipient legs vs. an independent vault-side measure of what the book redeemed (not the contract's split).
        assertEq(
            handler.sumLenderPaid() + handler.sumFillerPaid() + handler.sumServicePaid(),
            handler.sumAssetsOut(),
            "lender + filler + service == assets redeemed from the vault"
        );
        // ... and, independently, the no-liquidity legs reconstruct the pre-fill `previewRedeem` with no remainder.
        assertEq(handler.sumLegsNoDep(), handler.sumPreviewNoDep(), "no-liquidity legs == previewRedeem proceeds");
    }

    // 4. Monotonic ids / no double-fill: a closed request stays closed and `sizeRemaining` never increases.
    function invariant_monotonicIds() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.idAt(i);
            Request memory r = book.getExitRequest(id);
            assertLe(r.sizeRemaining, handler.sizeCeiling(id), "sizeRemaining never increases");
            if (handler.wasClosed(id)) {
                assertTrue(r.status != ExitStatus.Open, "a closed request never reopens");
                assertEq(r.sizeRemaining, 0, "a closed request has no remaining size");
            }
        }
    }

    // 5. Status partition: every id is exactly one of Open/Filled/Cancelled, and a closed or past-deadline
    //    request is not fillable (its live preview yields zero fillable shares).
    function invariant_statusPartitionAndFillability() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.idAt(i);
            Request memory r = book.getExitRequest(id);
            ExitStatus s = r.status;
            // Exactly one of the three (the enum is total; this asserts a real, owned request, never a zeroed row).
            assertTrue(s == ExitStatus.Open || s == ExitStatus.Filled || s == ExitStatus.Cancelled, "valid status");
            assertTrue(r.owner != address(0), "tracked id is a real request");

            bool closed = s != ExitStatus.Open;
            bool expired = block.timestamp > r.deadline;
            if (closed || expired) {
                assertEq(book.previewFill(id).filledShares, 0, "closed or expired request is not fillable");
            }
        }
    }
}
