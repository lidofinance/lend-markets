// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {NavOracleBase} from "../../../src/oracle/NavOracleBase.sol";
import {UsdyOracle} from "../../../src/oracle/UsdyOracle.sol";
import {NavOracleCheckParams} from "../../../src/types/NavOracleTypes.sol";

import {MockNavOracle, MockUsdFeed} from "../../setup/Mocks.sol";
import {NavOracleModel, NavOracleState} from "../../setup/NavOracleModel.sol";

/// @notice Drives one NAV oracle through every state-changing entry point: the source, the loan token feed and time
///         move, anyone calls `checkpoint()` and `moveReferencePrice()`, and the configurator accepts prices and
///         changes every parameter.
/// @dev The handler keeps a shadow of the stored state and updates it by the specification's rules only. Before each
///      call it predicts, from the shadow, whether the call succeeds and otherwise the exact revert data, so a call
///      the specification allows reverts the run and a call it refuses must revert with the predicted error. Calls
///      the specification says keep the price count a ghost violation when they do not, for the suite's invariants
///      to read. The source price is the NAV itself, since the suite's tokens give a `PRICE_SCALE` of one.
contract NavOracleHandler is Test {
    using NavOracleModel for NavOracleState;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ONE_USD = 1e8;

    UsdyOracle public immutable ORACLE;
    MockNavOracle internal immutable SOURCE;
    MockUsdFeed internal immutable FEED;
    address internal immutable CONFIGURATOR;

    NavOracleState internal shadow;

    /// @dev Ghost violations: an open call or a parameter change that the specification says keeps the price and
    ///      did not.
    uint256 public openCallPriceChanges;
    uint256 public parameterPriceChanges;

    /// @dev Coverage counters, logged after the campaign.
    mapping(bytes32 action => uint256) public succeeded;
    mapping(bytes32 action => uint256) public refused;

    constructor(UsdyOracle oracle, MockNavOracle source, MockUsdFeed feed, address configurator) {
        ORACLE = oracle;
        SOURCE = source;
        FEED = feed;
        CONFIGURATOR = configurator;
        shadow.referencePrice = oracle.referencePrice();
        shadow.referencePriceSetAt = oracle.referencePriceSetAt();
        shadow.checkpointPrice = oracle.checkpointPrice();
        shadow.checkpointAt = oracle.checkpointAt();
        shadow.protectedGrowthTolerance = oracle.protectedGrowthTolerance();
        shadow.params = oracle.checkParams();
    }

    function shadowState() external view returns (NavOracleState memory) {
        return shadow;
    }

    // ---
    // THE WORLD
    // ---

    /// @dev Moves the source anywhere from 5% under to 7% over the current expected price, past both band edges.
    function moveSource(uint256 seed) external {
        uint256 expected = shadow.expectedPrice(block.timestamp);
        SOURCE.setPrice(bound(seed, expected * 0.95e18 / WAD, expected * 1.07e18 / WAD));
    }

    /// @dev Keeps the source within a tenth of a percent of the path, where the open calls mostly succeed.
    function trackPath(uint256 seed) external {
        uint256 expected = shadow.expectedPrice(block.timestamp);
        SOURCE.setPrice(bound(seed, expected * 0.999e18 / WAD, expected * 1.001e18 / WAD));
    }

    /// @dev Takes the source down on one seed in eight and brings it back otherwise, so outages stay short.
    function setSourceDown(uint256 seed) external {
        SOURCE.setDown(seed % 8 == 0);
    }

    /// @dev The loan token's feed between 0.98 and 1.02 USD on one seed in four, across the peg edges of the
    ///      configurable deviations, and within 0.1% of 1 USD otherwise.
    function movePeg(uint256 seed) external {
        if (seed % 4 == 0) FEED.setAnswer(int256(bound(seed, 0.98e8, 1.02e8)));
        else FEED.setAnswer(int256(bound(seed, 0.999e8, 1.001e8)));
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1 minutes, 30 days));
    }

    // ---
    // OPEN CALLS
    // ---

    function checkpoint(uint256 callerSeed) external {
        _checkpoint(_caller(callerSeed));
    }

    function moveReferencePrice(uint256 callerSeed) external {
        _move(_caller(callerSeed));
    }

    /// @dev The keeper's day: one fall interval passes, the source mostly follows the path, then the keeper calls
    ///      `moveReferencePrice()` and `checkpoint()`, as the operations section describes.
    function keeperDay(uint256 seed) external {
        vm.warp(block.timestamp + shadow.params.fallInterval);
        if (seed % 4 != 0) {
            uint256 expected = shadow.expectedPrice(block.timestamp);
            SOURCE.setPrice(bound(seed, expected * 0.999e18 / WAD, expected * 1.001e18 / WAD));
        }
        address keeper = _caller(0);
        _move(keeper);
        _checkpoint(keeper);
    }

    function _checkpoint(address caller) internal {
        bytes memory expected = _predictCheckpoint();
        if (expected.length != 0) {
            vm.expectRevert(expected);
            vm.prank(caller);
            ORACLE.checkpoint();
            ++refused["checkpoint"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        uint256 source = SOURCE.navPrice();
        uint256 expectedPrice = shadow.expectedPrice(block.timestamp);
        vm.prank(caller);
        ORACLE.checkpoint();
        shadow.checkpointPrice = Math.min(source, expectedPrice);
        shadow.checkpointAt = block.timestamp;
        _countOpenCallChange(pricedBefore, before);
        ++succeeded["checkpoint"];
    }

    function _move(address caller) internal {
        bytes memory expected = _predictMove();
        if (expected.length != 0) {
            vm.expectRevert(expected);
            vm.prank(caller);
            ORACLE.moveReferencePrice();
            ++refused["move"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(caller);
        ORACLE.moveReferencePrice();
        shadow.referencePrice = SOURCE.navPrice();
        shadow.referencePriceSetAt = block.timestamp;
        _countOpenCallChange(pricedBefore, before);
        ++succeeded["move"];
    }

    // ---
    // CONFIGURATOR
    // ---

    /// @dev A range that contains the source on two seeds in three, and misses it or is empty otherwise.
    function acceptCurrentPrice(uint256 lowSeed, uint256 highSeed) external {
        uint256 source = SOURCE.navPrice();
        uint256 lowest = bound(lowSeed, source * 0.99e18 / WAD, source * 1.005e18 / WAD);
        uint256 highest = bound(highSeed, source * 0.995e18 / WAD, source * 1.01e18 / WAD);
        bytes memory expected;
        if (lowest > highest) {
            expected = abi.encodeWithSelector(NavOracleBase.InvalidAcceptRange.selector, lowest, highest);
        } else if (SOURCE.isDown()) {
            expected = abi.encodeWithSelector(MockNavOracle.NavOracleDown.selector);
        } else if (source < lowest || source > highest) {
            expected = abi.encodeWithSelector(NavOracleBase.SourceOutsideAcceptRange.selector, source, lowest, highest);
        }
        vm.prank(CONFIGURATOR);
        if (expected.length != 0) {
            vm.expectRevert(expected);
            ORACLE.acceptCurrentPrice(lowest, highest);
            ++refused["accept"];
            return;
        }
        ORACLE.acceptCurrentPrice(lowest, highest);
        shadow.referencePrice = source;
        shadow.referencePriceSetAt = block.timestamp;
        shadow.checkpointPrice = source;
        shadow.checkpointAt = block.timestamp;
        ++succeeded["accept"];
    }

    function setGrowthLimit(uint256 rateSeed, uint256 toleranceSeed) external {
        NavOracleCheckParams memory params = shadow.params;
        // A new rate restarts the reference interval, so it changes on one seed in four only.
        params.yearlyGrowthRate = rateSeed % 4 == 0 ? bound(rateSeed, 0, 0.1e18) : params.yearlyGrowthRate;
        params.growthTolerance = toleranceSeed % 3 == 0 ? params.growthTolerance : bound(toleranceSeed, 0, 0.01e18);
        bool toleranceChanged = params.growthTolerance != shadow.params.growthTolerance;
        _applyParams(
            params,
            abi.encodeCall(NavOracleBase.setGrowthLimit, (params.yearlyGrowthRate, params.growthTolerance)),
            toleranceChanged,
            "growth"
        );
    }

    function setFallLimit(uint256 stepSeed, uint256 intervalSeed) external {
        NavOracleCheckParams memory params = shadow.params;
        // A new step or interval restarts the fall interval, so each changes on one seed in two only.
        params.maxFallPerInterval = stepSeed % 2 == 0 ? bound(stepSeed, 0, 0.02e18) : params.maxFallPerInterval;
        params.fallInterval = intervalSeed % 2 == 0 ? uint40(bound(intervalSeed, 0, 3 days)) : params.fallInterval;
        _applyParams(
            params,
            abi.encodeCall(NavOracleBase.setFallLimit, (params.maxFallPerInterval, params.fallInterval)),
            false,
            "fall"
        );
    }

    function setRevertBand(uint256 drawdownSeed, uint256 overshootSeed, uint256 intervalSeed) external {
        NavOracleCheckParams memory params = shadow.params;
        params.maxDrawdown = bound(drawdownSeed, 0, 0.03e18);
        params.maxOvershoot = bound(overshootSeed, 0, 0.06e18);
        params.referenceInterval = uint40(bound(intervalSeed, 1 days, 60 days));
        bytes memory call_ = abi.encodeCall(
            NavOracleBase.setRevertBand, (params.maxDrawdown, params.maxOvershoot, params.referenceInterval)
        );
        _applyParams(params, call_, false, "band");
    }

    /// @dev A ratio between 0.95 and 0.995, zero on one seed in ten, and a borrow rate up to about 63% a year.
    function setMarketLimits(uint256 ratioSeed, uint256 rateSeed) external {
        NavOracleCheckParams memory params = shadow.params;
        params.minPriceRatio = ratioSeed % 10 == 0 ? 0 : bound(ratioSeed, 0.95e18, 0.995e18);
        params.maxBorrowRate = bound(rateSeed, 0, 2e10);
        bytes memory call_ = abi.encodeCall(NavOracleBase.setMarketLimits, (params.minPriceRatio, params.maxBorrowRate));
        _applyParams(params, call_, false, "limits");
    }

    function setLoanTokenPegCheck(uint256 seed) external {
        NavOracleCheckParams memory params = shadow.params;
        // A whole unit is refused, zero accepts only an exact 1 USD answer, the rest sits between 0.2% and 2%.
        if (seed % 10 == 0) params.maxLoanTokenDeviation = WAD;
        else if (seed % 10 == 1) params.maxLoanTokenDeviation = 0;
        else params.maxLoanTokenDeviation = bound(seed, 0.002e18, 0.02e18);
        bytes memory call_ = abi.encodeCall(NavOracleBase.setLoanTokenPegCheck, (params.maxLoanTokenDeviation));
        _applyParams(params, call_, false, "peg");
    }

    function releaseGrowthTolerance(uint256 seed) external {
        // Inside the allowed range on even seeds, anywhere around it on odd ones.
        uint256 released = seed % 2 == 0
            ? bound(seed, shadow.params.growthTolerance, shadow.protectedGrowthTolerance)
            : bound(seed, 0, shadow.protectedGrowthTolerance + 0.001e18);
        if (released < shadow.params.growthTolerance || released > shadow.protectedGrowthTolerance) {
            vm.prank(CONFIGURATOR);
            vm.expectRevert(
                abi.encodeWithSelector(
                    NavOracleBase.InvalidReleasedTolerance.selector,
                    released,
                    shadow.params.growthTolerance,
                    shadow.protectedGrowthTolerance
                )
            );
            ORACLE.releaseGrowthTolerance(released);
            ++refused["release"];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        vm.prank(CONFIGURATOR);
        ORACLE.releaseGrowthTolerance(released);
        shadow.protectedGrowthTolerance = released;
        _countParameterChange(pricedBefore, before, false);
        ++succeeded["release"];
    }

    // ---
    // PREDICTIONS
    // ---

    /// @dev The revert `price()` must give now, or nothing: the peg first, then the source, then the band.
    function predictPriceRevert() public view returns (bytes memory) {
        (, int256 answer,,,) = FEED.latestRoundData();
        if (NavOracleModel.isOffPeg(answer, ONE_USD, shadow.params.maxLoanTokenDeviation)) {
            return abi.encodeWithSelector(NavOracleBase.LoanTokenOffPeg.selector);
        }
        if (SOURCE.isDown()) return abi.encodeWithSelector(MockNavOracle.NavOracleDown.selector);
        uint256 source = SOURCE.navPrice();
        if (!shadow.inBand(source, block.timestamp)) {
            return abi.encodeWithSelector(
                NavOracleBase.PriceOutOfBounds.selector,
                source,
                shadow.bandLow(block.timestamp),
                shadow.bandHigh(block.timestamp)
            );
        }
        return "";
    }

    function _predictCheckpoint() internal view returns (bytes memory) {
        if (block.timestamp - shadow.checkpointAt < shadow.params.fallInterval) {
            return abi.encodeWithSelector(
                NavOracleBase.CheckpointIntervalNotElapsed.selector,
                uint40(shadow.checkpointAt),
                shadow.params.fallInterval
            );
        }
        bytes memory priceRevert = predictPriceRevert();
        if (priceRevert.length != 0) return priceRevert;
        uint256 source = SOURCE.navPrice();
        uint256 floor_ = shadow.floor(block.timestamp);
        if (source < floor_) return abi.encodeWithSelector(NavOracleBase.SourceBelowFloor.selector, source, floor_);
        return "";
    }

    function _predictMove() internal view returns (bytes memory) {
        if (block.timestamp - shadow.referencePriceSetAt < shadow.params.referenceInterval) {
            return abi.encodeWithSelector(
                NavOracleBase.ReferenceIntervalNotElapsed.selector,
                uint40(shadow.referencePriceSetAt),
                shadow.params.referenceInterval
            );
        }
        bytes memory priceRevert = predictPriceRevert();
        if (priceRevert.length != 0) return priceRevert;
        uint256 source = SOURCE.navPrice();
        uint256 lowest = Math.mulDiv(shadow.expectedPrice(block.timestamp), WAD - shadow.params.growthTolerance, WAD);
        if (source < lowest) {
            return abi.encodeWithSelector(NavOracleBase.SourceBelowGrowthTolerance.selector, source, lowest);
        }
        uint256 floor_ = shadow.floor(block.timestamp);
        uint256 upper = shadow.upperBound(block.timestamp);
        if (source < floor_ || source > upper) {
            return abi.encodeWithSelector(NavOracleBase.SourceOutsideFloorAndBound.selector, source, floor_, upper);
        }
        return "";
    }

    /// @dev The validator's first refusal for `params` against the protected tolerance it would carry, in the order
    ///      the specification lists the conditions.
    function _predictValidator(NavOracleCheckParams memory p) internal view returns (bytes memory) {
        if (p.fallInterval == 0 || p.maxFallPerInterval == 0 || p.maxFallPerInterval >= WAD) {
            return abi.encodeWithSelector(NavOracleBase.InvalidFallLimit.selector, p.maxFallPerInterval, p.fallInterval);
        }
        if (p.maxDrawdown >= WAD || p.maxOvershoot <= p.growthTolerance) {
            return abi.encodeWithSelector(
                NavOracleBase.InvalidRevertBand.selector, p.maxDrawdown, p.maxOvershoot, p.growthTolerance
            );
        }
        uint256 least = NavOracleModel.leastReferenceInterval(p);
        if (p.referenceInterval < least) {
            return abi.encodeWithSelector(NavOracleBase.ReferenceIntervalTooShort.selector, p.referenceInterval, least);
        }
        if (p.maxLoanTokenDeviation >= WAD) {
            return abi.encodeWithSelector(NavOracleBase.InvalidLoanTokenDeviation.selector, p.maxLoanTokenDeviation);
        }
        if (p.minPriceRatio == 0) return abi.encodeWithSelector(NavOracleBase.InvalidMinPriceRatio.selector, 0);
        uint256 protected_ = Math.max(shadow.protectedGrowthTolerance, p.growthTolerance);
        uint256 ratio = NavOracleModel.corridorRatio(p.maxDrawdown, p.growthTolerance, protected_);
        uint256 leastRatio = NavOracleModel.leastPriceRatio(p);
        if (ratio < leastRatio) {
            return abi.encodeWithSelector(NavOracleBase.PriceRatioBelowMinimum.selector, ratio, leastRatio);
        }
        return "";
    }

    // ---
    // HELPERS
    // ---

    /// @dev Calls a setter as the configurator, predicting the validator, and on success moves the shadow by the
    ///      specification's rebase rules: a new rate moves the reference to the expected price now, a new step or
    ///      interval moves the checkpoint to the floor now, and the protected tolerance rises with the tolerance.
    function _applyParams(NavOracleCheckParams memory params, bytes memory call_, bool toleranceChanged, bytes32 action)
        internal
    {
        bytes memory expected = _predictValidator(params);
        if (expected.length != 0) {
            vm.expectRevert(expected);
            vm.prank(CONFIGURATOR);
            (bool refusedOk,) = address(ORACLE).call(call_);
            refusedOk;
            ++refused[action];
            return;
        }
        (bool pricedBefore, uint256 before) = _price();
        uint256 expectedNow = shadow.expectedPrice(block.timestamp);
        uint256 floorNow = shadow.floor(block.timestamp);
        vm.prank(CONFIGURATOR);
        (bool ok,) = address(ORACLE).call(call_);
        require(ok, "NavOracleHandler: an allowed parameter change reverted");

        if (params.yearlyGrowthRate != shadow.params.yearlyGrowthRate) {
            shadow.referencePrice = expectedNow;
            shadow.referencePriceSetAt = block.timestamp;
        }
        if (
            params.maxFallPerInterval != shadow.params.maxFallPerInterval
                || params.fallInterval != shadow.params.fallInterval
        ) {
            shadow.checkpointPrice = floorNow;
            shadow.checkpointAt = block.timestamp;
        }
        shadow.protectedGrowthTolerance = Math.max(shadow.protectedGrowthTolerance, params.growthTolerance);
        shadow.params = params;
        _countParameterChange(pricedBefore, before, toleranceChanged);
        ++succeeded[action];
    }

    /// @dev Anyone: a fresh address per seed, never a precompile or a cheatcode address.
    function _caller(uint256 seed) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("caller", seed)))));
    }

    function _price() internal view returns (bool priced, uint256 value) {
        (bool ok, bytes memory data) = address(ORACLE).staticcall(abi.encodeCall(NavOracleBase.price, ()));
        if (!ok) return (false, 0);
        return (true, abi.decode(data, (uint256)));
    }

    function _countOpenCallChange(bool pricedBefore, uint256 before) internal {
        (bool pricedAfter, uint256 afterCall) = _price();
        if (pricedBefore != pricedAfter || before != afterCall) ++openCallPriceChanges;
    }

    /// @dev A parameter change may move a revert boundary, and a changed tolerance moves a clamped price with the
    ///      upper bound. Any other change of a returned price is a violation.
    function _countParameterChange(bool pricedBefore, uint256 before, bool toleranceChanged) internal {
        (bool pricedAfter, uint256 afterCall) = _price();
        if (!pricedBefore || !pricedAfter || toleranceChanged) return;
        if (before != afterCall) ++parameterPriceChanges;
    }
}
