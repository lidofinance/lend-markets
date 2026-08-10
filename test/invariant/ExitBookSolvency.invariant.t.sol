// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    using SafeERC20 for IERC20;

    uint256 public allocatedAssets;

    constructor(IERC20 asset_) ERC20("Vault", "vAST") ERC4626(asset_) {}

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + allocatedAssets;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), IERC20(asset()).balanceOf(address(this)));
    }

    function allocate(uint256 assets) external {
        allocatedAssets += assets;
        IERC20(asset()).safeTransfer(address(0xA110CA7E), assets);
    }

    function realizeLoss(uint256 assets) external {
        allocatedAssets -= assets;
    }
}

/// @notice L4 stateful invariant for the ERC-4626 exit book. A small fixed set of lenders place exit requests
///         against one liquidity-aware ERC-4626 vault; one filler fills them; the owner cancels; yield donations,
///         source allocations, pause state, and time move independently. Under any bounded action sequence:
///           1. the book custodies no assets at rest (every fill distributes the full redeem),
///           2. the book custodies no vault shares (Erc4626 is permission-only),
///           3. measured receiver, reward-recipient, and service payouts sum to exact withdrawals,
///           4. stored remainders and statuses exactly match the handler model.
///         The handler also checks that fills never use executor assets or source shares, plus share limits and
///         rollback of failed, paused, closed, or expired fills.
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
    address internal constant REWARD_RECIPIENT = address(0xB0B);
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
            book,
            IERC4626(address(vault)),
            IERC20(address(asset)),
            MAX_LIFETIME,
            FILLER,
            REWARD_RECIPIENT,
            FEE_RECIPIENT,
            lenders
        );
        book.grantRole(book.PAUSER_ROLE(), address(handler));
        book.grantRole(book.RESUMER_ROLE(), address(handler));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = ExitBookHandler.place.selector;
        selectors[1] = ExitBookHandler.fill.selector;
        selectors[2] = ExitBookHandler.cancel.selector;
        selectors[3] = ExitBookHandler.donateYield.selector;
        selectors[4] = ExitBookHandler.warp.selector;
        selectors[5] = ExitBookHandler.attemptUnavailableFill.selector;
        selectors[6] = ExitBookHandler.allocateLiquidity.selector;
        selectors[7] = ExitBookHandler.setPaused.selector;
        selectors[8] = ExitBookHandler.attemptLateShareFailure.selector;
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

    // 3. Independently measured payout legs reconstruct every successful exact withdrawal.
    function invariant_payoutConservation() public view {
        assertEq(
            handler.sumReceiverPaid() + handler.sumRewardPaid() + handler.sumServicePaid(),
            handler.sumFilledAssets(),
            "receiver + reward + service == exact fills"
        );
    }

    // 4. Monotonic ids / no double-fill: every request has its exact modelled remainder and terminal status.
    function invariant_monotonicIds() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.idAt(i);
            Request memory r = book.getExitRequest(id);
            assertEq(id, i + 1, "ids are sequential");
            assertTrue(r.owner != address(0), "tracked id is a real request");
            assertEq(r.assetsRemaining, handler.expectedRemaining(id), "exact model remainder");
            assertEq(uint256(r.status), uint256(handler.expectedStatus(id)), "exact model status");
            if (r.status != ExitStatus.Open) assertEq(r.assetsRemaining, 0, "closed request has no remainder");
        }
    }

    /// @dev Deterministically reaches the critical branches whose occurrence in a random campaign is not
    ///      guaranteed: exact direct and externally prepared fills, yield retention, share protection, and
    ///      late/paused/closed/expired rollback.
    function test_seededCriticalPaths_areNonVacuous() public {
        handler.place(0, 1_000 ether, 500 ether, 0.01e18, 0.01e18, 0, 0, 0);
        handler.fill(0, 500 ether, false);
        assertEq(handler.fillCount(), 1, "direct fill succeeds");
        assertGt(handler.sumRewardPaid(), 0, "non-zero reward leg reached");
        assertGt(handler.sumServicePaid(), 0, "non-zero service leg reached");

        handler.place(1, 1_000 ether, 500 ether, 0, 0, 0, 0, 0);
        handler.allocateLiquidity(asset.balanceOf(address(vault)));
        handler.fill(0, 500 ether, true);
        assertEq(handler.fillCount(), 2, "externally prepared fill succeeds");
        assertGt(vault.balanceOf(FILLER), 0, "external source position is retained by the filler");
        assertEq(handler.protectedFillCount(), 1, "protected fill succeeds");

        handler.place(3, 1_000 ether, 500 ether, 0, 0, 0, 0, 0);
        Request memory yieldedRequest = book.getExitRequest(book.lastRequestId());
        uint256 ownerSharesBefore = vault.balanceOf(yieldedRequest.owner);
        uint256 requiredShares = vault.previewWithdraw(yieldedRequest.assetsTotal);
        handler.donateYield(100 ether);
        handler.fill(0, 500 ether, false);
        assertEq(handler.fillCount(), 3, "yielded source still withdraws the exact fill");
        assertEq(handler.protectedFillCount(), 2, "yield reduces rather than increases protected burn");
        assertLt(
            ownerSharesBefore - vault.balanceOf(yieldedRequest.owner),
            requiredShares,
            "yield stays with owner through a lower share burn"
        );

        handler.place(5, 1_000 ether, 500 ether, 0, 0, 0, 0, 0);
        handler.attemptLateShareFailure(0, 500 ether);
        assertEq(handler.lateShareFailureCount(), 1, "post-placement loss trips share protection and rolls back");

        handler.setPaused(true);
        handler.place(0, 1_000 ether, 500 ether, 0, 0, 0, 0, 0);
        assertEq(handler.pausedPlacementAttempts(), 1, "paused placement rolled back");
        handler.fill(0, 500 ether, true);
        assertEq(handler.pausedFillFailures(), 1, "paused fill rolled back");
        handler.setPaused(false);

        handler.cancel(0);
        handler.attemptUnavailableFill(0);
        assertEq(handler.closedFillFailures(), 1, "closed fill rolled back");

        handler.place(4, 1_000 ether, 500 ether, 0, 0, 0, 0, 0);
        handler.warp(1 hours);
        handler.attemptUnavailableFill(4);
        assertEq(handler.expiredFillFailures(), 1, "expired fill rolled back");
        assertEq(handler.unavailableFillAttempts(), 2, "closed and expired paths reached");
    }
}
