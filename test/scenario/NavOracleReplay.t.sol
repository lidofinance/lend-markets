// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {
    TrailingAnchorOracleModel,
    TrailingAnchorOracleState,
    TrailingAnchorOracleUpdate
} from "../setup/TrailingAnchorOracleModel.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {INavSourceMock, MockCentrifugeSpoke, MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";

/// @notice A year of NAV series shaped like the token classes the oracle prices, each replayed through the adapter of
///         its source with the bounds and speeds sized for its class:
///         - an accruing token like USDY steps every day, through `UsdyNavOracle`;
///         - a treasury fund like JTRSY strikes its NAV on business days and catches up the accrual after weekends and
///           a holiday, through `CentrifugeNavOracle`;
///         - a credit fund like JAAA does the same with a daily move either way and one sharp fall, through
///           `CentrifugeNavOracle`.
///         With a keeper that updates every day, no day reverts, the price is the current price on every day, the
///         anchor follows the source at the speeds and stays above its floor, and no pending anchor is ever recorded.
///         Without a keeper the accruing token leaves its bound within days, and a creeping source gains its bound once
///         and then only the rise speed. A fourth series, the credit fund with a drawdown shaped like the JAAA
///         strategy's worst since 2020, is followed with the credit class's floor, 4% under the high-water mark, and
///         with a 1% one stops on the floor and then, after the acceptances there, on the ceiling.
/// @dev The loan token has 6 decimals, like USDC: the price scale is 1e6 for the 18-decimal USDY and 1e18 for the
///      6-decimal fund share.
contract NavOracleReplayTest is Test {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant DAYS = 365;
    /// @dev 2025-09-22 12:00 UTC, a Monday, so day `d` falls on a weekend when `d % 7` is 5 or 6.
    uint256 internal constant START = 1_758_542_400;

    /// @dev Daily accrual of a 4.2%, 4% and 4.25% yearly yield.
    uint256 internal constant USDY_DAILY = uint256(0.042e18) / 365;
    uint256 internal constant TREASURY_DAILY = uint256(0.04e18) / 365;
    uint256 internal constant CREDIT_DAILY = uint256(0.0425e18) / 365;
    /// @dev The credit fund's daily move either way on top of its accrual, and its sharp fall on a Wednesday.
    uint256 internal constant CREDIT_NOISE = 0.0008e18;
    uint256 internal constant CREDIT_DIP_DAY = 163;
    uint256 internal constant CREDIT_DIP = 0.0021e18;

    /// @dev The bounds sized for each class, used for both directions.
    uint256 internal constant ACCRUING_BOUND = 0.0005e18;
    uint256 internal constant TREASURY_BOUND = 0.001e18;
    uint256 internal constant CREDIT_BOUND = 0.003e18;
    /// @dev The speeds: a rise above the class's yield, so the anchor keeps up, and a fall well under it. The credit
    ///      fund's noise outruns a 6% rise, so its anchor rises at 8% and still trails the source by up to about 0.29%,
    ///      inside its 0.3% bound.
    uint256 internal constant RISE = 0.06e18;
    uint256 internal constant FALL = 0.01e18;
    uint256 internal constant CREDIT_RISE = 0.08e18;
    /// @dev The floors under the high-water mark: the working 1% for the accruing token and the treasury fund, and 4%
    ///      for the credit fund, about 1.2% under the 5.17% at which a 92% LLTV position borrowed at the top of its
    ///      0.3% bounds stops covering its liquidation at the bottom, which leaves room for interest accrued on the
    ///      floor.
    uint256 internal constant BELOW_MARK = TrailingAnchorOracleModel.MAX_ANCHOR_BELOW_MARK;
    uint256 internal constant CREDIT_BELOW_MARK = 0.04e18;
    /// @dev The ceilings over the high-water mark, about 80% of the room the corridor rule leaves over each floor:
    ///      0.31% for the accruing token and 0.21% for the treasury fund at a 98% LLTV, and 1.23% for the credit fund
    ///      at a 92% LLTV.
    uint256 internal constant ACCRUING_ABOVE_MARK = 0.0025e18;
    uint256 internal constant TREASURY_ABOVE_MARK = 0.0015e18;
    uint256 internal constant CREDIT_ABOVE_MARK = 0.01e18;
    /// @dev The stress: from a Wednesday after the holiday, 15 strikes of −0.19% on top of the accrual, then 15 of
    ///      +0.16%.
    uint256 internal constant STRESS_START = 100;
    uint256 internal constant STRESS_STEP = 0.0019e18;
    uint256 internal constant RECOVERY_STEP = 0.0016e18;

    uint64 internal constant POOL_ID = 281474976710662;
    bytes16 internal constant SHARE_CLASS_ID = 0x00010000000000060000000000000001;

    MockERC20 internal usdc;

    function setUp() public {
        vm.warp(START);
        usdc = new MockERC20("USD Coin", "USDC", 6);
    }

    /// @dev The accruing token steps every day, so the keeper moves the anchor every day, onto the source.
    function test_replay_accruingToken() public {
        uint256[] memory series = _accrualSeries(USDY_DAILY);
        (TrailingAnchorOracleBase oracle, INavSourceMock source) = _deployUsdy(series[0], ACCRUING_BOUND, RISE, FALL);
        (uint256 oldest, uint256 lag) = _replayWithKeeper(oracle, source, series, 1e6);
        assertEq(oldest, 1 days, "oldest anchor");
        assertEq(lag, 0, "the anchor reaches the source every day");
    }

    /// @dev The treasury fund's largest move is the accrual it catches up after its five-day pause, which the reach
    ///      over the pause covers, so the anchor reaches the source on every strike.
    function test_replay_treasuryFund() public {
        uint256[] memory series = _businessDaySeries(TREASURY_DAILY, 0, 0, 0);
        (TrailingAnchorOracleBase oracle, INavSourceMock source) =
            _deployCentrifuge(series[0], TREASURY_BOUND, RISE, FALL, BELOW_MARK, TREASURY_ABOVE_MARK);
        (uint256 oldest, uint256 lag) = _replayWithKeeper(oracle, source, series, 1e18);
        assertEq(oldest, 5 days, "oldest anchor: the longest pause");
        assertEq(lag, 0, "the anchor reaches the source on every strike");
    }

    /// @dev The credit fund's noise outruns the speeds on some days, so the anchor trails the source, but never far
    ///      enough for the price to leave the bounds. A trailing anchor keeps moving toward the source on the days it
    ///      pauses, so it is never older than the longest pause.
    function test_replay_creditFund() public {
        uint256[] memory series = _businessDaySeries(CREDIT_DAILY, CREDIT_NOISE, CREDIT_DIP_DAY, CREDIT_DIP);
        (TrailingAnchorOracleBase oracle, INavSourceMock source) =
            _deployCentrifuge(series[0], CREDIT_BOUND, CREDIT_RISE, FALL, CREDIT_BELOW_MARK, CREDIT_ABOVE_MARK);
        (uint256 oldest, uint256 lag) = _replayWithKeeper(oracle, source, series, 1e18);
        assertLe(oldest, 5 days, "never older than the longest pause");
        assertGt(lag, 0, "the anchor trails the source on some day");
        assertLt(lag, CREDIT_BOUND, "the lag stays inside the bounds");
    }

    /// @dev The credit fund's sharp fall, −0.21% in a day, sits inside its lower bound.
    function test_replay_creditDipInsideBound() public pure {
        uint256[] memory series = _businessDaySeries(CREDIT_DAILY, CREDIT_NOISE, CREDIT_DIP_DAY, CREDIT_DIP);
        uint256 dip = CREDIT_DIP_DAY;
        assertEq(series[dip], Math.mulDiv(series[dip - 1], WAD - CREDIT_DIP, WAD), "-0.21%");
        assertGt(series[dip], Math.mulDiv(series[dip - 1], WAD - CREDIT_BOUND, WAD), "inside the lower bound");
    }

    /// @dev The stress with the credit class's 4% floor: the anchor follows the fall and the recovery through
    ///      re-anchors, never reaches the floor or the ceiling, and every day is priced once the keeper has updated.
    function test_replay_creditStress_followedWithTheCreditFloor() public {
        uint256[] memory series = _stressSeries();
        assertGe(_maxDrawdown(series), 0.025e18, "a drawdown of about 2.6%");
        (TrailingAnchorOracleBase oracle, INavSourceMock source) =
            _deployCentrifuge(series[0], CREDIT_BOUND, CREDIT_RISE, FALL, CREDIT_BELOW_MARK, CREDIT_ABOVE_MARK);
        (uint256 floorStops, uint256 ceilingStops, uint256 pinnedDays) = _replayStress(oracle, source, series);
        assertEq(floorStops + ceilingStops, 0, "every day priced after the keeper");
        assertEq(pinnedDays, 0, "the anchor never on the floor or the ceiling");
    }

    /// @dev The same stress with the other classes' 1% floor: the anchor stops on the floor, and the market waits for
    ///      governance, which accepts the price on each day the market stands still; the series is followed from each
    ///      accepted price. Each acceptance restarts the high-water mark at the accepted price, and only drifts raise
    ///      it, so the recovery outruns the ceiling over the last one and the market waits on the ceiling too. Without
    ///      the acceptances the market would wait until the price came back within the floor's bounds.
    function test_replay_creditStress_waitsOnTheFloorThenTheCeilingAtOnePercent() public {
        uint256[] memory series = _stressSeries();
        (TrailingAnchorOracleBase oracle, INavSourceMock source) =
            _deployCentrifuge(series[0], CREDIT_BOUND, CREDIT_RISE, FALL, BELOW_MARK, CREDIT_ABOVE_MARK);
        (uint256 floorStops, uint256 ceilingStops,) = _replayStress(oracle, source, series);
        assertGt(floorStops, 0, "the fall waits on the floor");
        assertGt(ceilingStops, 0, "the recovery waits on the ceiling");
    }

    /// @dev Nobody updates: the anchor stays at the first day, and the accruing token's daily growth leaves the 0.05%
    ///      bound on day 5, so the price reverts on the bound and the keeper has days to act.
    function test_replayWithoutKeeper_leavesBoundOnDayFive() public {
        uint256[] memory series = _accrualSeries(USDY_DAILY);
        (TrailingAnchorOracleBase oracle, INavSourceMock source) = _deployUsdy(series[0], ACCRUING_BOUND, RISE, FALL);
        uint256 day = 1;
        for (; day <= DAYS; ++day) {
            vm.warp(START + day * 1 days);
            source.setCurrentPrice(series[day]);
            TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
            if (!s.withinBounds(series[day])) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        TrailingAnchorOracleBase.PriceOutOfBounds.selector, series[day], s.lowerBound(), s.upperBound()
                    )
                );
                oracle.price();
                break;
            }
            assertEq(oracle.price(), series[day] * 1e6, "the current price while inside the bounds");
        }
        assertEq(day, 5, "leaves the bound on day 5");
    }

    /// @dev A source held at the upper bound of each new anchor, updated every day: the price is accepted every day, a
    ///      second update in the same block moves nothing, and the anchor rises by exactly one day of the rise speed
    ///      each day, so after 60 days it has gained the 6% a year for 60 days and no more, and the returned price the
    ///      0.05% bound on top.
    function test_creepingSource_gainsBoundOnceThenRiseSpeed() public {
        uint256 initial = 1.1e18;
        (TrailingAnchorOracleBase oracle, INavSourceMock source) = _deployUsdy(initial, ACCRUING_BOUND, RISE, FALL);
        uint256 steps = 60;
        uint256 expected = initial;
        for (uint256 i = 1; i <= steps; ++i) {
            vm.warp(START + i * 1 days);
            TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
            source.setCurrentPrice(s.upperBound());
            assertEq(oracle.price(), s.upperBound() * 1e6, "the upper bound is returned");
            oracle.updateAnchor();
            expected += Math.mulDiv(expected, RISE * 1 days, WAD * YEAR);
            assertEq(oracle.anchorPrice(), expected, "one day of the rise speed");

            source.setCurrentPrice(TrailingAnchorOracleModel.read(oracle).upperBound());
            oracle.updateAnchor();
            assertEq(oracle.anchorPrice(), expected, "no second move in the block");
            assertEq(oracle.pendingAnchorAt(), 0, "the upper bound is no pending anchor");
        }
        uint256 returned = oracle.price();
        assertEq(returned, Math.mulDiv(expected, WAD + ACCRUING_BOUND, WAD) * 1e6, "the bound on the anchor");
        assertLt(returned, Math.mulDiv(initial, 1.0105e18, WAD) * 1e6, "under 1.05% above the start after 60 days");
    }

    // ---
    // REPLAY
    // ---

    /// @dev Replays `series` day by day with a keeper that updates every day, and checks each day against the model.
    ///      Returns the oldest anchor seen and the largest gap the speeds left between the source and the anchor after
    ///      the day's update, as a WAD fraction of the anchor.
    function _replayWithKeeper(
        TrailingAnchorOracleBase oracle,
        INavSourceMock source,
        uint256[] memory series,
        uint256 priceScale
    ) internal returns (uint256 oldest, uint256 lag) {
        for (uint256 day = 1; day <= DAYS; ++day) {
            vm.warp(START + day * 1 days);
            source.setCurrentPrice(series[day]);
            TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
            assertTrue(s.withinBounds(series[day]), "inside the bounds from the last anchor");
            assertEq(oracle.price(), series[day] * priceScale, "the price is the current price");
            oldest = Math.max(oldest, block.timestamp - s.anchorAt);
            TrailingAnchorOracleUpdate memory u = s.update(series[day], false, block.timestamp);
            assertEq(uint8(oracle.updateAnchor()), uint8(u.outcome), "the outcome the model predicts");
            assertEq(abi.encode(TrailingAnchorOracleModel.read(oracle)), abi.encode(u.next), "the model's state");
            assertEq(oracle.pendingAnchorAt(), 0, "no pending anchor");
            TrailingAnchorOracleState memory after_ = TrailingAnchorOracleModel.read(oracle);
            assertGt(after_.anchorPrice, after_.floor(), "above the floor");
            assertLe(after_.anchorPrice, after_.highWaterMark, "never over the high-water mark");
            uint256 anchorPrice = oracle.anchorPrice();
            uint256 gap = series[day] > anchorPrice ? series[day] - anchorPrice : anchorPrice - series[day];
            lag = Math.max(lag, Math.mulDiv(gap, WAD, anchorPrice));
        }
    }

    /// @dev Replays `series` with a keeper that updates every day, and again one delay later when the day's update left
    ///      a pending anchor, as a keeper watching `PendingAnchorSet` would; each update is checked against the model.
    ///      A day the oracle still reverts after that must find the anchor on the floor or the ceiling, and governance
    ///      then accepts the current price. Returns the days that needed it with the anchor on the floor and on the
    ///      ceiling, and the days the anchor sat on either after the keeper's updates.
    function _replayStress(TrailingAnchorOracleBase oracle, INavSourceMock source, uint256[] memory series)
        internal
        returns (uint256 floorStops, uint256 ceilingStops, uint256 pinnedDays)
    {
        oracle.grantRole(oracle.PRICE_ACCEPTOR_ROLE(), address(this));
        for (uint256 day = 1; day <= DAYS; ++day) {
            vm.warp(START + day * 1 days);
            source.setCurrentPrice(series[day]);
            _keeperUpdate(oracle, source);
            if (oracle.pendingAnchorAt() != 0) {
                vm.warp(block.timestamp + oracle.reanchorDelay());
                _keeperUpdate(oracle, source);
            }
            TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
            bool onFloor = s.anchorPrice == s.floor();
            bool onCeiling = s.anchorPrice == s.ceiling();
            if (onFloor || onCeiling) ++pinnedDays;
            if (s.withinBounds(series[day])) continue;
            assertTrue(onFloor || onCeiling, "unpriced only with the anchor on the floor or the ceiling");
            if (onFloor) ++floorStops;
            else ++ceilingStops;
            oracle.acceptPrice(series[day], series[day]);
            assertEq(oracle.price(), series[day] * 1e18, "priced once accepted");
        }
    }

    /// @dev One `updateAnchor()`, checked against the model.
    function _keeperUpdate(TrailingAnchorOracleBase oracle, INavSourceMock source) internal {
        TrailingAnchorOracleState memory s = TrailingAnchorOracleModel.read(oracle);
        TrailingAnchorOracleUpdate memory u = s.update(source.currentPrice(), false, block.timestamp);
        assertEq(uint8(oracle.updateAnchor()), uint8(u.outcome), "the outcome the model predicts");
        assertEq(abi.encode(TrailingAnchorOracleModel.read(oracle)), abi.encode(u.next), "the model's state");
    }

    // ---
    // DEPLOYMENT
    // ---

    function _deployUsdy(uint256 initialPrice, uint256 bound_, uint256 rise, uint256 fall)
        internal
        returns (TrailingAnchorOracleBase, INavSourceMock)
    {
        MockOndoPriceGetter getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(initialPrice);
        MockERC20 usdy = new MockERC20("Ondo US Dollar Yield", "USDY", 18);
        address impl = address(new UsdyNavOracle(address(getter), address(usdc), address(usdy)));
        return (_deploy(impl, bound_, rise, fall, BELOW_MARK, ACCRUING_ABOVE_MARK), getter);
    }

    function _deployCentrifuge(
        uint256 initialPrice,
        uint256 bound_,
        uint256 rise,
        uint256 fall,
        uint256 belowMark,
        uint256 aboveMark
    ) internal returns (TrailingAnchorOracleBase, INavSourceMock) {
        MockCentrifugeSpoke spoke = new MockCentrifugeSpoke(POOL_ID, SHARE_CLASS_ID);
        spoke.setCurrentPrice(initialPrice);
        MockERC20 share = new MockERC20("Fund share", "SHARE", 6);
        address impl =
            address(new CentrifugeNavOracle(address(spoke), POOL_ID, SHARE_CLASS_ID, address(usdc), address(share)));
        return (_deploy(impl, bound_, rise, fall, belowMark, aboveMark), spoke);
    }

    /// @dev The same bound both ways, the class's speeds, floor and ceiling, and the working delay and window.
    function _deploy(address impl, uint256 bound_, uint256 rise, uint256 fall, uint256 belowMark, uint256 aboveMark)
        internal
        returns (TrailingAnchorOracleBase)
    {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxPriceAboveAnchor = uint64(bound_);
        p.maxPriceBelowAnchor = uint64(bound_);
        p.maxAnchorRisePerYear = uint64(rise);
        p.maxAnchorFallPerYear = uint64(fall);
        p.maxAnchorBelowMark = uint64(belowMark);
        p.maxAnchorAboveMark = uint64(aboveMark);
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this), p);
        return TrailingAnchorOracleBase(address(new OssifiableProxy(impl, address(this), init)));
    }

    // ---
    // SERIES
    // ---

    /// @dev An accruing token: the NAV grows by `dailyRate` every calendar day.
    function _accrualSeries(uint256 dailyRate) internal pure returns (uint256[] memory series) {
        series = new uint256[](DAYS + 1);
        series[0] = 1.1e18;
        for (uint256 d = 1; d <= DAYS; ++d) {
            series[d] = series[d - 1] + Math.mulDiv(series[d - 1], dailyRate, WAD);
        }
    }

    /// @dev A fund that strikes its NAV on business days: the NAV stands still on other days and catches up the
    ///      accrual of every day since the last strike. `noise` adds a move of up to that share either way on each
    ///      strike, and on `dipDay` the NAV falls by `dip` instead.
    function _businessDaySeries(uint256 dailyRate, uint256 noise, uint256 dipDay, uint256 dip)
        internal
        pure
        returns (uint256[] memory series)
    {
        series = new uint256[](DAYS + 1);
        series[0] = 1.05e18;
        uint256 lastStrike;
        for (uint256 d = 1; d <= DAYS; ++d) {
            if (!_strikes(d)) {
                series[d] = series[d - 1];
                continue;
            }
            if (d == dipDay) {
                series[d] = Math.mulDiv(series[d - 1], WAD - dip, WAD);
            } else {
                uint256 nav = series[d - 1] + Math.mulDiv(series[d - 1], dailyRate * (d - lastStrike), WAD);
                uint256 move = noise == 0 ? 0 : uint256(keccak256(abi.encode(d))) % (2 * noise + 1);
                series[d] = Math.mulDiv(nav, WAD - noise + move, WAD);
            }
            lastStrike = d;
        }
    }

    /// @dev The credit fund's business-day accrual without its noise, with the stress from `STRESS_START`: 15 strikes
    ///      of `STRESS_STEP` down on top of the accrual, about 2.6% in three weeks, then 15 strikes of `RECOVERY_STEP`
    ///      up.
    function _stressSeries() internal pure returns (uint256[] memory series) {
        series = new uint256[](DAYS + 1);
        series[0] = 1.05e18;
        uint256 lastStrike;
        uint256 stressed;
        for (uint256 d = 1; d <= DAYS; ++d) {
            if (!_strikes(d)) {
                series[d] = series[d - 1];
                continue;
            }
            uint256 nav = series[d - 1] + Math.mulDiv(series[d - 1], CREDIT_DAILY * (d - lastStrike), WAD);
            if (d >= STRESS_START && stressed < 30) {
                nav = Math.mulDiv(nav, stressed < 15 ? WAD - STRESS_STEP : WAD + RECOVERY_STEP, WAD);
                ++stressed;
            }
            series[d] = nav;
            lastStrike = d;
        }
    }

    /// @dev The largest fall of `series` from its running high, as a WAD fraction of that high.
    function _maxDrawdown(uint256[] memory series) internal pure returns (uint256 drawdown) {
        uint256 high;
        for (uint256 d; d < series.length; ++d) {
            high = Math.max(high, series[d]);
            drawdown = Math.max(drawdown, Math.mulDiv(high - series[d], WAD, high));
        }
    }

    /// @dev Business days strike, except a holiday on the Thursday and Friday of week 13, so the longest pause runs
    ///      five days, from that Wednesday to the Monday after.
    function _strikes(uint256 d) internal pure returns (bool) {
        uint256 weekday = d % 7;
        if (weekday >= 5) return false;
        return !(d / 7 == 13 && weekday >= 3);
    }
}
