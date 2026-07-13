// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice L1 unit suite for `LidoLendERC4626`, modelled from requirements: the
///         vault is a single-market ERC-4626 over the market supply, plus two exits — `fallbackExit`
///         (redeem ordinary liquidity first, then settle the remainder against the risk queue) and `settle`
///         (targeted, liquidity-neutral, subject to the core's settle gate). Deploys a fresh stack via
///         `setup/` and drives the `MarketActions` helpers (which assert deltas/events) plus branch-specific
///         checks. Oracle price is seeded (non-parity); distress is induced via a deliberate price crash.
contract LidoLendERC4626Test is LidoLendSetup {
    using MarketActions for Market;

    MockERC20 internal loan;
    MockERC20 internal collateral;
    address internal vaultImpl;

    function setUp() public {
        loan = new MockERC20("Loan", "LOAN", 18);
        collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
        vaultImpl = address(new LidoLendERC4626(address(protocol.core)));
    }

    function _market() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender liquidity + a borrower at a safe LTV, then a price crash to an unhealthy-but-solvent
    ///      point so the borrower is settle-eligible (in the risk queue, not bad debt).
    function _distress(Market storage m, uint256 lenderLiquidity, uint256 borrow, uint256 crashPrice)
        internal
        returns (address lender, address borrower)
    {
        lender = _actor("lender");
        _fund(m.loanToken, lender, lenderLiquidity);
        m.vaultDeposit(lender, lenderLiquidity);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, borrow);

        MockPriceOracle(address(m.oracle)).setPrice(crashPrice);
        m.accrueInterest();
    }

    /// @dev Borrower posts large collateral and borrows the WHOLE lender supply (idle -> 0), then a crash to
    ///      a solvent-but-unhealthy point. Borrowing the full supply is seed-safe: 1000 collateral values at
    ///      >= 300 at any seed, so max borrow >= 240 > the 100 supply.
    function _distressFull(Market storage m, uint256 lenderLiquidity)
        internal
        returns (address lender, address borrower)
    {
        lender = _actor("lender");
        _fund(m.loanToken, lender, lenderLiquidity);
        m.vaultDeposit(lender, lenderLiquidity);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 1_000 ether);
        m.supplyCollateral(borrower, 1_000 ether);
        m.activateCollateral();
        m.borrow(borrower, lenderLiquidity); // borrow all supply -> idle 0

        // debt == lenderLiquidity; value = 1000·price/1e36 must be in (debt, debt/LLTV).
        // For lenderLiquidity == 100: value in (100, 125) -> price in (0.1e36, 0.125e36).
        MockPriceOracle(address(m.oracle)).setPrice(0.11e36);
        m.accrueInterest();
    }

    function _deployVaultProxy(MarketParams memory p, address controller) internal returns (address) {
        return address(
            new OssifiableProxy(
                vaultImpl,
                address(this),
                abi.encodeWithSignature(
                    "initialize((address,address,address,address,uint256),address,string,string)",
                    p,
                    controller,
                    "n",
                    "s"
                )
            )
        );
    }

    // ── mutations ──

    // ── ERC-4626 round-trips ──

    function test_depositWithdraw_roundTrip() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        uint256 expectedShares = m.vault.previewDeposit(100 ether);
        uint256 shares = m.vaultDeposit(lender, 100 ether);
        assertEq(shares, expectedShares, "minted shares == previewDeposit");
        m.vaultWithdraw(lender, 100 ether);
        assertEq(m.vault.balanceOf(lender), 0, "all shares burned");
    }

    function test_mintRedeem_roundTrip() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, m.vault.previewMint(50 ether));
        m.vaultMint(lender, 50 ether);
        m.vaultRedeem(lender, m.vault.balanceOf(lender));
        assertEq(m.vault.balanceOf(lender), 0, "all shares redeemed");
    }

    // ── maxRedeem is the exact redeem boundary (the property Erc4626ExitBook relies on) ──

    /// @dev When borrowing pushes idle below the owner's full position, `maxRedeem` falls to its
    ///      `convertToShares(liquidAssets)` branch. That value must be self-consistent with `redeem`: the vault
    ///      redeems exactly `maxRedeem` shares and refuses one more. `Erc4626ExitBook` caps availability at
    ///      `maxRedeem` and fills via `redeem`, so this coincidence is what keeps it from under- or over-reporting.
    function test_maxRedeem_isExactRedeemBoundary_underLiquidityConstraint() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        uint256 ownerShares = m.vaultDeposit(lender, 100 ether);

        // Borrow drains idle well below the position -> maxRedeem uses the liquidity fallback, not the balance.
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 1_000 ether);
        m.supplyCollateral(borrower, 1_000 ether);
        m.activateCollateral();
        m.borrow(borrower, 90 ether); // ~10 idle vs the 100 position

        uint256 cap = m.vault.maxRedeem(lender);
        assertGt(cap, 0, "some liquidity redeemable");
        assertLt(cap, ownerShares, "constrained: maxRedeem is the liquidity fallback, not the full balance");

        // One share past the cap is refused -> the vault never redeems beyond its own maxRedeem (no over-report).
        vm.prank(lender);
        vm.expectRevert();
        m.vault.redeem(cap + 1, lender, lender);

        // Exactly the cap redeems in one shot -> maxRedeem is a genuinely redeemable amount (no under-report).
        uint256 expectedOut = m.vault.previewRedeem(cap);
        vm.prank(lender);
        uint256 assetsOut = m.vault.redeem(cap, lender, lender);
        assertEq(assetsOut, expectedOut, "cap redeemed to previewRedeem(cap), exact");
        assertEq(m.vault.balanceOf(lender), ownerShares - cap, "exactly cap shares burned");
    }

    // ── fallbackExit: redeem-first, then settle ──

    function test_fallbackExit_pureRedeem_whenLiquidityCovers() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether); // all idle, nothing borrowed

        (,, uint256 collateralSeized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), lender, 0);
        assertEq(collateralSeized, 0, "no settle leg when ordinary liquidity covers the exit");
        assertEq(m.vault.balanceOf(lender), 0, "fully exited via redeem");
    }

    function test_fallbackExit_redeemThenSettle_whenLiquidityShort() public {
        Market storage m = _market();
        (address lender, address borrower) = _distress(m, 100 ether, 20 ether, 0.22e36); // 80 idle, 20 settles
        uint256 idle = m.core.market(m.id).totalSupplyAssets - m.core.market(m.id).totalBorrowAssets;
        uint128 colBefore = m.core.position(m.id, borrower).collateral;
        (, uint256 loanAssets, uint256 collateralSeized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), lender, 0);
        assertEq(loanAssets, idle, "redeem leg == idle liquidity (exact)");
        assertEq(collateralSeized, colBefore - m.core.position(m.id, borrower).collateral, "seized == position delta");
        assertEq(m.vault.balanceOf(lender), 0, "fully exited: redeem covered idle, settle covered the rest");
    }

    // ── reverts (vault-owned guards) ──

    function testRevert_fallbackExit_zeroShares() public {
        vm.expectRevert(ILidoLendERC4626.ZeroShares.selector);
        _market().vault.fallbackExit(0, address(this), address(this), 0);
    }

    function testRevert_fallbackExit_zeroReceiver() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 10 ether);
        m.vaultDeposit(lender, 10 ether);
        vm.prank(lender);
        vm.expectRevert(ILidoLendERC4626.ZeroAddress.selector);
        m.vault.fallbackExit(1 ether, address(0), lender, 0);
    }

    function testRevert_settle_emptyBorrowers() public {
        address[] memory none = new address[](0);
        vm.expectRevert(ILidoLendERC4626.EmptyBorrowers.selector);
        _market().vault.settle(1 ether, none, address(this), address(this));
    }

    function testRevert_settle_zeroShares() public {
        address[] memory bs = new address[](1);
        bs[0] = _actor("b");
        vm.expectRevert(ILidoLendERC4626.ZeroShares.selector);
        _market().vault.settle(0, bs, address(this), address(this));
    }

    // ── settle: liquidity-neutral & subject to the core gate ──

    function test_settle_liquidityNeutral() public {
        Market storage m = _market();
        (address lender, address borrower) = _distress(m, 100 ether, 20 ether, 0.22e36);
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        uint256 sliceAssets = m.controller.positionOf(borrower).slice;
        uint128 colBefore = m.core.position(m.id, borrower).collateral;
        // The helper asserts loanAssets == 0 (no redeem leg) and the receiver/share deltas.
        (,, uint256 collateralSeized, uint256 debtCanceled) = m.settle(lender, m.vault.balanceOf(lender), bs, lender);
        assertEq(debtCanceled, sliceAssets, "settle cut == settlementFor prediction (exact)");
        assertEq(collateralSeized, colBefore - m.core.position(m.id, borrower).collateral, "seized == position delta");
    }

    function test_fallbackExit_pureSettle_whenNoIdle() public {
        Market storage m = _market();
        (address lender, address borrower) = _distressFull(m, 100 ether); // idle == 0
        uint128 colBefore = m.core.position(m.id, borrower).collateral;
        (, uint256 loanAssets, uint256 collateralSeized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), lender, 0);
        assertEq(loanAssets, 0, "no redeem leg when there is no idle liquidity");
        assertEq(
            collateralSeized, colBefore - m.core.position(m.id, borrower).collateral, "settle seized == position delta"
        );
        assertEq(m.vault.balanceOf(lender), 0, "exit serviced entirely by the settle leg");
    }

    function test_fallbackExit_maxIterations_capsTheSettleLeg() public {
        // `maxIterations = 1` cuts the root borrower once, so the illiquid remainder is only partially
        // settled and the exit is partial (sharesBurned < shares), no revert. (With the default 0->150 the
        // loop would re-cut the re-keyed root until the remainder is fully serviced — a full exit.)
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, 20 ether); // 80 idle; remainder 20

        // One settle cut == the controller's predicted slice; total shares burned == the shares for the
        // 80 idle redeemed PLUS the shares for that one cut — both recomputed before the exit.
        uint256 sliceAssets = m.controller.positionOf(borrower).slice;
        uint256 shares = m.vault.balanceOf(lender);
        uint256 expectedBurned = m.vault.previewWithdraw(80 ether) + m.vault.previewWithdraw(sliceAssets);
        vm.prank(lender);
        (uint256 sharesBurned, uint256 loanAssets,, uint256 debtCanceled) =
            m.vault.fallbackExit(shares, lender, lender, 1);
        assertEq(loanAssets, 80 ether, "redeem leg paid exactly the 80 idle (100 - 20)");
        assertEq(debtCanceled, sliceAssets, "settle leg cut == settlementFor (one cut)");
        assertEq(sharesBurned, expectedBurned, "shares burned == redeem(80) + settle(cut), exact");
        assertEq(m.vault.balanceOf(lender), shares - sharesBurned, "remaining balance == unserviced shares");
    }

    function test_fallbackExit_receiverNotOwner() public {
        Market storage m = _market();
        address owner = _actor("owner");
        _fund(m.loanToken, owner, 100 ether);
        m.vaultDeposit(owner, 100 ether);
        address receiver = _actor("receiver");
        // Helper asserts owner share burn, receiver loan/collateral, and owner!=receiver routing.
        (, uint256 loanAssets,,) = m.fallbackExit(owner, m.vault.balanceOf(owner), receiver, 0);
        // Full idle (no borrow) -> the redeem leg pays out the whole deposit, exactly.
        assertEq(loanAssets, 100 ether, "pure-redeem paid the full deposit");
    }

    function test_fallbackExit_callerWithAllowance() public {
        Market storage m = _market();
        address owner = _actor("owner");
        _fund(m.loanToken, owner, 100 ether);
        m.vaultDeposit(owner, 100 ether);
        uint256 shares = m.vault.balanceOf(owner);

        address caller = _actor("caller");
        vm.prank(owner);
        m.vault.approve(caller, shares);

        vm.prank(caller);
        m.vault.fallbackExit(shares, owner, owner, 0);
        assertEq(m.vault.balanceOf(owner), 0, "caller burned the owner's shares");
        assertEq(m.vault.allowance(owner, caller), 0, "allowance spent for the burn");
    }

    function testRevert_fallbackExit_callerWithoutAllowance() public {
        Market storage m = _market();
        address owner = _actor("owner");
        _fund(m.loanToken, owner, 100 ether);
        m.vaultDeposit(owner, 100 ether);
        uint256 shares = m.vault.balanceOf(owner);

        address caller = _actor("caller");
        vm.prank(caller);
        // OZ ERC20: the caller holds no allowance from owner, needs `shares`.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, caller, 0, shares));
        m.vault.fallbackExit(shares, owner, owner, 0);
    }

    function testRevert_fallbackExit_exceededBalance() public {
        Market storage m = _market();
        address owner = _actor("owner");
        _fund(m.loanToken, owner, 10 ether);
        m.vaultDeposit(owner, 10 ether);
        uint256 tooMany = m.vault.balanceOf(owner) + 1;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ILidoLendERC4626.ExceededBalance.selector, owner, tooMany, m.vault.balanceOf(owner))
        );
        m.vault.fallbackExit(tooMany, owner, owner, 0);
    }

    function testRevert_settle_exceededBalance() public {
        Market storage m = _market();
        address owner = _actor("owner");
        _fund(m.loanToken, owner, 10 ether);
        m.vaultDeposit(owner, 10 ether);
        uint256 tooMany = m.vault.balanceOf(owner) + 1;
        address[] memory bs = new address[](1);
        bs[0] = _actor("b");
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(ILidoLendERC4626.ExceededBalance.selector, owner, tooMany, m.vault.balanceOf(owner))
        );
        m.vault.settle(tooMany, bs, owner, owner);
    }

    function test_settle_receiverNotOwner() public {
        Market storage m = _market();
        (address lender, address borrower) = _distress(m, 100 ether, 20 ether, 0.22e36);
        address receiver = _actor("receiver");
        uint256 sliceAssets = m.controller.positionOf(borrower).slice;
        uint128 colBefore = m.core.position(m.id, borrower).collateral;
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        // Helper asserts owner share burn, receiver collateral, and owner!=receiver routing.
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(lender, m.vault.balanceOf(lender), bs, receiver);
        assertEq(debtCanceled, sliceAssets, "cancelled == settlementFor prediction");
        assertEq(collateralSeized, colBefore - m.core.position(m.id, borrower).collateral, "seized == position delta");
        assertGt(sharesBurned, 0, "settle burned shares");
    }

    // ── initialize guards ──

    function testRevert_initialize_zeroController() public {
        vm.expectRevert(ILidoLendERC4626.ZeroController.selector);
        _deployVaultProxy(_market().params, address(0));
    }

    function testRevert_initialize_zeroLoanToken() public {
        MarketParams memory p = _market().params;
        p.loanToken = address(0);
        vm.expectRevert(ILidoLendERC4626.ZeroLoanToken.selector);
        _deployVaultProxy(p, address(_market().controller));
    }

    function testRevert_initialize_zeroCollateralToken() public {
        MarketParams memory p = _market().params;
        p.collateralToken = address(0);
        vm.expectRevert(ILidoLendERC4626.ZeroCollateralToken.selector);
        _deployVaultProxy(p, address(_market().controller));
    }

    function testRevert_constructor_zeroLidoLend() public {
        vm.expectRevert(ILidoLendERC4626.ZeroLidoLend.selector);
        new LidoLendERC4626(address(0));
    }

    // ── views ──

    function test_maxWithdraw_cappedByFreeLiquidity() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, 20 ether); // 20 of the 100 supplied is borrowed out (safe at any seeded price)

        // Free liquidity = totalSupply - totalBorrow = 100 - 20 = 80; the 100-asset position caps to it.
        assertEq(m.vault.maxWithdraw(lender), 80 ether, "maxWithdraw == free liquidity (100 - 20)");
    }

    // NOTE: the core settle gate ("ordinary liquidity available", debtCanceled > settleableSupply) cannot
    // be strictly tripped through the vault: the core takes `_settleableSupply(id, onBehalf=vault)`, and the
    // vault's Morpho supply is the whole market supply, so settleableSupply == totalBorrow while any cut is
    // bounded by totalBorrow — always at the boundary, never over. A strict trip needs a direct core settle
    // (the fork's own suite / scenario), not a vault-level unit.

    function test_previewFallbackExit_matchesActual_pureRedeem() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);
        uint256 shares = m.vault.balanceOf(lender);

        (uint256 previewLoan,) = m.vault.previewFallbackExit(shares);
        vm.prank(lender);
        (, uint256 loanAssets,,) = m.vault.fallbackExit(shares, lender, lender, 0);
        assertEq(loanAssets, previewLoan, "preview matches the actual redeem-leg payout");
    }

    function test_maxRedeem_cappedByFreeLiquidity() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, 20 ether);

        // 20 borrowed out -> redeemable shares == the shares needed to withdraw the 80 of free liquidity.
        assertEq(m.vault.maxRedeem(lender), m.vault.previewWithdraw(80 ether), "maxRedeem == previewWithdraw(free)");
    }

    function test_totalAssets_tracksDeposit() public {
        Market storage m = _market();
        uint256 before = m.vault.totalAssets();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);
        assertEq(m.vault.totalAssets(), before + 100 ether, "totalAssets rose by the deposit");
    }

    function test_marketParams_returnsConfigured() public view {
        MarketParams memory p = _market().vault.marketParams();
        assertEq(p.loanToken, _market().params.loanToken, "loan token");
        assertEq(p.collateralToken, _market().params.collateralToken, "collateral token");
        assertEq(p.oracle, _market().params.oracle, "oracle");
        assertEq(p.irm, _market().params.irm, "irm");
        assertEq(p.lltv, _market().params.lltv, "lltv");
    }

    // ── maxDeposit / maxMint: deposit-side controller vetoes ──

    /// @dev With no cap and no pause the supply hook vetoes nothing, so both maxes report the ERC-4626
    ///      sentinel `type(uint256).max`, matching what `deposit`/`mint` will honor.
    function test_maxDeposit_maxWhenUncapped() public view {
        Market storage m = _market();
        assertEq(m.vault.maxDeposit(address(this)), type(uint256).max, "uncapped: maxDeposit is the sentinel");
        assertEq(m.vault.maxMint(address(this)), type(uint256).max, "uncapped: maxMint is the sentinel");
    }

    /// @dev A paused market reverts every supply in the hook, so both maxes collapse to 0 irrespective of cap.
    function test_maxDeposit_zeroWhenPaused() public {
        Market storage m = _market();
        m.controller.grantRole(m.controller.PAUSER_ROLE(), address(this));
        m.controller.pauseFor(1 hours);
        assertTrue(m.controller.isPaused(), "market paused");
        assertEq(m.vault.maxDeposit(address(this)), 0, "paused: maxDeposit 0");
        assertEq(m.vault.maxMint(address(this)), 0, "paused: maxMint 0");
    }

    /// @dev Freeze blocks borrow and withdrawCollateral but not plain lender supply, so it must leave the
    ///      deposit maxes untouched — the sentinel here, since no cap is set.
    function test_maxDeposit_unaffectedByFreeze() public {
        Market storage m = _market();
        m.controller.grantRole(m.controller.FREEZER_ROLE(), address(this));
        m.controller.freeze();
        assertEq(m.vault.maxDeposit(address(this)), type(uint256).max, "frozen: deposit still uncapped");
        assertEq(m.vault.maxMint(address(this)), type(uint256).max, "frozen: mint still uncapped");
    }

    /// @dev With a cap set, `maxDeposit` is the remaining headroom `cap - totalSupplyAssets`, and it is the
    ///      EXACT boundary `deposit` honors: depositing precisely `maxDeposit` fills the market to the cap
    ///      (`attempted == cap`, passes), and once at the cap the view drops to 0 so `deposit` rejects one wei
    ///      more at the ERC-4626 layer (`ERC4626ExceededMaxDeposit`) — before the supply hook even runs. This is
    ///      the deposit-side analogue of the maxRedeem exact-boundary test: the corrected view is now
    ///      load-bearing, neither under- nor over-reporting what `deposit` accepts.
    function test_maxDeposit_capHeadroomIsExactDepositBoundary() public {
        Market storage m = _market();
        uint256 cap = 100 ether;
        m.controller.setSupplyCap(cap);

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 30 ether);
        m.vaultDeposit(lender, 30 ether); // no borrow -> no accrual, totalSupplyAssets == 30

        uint256 headroom = m.vault.maxDeposit(lender);
        assertEq(headroom, cap - 30 ether, "maxDeposit == cap - totalSupplyAssets");

        // Depositing exactly the headroom fills the market to the cap (attempted == cap, not > cap).
        address filler = _actor("filler");
        _fund(m.loanToken, filler, headroom + 1);
        m.vaultDeposit(filler, headroom);
        assertEq(m.vault.maxDeposit(filler), 0, "at the cap: no headroom left");

        // One wei more is rejected at the ERC-4626 layer, since `deposit` consults the now-zero `maxDeposit`.
        vm.prank(filler);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, filler, 1, 0));
        m.vault.deposit(1, filler);
    }

    /// @dev Shares form of the capped case: `maxMint` is `maxDeposit` floored through the share conversion, so
    ///      it equals `convertToShares(headroom)`.
    function test_maxMint_mirrorsCappedMaxDeposit() public {
        Market storage m = _market();
        uint256 cap = 100 ether;
        m.controller.setSupplyCap(cap);

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 40 ether);
        m.vaultDeposit(lender, 40 ether);

        uint256 headroom = m.vault.maxDeposit(lender);
        assertEq(headroom, 60 ether, "headroom == cap - 40");
        assertEq(m.vault.maxMint(lender), m.vault.convertToShares(headroom), "maxMint == convertToShares(headroom)");
    }

    /// @dev Tightness of `maxMint` on a RAGGED share ratio (a year of accrued interest breaks the exact
    ///      divisibility a fresh market has): the reported shares resolve to assets within the cap headroom,
    ///      one share more resolves beyond it, and minting exactly `maxMint` executes end to end. Pins the
    ///      Floor rounding — a round-up would report a share count whose mint the supply hook rejects.
    function test_maxMint_isExactMintBoundary_underCapWithInterest() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 50 ether);
        m.vaultDeposit(lender, 50 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 1_000 ether);
        m.supplyCollateral(borrower, 1_000 ether);
        m.activateCollateral();
        m.borrow(borrower, 40 ether); // high utilization -> interest accrues

        vm.warp(block.timestamp + 365 days);
        m.accrueInterest();
        m.controller.setSupplyCap(m.core.market(m.id).totalSupplyAssets + 10 ether);

        uint256 headroom = m.vault.maxDeposit(lender);
        uint256 maxShares = m.vault.maxMint(lender);
        assertLe(m.vault.previewMint(maxShares), headroom, "maxMint resolves within the headroom");
        assertGt(m.vault.previewMint(maxShares + 1), headroom, "one share more resolves beyond the headroom");

        // Minting exactly maxMint clears both the ERC-4626 guard and the supply hook.
        address minter = _actor("minter");
        uint256 assetsNeeded = m.vault.previewMint(maxShares);
        _fund(m.loanToken, minter, assetsNeeded);
        vm.prank(minter);
        m.loanToken.approve(address(m.vault), assetsNeeded);
        vm.prank(minter);
        m.vault.mint(maxShares, minter);
        assertEq(m.vault.balanceOf(minter), maxShares, "minted exactly maxMint");
    }
}
