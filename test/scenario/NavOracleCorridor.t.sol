// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {NavOracleCheckParams} from "../../src/types/NavOracleTypes.sol";

import {MarketActions} from "../setup/MarketActions.sol";
import {NavOracleMarketSetup} from "../setup/NavOracleMarketSetup.sol";
import {NavOracleModel, NavOracleState} from "../setup/NavOracleModel.sol";
import {Market} from "../setup/Types.sol";

/// @notice The corridor's guarantees as scenarios on a fresh stack: parameter changes that keep the price, the
///         two-motion bypass of the corridor ratio, the at-most-one-tolerance lock-in of the open move, a frozen source
///         tripping the band, and a held source catching up inside it.
contract NavOracleCorridorTest is NavOracleMarketSetup {
    using MarketActions for Market;
    using NavOracleModel for NavOracleState;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOLERANCE = 0.002e18;

    function setUp() public {
        _deployNavMarket(NavOracleModel.workingDefaults(0.0375e18));
    }

    /// @dev A year of a source yielding 3.65% against a 3.75% path, re-anchored by the keeper every 90 days, then a
    ///      rate cut: the price and the expected price stay, the reference moves to the expected price now, and the
    ///      path grows at the new rate from there.
    function test_rateChangeAfterYear_keepsPrice() public {
        uint256 start = block.timestamp;
        uint256 moves;
        for (uint256 day = 1; day <= 365; ++day) {
            vm.warp(start + day * 1 days);
            _setSource(INITIAL_NAV * PRICE_SCALE * (WAD + 0.0365e18 * day / 365) / WAD);
            (bool moved,) = _keeper();
            if (moved) ++moves;
        }
        assertEq(moves, 4, "one re-anchor per 90 days");

        uint256 before = _m().oracle.price();
        uint256 expected = _state().expectedPrice(block.timestamp);
        uint256 capacity = Math.mulDiv(Math.mulDiv(100e18, before, ORACLE_PRICE_SCALE), LLTV, WAD);
        vm.prank(configurator);
        navOracle.setGrowthLimit(0.0355e18, TOLERANCE);

        assertEq(_m().oracle.price(), before, "price kept");
        assertEq(navOracle.referencePrice(), expected, "reference is the expected price at the change");
        assertEq(navOracle.referencePriceSetAt(), block.timestamp, "reference time is the change");
        assertEq(
            Math.mulDiv(Math.mulDiv(100e18, _m().oracle.price(), ORACLE_PRICE_SCALE), LLTV, WAD),
            capacity,
            "borrow capacity kept"
        );

        vm.warp(block.timestamp + 30 days);
        assertEq(
            _state().expectedPrice(block.timestamp),
            expected * (WAD + Math.mulDiv(0.0355e18, 30 days, 365 days)) / WAD,
            "the path grows at the new rate"
        );
    }

    /// @dev While the floor holds the price, a new interval and then a new step keep the floor and the price. Each
    ///      change restarts the step clock, so the next step lands one new interval later with the new size.
    function test_fallLimitChange_keepsFloor() public {
        vm.warp(block.timestamp + 1 days);
        _setSourceAtPath(WAD);
        navOracle.checkpoint();
        vm.warp(block.timestamp + 1 days);
        uint256 source = _setSource(navOracle.checkpointPrice() * 0.994e18 / WAD);
        uint256 floor_ = _state().floor(block.timestamp);
        assertEq(_m().oracle.price(), floor_, "held at the floor");

        vm.prank(configurator);
        navOracle.setFallLimit(0.0025e18, 12 hours);
        assertEq(_m().oracle.price(), floor_, "interval change keeps the price");
        assertEq(navOracle.checkpointPrice(), floor_, "checkpoint is the floor");
        vm.warp(block.timestamp + 12 hours - 1);
        assertEq(_m().oracle.price(), floor_, "no step before one new interval");
        vm.warp(block.timestamp + 1);
        floor_ = floor_ * (WAD - 0.0025e18) / WAD;
        assertEq(_m().oracle.price(), Math.max(source, floor_), "one step after one new interval");

        vm.prank(configurator);
        navOracle.setFallLimit(0.005e18, 12 hours);
        assertEq(_m().oracle.price(), Math.max(source, floor_), "step change keeps the price");
        vm.warp(block.timestamp + 12 hours);
        assertEq(_m().oracle.price(), Math.max(source, floor_ * (WAD - 0.005e18) / WAD), "one new step");
    }

    /// @dev Lowering the tolerance and then widening the drawdown would let debt taken under the old upper bound
    ///      fall past the write-off boundary. The second motion is refused until the configurator releases the old
    ///      tolerance.
    function test_twoMotionBypass_refusedUntilReleased() public {
        vm.startPrank(configurator);
        navOracle.setGrowthLimit(0.0375e18, 0);
        assertEq(navOracle.protectedGrowthTolerance(), TOLERANCE, "the old tolerance stays protected");

        NavOracleCheckParams memory wider = navOracle.checkParams();
        wider.maxDrawdown = 0.011e18;
        uint256 least = NavOracleModel.leastPriceRatio(wider);
        uint256 guarded = NavOracleModel.corridorRatio(0.011e18, 0, TOLERANCE);
        assertLt(guarded, least, "debt from the old bound would cross the write-off boundary");
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.PriceRatioBelowMinimum.selector, guarded, least));
        navOracle.setRevertBand(0.011e18, 0.03e18, 90 days);

        navOracle.releaseGrowthTolerance(0);
        navOracle.setRevertBand(0.011e18, 0.03e18, 90 days);
        vm.stopPrank();
        assertGe(NavOracleModel.corridorRatio(0.011e18, 0, 0), least, "accepted once released");
        assertEq(navOracle.checkParams().maxDrawdown, 0.011e18, "drawdown widened");
    }

    /// @dev I9: a source at the lowest value the move accepts, re-anchored and checkpointed in one transaction, lowers
    ///      the path by one tolerance. Neither call can repeat in that transaction, and the next move waits a full
    ///      reference interval.
    function test_moveThenCheckpoint_locksInAtMostOneTolerance() public {
        uint256 start = block.timestamp;
        for (uint256 day = 1; day < 90; ++day) {
            vm.warp(start + day * 1 days);
            _setSourceAtPath(WAD);
            _keeper();
        }
        vm.warp(start + 90 days);
        uint256 expected = _state().expectedPrice(block.timestamp);
        uint256 lowest = Math.mulDiv(expected, WAD - TOLERANCE, WAD);
        uint256 source = _setSource(lowest);
        assertLt(source - lowest, PRICE_SCALE, "the source sits on the lowest accepted value");
        uint256 before = _m().oracle.price();
        assertEq(before, source, "the price is the source");

        navOracle.moveReferencePrice();
        navOracle.checkpoint();

        assertEq(_m().oracle.price(), before, "the calls kept the price");
        assertEq(navOracle.referencePrice(), source, "reference");
        assertEq(navOracle.checkpointPrice(), source, "checkpoint");
        assertGe(_state().expectedPrice(block.timestamp), lowest, "the path fell by at most one tolerance");
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.ReferenceIntervalNotElapsed.selector, uint40(block.timestamp), uint40(90 days)
            )
        );
        navOracle.moveReferencePrice();
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.CheckpointIntervalNotElapsed.selector, uint40(block.timestamp), uint40(1 days)
            )
        );
        navOracle.checkpoint();

        vm.warp(block.timestamp + 90 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.ReferenceIntervalNotElapsed.selector, uint40(block.timestamp - 90 days + 1), 90 days
            )
        );
        navOracle.moveReferencePrice();
    }

    /// @dev A source that freezes five days before a reference move is re-anchored on the frozen value, since the path
    ///      has grown less than one tolerance above it. It then leaves the band
    ///      `maxDrawdown / ((1 − maxDrawdown) × yearlyGrowthRate)` of a year after that move, 78.5 days at the USDY
    ///      defaults, before the next move is allowed.
    function test_frozenSource_tripsBandAfterDrawdownOverRate() public {
        uint256 start = block.timestamp;
        for (uint256 day = 1; day <= 85; ++day) {
            vm.warp(start + day * 1 days);
            _setSourceAtPath(WAD);
            _keeper();
        }
        uint256 frozen = _source();
        bool moved;
        for (uint256 day = 86; day <= 90; ++day) {
            vm.warp(start + day * 1 days);
            (moved,) = _keeper();
        }
        assertTrue(moved, "re-anchored on the frozen value on day 90");
        assertEq(navOracle.referencePrice(), frozen, "reference");
        uint256 movedAt = block.timestamp;

        NavOracleCheckParams memory p = navOracle.checkParams();
        // The first whole day after maxDrawdown × 365 days / ((1 − maxDrawdown) × yearlyGrowthRate).
        uint256 tripSeconds = p.maxDrawdown * 365 days / Math.mulDiv(WAD - p.maxDrawdown, p.yearlyGrowthRate, WAD);
        uint256 tripDay = tripSeconds / 1 days + 1;
        assertEq(tripDay, 79, "78.5 days at the USDY defaults");
        assertLt(tripDay * 1 days, p.referenceInterval, "the band trips before the next move is allowed");

        for (uint256 day = 1; day < tripDay; ++day) {
            vm.warp(movedAt + day * 1 days);
            _keeper();
            assertEq(_m().oracle.price(), frozen, "the frozen source still prices");
        }
        vm.warp(movedAt + tripDay * 1 days);
        assertLt(frozen, _state().bandLow(block.timestamp), "under the band");
        vm.expectRevert(_bandError());
        _m().oracle.price();
    }

    /// @dev The public JTRSY NAVLink feed held 1.092899 for 65 days and then printed +0.755% in one round. At the JTRSY
    ///      defaults both the held value and the catch-up stay inside the band and under the upper bound.
    function test_sourceHeld65DaysThenCatchesUp_staysInBand() public {
        vm.startPrank(configurator);
        navOracle.setGrowthLimit(0.035e18, TOLERANCE);
        uint256 held = _setSource(1.092899e18 * PRICE_SCALE);
        navOracle.acceptCurrentPrice(held, held);
        vm.stopPrank();

        uint256 start = block.timestamp;
        for (uint256 day = 1; day <= 65; ++day) {
            vm.warp(start + day * 1 days);
            _keeper();
            assertEq(_m().oracle.price(), held, "the held value prices");
        }
        uint256 caughtUp = _setSource(1.10115e18 * PRICE_SCALE);
        NavOracleState memory s = _state();
        assertTrue(s.inBand(caughtUp, block.timestamp), "the catch-up is inside the band");
        assertLe(caughtUp, s.upperBound(block.timestamp), "and under the upper bound");
        assertEq(_m().oracle.price(), caughtUp, "the price follows the catch-up");
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }
}
