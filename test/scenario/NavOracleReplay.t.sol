// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel, TrailingAnchorOracleState} from "../setup/TrailingAnchorOracleModel.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {INavSourceMock, MockCentrifugeSpoke, MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";

/// @notice A year of NAV series shaped like the token classes the oracle prices, each replayed through the adapter of
///         its source with the bounds and speeds sized for its class:
///         - an accruing token like USDY steps every day, through `UsdyNavOracle`;
///         - a treasury fund like JTRSY strikes its NAV on business days and catches up the accrual after weekends and
///           a holiday, through `CentrifugeNavOracle`;
///         - a credit fund like JAAA does the same with a daily move either way and one sharp fall, through
///           `CentrifugeNavOracle`.
///         With a keeper that updates whenever the rules let it move the anchor, no day reverts, the price is the
///         current price on every day, and the anchor follows the source at the speeds. Without a keeper the accruing
///         token leaves its bound before its lifetime passes, and a creeping source gains its bound once and then only
///         the rise speed.
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
            _deployCentrifuge(series[0], TREASURY_BOUND, RISE, FALL);
        (uint256 oldest, uint256 lag) = _replayWithKeeper(oracle, source, series, 1e18);
        assertEq(oldest, 5 days, "oldest anchor: the longest pause");
        assertEq(lag, 0, "the anchor reaches the source on every strike");
    }

    /// @dev The credit fund's noise outruns the speeds on some days, so the anchor trails the source, but never far
    ///      enough for the price to leave the bounds.
    function test_replay_creditFund() public {
        uint256[] memory series = _businessDaySeries(CREDIT_DAILY, CREDIT_NOISE, CREDIT_DIP_DAY, CREDIT_DIP);
        (TrailingAnchorOracleBase oracle, INavSourceMock source) =
            _deployCentrifuge(series[0], CREDIT_BOUND, CREDIT_RISE, FALL);
        (uint256 oldest, uint256 lag) = _replayWithKeeper(oracle, source, series, 1e18);
        assertEq(oldest, 5 days, "oldest anchor: the longest pause");
        assertGt(lag, 0, "the anchor trails the source on some day");
        assertLt(lag, CREDIT_BOUND, "the lag stays inside the bounds");
    }

    /// @dev The credit fund's sharp fall, −0.21% in a day, sits inside its decrease bound.
    function test_replay_creditDipInsideBound() public pure {
        uint256[] memory series = _businessDaySeries(CREDIT_DAILY, CREDIT_NOISE, CREDIT_DIP_DAY, CREDIT_DIP);
        uint256 dip = CREDIT_DIP_DAY;
        assertEq(series[dip], Math.mulDiv(series[dip - 1], WAD - CREDIT_DIP, WAD), "-0.21%");
        assertGt(series[dip], Math.mulDiv(series[dip - 1], WAD - CREDIT_BOUND, WAD), "inside the decrease bound");
    }

    /// @dev Nobody updates: the anchor stays at the first day, and the accruing token's daily growth leaves the 0.05%
    ///      bound on day 5, before the 10-day lifetime, so the price reverts on the bound and the keeper has days, not
    ///      the lifetime, to act.
    function test_replayWithoutKeeper_leavesBoundBeforeLifetime() public {
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
        assertLt(day * 1 days, TrailingAnchorOracleModel.ANCHOR_LIFETIME, "before the lifetime");
    }

    /// @dev A source held at the upper bound of each new anchor, updated every day: the price is accepted every day, a
    ///      second update in the same block is refused, and the anchor rises by exactly one day of the rise speed each
    ///      day, so after 60 days it has gained the 6% a year for 60 days and no more, and the returned price the 0.05%
    ///      bound on top.
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
            vm.expectRevert(
                abi.encodeWithSelector(TrailingAnchorOracleBase.AnchorUnchanged.selector, source.currentPrice())
            );
            oracle.updateAnchor();
        }
        uint256 returned = oracle.price();
        assertEq(returned, Math.mulDiv(expected, WAD + ACCRUING_BOUND, WAD) * 1e6, "the bound on the anchor");
        assertLt(returned, Math.mulDiv(initial, 1.0105e18, WAD) * 1e6, "under 1.05% above the start after 60 days");
    }

    // ---
    // REPLAY
    // ---

    /// @dev Replays `series` day by day with a keeper that updates whenever the rules let it move the anchor, and
    ///      checks each day against the model. Returns the oldest anchor seen and the largest gap the speeds left
    ///      between the source and the anchor after the day's update, as a WAD fraction of the anchor.
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
            assertFalse(s.isStale(block.timestamp), "never stale");
            assertTrue(s.withinBounds(series[day]), "inside the bounds from the last anchor");
            assertEq(oracle.price(), series[day] * priceScale, "the price is the current price");
            oldest = Math.max(oldest, block.timestamp - s.anchorAt);
            if (s.updateRevert(series[day], false, block.timestamp).length == 0) {
                oracle.updateAnchor();
                assertEq(oracle.anchorPrice(), s.nextAnchor(series[day], block.timestamp), "the model's anchor");
            }
            uint256 anchorPrice = oracle.anchorPrice();
            uint256 gap = series[day] > anchorPrice ? series[day] - anchorPrice : anchorPrice - series[day];
            lag = Math.max(lag, Math.mulDiv(gap, WAD, anchorPrice));
        }
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
        return (_deploy(impl, bound_, rise, fall), getter);
    }

    function _deployCentrifuge(uint256 initialPrice, uint256 bound_, uint256 rise, uint256 fall)
        internal
        returns (TrailingAnchorOracleBase, INavSourceMock)
    {
        MockCentrifugeSpoke spoke = new MockCentrifugeSpoke(POOL_ID, SHARE_CLASS_ID);
        spoke.setCurrentPrice(initialPrice);
        MockERC20 share = new MockERC20("Fund share", "SHARE", 6);
        address impl =
            address(new CentrifugeNavOracle(address(spoke), POOL_ID, SHARE_CLASS_ID, address(usdc), address(share)));
        return (_deploy(impl, bound_, rise, fall), spoke);
    }

    /// @dev The same bound both ways, the class's speeds and the working lifetime.
    function _deploy(address impl, uint256 bound_, uint256 rise, uint256 fall)
        internal
        returns (TrailingAnchorOracleBase)
    {
        bytes memory init = TrailingAnchorOracleModel.initializeCall(
            address(this), bound_, bound_, TrailingAnchorOracleModel.ANCHOR_LIFETIME, rise, fall
        );
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

    /// @dev Business days strike, except a holiday on the Thursday and Friday of week 13, so the longest pause runs
    ///      five days, from that Wednesday to the Monday after.
    function _strikes(uint256 d) internal pure returns (bool) {
        uint256 weekday = d % 7;
        if (weekday >= 5) return false;
        return !(d / 7 == 13 && weekday >= 3);
    }
}
