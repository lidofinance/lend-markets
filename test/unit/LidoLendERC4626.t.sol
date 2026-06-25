// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

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

    // ── ERC-4626 round-trips ──

    function test_depositWithdraw_roundTrip() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        uint256 shares = m.vaultDeposit(lender, 100 ether);
        m.vaultWithdraw(lender, 100 ether);
        assertEq(m.vault.balanceOf(lender), 0, "all shares burned");
        assertGt(shares, 0, "minted");
    }

    function test_mintRedeem_roundTrip() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, m.vault.previewMint(50 ether));
        m.vaultMint(lender, 50 ether);
        m.vaultRedeem(lender, m.vault.balanceOf(lender));
        assertEq(m.vault.balanceOf(lender), 0, "all shares redeemed");
    }

    // ── maxWithdraw / maxRedeem are capped by free liquidity ──

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

        uint256 maxW = m.vault.maxWithdraw(lender);
        assertLt(maxW, 100 ether, "capped below the full position");
        assertApproxEqAbs(maxW, 80 ether, 1e15, "bounded by free liquidity (~80)");
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
        (address lender,) = _distress(m, 100 ether, 20 ether, 0.22e36); // 80 idle, 20 borrowed (illiquid part settles)
        (, uint256 loanAssets, uint256 collateralSeized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), lender, 0);
        assertGt(loanAssets, 0, "redeem leg paid out the idle liquidity");
        assertGt(collateralSeized, 0, "settle leg seized collateral for the illiquid remainder");
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
        // The helper asserts loanAssets == 0 (no redeem leg) and the collateral/share deltas.
        (, uint256 loanAssets, uint256 collateralSeized,) = m.settle(lender, m.vault.balanceOf(lender), bs, lender);
        assertEq(loanAssets, 0, "settle pays no loan assets");
        assertGt(collateralSeized, 0, "settle seized collateral");
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

    function test_fallbackExit_pureSettle_whenNoIdle() public {
        Market storage m = _market();
        (address lender,) = _distressFull(m, 100 ether); // idle == 0
        (, uint256 loanAssets, uint256 collateralSeized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), lender, 0);
        assertEq(loanAssets, 0, "no redeem leg when there is no idle liquidity");
        assertGt(collateralSeized, 0, "exit serviced entirely by the settle leg");
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

        uint256 shares = m.vault.balanceOf(lender);
        vm.prank(lender);
        (uint256 sharesBurned,,,) = m.vault.fallbackExit(shares, lender, lender, 1);
        assertLt(sharesBurned, shares, "maxIterations=1 -> only the idle part + one cut is burned");
        assertGt(sharesBurned, 0, "redeem leg burned at least the idle part");
    }

    function test_fallbackExit_receiverNotOwner() public {
        Market storage m = _market();
        address owner = _actor("owner");
        _fund(m.loanToken, owner, 100 ether);
        m.vaultDeposit(owner, 100 ether);
        address receiver = _actor("receiver");
        uint256 before = m.loanToken.balanceOf(receiver);
        uint256 shares = m.vault.balanceOf(owner);
        vm.prank(owner);
        (, uint256 loanAssets,,) = m.vault.fallbackExit(shares, receiver, owner, 0);
        assertEq(m.loanToken.balanceOf(receiver), before + loanAssets, "loan assets paid to receiver, not owner");
        assertEq(m.vault.balanceOf(owner), 0, "shares burned at owner");
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

        vm.prank(_actor("caller"));
        vm.expectRevert(); // OZ ERC20InsufficientAllowance
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
        uint256 before = m.collateralToken.balanceOf(receiver);
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        uint256 shares = m.vault.balanceOf(lender);
        vm.prank(lender);
        (,, uint256 collateralSeized,) = m.vault.settle(shares, bs, receiver, lender);
        assertEq(m.collateralToken.balanceOf(receiver), before + collateralSeized, "collateral to receiver");
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

        // 20 borrowed out -> redeemable shares are capped below the full balance.
        assertLt(m.vault.maxRedeem(lender), m.vault.balanceOf(lender), "maxRedeem capped by free liquidity");
    }

    function test_totalAssets_tracksDeposit() public {
        Market storage m = _market();
        uint256 before = m.vault.totalAssets();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);
        assertEq(m.vault.totalAssets(), before + 100 ether, "totalAssets rose by the deposit");
    }

    // ── initialize guards ──

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
}
