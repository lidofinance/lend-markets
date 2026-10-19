// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {NavOracleCheckParams} from "../../src/types/NavOracleTypes.sol";

import {MarketActions} from "../setup/MarketActions.sol";
import {NavOracleMarketSetup} from "../setup/NavOracleMarketSetup.sol";
import {NavOracleModel, NavOracleState} from "../setup/NavOracleModel.sol";
import {IrmKind, Market} from "../setup/Types.sol";

/// @notice The NAV oracle inside a live market on the real core: borrowing and liquidation at a clamped price, the
///         exact set of paths a revert stops, the DAO acceptance that restarts the corridor, and settlement while the
///         floor holds the price above the source.
contract NavOracleMarketTest is NavOracleMarketSetup {
    using MarketActions for Market;
    using NavOracleModel for NavOracleState;

    uint256 internal constant COLLATERAL = 1_000e18;
    uint256 internal constant FREE_COLLATERAL = 50e18;
    uint256 internal constant TOP_UP = 10e18;

    address internal lender;
    address internal borrower;
    address internal freeHolder;
    address internal keeper;

    function setUp() public {
        _deployNavMarket(NavOracleModel.workingDefaults(0.0375e18));
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

    /// @dev A source 2% over the path is held at the upper bound. Borrowing sizes against the bound, not the source,
    ///      and a lower tolerance then lowers the clamped price, which makes the position liquidatable at the clamp.
    function test_borrowAndLiquidation_atClampedPrice() public {
        Market storage m = _m();
        uint256 source = _setSourceAtPath(1.02e18);
        uint256 upper = _state().upperBound(block.timestamp);
        assertEq(m.oracle.price(), upper, "clamped at the upper bound");
        assertLt(upper, source, "the bound is under the source");

        uint256 maxBorrow = _maxBorrow(COLLATERAL, upper);
        _lend(maxBorrow * 2);
        m.borrow(borrower, maxBorrow - 1);
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, 2, 0, borrower, borrower);
        assertGt(_maxBorrow(COLLATERAL, source), maxBorrow + 2, "the source alone would have allowed more");

        vm.prank(configurator);
        navOracle.setGrowthLimit(0.0375e18, 0.0005e18);
        uint256 lowered = _state().upperBound(block.timestamp);
        assertEq(m.oracle.price(), lowered, "clamped at the lowered bound");
        assertGt(_ltv(borrower, lowered), LLTV, "liquidatable at the clamp");

        _fund(m.loanToken, keeper, maxBorrow);
        m.liquidate(keeper, borrower, 100e18, 0);
    }

    /// @dev I10: below the band every price-dependent path reverts with the band error and every other path runs.
    function test_bandRevert_stopsPricedPathsOnly() public {
        _openDebt();
        _setSourceAtPath(0.985e18);
        bytes memory err = _bandError();
        _assertPricedPathsRevert(err);
        _assertUnpricedPathsRun();
    }

    /// @dev The peg kill switch stops the same paths and leaves the same paths running.
    function test_offPeg_stopsPricedPathsOnly() public {
        _openDebt();
        feed.setAnswer(0.99e8);
        _assertPricedPathsRevert(abi.encodeWithSelector(NavOracleBase.LoanTokenOffPeg.selector));
        _assertUnpricedPathsRun();
    }

    /// @dev The DAO accepts the fallen source inside the range it reviewed: the price lands on the source at once,
    ///      borrowing resumes against it, and the corridor and the floor restart from it.
    function test_acceptance_restartsCorridor() public {
        Market storage m = _m();
        _openDebt();
        uint256 fallen = _setSourceAtPath(0.95e18);
        vm.expectRevert(_bandError());
        m.oracle.price();

        vm.prank(configurator);
        navOracle.acceptCurrentPrice(fallen - PRICE_SCALE, fallen + PRICE_SCALE);
        NavOracleState memory s = _state();
        assertEq(s.referencePrice, fallen, "reference is the accepted source");
        assertEq(s.checkpointPrice, fallen, "checkpoint is the accepted source");
        assertEq(s.expectedPrice(block.timestamp), fallen, "the path starts at the source");
        assertEq(m.oracle.price(), fallen, "price is the source");

        m.borrow(borrower, 100e6);
        m.setSettlementLtv(borrower, 0.3e18);
        m.controller.positionOf(borrower);

        // A further 0.5% fall sits inside the new band and is held by the restarted floor for one interval.
        uint256 lower = _setSource(fallen * 0.995e18 / 1e18);
        assertEq(m.oracle.price(), fallen, "held at the accepted price");
        vm.warp(block.timestamp + 1 days);
        uint256 floor_ = fallen * (1e18 - 0.0025e18) / 1e18;
        assertEq(m.oracle.price(), Math.max(lower, floor_), "one step down after one interval");
    }

    /// @dev With the floor above the source, settlement keeps running at the held price, so the exiting lender takes
    ///      fewer collateral units than the source price would give.
    function test_settlementWhileFloorHolds() public {
        Market storage m = _m();
        uint256 price0 = m.oracle.price();
        uint256 debt = Math.mulDiv(_maxBorrow(COLLATERAL, price0), 0.9e18, LLTV);
        _lend(debt * 2);
        m.borrow(borrower, debt);
        m.setSettlementLtv(borrower, 0.5e18);

        vm.warp(block.timestamp + 1 days);
        _setSourceAtPath(1e18);
        navOracle.checkpoint();
        vm.warp(block.timestamp + 1 days);
        uint256 dipped = _setSource(_state().checkpointPrice * 0.994e18 / 1e18);
        uint256 floor_ = _state().floor(block.timestamp);
        assertGt(floor_, dipped, "the floor is above the source");
        assertTrue(_state().inBand(dipped, block.timestamp), "inside the band");
        assertEq(m.oracle.price(), floor_, "held at the floor");

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint256 shares = m.vault.balanceOf(lender) / 4;
        (, uint256 seized, uint256 canceled) = m.settle(lender, shares, borrowers, lender);
        assertGt(seized, 0, "settled");
        assertLt(seized, Math.mulDiv(canceled, ORACLE_PRICE_SCALE, dipped), "fewer units than at the source price");
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

/// @notice The worst case the validator sizes the corridor for, on the real core with an interest rate model that
///         charges a flat 16% a year throughout: debt taken at LLTV under the upper bound, the open move lowering the
///         path by one tolerance, the source falling to the band's lower edge, and no liquidation until the floor
///         reaches the source.
contract NavOracleFloorHoldTest is NavOracleMarketSetup {
    using MarketActions for Market;
    using NavOracleModel for NavOracleState;

    uint256 internal constant COLLATERAL = 1_000e18;

    address internal lender;
    address internal borrower;
    address internal keeper;

    function setUp() public {
        irmKind = IrmKind.Fixed;
        fixedBorrowRate = NavOracleModel.MAX_BORROW_RATE;
        _deployNavMarket(NavOracleModel.workingDefaults(0.0375e18));
        lender = _actor("lender");
        borrower = _actor("borrower");
        keeper = _actor("keeper");
        Market storage m = _m();
        _fund(m.collateralToken, borrower, COLLATERAL);
        m.supplyCollateral(borrower, COLLATERAL);
        m.activateCollateral();
    }

    /// @dev At the oracle's `maxBorrowRate` the floor holds the price for one corridor crossing while the debt
    ///      accrues, and the whole debt is then repaid from the collateral at the liquidation incentive: nothing is
    ///      written off.
    function test_floorHoldAtMaxBorrowRate_writesNothingOff() public {
        Market storage m = _m();
        (uint256 debt, uint256 held) = _borrowAtBoundThenHold();
        NavOracleCheckParams memory params = navOracle.checkParams();
        assertEq(held, NavOracleModel.corridorCrossing(params), "held for one corridor crossing");

        m.accrueInterest();
        uint256 shares = m.core.position(m.id, borrower).borrowShares;
        uint256 owed = m.repayAssets(shares);
        assertApproxEqRel(owed, debt * (1e18 + NavOracleModel.heldInterest(params)) / 1e18, 1e12, "accrued at 16%");
        _fund(m.loanToken, keeper, owed);
        m.liquidate(keeper, borrower, 0, shares);
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "the whole debt is repaid");
    }

    /// @dev The same path with a rate the market does not honour: told no interest accrues, the validator admits a 1%
    ///      drawdown, the floor holds for four days at 16%, and the liquidation at the source writes debt off.
    function test_floorHoldUnderstatedRate_writesOff() public {
        NavOracleCheckParams memory params = navOracle.checkParams();
        vm.startPrank(configurator);
        navOracle.setMarketLimits(params.minPriceRatio, 0);
        navOracle.setRevertBand(0.01e18, params.maxOvershoot, params.referenceInterval);
        vm.stopPrank();

        (, uint256 held) = _borrowAtBoundThenHold();
        assertEq(held, 4 days, "held for four days");
        Market storage m = _m();
        m.accrueInterest();
        _fund(m.loanToken, keeper, m.repayAssets(m.core.position(m.id, borrower).borrowShares));
        m.liquidateBadDebt(keeper, borrower, COLLATERAL, 0);
    }

    /// @dev Borrows just under LLTV against the upper bound once the reference interval has passed, moves the path
    ///      down by one tolerance with a checkpoint on it, and lets the source follow the band's lower edge day by
    ///      day until the floor reaches it. Returns the loan and how long the floor held the price above the source.
    function _borrowAtBoundThenHold() internal returns (uint256 debt, uint256 held) {
        Market storage m = _m();
        vm.warp(START + navOracle.checkParams().referenceInterval);
        _setSourceAtPath(1.01e18);
        uint256 upper = _state().upperBound(block.timestamp);
        assertEq(m.oracle.price(), upper, "clamped at the upper bound");
        debt = Math.mulDiv(Math.mulDiv(COLLATERAL, upper, ORACLE_PRICE_SCALE), LLTV, 1e18) - 1;
        _fund(m.loanToken, lender, debt * 2);
        m.vaultDeposit(lender, debt * 2);
        m.borrow(borrower, debt);

        uint256 tolerance = navOracle.checkParams().growthTolerance;
        _setSource(Math.mulDiv(_state().expectedPrice(block.timestamp), 1e18 - tolerance, 1e18));
        navOracle.moveReferencePrice();
        navOracle.checkpoint();

        uint256 heldFrom = block.timestamp;
        uint256 source = _setSource(_state().bandLow(block.timestamp));
        while (m.oracle.price() > source) {
            vm.warp(block.timestamp + 1 days);
            source = _setSource(_state().bandLow(block.timestamp));
        }
        held = block.timestamp - heldFrom;
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }
}
