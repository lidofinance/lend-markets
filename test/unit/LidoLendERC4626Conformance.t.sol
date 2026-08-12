// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {IrmKind, Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice EIP-4626 conformance for `LidoLendERC4626`, hand-written (no external suite), against the standard's
///         per-method requirements. The vault takes no fee, so the four `preview*` figures are EXACT (== actual),
///         not just bounded; `convertTo*` equals the matching preview; `totalAssets` counts only the Morpho supply
///         position, so direct token donations cannot move the share price. Every check runs on a NON-parity vault
///         (interest has accrued, so the share price is off 1:1). The standard invariants run in the liquid regime
///         (no borrows, so `maxWithdraw == convertToAssets(balance)`); a second section drives the Lido-specific
///         deviations (liquidity-capped `max*`, donation defence, boundary amounts). `LidoLendERC4626.t.sol` keeps
///         the bespoke settle/fallbackExit surface.
contract LidoLendERC4626ConformanceTest is LidoLendSetup {
    using MarketActions for Market;

    address internal alice;
    address internal bob;

    function setUp() public {
        irmKind = IrmKind.Fixed; // flat rate: accrual moves the price deterministically, no adaptive runaway
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        alice = _actor("alice");
        bob = _actor("bob");
        _seedNonParityLiquid();
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _v() internal view returns (IERC4626) {
        return IERC4626(address(_m().vault));
    }

    /// @dev Lift the share price off parity while leaving the vault fully liquid: a lender deposits, a borrower
    ///      borrows part, interest accrues, then the borrower repays in full — restoring idle liquidity but keeping
    ///      the interest that grew the supply position, so `totalAssets > totalSupply`-implied parity.
    function _seedNonParityLiquid() private {
        Market storage m = _m();
        address seedLender = _actor("seedLender");
        _fund(m.loanToken, seedLender, 100 ether);
        m.vaultDeposit(seedLender, 100 ether);

        address seedBorrower = _actor("seedBorrower");
        _fund(m.collateralToken, seedBorrower, 1_000 ether);
        m.supplyCollateral(seedBorrower, 1_000 ether);
        m.activateCollateral();
        m.borrow(seedBorrower, 50 ether);
        m.warpAndAccrue(200 days); // grow the supply position -> price off parity

        uint256 debt = m.core.position(m.id, seedBorrower).borrowShares;
        _fund(m.loanToken, seedBorrower, m.repayAssets(debt));
        m.repay(seedBorrower, debt); // full repay -> idle restored, vault fully liquid again
    }

    /// @dev Fund `who` with `assets` loan tokens and approve the vault to pull them.
    function _fundApprove(address who, uint256 assets) private {
        _fund(_m().loanToken, who, assets);
        vm.prank(who);
        _m().loanToken.approve(address(_m().vault), assets);
    }

    // =========================================================================================================
    // Standard invariants — liquid, non-parity
    // =========================================================================================================

    // ── G1: zero fee -> preview equals actual, exactly ──

    function testFuzz_previewDeposit_isExact(uint256 assets) public {
        assets = bound(assets, 1, 1_000_000 ether);
        _fundApprove(alice, assets);
        uint256 preview = _v().previewDeposit(assets);
        // A nonzero deposit that would mint zero shares is rejected (see `testRevert_subPriceDeposit_...`), so the
        // preview-equals-actual property is asserted only where the deposit is executable.
        vm.assume(preview != 0);
        vm.prank(alice);
        uint256 shares = _v().deposit(assets, alice);
        assertEq(shares, preview, "deposit shares == previewDeposit (no fee)");
    }

    function testFuzz_previewMint_isExact(uint256 shares) public {
        shares = bound(shares, 1, 1_000_000 ether);
        uint256 preview = _v().previewMint(shares);
        _fundApprove(alice, preview);
        vm.prank(alice);
        uint256 assets = _v().mint(shares, alice);
        assertEq(assets, preview, "mint assets == previewMint (no fee)");
    }

    function testFuzz_previewWithdraw_isExact(uint256 assets) public {
        _fundApprove(alice, 1_000_000 ether);
        vm.prank(alice);
        _v().deposit(1_000_000 ether, alice);

        assets = bound(assets, 1, _v().maxWithdraw(alice));
        uint256 preview = _v().previewWithdraw(assets);
        vm.prank(alice);
        uint256 shares = _v().withdraw(assets, alice, alice);
        assertEq(shares, preview, "withdraw shares == previewWithdraw (no fee)");
    }

    function testFuzz_previewRedeem_isExact(uint256 shares) public {
        _fundApprove(alice, 1_000_000 ether);
        vm.prank(alice);
        _v().deposit(1_000_000 ether, alice);

        shares = bound(shares, 1, _v().maxRedeem(alice));
        uint256 preview = _v().previewRedeem(shares);
        vm.prank(alice);
        uint256 assets = _v().redeem(shares, alice, alice);
        assertEq(assets, preview, "redeem assets == previewRedeem (no fee)");
    }

    // ── G2: convertTo* equals the matching preview, is caller-invariant, does not revert ──

    function testFuzz_convert_equalsPreview_andCallerInvariant(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);
        // Zero fee: convertToShares is exactly previewDeposit; convertToAssets is exactly previewRedeem.
        assertEq(_v().convertToShares(amount), _v().previewDeposit(amount), "convertToShares == previewDeposit");
        assertEq(_v().convertToAssets(amount), _v().previewRedeem(amount), "convertToAssets == previewRedeem");

        // MUST NOT vary by caller.
        vm.prank(alice);
        uint256 sA = _v().convertToShares(amount);
        vm.prank(bob);
        uint256 sB = _v().convertToShares(amount);
        assertEq(sA, sB, "convertToShares is caller-invariant");
    }

    // ── G3: round-trips never yield a free profit; the exact result is the preview composition ──

    function testFuzz_roundTrip_depositRedeem_noFreeProfit(uint256 assets) public {
        assets = bound(assets, 1, 1_000_000 ether);
        _fundApprove(alice, assets);
        // Skip the amounts that would mint zero shares — the vault rejects those deposits, so there is no
        // round-trip to bound (see `testRevert_subPriceDeposit_...`).
        vm.assume(_v().previewDeposit(assets) != 0);

        vm.startPrank(alice);
        uint256 out = _v().redeem(_v().deposit(assets, alice), alice, alice);
        vm.stopPrank();

        // The exact redeem amount is pinned by G1 (redeem == previewRedeem); here the invariant is the EIP round-trip
        // bound: a deposit immediately redeemed returns no more than went in (rounding is a loss, never a gain).
        assertLe(out, assets, "no free profit: deposit -> redeem returns no more than put in");
    }

    function testFuzz_roundTrip_mintWithdraw_noFreeProfit(uint256 shares) public {
        shares = bound(shares, 1, 1_000_000 ether);
        uint256 cost = _v().previewMint(shares);
        _fundApprove(alice, cost);

        vm.startPrank(alice);
        _v().mint(shares, alice);
        uint256 back = _v().withdraw(_v().maxWithdraw(alice), alice, alice);
        vm.stopPrank();

        assertLe(back, cost, "no free profit: mint then withdraw returns no more than the mint cost");
    }

    // ── G5: preview rounding direction — mint/withdraw round UP, deposit/redeem round DOWN ──

    function testFuzz_previewRounding_directions(uint256 shares) public view {
        shares = bound(shares, 1, 1_000_000 ether);
        // previewMint (assets to mint `shares`, round UP) and previewRedeem (assets from redeeming `shares`, round
        // DOWN) are the ceil and floor of the same ratio, so they are equal (exact division) or differ by exactly 1.
        uint256 up = _v().previewMint(shares);
        uint256 down = _v().previewRedeem(shares);
        assertTrue(up == down || up == down + 1, "previewMint == previewRedeem or exactly one more (up vs down)");
    }

    // ── G8: standard withdraw/redeem on behalf of an owner — allowance, receiver, event ──

    function test_withdraw_onBehalf_spendsAllowance_paysReceiver() public {
        _fundApprove(alice, 100 ether);
        vm.prank(alice);
        _v().deposit(100 ether, alice);

        uint256 assets = 40 ether;
        uint256 shares = _v().previewWithdraw(assets);
        vm.prank(alice);
        _v().approve(bob, shares);

        uint256 recvBefore = _m().loanToken.balanceOf(address(0xCAFE));
        vm.expectEmit(true, true, true, true, address(_v()));
        emit IERC4626.Withdraw(bob, address(0xCAFE), alice, assets, shares);
        vm.prank(bob);
        uint256 burned = _v().withdraw(assets, address(0xCAFE), alice);

        assertEq(burned, shares, "shares burned == previewWithdraw");
        assertEq(_m().loanToken.balanceOf(address(0xCAFE)) - recvBefore, assets, "assets paid to receiver");
        assertEq(_v().allowance(alice, bob), 0, "allowance fully spent");
    }

    function testRevert_withdraw_onBehalf_withoutAllowance() public {
        _fundApprove(alice, 100 ether);
        vm.prank(alice);
        _v().deposit(100 ether, alice);

        uint256 shares = _v().previewWithdraw(40 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, shares));
        _v().withdraw(40 ether, bob, alice);
    }

    // ── G11: asset / decimals / max{Deposit,Mint} ──

    function test_asset_decimals_maxDepositMint() public view {
        assertEq(_v().asset(), address(_m().loanToken), "asset == loan token");
        assertEq(
            _v().decimals(),
            MockERC20(address(_m().loanToken)).decimals(),
            "vault decimals == asset decimals (offset 0)"
        );
        assertEq(_v().maxDeposit(alice), type(uint256).max, "maxDeposit unlimited");
        assertEq(_v().maxMint(alice), type(uint256).max, "maxMint unlimited");
    }

    // =========================================================================================================
    // Lido deviations — donation defence, liquidity cap, boundaries
    // =========================================================================================================

    // ── G4: totalAssets counts only the Morpho position, so a direct token donation cannot move the price ──

    function test_donation_isUncounted_priceUnmoved() public {
        uint256 taBefore = _v().totalAssets();
        uint256 ppsBefore = _v().convertToAssets(1e18);

        _fund(_m().loanToken, address(this), 1_000 ether);
        _m().loanToken.transfer(address(_v()), 1_000 ether); // direct donation

        assertEq(_v().totalAssets(), taBefore, "direct donation is uncounted");
        assertEq(_v().convertToAssets(1e18), ppsBefore, "share price unmoved by donation");
    }

    // ── G6 / G9: max* and the revert-past-cap boundary under a liquidity constraint ──

    function test_maxWithdrawRedeem_cappedByLiquidity_andRevertPastCap() public {
        _fundApprove(alice, 100 ether);
        vm.prank(alice);
        uint256 shares = _v().deposit(100 ether, alice);

        // Drain idle below alice's position so the liquidity cap binds.
        address borrower = _actor("borrower");
        _fund(_m().collateralToken, borrower, 1_000 ether);
        _m().supplyCollateral(borrower, 1_000 ether);
        _m().activateCollateral();
        _m().borrow(borrower, 130 ether); // idle now well below the ~200 total position

        // Exact: the cap is the free liquidity. maxWithdraw == idle (assets), maxRedeem == convertToShares(idle).
        uint256 idle = _m().core.market(_m().id).totalSupplyAssets - _m().core.market(_m().id).totalBorrowAssets;
        assertEq(_v().maxWithdraw(alice), idle, "maxWithdraw == free liquidity");
        uint256 capShares = _v().maxRedeem(alice);
        assertEq(capShares, _v().convertToShares(idle), "maxRedeem == convertToShares(free liquidity)");

        // One past the cap reverts; exactly the cap succeeds.
        vm.prank(alice);
        vm.expectRevert();
        _v().redeem(capShares + 1, alice, alice);

        vm.prank(alice);
        _v().redeem(capShares, alice, alice);
        assertEq(_v().balanceOf(alice), shares - capShares, "exactly the cap redeemed");
    }

    // ── G7: boundary amounts — zero deposit is a no-op, and a sub-price deposit that would mint zero shares is
    //    rejected (VLT-01 defense in depth), not silently accepted for dust ──

    function test_zeroDeposit_mintsZero() public {
        _fundApprove(alice, 0);
        vm.prank(alice);
        uint256 shares = _v().deposit(0, alice);
        assertEq(shares, 0, "zero deposit mints zero shares");
        assertEq(_v().balanceOf(alice), 0, "no shares credited");
    }

    /// @dev At a >1 share price a 1-wei deposit floors to zero shares. `previewDeposit` still reports that 0
    ///      (the views never revert), but the deposit itself is rejected with `ZeroSharesMinted` rather than
    ///      pulling the wei as dust — a nonzero deposit must never mint zero shares. The wei stays with the caller.
    function testRevert_subPriceDeposit_zeroSharesRejected() public {
        assertEq(_v().previewDeposit(1), 0, "1 wei previews to zero shares at a >1 price");

        _fundApprove(alice, 1);
        uint256 assetsBefore = _m().loanToken.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILidoLendERC4626.ZeroSharesMinted.selector, uint256(1)));
        _v().deposit(1, alice);

        assertEq(_v().balanceOf(alice), 0, "no shares credited");
        assertEq(_m().loanToken.balanceOf(alice), assetsBefore, "the wei is not pulled: deposit reverted");
    }

    // =========================================================================================================
    // State matrix — the EIP `max*` MUST equal the boundary where the action reverts, in every state
    // =========================================================================================================

    function _controller() private view returns (LidoLendMarketController) {
        return LidoLendMarketController(address(_m().controller));
    }

    function _pause() private {
        LidoLendMarketController c = _controller();
        c.grantRole(c.PAUSER_ROLE(), address(this));
        c.pauseFor(1 hours);
    }

    function _freeze() private {
        LidoLendMarketController c = _controller();
        c.grantRole(c.FREEZER_ROLE(), address(this));
        c.freeze();
    }

    /// @dev Give alice a position and record the loan she holds, so withdraw/redeem have something to act on.
    function _seedAlice(uint256 assets) private returns (uint256 shares) {
        _fundApprove(alice, assets);
        vm.prank(alice);
        shares = _v().deposit(assets, alice);
    }

    /// @dev `preview*`, `convertTo*` and `max*` are views and MUST NOT revert in any state (EIP).
    function _assertViewsNeverRevert() private view {
        _v().convertToShares(1 ether);
        _v().convertToAssets(1 ether);
        _v().previewDeposit(1 ether);
        _v().previewMint(1 ether);
        _v().previewWithdraw(1 ether);
        _v().previewRedeem(1 ether);
        _v().maxDeposit(alice);
        _v().maxMint(alice);
        _v().maxWithdraw(alice);
        _v().maxRedeem(alice);
    }

    // ── Frozen: freeze gates borrows only; lender deposit/withdraw are unaffected ──

    function test_state_frozen_lenderFlowsUnaffected() public {
        uint256 shares = _seedAlice(100 ether);
        _freeze();

        _assertViewsNeverRevert();
        assertEq(_v().maxDeposit(alice), type(uint256).max, "frozen: deposits still unlimited");
        assertEq(_v().maxRedeem(alice), shares, "frozen: full redeem still available");

        // deposit and withdraw both still work while frozen.
        _fundApprove(alice, 10 ether);
        vm.prank(alice);
        _v().deposit(10 ether, alice);
        vm.prank(alice);
        _v().withdraw(5 ether, alice, alice);
    }

    // ── Paused: `_checkResumed` gates the whole `on()`, so every flow reverts -> all max* MUST be 0 ──

    function test_state_paused_disablesEverything() public {
        _seedAlice(100 ether);
        _pause();

        _assertViewsNeverRevert();

        _fundApprove(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert();
        _v().deposit(10 ether, alice);
        vm.prank(alice);
        vm.expectRevert();
        _v().withdraw(1 ether, alice, alice);

        // A disabled flow makes its max the amount that would not revert: zero.
        assertEq(_v().maxDeposit(alice), 0, "paused: maxDeposit == 0");
        assertEq(_v().maxMint(alice), 0, "paused: maxMint == 0");
        assertEq(_v().maxWithdraw(alice), 0, "paused: maxWithdraw == 0");
        assertEq(_v().maxRedeem(alice), 0, "paused: maxRedeem == 0");
    }

    // ── Supply cap: maxDeposit MUST be the remaining headroom, and deposit(maxDeposit) MUST NOT revert ──

    function test_state_supplyCap_maxDepositReflectsHeadroom() public {
        _seedAlice(100 ether); // establish some totalSupplyAssets
        uint256 supplied = _m().core.market(_m().id).totalSupplyAssets;
        uint256 cap = supplied + 40 ether;
        _controller().setSupplyCap(cap);

        uint256 headroom = cap - supplied;
        assertEq(_v().maxDeposit(alice), headroom, "capped: maxDeposit == cap - totalSupplyAssets");

        // Depositing exactly the reported max MUST succeed; one wei more MUST revert.
        _fundApprove(bob, headroom + 1);
        vm.prank(bob);
        _v().deposit(headroom, bob);
        vm.prank(bob);
        vm.expectRevert();
        _v().deposit(1, bob);
    }
}
