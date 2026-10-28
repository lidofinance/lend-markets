// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IIrm} from "@lido-lend/src/interfaces/IIrm.sol";
import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {MathLib, WAD} from "@lido-lend/src/libraries/MathLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockNavOracle, MockUsdFeed} from "../setup/Mocks.sol";

/// @notice What a market can still do while its oracle refuses to price. The requirement is the market
///         spec: price-dependent actions revert — borrowing, debt-bearing collateral withdrawal,
///         liquidation, and settlement — while an oracle failure does not by itself block repayment or
///         ordinary loan-asset withdrawal.
///
///         The market runs on a real `UsdyStableOracle` over mock sources, so an outage is produced the way
///         one happens in production rather than by mocking `price()` away: either the NAV source reverts,
///         or it reports a value outside the oracle's immutable price band. Each test asserts the exact
///         revert data, which pins the oracle as the cause — a bare "it reverted" would also pass for a
///         healthy position rejecting a liquidation.
contract OracleOutageTest is LidoLendSetup {
    using MarketActions for Market;
    using MathLib for uint256;
    using SharesMathLib for uint256;

    uint256 internal constant LLTV = 0.8e18;

    /// @dev `price()` per unit of NAV: 10^(36 + loanDec + feedDec - 18 - 18) / 10^feedDec at an $1.00 feed,
    ///      which is 1e18 for the 18-decimal loan token below.
    uint256 internal constant PRICE_PER_NAV = 1e18;

    /// @dev Collateral lots. The debtor's is the sized position; the free holder's carries no debt, so it
    ///      exercises the collateral withdrawal that the spec expects to survive an outage.
    uint256 internal constant DEBTOR_COLLATERAL = 100 ether;
    uint256 internal constant FREE_COLLATERAL = 50 ether;
    /// @dev Above `minActivationAmount` (10 ether), so a top-up during the outage enters a normal lot.
    uint256 internal constant COLLATERAL_TOP_UP = 10 ether;
    /// @dev The debtor's personal settlement target: above the 0.8 LLTV and below the WAD ceiling.
    uint256 internal constant SETTLEMENT_LTV = 0.9e18;

    MockERC20 internal loan;
    MockERC20 internal collateral;
    MockNavOracle internal nav;
    MockUsdFeed internal feed;

    address internal lender;
    address internal debtor;
    address internal freeHolder;
    address internal keeper;

    /// @dev The oracle's immutable band and the NAV that prices inside it, all fixed at deployment.
    uint256 internal minPrice;
    uint256 internal maxPrice;
    uint256 internal healthyNav;

    uint256 internal lenderSupply;
    uint256 internal borrowShares;

    function setUp() public {
        loan = new MockERC20("Loan", "LOAN", 18);
        collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        Market storage m = _m();
        lender = _actor("lender");
        debtor = _actor("debtor");
        freeHolder = _actor("freeHolder");
        keeper = _actor("keeper");

        // Utilization is deliberately high: the lender's ordinary withdrawal below must fit in free
        // liquidity while a full fallbackExit must not, so the exit has to reach for the settlement leg.
        uint256 collateralValue = Math.mulDiv(DEBTOR_COLLATERAL, m.oracle.price(), ORACLE_PRICE_SCALE);
        lenderSupply = collateralValue / 2;
        uint256 borrowAssets = lenderSupply * 4 / 5; // 80% utilization, and LTV 0.4 against the 0.8 LLTV

        _fund(m.loanToken, lender, lenderSupply);
        m.vaultDeposit(lender, lenderSupply);

        _fund(m.collateralToken, debtor, DEBTOR_COLLATERAL + COLLATERAL_TOP_UP);
        m.supplyCollateral(debtor, DEBTOR_COLLATERAL);
        _fund(m.collateralToken, freeHolder, FREE_COLLATERAL);
        m.supplyCollateral(freeHolder, FREE_COLLATERAL);
        m.activateCollateral();

        borrowShares = m.borrow(debtor, borrowAssets);
        // The debtor opts into a personal settlement target, so it is a real settlement candidate and the
        // `settlementLtv` quote reaches its priced branch (an opt-in-less borrower short-circuits at zero).
        m.setSettlementLtv(debtor, SETTLEMENT_LTV);
        _fund(m.loanToken, debtor, borrowAssets); // headroom to repay principal plus accrued interest
        _fund(m.loanToken, keeper, borrowAssets);
    }

    /// @notice The market's oracle is a real `UsdyStableOracle` over a mock NAV source and stablecoin feed,
    ///         banded around the seeded price so both outage modes are reachable from the sources.
    function _deployOracle(
        address,
        /* oracleSource */
        address admin
    )
        internal
        override
        returns (address)
    {
        nav = new MockNavOracle();
        feed = new MockUsdFeed();

        // Reproduce the seeded price as a NAV, then bracket it with a band it sits strictly inside.
        healthyNav = oraclePrice / PRICE_PER_NAV;
        minPrice = (healthyNav / 2) * PRICE_PER_NAV;
        maxPrice = (healthyNav * 2) * PRICE_PER_NAV;
        nav.setPrice(healthyNav);

        address impl = address(new UsdyStableOracle(address(nav), minPrice, maxPrice));
        return _behindProxy(impl, admin, abi.encodeCall(UsdyStableOracle.initialize, (address(feed), address(loan))));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ── outage modes ──

    /// @dev The NAV source itself is down, so `price()` reverts with the source's own error.
    function test_navSourceDown_pricedActionsHalt_othersRun() public {
        nav.setDown(true);

        _assertPricedActionsRevert(abi.encodeWithSelector(MockNavOracle.NavOracleDown.selector));
        _assertUnpricedActionsRun();
        _assertMarketResumes();
    }

    /// @dev The NAV answers, but below the oracle's band — the failure mode the band exists to catch. The
    ///      market must halt exactly as it does for a dead source, not price against the out-of-band value.
    function test_navBelowBand_pricedActionsHalt_othersRun() public {
        uint256 outOfBand = _parkNav(healthyNav / 2 - 1);
        assertLt(outOfBand, minPrice, "setup: parked price is below the band");

        _assertPricedActionsRevert(abi.encodeWithSelector(UsdyStableOracle.PriceOutOfBounds.selector, outOfBand));
        _assertUnpricedActionsRun();
        _assertMarketResumes();
    }

    /// @dev Symmetrically above the band: a NAV blow-up halts the same actions.
    function test_navAboveBand_pricedActionsHalt_othersRun() public {
        uint256 outOfBand = _parkNav(healthyNav * 2 + 1);
        assertGt(outOfBand, maxPrice, "setup: parked price is above the band");

        _assertPricedActionsRevert(abi.encodeWithSelector(UsdyStableOracle.PriceOutOfBounds.selector, outOfBand));
        _assertUnpricedActionsRun();
        _assertMarketResumes();
    }

    // ── interest through an outage ──

    /// @dev Unlike a pause, an outage leaves accrual running, so interest is booked while no one can liquidate. A
    ///      borrower who does not cure crosses LLTV from interest alone and is liquidated when the price returns.
    function test_outage_interestAccrues_uncuredBorrowerLiquidatableWhenPriceReturns() public {
        Market storage m = _m();
        address victim = _actor("victim");
        uint256 price = m.oracle.price();

        // The victim takes all free liquidity at LTV 0.76: utilization is 100% and the position is healthy.
        MorphoMarket memory market = m.core.market(m.id);
        uint256 victimDebt = market.totalSupplyAssets - market.totalBorrowAssets;
        uint256 victimCollateral = victimDebt * ORACLE_PRICE_SCALE / price * WAD / 0.76e18;
        _fund(m.collateralToken, victim, victimCollateral);
        m.supplyCollateral(victim, victimCollateral);
        m.activateCollateral();
        m.borrow(victim, victimDebt);
        market = m.core.market(m.id);
        assertEq(market.totalBorrowAssets, market.totalSupplyAssets, "setup: utilization is 100%");
        assertLt(_ltv(victim, price), LLTV, "setup: healthy before the outage");

        nav.setDown(true);
        vm.warp(block.timestamp + 21 days);

        uint256 interest = _pendingInterest();
        m.accrueInterest();
        assertEq(
            m.core.market(m.id).totalBorrowAssets, market.totalBorrowAssets + interest, "21 days booked during outage"
        );

        uint256 victimShares = m.core.position(m.id, victim).borrowShares;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MockNavOracle.NavOracleDown.selector));
        m.core.liquidate(m.params, victim, 0, victimShares, "");

        nav.setDown(false);
        assertEq(m.oracle.price(), price, "the same price returns");
        assertGt(_ltv(victim, price), LLTV, "interest alone crossed LLTV");
        m.liquidate(keeper, victim, 0, victimShares);
    }

    // ── the matrix ──

    /// @dev Every action and quote that reads the price fails with the oracle's own error, so none of them
    ///      can act on a price the oracle refused to report.
    function _assertPricedActionsRevert(bytes memory err) internal {
        Market storage m = _m();

        vm.prank(debtor);
        vm.expectRevert(err);
        m.core.borrow(m.params, 1 ether, 0, debtor, debtor);

        vm.prank(debtor);
        vm.expectRevert(err);
        m.core.withdrawCollateral(m.params, 1 ether, debtor, debtor);

        vm.prank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(err);
        m.core.liquidate(m.params, debtor, 1 ether, 0, "");

        address[] memory borrowers = new address[](1);
        borrowers[0] = debtor;
        uint256 lenderShares = m.vault.balanceOf(lender);
        vm.prank(lender);
        vm.expectRevert(err);
        m.vault.settle(lenderShares, borrowers, lender, lender);

        // The whole stake: the redeem leg cannot cover it at 80% utilization, so the exit must quote the
        // settlement leg, which prices collateral. Pinned, so a later resize cannot make this vacuous by
        // letting free liquidity satisfy the exit outright.
        uint256 freeLiquidity = m.core.market(m.id).totalSupplyAssets - m.core.market(m.id).totalBorrowAssets;
        assertGt(m.vault.previewRedeem(lenderShares), freeLiquidity, "exit must outgrow free liquidity");
        vm.prank(lender);
        vm.expectRevert(err);
        m.vault.fallbackExit(lenderShares, lender, lender, 0);

        // Keeper- and UI-facing quotes go down with the price, so an outage is not silently quotable.
        vm.expectRevert(err);
        m.controller.positionOf(debtor);
        vm.expectRevert(err);
        m.controller.settlementLtv(debtor);
        vm.expectRevert(err);
        m.controller.hasBadDebt();
        vm.expectRevert(err);
        m.controller.nextSettlementBorrower(0);
        vm.expectRevert(err);
        m.controller.settlementFor(debtor, 0);
    }

    /// @dev Everything that does not need a price keeps working: a borrower can always reduce debt and top
    ///      up collateral, a debt-free holder can take collateral back, and a lender can supply and take
    ///      ordinary liquidity out.
    function _assertUnpricedActionsRun() internal {
        Market storage m = _m();

        m.accrueInterest();

        // Borrower: repay half the debt, then top the collateral up.
        _fund(m.loanToken, debtor, m.repayAssets(borrowShares / 2));
        m.repay(debtor, borrowShares / 2);
        _supplyCollateralUnpriced(debtor, COLLATERAL_TOP_UP);

        // Debt-free holder: the collateral leaves without a health check, since there is no debt to check.
        _withdrawCollateralUnpriced(freeHolder, FREE_COLLATERAL / 2);

        // Lender: ordinary liquidity in, then straight back out of free liquidity. Taking the whole stake
        // out is the fallbackExit case, which stays blocked above.
        uint256 topUp = lenderSupply / 10;
        _fund(m.loanToken, lender, topUp);
        m.vaultDeposit(lender, topUp);
        m.vaultWithdraw(lender, topUp);
    }

    /// @dev The halt lasts exactly as long as the outage: with the NAV back inside the band, the priced
    ///      actions run again.
    function _assertMarketResumes() internal {
        Market storage m = _m();
        nav.setDown(false);
        _parkNav(healthyNav);

        assertEq(m.oracle.price(), healthyNav * PRICE_PER_NAV, "price is quotable again");
        m.borrow(debtor, 1 ether);
        m.controller.positionOf(debtor);
    }

    // ── helpers ──

    /// @dev Interest the next accrual must book: the IRM's average rate since `lastUpdate`, Taylor-compounded over
    ///      the elapsed time.
    function _pendingInterest() internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory market = m.core.market(m.id);
        uint256 rate = IIrm(m.params.irm).borrowRateView(m.params, market);
        return uint256(market.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(block.timestamp - market.lastUpdate));
    }

    /// @dev LTV at `price`, the price before the outage, so a change in LTV comes from debt alone.
    function _ltv(address account, uint256 price) internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory market = m.core.market(m.id);
        uint256 debt = uint256(m.core.position(m.id, account).borrowShares)
            .toAssetsUp(market.totalBorrowAssets, market.totalBorrowShares);
        return debt * WAD / (uint256(m.core.position(m.id, account).collateral) * price / ORACLE_PRICE_SCALE);
    }

    /// @dev Move the NAV and return the price it produces, computed rather than read back, since `price()`
    ///      is exactly what may now revert.
    function _parkNav(uint256 navValue) internal returns (uint256) {
        nav.setPrice(navValue);
        return navValue * PRICE_PER_NAV;
    }

    /// @dev `MarketActions.supplyCollateral` reads `positionOf`, which is itself priced, so the outage half
    ///      asserts the core-side effects directly.
    function _supplyCollateralUnpriced(address borrower, uint256 amount) internal {
        Market storage m = _m();
        uint128 collateralBefore = m.core.position(m.id, borrower).collateral;
        uint256 coreBefore = m.collateralToken.balanceOf(address(m.core));

        vm.prank(borrower);
        m.collateralToken.approve(address(m.core), amount);
        vm.prank(borrower);
        m.core.supplyCollateral(m.params, amount, borrower, "");

        assertEq(m.core.position(m.id, borrower).collateral, collateralBefore + amount, "supplyCollateral: position");
        assertEq(
            m.collateralToken.balanceOf(address(m.core)), coreBefore + amount, "supplyCollateral: collateral to core"
        );
    }

    /// @dev Same for the withdrawal side.
    function _withdrawCollateralUnpriced(address borrower, uint256 amount) internal {
        Market storage m = _m();
        uint128 collateralBefore = m.core.position(m.id, borrower).collateral;
        uint256 holderBefore = m.collateralToken.balanceOf(borrower);

        vm.prank(borrower);
        m.core.withdrawCollateral(m.params, amount, borrower, borrower);

        assertEq(m.core.position(m.id, borrower).collateral, collateralBefore - amount, "withdrawCollateral: position");
        assertEq(m.collateralToken.balanceOf(borrower), holderBefore + amount, "withdrawCollateral: received");
    }
}
