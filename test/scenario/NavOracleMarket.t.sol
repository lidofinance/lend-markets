// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";

import {TrailingAnchorOracleModel, TrailingAnchorOracleState} from "../setup/TrailingAnchorOracleModel.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {NavOracleMarketSetup} from "../setup/NavOracleMarketSetup.sol";
import {Market} from "../setup/Types.sol";

/// @notice The NAV oracle inside a live market on the real core: borrowing and liquidation at the current price, a slow
///         fall that the keeper's updates follow and a fast one that leaves the bounds until the committee accepts it,
///         the exact set of paths a revert stops, and the committee's acceptance that restarts the anchor, or refuses a
///         price that moved after its check.
contract NavOracleMarketTest is NavOracleMarketSetup {
    using MarketActions for Market;
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant COLLATERAL = 1_000e18;
    uint256 internal constant FREE_COLLATERAL = 50e18;
    uint256 internal constant TOP_UP = 10e18;

    address internal lender;
    address internal borrower;
    address internal freeHolder;
    address internal keeper;

    function setUp() public {
        _deployNavMarket();
        lender = _actor("lender");
        borrower = _actor("borrower");
        freeHolder = _actor("freeHolder");
        keeper = _actor("keeper");

        Market storage m = _m();
        _fund(m.collateralToken, borrower, COLLATERAL + TOP_UP);
        m.supplyCollateral(borrower, COLLATERAL);
        _fund(m.collateralToken, freeHolder, FREE_COLLATERAL);
        m.supplyCollateral(freeHolder, FREE_COLLATERAL);
        m.activateCollateral();
    }

    /// @dev Borrowing sizes against the current price itself. A fall inside the decrease bound reaches the price at
    ///      once, so a position borrowed at LLTV becomes liquidatable without any call to the oracle.
    function test_borrowAndLiquidation_atCurrentPrice() public {
        Market storage m = _m();
        uint256 price0 = m.oracle.price();
        assertEq(price0, _oraclePrice(), "price is the current price, scaled");

        uint256 maxBorrow = _maxBorrow(COLLATERAL, price0);
        _lend(maxBorrow * 2);
        m.borrow(borrower, maxBorrow - 1);
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, 2, 0, borrower, borrower);

        uint256 fallen = _setCurrentPriceAtAnchor(0.9996e18);
        assertEq(m.oracle.price(), fallen, "a fall inside the bound reaches the price");
        assertGt(_ltv(borrower, fallen), LLTV, "liquidatable at the fallen price");

        _fund(m.loanToken, keeper, maxBorrow);
        m.liquidate(keeper, borrower, 100e18, 0);
    }

    /// @dev A fall of 0.002% a day, about 0.73% a year and under the 1% fall speed, is followed by the keeper's daily
    ///      updates: for 30 days the price returns every day and the anchor lands on it.
    function test_slowFall_followedByUpdates() public {
        Market storage m = _m();
        for (uint256 day = 1; day <= 30; ++day) {
            vm.warp(START + day * 1 days);
            uint256 lower = _setCurrentPrice(Math.mulDiv(nav.currentPrice(), 0.99998e18, 1e18));
            assertEq(m.oracle.price(), lower, "each day's price returns");
            assertTrue(_keeper(), "the keeper updates");
            assertEq(_state().anchorPrice * PRICE_SCALE, lower, "the anchor lands on the price");
        }
    }

    /// @dev A fall of 0.04% a day outruns the 1% a year fall speed: the anchor trails, and on day 3 the price is 0.12%
    ///      down, past the 0.1% decrease bound, so it reverts. The keeper's updates keep moving the anchor down at the
    ///      fall speed but do not bring the price back; the committee's acceptance does.
    function test_fastFall_leavesBoundsUntilAccepted() public {
        Market storage m = _m();
        for (uint256 day = 1; day <= 2; ++day) {
            vm.warp(START + day * 1 days);
            uint256 lower = _setCurrentPrice(Math.mulDiv(nav.currentPrice(), 0.9996e18, 1e18));
            assertEq(m.oracle.price(), lower, "inside the bounds on days 1 and 2");
            assertTrue(_keeper(), "the keeper updates");
            assertGt(_state().anchorPrice * PRICE_SCALE, lower, "the anchor trails above the price");
        }

        vm.warp(START + 3 days);
        _setCurrentPrice(Math.mulDiv(nav.currentPrice(), 0.9996e18, 1e18));
        vm.expectRevert(_boundsError());
        m.oracle.price();
        uint256 before = _state().anchorPrice;
        assertTrue(_keeper(), "the keeper still updates outside the bounds");
        assertLt(_state().anchorPrice, before, "the anchor moves down at the fall speed");
        vm.expectRevert(_boundsError());
        m.oracle.price();

        uint256 checked = nav.currentPrice();
        vm.prank(priceAcceptor);
        navOracle.acceptPrice(checked, checked);
        assertEq(m.oracle.price(), checked * PRICE_SCALE, "priced again after the acceptance");
    }

    /// @dev A current price outside the bounds stops every price-dependent path with the oracle's error and leaves
    ///      every other path running.
    function test_boundsRevert_stopsPricedPathsOnly() public {
        _openDebt();
        _setCurrentPriceAtAnchor(0.985e18);
        bytes memory err = _boundsError();
        _assertPricedPathsRevert(err);
        _assertUnpricedPathsRun();
    }

    /// @dev An update refuses a source that has not changed, so after the lifetime the same paths stop as stale.
    function test_staleAnchor_stopsPricedPathsOnly() public {
        _openDebt();
        uint256 lifetime = navOracle.anchorLifetime();
        vm.warp(START + lifetime + 1);
        assertFalse(_keeper(), "an unchanged price cannot move the anchor");
        bytes memory err =
            abi.encodeWithSelector(TrailingAnchorOracleBase.StaleAnchor.selector, uint40(START), uint40(lifetime));
        _assertPricedPathsRevert(err);
        _assertUnpricedPathsRun();
    }

    /// @dev The NAV falls 0.09%, inside the decrease bound, and the issuer stops publishing. The first update moves the
    ///      anchor a day of the fall speed toward the frozen NAV and every later one is refused, so a lifetime after
    ///      that update borrowing stops as stale, although the anchor still trails the NAV.
    function test_frozenSource_stopsALifetimeAfterTheUpdate() public {
        Market storage m = _m();
        _lend(1_000e6);
        uint256 frozen = _setCurrentPriceAtAnchor(0.9991e18);
        uint256 lifetime = navOracle.anchorLifetime();
        vm.warp(START + 1 days);
        vm.prank(keeper);
        navOracle.updateAnchor();

        bytes memory unchanged =
            abi.encodeWithSelector(TrailingAnchorOracleBase.SourceUnchanged.selector, nav.currentPrice());
        for (uint256 day = 2; day <= 1 + lifetime / 1 days; ++day) {
            vm.warp(START + day * 1 days);
            assertEq(m.oracle.price(), frozen, "the frozen NAV returns within a lifetime of the update");
            vm.prank(keeper);
            vm.expectRevert(unchanged);
            navOracle.updateAnchor();
        }
        assertGt(_state().anchorPrice * PRICE_SCALE, frozen, "the anchor still trails the frozen NAV");

        vm.warp(START + 1 days + lifetime + 1);
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.StaleAnchor.selector, uint40(START + 1 days), uint40(lifetime)
            )
        );
        m.core.borrow(m.params, 500e6, 0, borrower, borrower);
    }

    /// @dev The committee accepts the fallen price inside the range it checked: the price lands on it at once,
    ///      borrowing resumes against it, and the bounds are measured from it from then on.
    function test_acceptance_restartsAnchor() public {
        Market storage m = _m();
        _openDebt();
        uint256 fallen = _setCurrentPriceAtAnchor(0.95e18);
        vm.expectRevert(_boundsError());
        m.oracle.price();

        uint256 checked = nav.currentPrice();
        vm.prank(priceAcceptor);
        navOracle.acceptPrice(checked, checked);
        TrailingAnchorOracleState memory s = _state();
        assertEq(s.anchorPrice, checked, "anchor is the accepted price");
        assertEq(s.anchorAt, block.timestamp, "anchor time");
        assertEq(m.oracle.price(), fallen, "price is the current price");

        m.borrow(borrower, 100e6);
        m.setSettlementLtv(borrower, 0.3e18);
        m.controller.positionOf(borrower);

        // A further 0.04% fall sits inside the bounds measured from the accepted price and reaches the price at once.
        uint256 lower = _setCurrentPrice(checked * 0.9996e18 / 1e18);
        assertEq(m.oracle.price(), lower, "a further small fall reaches the price");
    }

    /// @dev The committee checked one price, and the source fell further before the acceptance ran: the acceptance is
    ///      refused with the range, the anchor stays, and the market stays stopped until a new check.
    function test_acceptance_refusesPriceMovedAfterCheck() public {
        Market storage m = _m();
        _openDebt();
        _setCurrentPriceAtAnchor(0.95e18);
        uint256 checked = nav.currentPrice();
        uint256 minPrice = Math.mulDiv(checked, 0.9999e18, 1e18);
        uint256 maxPrice = Math.mulDiv(checked, 1.0001e18, 1e18);

        _setCurrentPrice(Math.mulDiv(checked, 0.99e18, 1e18));
        uint256 moved = nav.currentPrice();
        TrailingAnchorOracleState memory before = _state();
        vm.prank(priceAcceptor);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.UnexpectedPrice.selector, moved, minPrice, maxPrice)
        );
        navOracle.acceptPrice(minPrice, maxPrice);
        assertEq(_state().anchorPrice, before.anchorPrice, "anchor kept");
        vm.expectRevert(_boundsError());
        m.oracle.price();
    }

    // ── matrix ──

    /// @dev Every action and quote that reads the price fails with the oracle's error.
    function _assertPricedPathsRevert(bytes memory err) internal {
        Market storage m = _m();
        vm.prank(borrower);
        vm.expectRevert(err);
        m.core.borrow(m.params, 1e6, 0, borrower, borrower);

        vm.prank(borrower);
        vm.expectRevert(err);
        m.core.withdrawCollateral(m.params, 1e18, borrower, borrower);

        _fund(m.loanToken, keeper, 1_000e6);
        vm.prank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert(err);
        m.core.liquidate(m.params, borrower, 1e18, 0, "");

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256 shares = m.vault.balanceOf(lender);
        vm.prank(lender);
        vm.expectRevert(err);
        m.vault.settle(shares, borrowers, lender, lender);

        uint256 freeLiquidity = m.core.market(m.id).totalSupplyAssets - m.core.market(m.id).totalBorrowAssets;
        assertGt(m.vault.previewRedeem(shares), freeLiquidity, "the exit needs its settlement leg");
        vm.prank(lender);
        vm.expectRevert(err);
        m.vault.fallbackExit(shares, lender, lender, 0);

        vm.expectRevert(err);
        m.controller.positionOf(borrower);
        vm.expectRevert(err);
        m.controller.settlementLtv(borrower);
        vm.expectRevert(err);
        m.controller.hasBadDebt();
        vm.expectRevert(err);
        m.controller.nextSettlementBorrower(0);
        vm.expectRevert(err);
        m.controller.settlementFor(borrower, 0);
    }

    /// @dev Repay, collateral supply, a debt-free collateral withdrawal and lender liquidity in and out read no price.
    function _assertUnpricedPathsRun() internal {
        Market storage m = _m();
        m.accrueInterest();
        uint256 halfShares = m.core.position(m.id, borrower).borrowShares / 2;
        _fund(m.loanToken, borrower, m.repayAssets(halfShares));
        m.repay(borrower, halfShares);

        uint128 collateralBefore = m.core.position(m.id, borrower).collateral;
        vm.prank(borrower);
        m.collateralToken.approve(address(m.core), TOP_UP);
        vm.prank(borrower);
        m.core.supplyCollateral(m.params, TOP_UP, borrower, "");
        assertEq(m.core.position(m.id, borrower).collateral, collateralBefore + TOP_UP, "collateral supplied");

        uint256 holderBefore = m.collateralToken.balanceOf(freeHolder);
        vm.prank(freeHolder);
        m.core.withdrawCollateral(m.params, FREE_COLLATERAL / 2, freeHolder, freeHolder);
        assertEq(m.collateralToken.balanceOf(freeHolder), holderBefore + FREE_COLLATERAL / 2, "debt-free withdrawal");

        uint256 topUp = 1_000e6;
        _fund(m.loanToken, lender, topUp);
        m.vaultDeposit(lender, topUp);
        m.vaultWithdraw(lender, topUp);
    }

    // ── helpers ──

    /// @dev A borrower at about 45% LTV in a market at 80% utilization, opted into a personal settlement target.
    function _openDebt() internal {
        Market storage m = _m();
        uint256 debt = 500e6;
        _lend(debt * 5 / 4);
        m.borrow(borrower, debt);
        m.setSettlementLtv(borrower, 0.3e18);
    }

    function _lend(uint256 assets) internal {
        Market storage m = _m();
        _fund(m.loanToken, lender, assets);
        m.vaultDeposit(lender, assets);
    }

    /// @dev The controller's capacity: collateral value at `price`, rounded down, times LLTV, rounded down.
    function _maxBorrow(uint256 collateral, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(collateral, price, ORACLE_PRICE_SCALE), LLTV, 1e18);
    }

    function _ltv(address account, uint256 price) internal view returns (uint256) {
        Market storage m = _m();
        uint256 debt = m.repayAssets(m.core.position(m.id, account).borrowShares);
        uint256 value = Math.mulDiv(m.core.position(m.id, account).collateral, price, ORACLE_PRICE_SCALE);
        return Math.mulDiv(debt, 1e18, value);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }
}
