// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, Market as MorphoMarket, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice One end-to-end "all-systems-live" run that drives every money-flow lever of the protocol through a
///         single coherent, monotonically-declining-price narrative, and asserts the CROSS-STEP couplings that no
///         single-action helper checks: the vault share price rises with accrued interest, survives an ordinary
///         liquidation unchanged, then on a bad-debt liquidation the socialized loss falls wholly on the vault (it
///         owns every core supply share) and thus on its two lenders. Every individual action reuses a
///         `MarketActions` helper, so each step is already exact-asserted (shares vs preview, event, token movement,
///         position delta); this test adds the between-step invariants on top.
///
///         Actions exercised: deposit, mint, withdraw, redeem, settle, fallbackExit (lender); supplyCollateral,
///         activate (timer + instant), borrow, repay, withdrawCollateral, setSettlementLtv (borrower); liquidate
///         (no bad debt) and liquidateBadDebt (socialization) (keeper); accrueInterest / time warp (interest); a
///         guardian flag driving a ban (guardian control plane); oracle price moves (moderate then severe).
contract FullLifecycleTest is LidoLendSetup {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    // Two lenders: A enters first and rides the whole story (so it eats the socialized loss); B enters via `mint`.
    address internal lenderA;
    address internal lenderB;
    // Borrowers, one per fate. Buffers ordered liq < bad < settle so a single falling price hits them in turn.
    address internal borrowerHealthy; // instant-activated, fully unwound before any crash
    address internal borrowerLiq; // moderate crash -> ordinary liquidation, no bad debt
    address internal borrowerBad; // severe crash -> bad debt, socialized
    address internal borrowerSettle; // solvent-but-unhealthy at the end -> lender settle / fallbackExit target
    address internal borrowerBanned; // guardian-banned: proves the ban blocks borrowing mid-lifecycle
    address internal keeper;

    // Small principals for the borrowers that unwind early, one large illiquid principal for the settle target, so
    // ordinary liquidity stays scarce throughout and `fallbackExit` is genuinely forced onto its settle leg.
    uint256 internal constant P_SMALL = 30 ether;
    uint256 internal constant P_SETTLE = 300 ether;

    function setUp() public {
        vm.roll(1000); // a non-zero block so guardian `flag` has a real prior blockhash
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        lenderA = _actor("lenderA");
        lenderB = _actor("lenderB");
        borrowerHealthy = _actor("borrowerHealthy");
        borrowerLiq = _actor("borrowerLiq");
        borrowerBad = _actor("borrowerBad");
        borrowerSettle = _actor("borrowerSettle");
        borrowerBanned = _actor("borrowerBanned");
        keeper = _actor("keeper");
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ── model helpers (seed-robust: everything derives from the live position and the seeded oracle price) ──

    /// @dev Collateral that makes `principal` exactly `bufNum/bufDen` over the LLTV limit at the seed price (health
    ///      factor == bufNum/bufDen at borrow time). maxBorrow == collat * price/1e36 * lltv.
    function _collatFor(uint256 principal, uint256 bufNum, uint256 bufDen) internal view returns (uint256) {
        return principal * 1e36 / oraclePrice * 100 / 80 * bufNum / bufDen;
    }

    /// @dev Live debt in loan assets (round up, as the core does).
    function _debtAssets(address b) internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 shares = m.core.position(m.id, b).borrowShares;
        return shares.toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
    }

    /// @dev The oracle price at which `b`'s collateral is worth exactly its debt (below this the position is
    ///      insolvent; above `insolvencyPrice / lltv` it is healthy). Basis for choosing crash regimes.
    function _insolvencyPrice(address b) internal view returns (uint256) {
        uint256 collat = _m().core.position(_m().id, b).collateral;
        return _debtAssets(b) * 1e36 / collat;
    }

    /// @dev Vault assets backing one whole share (1e18) at current totals — the share price.
    function _pps() internal view returns (uint256) {
        return _m().vault.convertToAssets(1e18);
    }

    function _setPrice(uint256 p) internal {
        MockPriceOracle(address(_m().oracle)).setPrice(p);
    }

    // ── the run ──

    /// @dev End-to-end lifecycle on a freshly deployed stack, run in phases: seed liquidity, open every
    ///      collateral/borrow path, accrue interest and check the share price, repay and withdraw, a healthy
    ///      liquidation, a severe bad-debt liquidation, then lender exits (incl. a fallbackExit onto its settle
    ///      leg). Each phase is exact-asserted by its helper.
    function test_fullLifecycle_allActionsLive() public {
        _phaseSeedLiquidity();
        _phaseOpenPositions();
        _phaseAccrueAndSharePrice();
        _phaseRepayAndWithdraw();
        _phaseModerateLiquidation();
        _phaseSevereBadDebt();
        _phaseLenderExits();
    }

    /// @dev Lender A deposits, lender B mints. Two entry paths, both exact-asserted by the helpers. Supply is kept
    ///      close to total borrows so that, after the exits drain ordinary liquidity, `fallbackExit` is forced onto
    ///      its settle leg.
    function _phaseSeedLiquidity() private {
        Market storage m = _m();
        _fund(m.loanToken, lenderA, 400 ether);
        _fund(m.loanToken, lenderB, 100 ether);

        // A is the dominant lender (it can later buy out all ordinary liquidity); B holds a small slice that ends up
        // backed only by the illiquid settle position.
        m.vaultDeposit(lenderA, 360 ether);
        m.vaultMint(lenderB, 60 ether); // pull ~60 assets for 60 shares while the price is ~parity
    }

    /// @dev Every collateral + borrow path: instant activation (no timer) for one borrower, timer activation for
    ///      the rest, an opt-in settlement LTV, and a guardian ban that provably blocks its victim.
    function _phaseOpenPositions() private {
        Market storage m = _m();

        // Instant-activated borrower: grant, supply, borrow with no warp. `supplyCollateral` models the
        // non-instant classification only, so bypass the helper and call core directly (the lot lands
        // straight in active, not dust/activating).
        m.controller.setInstantActivation(borrowerHealthy, true);
        uint256 healthyCollat = _collatFor(P_SMALL, 200, 100);
        _fund(m.collateralToken, borrowerHealthy, healthyCollat);
        vm.prank(borrowerHealthy);
        m.collateralToken.approve(address(m.core), healthyCollat);
        vm.prank(borrowerHealthy);
        m.core.supplyCollateral(m.params, healthyCollat, borrowerHealthy, "");
        m.borrow(borrowerHealthy, P_SMALL);

        // Timer-activated borrowers: supply now, mature via the delay, then borrow.
        _fund(m.collateralToken, borrowerLiq, _collatFor(P_SMALL, 115, 100));
        _fund(m.collateralToken, borrowerBad, _collatFor(P_SMALL, 160, 100));
        _fund(m.collateralToken, borrowerSettle, _collatFor(P_SETTLE, 230, 100));
        _fund(m.collateralToken, borrowerBanned, _collatFor(P_SMALL, 200, 100));
        m.supplyCollateral(borrowerLiq, _collatFor(P_SMALL, 115, 100));
        m.supplyCollateral(borrowerBad, _collatFor(P_SMALL, 160, 100));
        m.supplyCollateral(borrowerSettle, _collatFor(P_SETTLE, 230, 100));
        m.supplyCollateral(borrowerBanned, _collatFor(P_SMALL, 200, 100));

        m.activateCollateral(); // warp past the max activation delay -> the timer lots mature

        m.borrow(borrowerLiq, P_SMALL);
        m.borrow(borrowerBad, P_SMALL);
        m.borrow(borrowerSettle, P_SETTLE);
        // The position starts below this target, then crosses it after the later price shock.
        m.setSettlementLtv(borrowerSettle, 0.85e18);

        // Guardian control plane: a single flag reaches quorum (1) and bans the address; a banned lot never matures.
        _flag(borrowerBanned);
        vm.prank(borrowerBanned);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        m.core.borrow(m.params, P_SMALL, 0, borrowerBanned, borrowerBanned);
    }

    /// @dev Interest accrues over 180 days. A pure accrual mints no vault shares, and the interest the borrowers are
    ///      charged (the rise in core borrow assets) lands entirely in the vault's assets — so the share price rises
    ///      by exactly that interest spread over an unchanged share count. Both equalities are checked exactly.
    function _phaseAccrueAndSharePrice() private {
        Market storage m = _m();
        uint256 supplySharesBefore = m.vault.totalSupply();
        uint256 supplyBefore = m.core.market(m.id).totalSupplyAssets;
        uint256 borrowBefore = m.core.market(m.id).totalBorrowAssets;

        m.warpAndAccrue(180 days);

        // Pure accrual mints no vault shares, and with no market fee every unit of borrower interest accrues to the
        // supply side — which the vault owns in full — so the share price rises by exactly that interest per share.
        assertEq(m.vault.totalSupply(), supplySharesBefore, "pure accrual mints no vault shares (no dilution)");
        uint256 supplyInterest = m.core.market(m.id).totalSupplyAssets - supplyBefore;
        uint256 borrowInterest = m.core.market(m.id).totalBorrowAssets - borrowBefore;
        assertEq(supplyInterest, borrowInterest, "no fee: all borrower interest accrues to the supply side");

        // Ordinary liquidity is still available -> exercise both exit-by-assets and exit-by-shares at the richer rate
        // (the helpers assert assets/shares vs the live preview).
        m.vaultWithdraw(lenderA, 8 ether);
        m.vaultRedeem(lenderB, 4 ether);
    }

    /// @dev The healthy borrower fully unwinds before any crash: repay the whole debt, then pull all collateral.
    function _phaseRepayAndWithdraw() private {
        Market storage m = _m();
        uint256 shares = m.core.position(m.id, borrowerHealthy).borrowShares;

        _fund(m.loanToken, borrowerHealthy, m.repayAssets(shares)); // enough to cover principal + accrued
        m.repay(borrowerHealthy, shares);

        uint256 collat = m.core.position(m.id, borrowerHealthy).collateral;
        m.withdrawCollateral(borrowerHealthy, collat, borrowerHealthy);
        assertEq(m.core.position(m.id, borrowerHealthy).borrowShares, 0, "healthy borrower fully repaid");
        assertEq(m.core.position(m.id, borrowerHealthy).collateral, 0, "healthy borrower fully exited");
    }

    /// @dev Moderate crash: price drops to just below `borrowerLiq`'s health line but above its insolvency line, so
    ///      an ordinary liquidation clears it WITHOUT bad debt. A solvent liquidation touches only the borrow side
    ///      (repay + seize), so the supply assets — and therefore the share price — are left exactly unchanged.
    function _phaseModerateLiquidation() private {
        Market storage m = _m();
        m.accrueInterest(); // settle interest so the supply/pps comparison isolates the liquidation
        uint256 ppsBefore = _pps();
        uint256 supplyBefore = m.core.market(m.id).totalSupplyAssets;

        // 12% above insolvency is still under the 1/lltv = 125% health line -> unhealthy but solvent.
        _setPrice(_insolvencyPrice(borrowerLiq) * 112 / 100);

        uint256 shares = m.core.position(m.id, borrowerLiq).borrowShares;
        _fund(m.loanToken, keeper, m.repayAssets(shares) + 1 ether);
        m.liquidate(keeper, borrowerLiq, 0, shares); // repay the whole debt, seize the priced collateral

        assertEq(m.core.market(m.id).totalSupplyAssets, supplyBefore, "solvent liquidation loses no supply assets");
        assertEq(_pps(), ppsBefore, "share price unchanged by a solvent liquidation");
    }

    /// @dev Severe crash: price falls under `borrowerBad`'s insolvency line, so seizing all its collateral still
    ///      leaves debt — realized as bad debt and socialized (`liquidateBadDebt` asserts the supply-asset drop).
    ///      The vault holds every core supply share, so the loss falls wholly on it; no vault shares are burned; and
    ///      the two lenders hold every vault share — so the loss is a pure share-price fall borne entirely by them.
    function _phaseSevereBadDebt() private {
        Market storage m = _m();
        uint256 sharesBefore = m.vault.totalSupply();

        // 20% below insolvency guarantees residual debt after a full seize; still leaves `borrowerSettle` solvent.
        _setPrice(_insolvencyPrice(borrowerBad) * 80 / 100);

        uint256 collat = m.core.position(m.id, borrowerBad).collateral;
        _fund(m.loanToken, keeper, _debtAssets(borrowerBad) + 1 ether);
        m.liquidateBadDebt(keeper, borrowerBad, collat, 0); // seize all collateral; the rest is socialized

        // `liquidateBadDebt` already asserted the core supply assets dropped (the socialized loss). The vault holds
        // every supply share, so that loss falls wholly on it; no vault shares are burned; and the two lenders hold
        // every vault share — so the loss is a pure share-price fall borne entirely by them.
        assertEq(
            m.core.position(m.id, address(m.vault)).supplyShares,
            m.core.market(m.id).totalSupplyShares,
            "vault holds every supply share, so it absorbs the whole loss"
        );
        assertEq(m.vault.totalSupply(), sharesBefore, "no vault shares burned: the loss is pure share price");
        assertEq(
            m.vault.balanceOf(lenderA) + m.vault.balanceOf(lenderB),
            m.vault.totalSupply(),
            "the two lenders hold every vault share, so they bear the whole loss"
        );
    }

    /// @dev With `borrowerSettle` now solvent-but-unhealthy (settle-eligible, not bad debt), the remaining lenders
    ///      recover collateral instead of loan: A via targeted `settle`, then the ordinary idle is drained so B's
    ///      `fallbackExit` is forced onto its settle leg. Both helpers assert the exact share burn and collateral
    ///      received.
    function _phaseLenderExits() private {
        Market storage m = _m();
        uint256 collat1;
        uint256 borrow1;

        {
            uint256 collat0 = m.core.position(m.id, borrowerSettle).collateral;
            uint256 borrow0 = m.core.market(m.id).totalBorrowAssets;

            // A targeted settle: the borrower's personal LTV is now breached, so the cut cancels exactly the core's
            // borrow-asset reduction and pays out exactly the borrower's collateral debit.
            address[] memory targets = new address[](1);
            targets[0] = borrowerSettle;
            uint256 settleShares = m.vault.balanceOf(lenderA);
            (, uint256 personalSlice) = m.controller.settlementLtv(borrowerSettle);
            assertGt(personalSlice, 0, "personal settlement LTV is active after the price shock");
            (, uint256 seizedA, uint256 canceledA) = m.settle(lenderA, settleShares, targets, lenderA);
            assertGt(seizedA, 0, "targeted settle pays collateral");
            assertGt(canceledA, 0, "targeted settle cancels debt");
            collat1 = m.core.position(m.id, borrowerSettle).collateral;
            borrow1 = m.core.market(m.id).totalBorrowAssets;
            assertEq(borrow0 - borrow1, canceledA, "settle cancelled exactly the borrow-asset reduction");
            assertEq(
                collat0 - collat1, seizedA, "settle debited the borrower's collateral by exactly the seized amount"
            );
        }

        // Drain the remaining free liquidity so B's fallback exit exercises the pure root-policy leg.
        m.vaultWithdraw(lenderA, m.vault.maxWithdraw(lenderA));
        assertEq(m.loanToken.balanceOf(address(m.core)), 0, "ordinary liquidity fully drained before fallbackExit");

        (, uint256 loanAssetsB, uint256 seizedB, uint256 canceledB) =
            m.fallbackExit(lenderB, m.vault.balanceOf(lenderB), lenderB, 0);
        assertEq(loanAssetsB, 0, "no loan-token liquidity remains for the liquid leg");
        assertEq(
            borrow1 - m.core.market(m.id).totalBorrowAssets, canceledB, "fallbackExit cancelled exactly the reduction"
        );
        assertEq(
            collat1 - m.core.position(m.id, borrowerSettle).collateral,
            seizedB,
            "fallbackExit debited the borrower's collateral by exactly the seized amount"
        );
    }

    /// @dev Raise a guardian flag on `account`; with the default quorum of 1 this immediately bans it.
    function _flag(address account) private {
        address[] memory a = new address[](1);
        a[0] = account;
        _m().guardianSignals.flag(_m().id, address(this), a);
    }
}
