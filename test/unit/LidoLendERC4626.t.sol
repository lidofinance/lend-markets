// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, MarketParams, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {SettlementConfig, SettlementSlice, SettlementQuote} from "../../src/types/SettlementTypes.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {IrmKind, Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice L1 unit suite for `LidoLendERC4626`: the
///         vault is a single-market ERC-4626 over the market supply, plus two exits — `fallbackExit`
///         (redeem ordinary liquidity first, then settle the remainder against the risk queue) and `settle`
///         (targeted, liquidity-neutral, and gated by the borrower's personal settlement LTV). Deploys a fresh stack
/// via `setup/` and drives the `MarketActions` helpers (which assert deltas/events) plus branch-specific
///         checks. Oracle price is seeded (non-parity); distress is induced via a deliberate price crash.
contract LidoLendERC4626Test is LidoLendSetup {
    using MarketActions for Market;
    using SharesMathLib for uint256;

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

    function _settlementForDebtAssets(Market storage m, address borrower) internal view returns (uint256) {
        SettlementQuote memory quote = m.controller.settlementFor(borrower, 0);
        assertGt(quote.personal.remainingBorrowShares, 0, "precondition: personal cut is partial");
        MorphoMarket memory market_ = m.core.market(m.id);
        return quote.personal.borrowShares.toAssetsUp(market_.totalBorrowAssets, market_.totalBorrowShares);
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

    function _deploySixDecimalMarket() internal returns (Market storage m) {
        irmKind = IrmKind.Fixed;
        MockERC20 loan6 = new MockERC20("Mock USD Stablecoin", "USD6", 6);
        MockERC20 collateral18 = new MockERC20("Mock Yield Dollar", "YLD18", 18);
        m = _deployProtocol(_defaultConfig(address(loan6), address(collateral18), address(0)));

        // Keep the same real-terms oracle ratio after introducing the 12-decimal token gap.
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 1e12);
    }

    function _seedSixDecimalLiquidityBoundary(Market storage m, address lender, address borrower)
        internal
        returns (uint256 ownerShares, uint256 liquidAssets)
    {
        _fund(m.loanToken, lender, 100_000e6);
        ownerShares = m.vaultDeposit(lender, 100_000e6);

        _fund(m.collateralToken, borrower, 1_000_000 ether);
        m.supplyCollateral(borrower, 1_000_000 ether);
        m.activateCollateral();
        m.borrow(borrower, 90_000e6);

        liquidAssets = m.controller.maxWithdrawableAssets(address(m.vault));
        assertEq(liquidAssets, 10_000e6, "exactly 10,000 loan tokens remain liquid");
    }

    function _assertSixDecimalTargetedSettle(
        Market storage m,
        address lender,
        address borrower,
        uint256 shares,
        uint256 availableLiquidity
    ) internal {
        // Request assets, redemption budget, expected cut, core shares before, borrower debt shares before.
        uint256[5] memory expected;
        {
            expected[0] = m.vault.previewRedeem(shares);
            SettlementQuote memory quote = m.controller.settlementFor(borrower, 0);
            MorphoMarket memory market_ = m.core.market(m.id);
            expected[1] = expected[0].toSharesDown(market_.totalSupplyAssets, market_.totalSupplyShares);
            uint256 budgetAssets = expected[1].toAssetsDown(market_.totalSupplyAssets, market_.totalSupplyShares);
            uint256 borrowShares = Math.min(
                quote.personal.borrowShares,
                budgetAssets.toSharesDown(market_.totalBorrowAssets, market_.totalBorrowShares)
            );
            uint256 debtAssets = borrowShares.toAssetsUp(market_.totalBorrowAssets, market_.totalBorrowShares);
            expected[2] = debtAssets.toSharesUp(market_.totalSupplyAssets, market_.totalSupplyShares);
            expected[3] = m.core.position(m.id, address(m.vault)).supplyShares;
            expected[4] = m.core.position(m.id, borrower).borrowShares;
        }

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(lender, shares, borrowers, lender);

        assertLt(expected[0], availableLiquidity, "request is fully covered by current free liquidity");
        assertGt(expected[1], 0, "request has a positive redemption settlement budget");
        assertEq(
            expected[3] - m.core.position(m.id, address(m.vault)).supplyShares,
            expected[2],
            "settlement consumes the independently modeled redemption budget"
        );
        assertEq(sharesBurned, shares, "the whole request is serviced");
        assertGt(collateralSeized, 0, "targeted request seizes collateral");
        assertGt(debtCanceled, 0, "targeted request cancels debt");
        assertLt(m.core.position(m.id, borrower).borrowShares, expected[4], "borrower debt reduced");
        MorphoMarket memory marketAfter = m.core.market(m.id);
        assertEq(
            marketAfter.totalSupplyAssets - marketAfter.totalBorrowAssets,
            availableLiquidity,
            "targeted settle preserves free liquidity"
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

    // ── maxRedeem is a conservative, honoured redeem boundary ──

    /// @dev When borrowing pushes idle below the owner's full position, `maxRedeem` falls to its
    ///      `convertToShares(liquidAssets)` branch. That value must be self-consistent with `redeem`: the vault
    ///      redeems exactly `maxRedeem` shares and refuses one more. The floor conversion may exclude additional
    ///      shares on the same `previewRedeem` rounding plateau; `fallbackExit` services that boundary separately.
    function test_maxRedeem_isHonouredConservativeBoundary_underLiquidityConstraint() public {
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
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, lender, cap + 1, cap)
        );
        m.vault.redeem(cap + 1, lender, lender);

        // Exactly the reported conservative cap remains executable in one redeem.
        uint256 expectedOut = m.vault.previewRedeem(cap);
        vm.prank(lender);
        uint256 assetsOut = m.vault.redeem(cap, lender, lender);
        assertEq(assetsOut, expectedOut, "cap redeemed to previewRedeem(cap), exact");
        assertEq(m.vault.balanceOf(lender), ownerShares - cap, "exactly cap shares burned");
    }

    /// @dev A 6-decimal loan token creates a wide redeem rounding plateau. The requested shares exceed the
    ///      conservative `maxRedeem`, but their full floor-rounded value still fits in liquidity. `fallbackExit`
    ///      must burn those exact shares instead of routing a one-share remainder into settlement.
    function test_fallbackExit_burnsExactShares_onSixDecimalRedeemPlateau() public {
        Market storage m = _deploySixDecimalMarket();
        address owner = _actor("six-decimal-owner");
        address borrower = _actor("six-decimal-borrower");
        address caller = _actor("six-decimal-caller");
        address receiver = _actor("six-decimal-receiver");
        uint256 shares;
        uint256 expectedLoanAssets;
        {
            (uint256 ownerShares, uint256 liquidAssets) = _seedSixDecimalLiquidityBoundary(m, owner, borrower);
            uint256 maxRedeem_ = m.vault.maxRedeem(owner);
            shares = m.vault.previewWithdraw(liquidAssets) + 1;
            expectedLoanAssets = m.vault.previewRedeem(shares);

            assertLt(maxRedeem_, ownerShares, "owner is liquidity-constrained");
            assertGt(shares, maxRedeem_, "request is past the public redeem gate");
            assertEq(expectedLoanAssets, liquidAssets, "request remains on the last liquid asset plateau");
            assertLt(m.vault.previewWithdraw(liquidAssets), shares, "withdraw would burn too few shares");

            vm.prank(owner);
            vm.expectRevert(
                abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, owner, shares, maxRedeem_)
            );
            m.vault.redeem(shares, receiver, owner);
        }

        vm.prank(owner);
        m.vault.approve(caller, shares);

        uint256 ownerSharesBefore = m.vault.balanceOf(owner);
        uint256 receiverLoanBefore = m.loanToken.balanceOf(receiver);
        vm.prank(caller);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            m.vault.fallbackExit(shares, receiver, owner, 0);

        assertEq(sharesBurned, shares, "fallbackExit exits the requested shares");
        assertEq(loanAssets, expectedLoanAssets, "liquid leg paid the preview amount");
        assertEq(m.loanToken.balanceOf(receiver), receiverLoanBefore + expectedLoanAssets, "receiver got loan assets");
        assertEq(m.vault.balanceOf(owner), ownerSharesBefore - shares, "owner's exact requested shares burned");
        assertEq(m.vault.allowance(owner, caller), 0, "delegated allowance spent exactly");
        assertEq(collateralSeized, 0, "no settle leg needed");
        assertEq(debtCanceled, 0, "no debt canceled");
    }

    /// @dev Targeted settlement uses the request's redemption value even when the request is fully covered by
    ///      free liquidity. The 6-decimal loan token exercises the vault's 12-decimal offset and nontrivial share math.
    function test_settle_usesRedemptionBudget_withSixDecimalLoanToken() public {
        Market storage m = _deploySixDecimalMarket();
        address lender = _actor("six-decimal-settle-lender");
        address borrower = _actor("six-decimal-settle-borrower");
        (, uint256 availableLiquidity) = _seedSixDecimalLiquidityBoundary(m, lender, borrower);

        uint256 borrowerDebt = m.core.market(m.id).totalBorrowAssets;
        uint256 borrowerCollateral = m.core.position(m.id, borrower).collateral;
        MockPriceOracle(address(m.oracle)).setPrice(borrowerDebt * 1e36 / borrowerCollateral * 110 / 100);
        m.accrueInterest();
        SettlementConfig memory fullCut = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 2_000_000 ether, ltvStepBps: 100
        });
        m.controller.setSettlementConfig(fullCut);
        vm.prank(borrower);
        m.controller.setSettlementLtv(0.8e18);

        uint256 belowBoundaryShares = m.vault.previewWithdraw(availableLiquidity - 1);
        assertLt(m.vault.previewRedeem(belowBoundaryShares), availableLiquidity, "request is below liquidity");
        _assertSixDecimalTargetedSettle(m, lender, borrower, belowBoundaryShares, availableLiquidity);
    }

    /// @dev A sub-asset-unit share fragment has zero current redeem value. It can still be burned exactly without
    ///      touching core accounting or entering the settlement leg.
    function test_fallbackExit_burnsZeroValueShareDust_withoutSettlement() public {
        Market storage m = _deploySixDecimalMarket();
        address lender = _actor("six-decimal-lender");
        address dustOwner = _actor("six-decimal-dust-owner");

        _fund(m.loanToken, lender, 100_000e6);
        m.vaultDeposit(lender, 100_000e6);
        vm.prank(lender);
        m.vault.transfer(dustOwner, 1);

        assertEq(m.vault.previewRedeem(1), 0, "one share wei has zero asset value");
        uint256 coreSupplySharesBefore = m.core.position(m.id, address(m.vault)).supplyShares;
        uint256 vaultAssetsBefore = m.vault.totalAssets();

        vm.prank(dustOwner);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            m.vault.fallbackExit(1, dustOwner, dustOwner, 0);

        assertEq(sharesBurned, 1, "dust share burned");
        assertEq(loanAssets, 0, "zero loan assets paid");
        assertEq(collateralSeized, 0, "no collateral seized");
        assertEq(debtCanceled, 0, "no debt canceled");
        assertEq(m.vault.balanceOf(dustOwner), 0, "dust owner fully exited");
        assertEq(m.core.position(m.id, address(m.vault)).supplyShares, coreSupplySharesBefore, "core shares unchanged");
        assertEq(m.vault.totalAssets(), vaultAssetsBefore, "vault assets unchanged");
    }

    /// @dev Pausing collapses withdrawable liquidity to zero. A positive-value fallback exit therefore cannot use
    ///      the internal liquid leg; with no settleable borrower it reverts instead of silently returning a no-op.
    function testRevert_fallbackExit_doesNotNoopPositiveValueShares_whenPaused() public {
        Market storage m = _market();
        address lender = _actor("paused-lender");
        _fund(m.loanToken, lender, 100 ether);
        uint256 shares = m.vaultDeposit(lender, 100 ether);

        m.controller.grantRole(m.controller.PAUSER_ROLE(), address(this));
        m.controller.pauseFor(1 hours);

        vm.prank(lender);
        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        m.vault.fallbackExit(shares, lender, lender, 0);

        assertEq(m.vault.balanceOf(lender), shares, "lender balance unchanged");
    }

    /// @dev The controller reports zero withdrawable assets while paused. The liquid leg must treat that zero as
    ///      unavailable even when `previewRedeem(1) == 0`, rather than satisfying the liquidity comparison.
    function testRevert_fallbackExit_doesNotBurnZeroValueShareDust_whenPaused() public {
        Market storage m = _deploySixDecimalMarket();
        address lender = _actor("paused-six-decimal-lender");
        address owner = _actor("paused-six-decimal-dust-owner");
        address caller = _actor("paused-six-decimal-caller");

        _fund(m.loanToken, lender, 100_000e6);
        m.vaultDeposit(lender, 100_000e6);
        vm.prank(lender);
        m.vault.transfer(owner, 1);
        assertEq(m.vault.previewRedeem(1), 0, "one share wei is on the zero-value plateau");

        m.controller.grantRole(m.controller.PAUSER_ROLE(), address(this));
        m.controller.pauseFor(1 hours);
        assertEq(m.vault.maxRedeem(owner), 0, "zero controller limit gates zero-value shares while paused");
        vm.prank(owner);
        m.vault.approve(caller, 1);

        vm.prank(caller);
        vm.expectRevert(ILidoLendERC4626.ZeroMorphoSupplyShares.selector);
        m.vault.fallbackExit(1, owner, owner, 0);

        assertEq(m.vault.balanceOf(owner), 1, "paused dust share not burned");
        assertEq(m.vault.allowance(owner, caller), 1, "paused call spends no allowance");
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
        // The gas-sized default (0) stops before this book drains, so the exit resumes over calls.
        uint256 loanAssets;
        uint256 collateralSeized;
        // terminates: a call that burns nothing reverts NothingSettled
        while (m.vault.balanceOf(lender) != 0) {
            (, uint256 loan, uint256 seized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), lender, 0);
            loanAssets += loan;
            collateralSeized += seized;
        }
        assertEq(loanAssets, idle, "liquid leg == idle liquidity (exact)");
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

    // ── settle: liquidity-neutral and personal-LTV-gated ──

    function test_settle_liquidityNeutral() public {
        Market storage m = _market();
        (address lender, address borrower) = _distress(m, 100 ether, 20 ether, 0.22e36);
        vm.prank(borrower);
        m.controller.setSettlementLtv(0.5e18);
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        uint256 expectedDebtCanceled = _settlementForDebtAssets(m, borrower);
        uint128 colBefore = m.core.position(m.id, borrower).collateral;
        // The helper asserts liquidity-neutrality (no liquid leg) and the receiver/share deltas.
        (, uint256 collateralSeized, uint256 debtCanceled) = m.settle(lender, m.vault.balanceOf(lender), bs, lender);
        assertEq(debtCanceled, expectedDebtCanceled, "settle cut == settlementFor prediction (exact)");
        assertEq(collateralSeized, colBefore - m.core.position(m.id, borrower).collateral, "seized == position delta");
    }

    function test_fallbackExit_pureSettle_whenNoIdle() public {
        Market storage m = _market();
        (address lender, address borrower) = _distressFull(m, 100 ether); // idle == 0
        uint128 colBefore = m.core.position(m.id, borrower).collateral;
        // The gas-sized default (0) stops before this book drains, so the exit resumes over calls.
        uint256 loanAssets;
        uint256 collateralSeized;
        uint256 calls;
        // terminates: a call that burns nothing reverts NothingSettled
        while (m.vault.balanceOf(lender) != 0) {
            ++calls;
            (, uint256 loan, uint256 seized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), lender, 0);
            loanAssets += loan;
            collateralSeized += seized;
        }
        assertGt(calls, 1, "the default bound spreads this drain over calls");
        assertEq(loanAssets, 0, "no liquid leg when there is no idle liquidity");
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

        uint256 debtAssets = m.controller.positionOf(borrower).debtAssets;
        uint256 collateralValue = 100 ether * MockPriceOracle(address(m.oracle)).price() / 1e36;
        uint256 currentLtv = Math.mulDiv(debtAssets, 1e18, collateralValue);
        vm.prank(borrower);
        m.controller.setSettlementLtv(currentLtv / 2);

        // One settle cut == the controller's predicted slice; total shares burned == the shares for the
        // 80 idle redeemed PLUS the shares for that one cut — both recomputed before the exit.
        ILidoLendMarketController.BorrowerPosition memory dashboard = m.controller.positionOf(borrower);
        uint256 sliceAssets = Math.max(dashboard.personalSliceAssets, dashboard.queueRootSliceAssets);
        uint256 shares = m.vault.balanceOf(lender);
        uint256 expectedBurned = m.vault.previewWithdraw(80 ether) + m.vault.previewWithdraw(sliceAssets);
        vm.prank(lender);
        (uint256 sharesBurned, uint256 loanAssets,, uint256 debtCanceled) =
            m.vault.fallbackExit(shares, lender, lender, 1);
        assertEq(loanAssets, 80 ether, "liquid leg paid exactly the 80 idle (100 - 20)");
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
        // Full idle (no borrow) -> the liquid leg pays out the whole deposit, exactly.
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
        vm.prank(borrower);
        m.controller.setSettlementLtv(0.5e18);
        address receiver = _actor("receiver");
        uint256 expectedDebtCanceled = _settlementForDebtAssets(m, borrower);
        uint128 colBefore = m.core.position(m.id, borrower).collateral;
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        // Helper asserts owner share burn, receiver collateral, and owner!=receiver routing.
        (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(lender, m.vault.balanceOf(lender), bs, receiver);
        assertEq(debtCanceled, expectedDebtCanceled, "cancelled == settlementFor prediction");
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

    function test_fallbackExit_pureRedeem_matchesPreviewRedeem() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);
        uint256 shares = m.vault.balanceOf(lender);

        uint256 previewLoan = m.vault.previewRedeem(shares);
        vm.prank(lender);
        (, uint256 loanAssets,,) = m.vault.fallbackExit(shares, lender, lender, 0);
        assertEq(loanAssets, previewLoan, "previewRedeem matches the actual redeem-leg payout");
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

        // 20 borrowed out -> the conservative share cap is the floor conversion of the 80 free assets.
        assertEq(m.vault.maxRedeem(lender), m.vault.convertToShares(80 ether), "maxRedeem == convertToShares(free)");
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

    // ── storage layout ──

    /// @dev `marketId` opens the ERC-7201 namespace. `_managedSupplyShares` closes it at base + 8, after `controller`
    ///      (1 slot), the five-field `_marketParams` (5 slots) and `_loanDecimalsOffset` (1 slot). A field inserted
    ///      before the last one moves it off that slot.
    function test_storageLayout_firstAndLastFieldAtErc7201Slots() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 10 ether);
        m.vaultDeposit(lender, 10 ether);
        assertGt(m.vault.managedSupplyShares(), 0, "setup: managed supply shares are nonzero");

        bytes32 base = _erc7201Slot("lido.lend.storage.LidoLendERC4626");
        address vault = address(m.vault);
        assertEq(vm.load(vault, base), Id.unwrap(m.vault.marketId()), "marketId at the base slot");
        assertEq(
            uint256(vm.load(vault, bytes32(uint256(base) + 8))),
            m.vault.managedSupplyShares(),
            "_managedSupplyShares at base + 8"
        );
    }

    /// @dev ERC-7201 base slot of `namespaceId`, by the formula of the standard.
    function _erc7201Slot(string memory namespaceId) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespaceId))) - 1)) & ~bytes32(uint256(0xff));
    }
}
