// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";

import {TrailingAnchorOracleModel, TrailingAnchorOracleState} from "../setup/TrailingAnchorOracleModel.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {NavOracleMarketSetup} from "../setup/NavOracleMarketSetup.sol";
import {Market} from "../setup/Types.sol";

/// @notice The NAV oracle inside a live market on the real core:
///         - borrowing and liquidation at the current price, and a slow fall the keeper's updates follow;
///         - a real fall past the bounds and inside the floor that prices itself one delay later, after which
///           liquidations run;
///         - a deeper fall that stops on the floor until governance accepts it;
///         - a source that grows faster than the anchor's rise and stops on the ceiling, then walks down past the bound
///           every window, stopping on the floor, where a position borrowed at LLTV at the top of the ceiling's bounds
///           is still liquidated without bad debt;
///         - a wrong jump up that stops on the ceiling and leaves no bad debt, and the same jump without the ceiling,
///           which leaves bad debt;
///         - a faulty fall the committee holds with a market pause until governance resets the anchor;
///         - governance's pricing suspension, which stops liquidations while borrowers repay;
///         - the exact set of paths a revert stops, governance's acceptance, and a frozen source that stays priced.
contract NavOracleMarketTest is NavOracleMarketSetup {
    using MarketActions for Market;
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant COLLATERAL = 1_000e18;
    uint256 internal constant FREE_COLLATERAL = 50e18;
    uint256 internal constant TOP_UP = 10e18;
    /// @dev A real fall past the 0.1% bound and inside the 1% floor, and the LTV it lifts to about 98.4%: above the 98%
    ///      LLTV and under the 99.4% where a liquidation leaves bad debt.
    uint256 internal constant FALL_INSIDE_FLOOR = 0.991e18;
    uint256 internal constant NEAR_LLTV = 0.975e18;
    /// @dev A 5% fall, past the floor, and the LTV it lifts to about 98.4%.
    uint256 internal constant DEEP_FALL = 0.95e18;
    uint256 internal constant NEAR_LLTV_BEFORE_DEEP_FALL = 0.935e18;
    /// @dev A wrong 5% jump up, past the 0.2% ceiling.
    uint256 internal constant WRONG_JUMP = 1.05e18;

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

    /// @dev Borrowing sizes against the current price itself. A fall inside the lower bound reaches the price at once,
    ///      so a position borrowed at LLTV becomes liquidatable without any call to the oracle.
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
            assertTrue(_keeper(), "the keeper moves the anchor");
            assertEq(_state().anchorPrice * PRICE_SCALE, lower, "the anchor lands on the price");
        }
    }

    /// @dev A real 0.9% fall, past the bound and inside the floor: the oracle reverts on the bounds until the keeper
    ///      re-anchors onto the fall one delay after recording it, and then a position the fall pushed past LLTV is
    ///      liquidated.
    function test_realFall_pricedAfterOneDelayAndLiquidationsResume() public {
        Market storage m = _m();
        uint256 debt = _openNearLltv(NEAR_LLTV);
        uint256 fallen = _setCurrentPriceAtAnchor(FALL_INSIDE_FLOOR);
        assertFalse(_keeper(), "the first update records a pending anchor and leaves the anchor");
        _approveKeeper(debt);
        vm.prank(keeper);
        vm.expectRevert(_boundsError());
        m.core.liquidate(m.params, borrower, 1e18, 0, "");

        uint256 started = block.timestamp;
        assertEq(_keeperWalk(), 1, "one re-anchor onto the fall");
        assertEq(block.timestamp, started + navOracle.reanchorDelay(), "one delay");
        assertEq(m.oracle.price(), fallen, "priced at the fall");
        assertGt(_ltv(borrower, fallen), LLTV, "liquidatable at the fallen price");
        m.liquidate(keeper, borrower, 100e18, 0);
    }

    /// @dev A real 5% fall goes past the floor: one delay later the keeper moves the anchor only onto the floor, 1%
    ///      under the high-water mark, and the oracle keeps reverting with the floor's bounds. Governance accepts the
    ///      fallen price, and a position the fall pushed past LLTV is liquidated without bad debt.
    function test_deepFall_waitsOnTheFloorForGovernance() public {
        Market storage m = _m();
        uint256 debt = _openNearLltv(NEAR_LLTV_BEFORE_DEEP_FALL);
        TrailingAnchorOracleState memory start = _state();
        uint256 fallen = _setCurrentPriceAtAnchor(DEEP_FALL);
        assertEq(_keeperWalk(), 1, "one re-anchor, onto the floor");
        uint256 floorPrice = start.anchorPrice - Math.mulDiv(start.anchorPrice, 0.01e18, 1e18);
        assertEq(_state().anchorPrice, floorPrice, "the anchor on the floor");
        _approveKeeper(debt);
        vm.prank(keeper);
        vm.expectRevert(_boundsError());
        m.core.liquidate(m.params, borrower, 1e18, 0, "");

        vm.warp(block.timestamp + 2 days);
        assertFalse(_keeper(), "the keeper alone moves nothing");
        uint256 checked = nav.currentPrice();
        vm.prank(governance);
        navOracle.acceptPrice(checked, checked);
        assertEq(m.oracle.price(), fallen, "priced at the fall once governance accepts it");
        assertGt(_ltv(borrower, fallen), LLTV, "liquidatable at the fallen price");
        m.liquidate(keeper, borrower, 100e18, 0);
    }

    /// @dev A source that grows 10% a year, faster than the anchor's 6% rise: the keeper's drifts and re-anchors carry
    ///      the anchor up until the ceiling, 0.2% over the high-water mark, which only the drifts raised, and there the
    ///      oracle reverts. The source eases back to the ceiling's upper bound, the highest price the oracle returns,
    ///      and a position is borrowed at LLTV against it. A walk down 0.2% past the anchor in every window ends on the
    ///      floor, and a full liquidation at the lowest price the oracle returns there still repays the whole debt and
    ///      leaves no bad debt.
    function test_growthToTheCeilingThenFaultyWalk_endsOnTheFloorWithoutBadDebt() public {
        Market storage m = _m();
        _growDaily(30, 0.1e18);
        TrailingAnchorOracleState memory s = _state();
        uint256 mark = s.highWaterMark;
        assertGt(mark, INITIAL_NAV, "the drifts raised the high-water mark");
        assertEq(s.anchorPrice, s.ceiling(), "the anchor on the ceiling");
        vm.expectRevert(_boundsError());
        m.oracle.price();

        uint256 top = _setCurrentPrice(s.upperBound());
        uint256 maxBorrow = _maxBorrow(COLLATERAL, top);
        _lend(maxBorrow * 2);
        m.borrow(borrower, maxBorrow - 1);

        uint256 floorPrice = mark - Math.mulDiv(mark, 0.01e18, 1e18);
        for (uint256 i; i < 20; ++i) {
            _setCurrentPriceAtAnchor(0.998e18);
            _keeper();
            vm.warp(block.timestamp + navOracle.reanchorDelay());
            _keeper();
            assertGe(_state().anchorPrice, floorPrice, "never under the floor");
        }
        assertEq(_state().anchorPrice, floorPrice, "the walk ends on the floor");
        assertEq(_state().highWaterMark, mark, "the high-water mark stays");

        uint256 lowest = _setCurrentPrice(_state().lowerBound());
        assertEq(m.oracle.price(), lowest, "the lowest price the oracle returns");
        assertGt(_ltv(borrower, lowest), LLTV, "liquidatable");
        m.accrueInterest();
        uint256 shares = m.core.position(m.id, borrower).borrowShares;
        _approveKeeper(m.repayAssets(shares));
        m.liquidate(keeper, borrower, 0, shares);
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "the whole debt repaid");
        assertGt(m.core.position(m.id, borrower).collateral, 0, "collateral left after the incentive");
    }

    /// @dev A wrong 5% jump up is held past the delay: the keeper moves the anchor only onto the ceiling, 0.2% over the
    ///      high-water mark, and the oracle keeps reverting, so the wrong value never becomes the price. The source
    ///      eases to the ceiling's upper bound, the highest price the oracle returns, and a position is borrowed at
    ///      LLTV against it. When the true price returns, the keeper re-anchors onto it one delay later, and a full
    ///      liquidation there repays the whole debt and leaves no bad debt.
    function test_wrongJumpUp_stopsOnTheCeilingWithoutBadDebt() public {
        Market storage m = _m();
        uint256 truePrice = nav.currentPrice();
        _setCurrentPriceAtAnchor(WRONG_JUMP);
        assertEq(_keeperWalk(), 1, "one re-anchor, onto the ceiling");
        TrailingAnchorOracleState memory s = _state();
        assertEq(s.anchorPrice, s.ceiling(), "the anchor on the ceiling");
        assertEq(s.highWaterMark, INITIAL_NAV, "the high-water mark stays");
        vm.expectRevert(_boundsError());
        m.oracle.price();

        uint256 top = _setCurrentPrice(s.upperBound());
        uint256 maxBorrow = _maxBorrow(COLLATERAL, top);
        _lend(maxBorrow * 2);
        m.borrow(borrower, maxBorrow - 1);

        uint256 restored = _setCurrentPrice(truePrice);
        assertEq(_keeperWalk(), 1, "one re-anchor onto the true price");
        assertEq(m.oracle.price(), restored, "priced at the true price");
        assertGt(_ltv(borrower, restored), LLTV, "liquidatable");
        m.accrueInterest();
        uint256 shares = m.core.position(m.id, borrower).borrowShares;
        _approveKeeper(m.repayAssets(shares));
        m.liquidate(keeper, borrower, 0, shares);
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "the whole debt repaid");
        assertGt(m.core.position(m.id, borrower).collateral, 0, "collateral left after the incentive");
    }

    /// @dev The same wrong jump with the ceiling out of the way, a `maxAnchorAboveMark` of almost a whole price, which
    ///      the corridor rule refuses: the keeper re-anchors onto the wrong value one delay later, so it becomes the
    ///      price. A position borrowed at LLTV against it is insolvent when the true price returns, since a re-anchor
    ///      does not raise the floor, and its liquidation leaves bad debt.
    function test_wrongJumpUp_withoutTheCeilingLeavesBadDebt() public {
        Market storage m = _m();
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveMark = uint64(1e18 - 1);
        vm.prank(governance);
        navOracle.setParameters(p);
        uint256 truePrice = nav.currentPrice();
        uint256 wrong = _setCurrentPriceAtAnchor(WRONG_JUMP);
        assertEq(_keeperWalk(), 1, "one re-anchor onto the wrong value");
        assertEq(m.oracle.price(), wrong, "the wrong value is the price");

        uint256 top = _setCurrentPrice(_state().upperBound());
        uint256 maxBorrow = _maxBorrow(COLLATERAL, top);
        _lend(maxBorrow * 2);
        m.borrow(borrower, maxBorrow - 1);

        uint256 restored = _setCurrentPrice(truePrice);
        assertEq(_keeperWalk(), 1, "one re-anchor onto the true price");
        assertEq(m.oracle.price(), restored, "priced at the true price");
        assertGt(_ltv(borrower, restored), 1e18, "insolvent at the true price");
        m.accrueInterest();
        _approveKeeper(m.repayAssets(m.core.position(m.id, borrower).borrowShares));
        m.liquidateBadDebt(keeper, borrower, COLLATERAL, 0);
    }

    /// @dev A faulty source falls 0.9%, inside the floor. The committee pauses the market on the pending anchor; the
    ///      re-anchor still lands, so the faulty value becomes the oracle price, but the pause stops the liquidation it
    ///      would allow. Governance fixes the source and accepts the true price before the market resumes, and the
    ///      position is healthy.
    function test_marketPause_holdsAFaultyFall() public {
        Market storage m = _m();
        uint256 debt = _openNearLltv(NEAR_LLTV);
        _setCurrentPriceAtAnchor(FALL_INSIDE_FLOOR);
        _keeper();
        m.pause(3 days);
        _keeperWalk();
        assertEq(m.oracle.price(), _oraclePrice(), "the faulty value is the oracle price");
        _approveKeeper(debt);
        vm.prank(keeper);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.core.liquidate(m.params, borrower, 1e18, 0, "");

        _setCurrentPrice(INITIAL_NAV);
        vm.prank(governance);
        navOracle.acceptPrice(INITIAL_NAV, INITIAL_NAV);
        m.resume();
        assertLt(_ltv(borrower, m.oracle.price()), LLTV, "healthy at the true price");
    }

    /// @dev After a real fall is priced, governance suspends pricing for a day: liquidations wait while the borrower
    ///      repays half the debt, so the position is healthy when pricing resumes.
    function test_suspension_stopsLiquidationsWhileBorrowersRepay() public {
        Market storage m = _m();
        uint256 debt = _openNearLltv(NEAR_LLTV);
        uint256 fallen = _setCurrentPriceAtAnchor(FALL_INSIDE_FLOOR);
        _keeperWalk();
        assertGt(_ltv(borrower, fallen), LLTV, "liquidatable at the fallen price");

        uint256 resumesAt = block.timestamp + 1 days;
        vm.prank(governance);
        navOracle.setPricingResumesAt(uint40(resumesAt));
        _approveKeeper(debt);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.PricingSuspended.selector, uint40(resumesAt)));
        m.core.liquidate(m.params, borrower, 1e18, 0, "");

        m.accrueInterest();
        uint256 halfShares = m.core.position(m.id, borrower).borrowShares / 2;
        _fund(m.loanToken, borrower, m.repayAssets(halfShares));
        m.repay(borrower, halfShares);
        vm.warp(resumesAt);
        assertEq(m.oracle.price(), fallen, "priced again");
        assertLt(_ltv(borrower, fallen), LLTV, "healthy when pricing resumes");
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

    /// @dev A suspension stops the same paths as a revert on the bounds, and leaves the same paths running.
    function test_suspension_stopsPricedPathsOnly() public {
        _openDebt();
        uint256 resumesAt = block.timestamp + 2 days;
        vm.prank(governance);
        navOracle.setPricingResumesAt(uint40(resumesAt));
        bytes memory err = abi.encodeWithSelector(TrailingAnchorOracleBase.PricingSuspended.selector, uint40(resumesAt));
        _assertPricedPathsRevert(err);
        _assertUnpricedPathsRun();
    }

    /// @dev Governance accepts the fallen price inside the range it checked: the price lands on it at once, borrowing
    ///      resumes against it, and the bounds are measured from it from then on.
    function test_acceptance_restartsAnchor() public {
        Market storage m = _m();
        _openDebt();
        uint256 fallen = _setCurrentPriceAtAnchor(0.95e18);
        vm.expectRevert(_boundsError());
        m.oracle.price();

        uint256 checked = nav.currentPrice();
        vm.prank(governance);
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

    /// @dev Governance checked one price, and the source fell further before the acceptance ran: the acceptance is
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
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.UnexpectedPrice.selector, moved, minPrice, maxPrice)
        );
        navOracle.acceptPrice(minPrice, maxPrice);
        assertEq(_state().anchorPrice, before.anchorPrice, "anchor kept");
        vm.expectRevert(_boundsError());
        m.oracle.price();
    }

    /// @dev The issuer stops publishing: the source stays at its last value, no update moves the anchor, and the
    ///      market keeps pricing that value and lending against it a month later. Catching a frozen source is left to
    ///      monitoring and the committee's freeze.
    function test_frozenSource_staysPriced() public {
        Market storage m = _m();
        _lend(1_000e6);
        uint256 frozen = _oraclePrice();
        for (uint256 day = 1; day <= 30; ++day) {
            vm.warp(START + day * 1 days);
            assertFalse(_keeper(), "an unchanged source moves nothing");
            assertEq(m.oracle.price(), frozen, "the frozen value is still the price");
        }
        m.borrow(borrower, 100e6);
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

        _approveKeeper(1_000e6);
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

    /// @dev A borrower at `ltv` of the collateral's value at the current price, in a market at half utilization.
    function _openNearLltv(uint256 ltv) internal returns (uint256 debt) {
        Market storage m = _m();
        uint256 value = Math.mulDiv(COLLATERAL, m.oracle.price(), ORACLE_PRICE_SCALE);
        debt = Math.mulDiv(value, ltv, 1e18);
        _lend(debt * 2);
        m.borrow(borrower, debt);
    }

    /// @dev `days_` days of a source growing at `yearlyRate`, each followed by the keeper, and by the keeper again one
    ///      delay later when the day's update recorded a pending anchor.
    function _growDaily(uint256 days_, uint256 yearlyRate) internal {
        for (uint256 day; day < days_; ++day) {
            vm.warp(block.timestamp + 1 days);
            uint256 current = nav.currentPrice();
            _setCurrentPrice(current + Math.mulDiv(current, yearlyRate, 365e18));
            _keeper();
            if (_state().pendingAnchorAt == 0) continue;
            vm.warp(block.timestamp + navOracle.reanchorDelay());
            _keeper();
        }
    }

    function _approveKeeper(uint256 assets) internal {
        Market storage m = _m();
        _fund(m.loanToken, keeper, assets);
        vm.prank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
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
