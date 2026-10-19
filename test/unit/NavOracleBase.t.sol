// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test, stdError} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ChainlinkNavOracle} from "../../src/oracle/ChainlinkNavOracle.sol";
import {IChainlinkAggregator, NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {UsdyOracle} from "../../src/oracle/UsdyOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {NavOracleCheckParams} from "../../src/types/NavOracleTypes.sol";

import {MockERC20, MockNavOracle, MockUsdFeed} from "../setup/Mocks.sol";
import {NavOracleModel, NavOracleState} from "../setup/NavOracleModel.sol";

/// @notice `NavOracleBase` method by method, through `UsdyOracle` over a mock NAV getter and a mock USD feed.
/// @dev The loan token has 18 decimals and the collateral 36, so `PRICE_SCALE` is one and a source price is a NAV
///      to the wei: every band, bound, floor and peg edge is reachable exactly. Adapter scaling is covered in the
///      adapter suites. Every expected value comes from `NavOracleModel`, the spec's formulas, over the stored
///      state, never from a value the oracle computed.
contract NavOracleBaseTest is Test {
    using NavOracleModel for NavOracleState;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant START = 1_760_000_000;
    uint256 internal constant INITIAL_NAV = 1.112233445566778899e18;
    /// @dev 1 USD in the mock feed's 8 decimals.
    uint256 internal constant ONE_USD = 1e8;

    MockERC20 internal loan;
    MockERC20 internal collateral;
    MockNavOracle internal nav;
    MockUsdFeed internal feed;
    UsdyOracle internal oracle;

    address internal admin = makeAddr("admin");
    address internal configurator = makeAddr("configurator");
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        vm.warp(START);
        loan = new MockERC20("Loan", "LOAN", 18);
        collateral = new MockERC20("Collateral", "COLL", 36);
        nav = new MockNavOracle();
        feed = new MockUsdFeed();
        nav.setPrice(INITIAL_NAV);
        oracle = _deploy(_defaults());
        bytes32 configRole = oracle.CONFIG_ROLE();
        vm.prank(admin);
        oracle.grantRole(configRole, configurator);
    }

    // ---
    // CONSTRUCTOR AND INITIALIZE
    // ---

    function testRevert_constructor_zeroAddress() public {
        vm.expectRevert(NavOracleBase.ZeroAddress.selector);
        new UsdyOracle(address(nav), address(0), address(collateral), address(feed));
        vm.expectRevert(NavOracleBase.ZeroAddress.selector);
        new UsdyOracle(address(nav), address(loan), address(0), address(feed));
        vm.expectRevert(NavOracleBase.ZeroAddress.selector);
        new UsdyOracle(address(nav), address(loan), address(collateral), address(0));
    }

    /// @dev `PRICE_SCALE = 10^(36 + loanDecimals − collateralDecimals − 18)`, refused when the exponent is
    /// negative.
    function testFuzz_constructor_priceScale(uint8 loanDecimals, uint8 collateralDecimals) public {
        loanDecimals = uint8(bound(loanDecimals, 0, 36));
        collateralDecimals = uint8(bound(collateralDecimals, 0, 60));
        MockERC20 loanToken = new MockERC20("L", "L", loanDecimals);
        MockERC20 collateralToken = new MockERC20("C", "C", collateralDecimals);
        if (uint256(collateralDecimals) + 18 > 36 + uint256(loanDecimals)) {
            vm.expectRevert(
                abi.encodeWithSelector(NavOracleBase.UnsupportedDecimals.selector, loanDecimals, collateralDecimals)
            );
            new UsdyOracle(address(nav), address(loanToken), address(collateralToken), address(feed));
            return;
        }
        UsdyOracle impl = new UsdyOracle(address(nav), address(loanToken), address(collateralToken), address(feed));
        assertEq(impl.PRICE_SCALE(), 10 ** (36 + uint256(loanDecimals) - collateralDecimals - 18), "PRICE_SCALE");
        assertEq(address(impl.LOAN_TOKEN_FEED()), address(feed), "LOAN_TOKEN_FEED");
        assertEq(impl.ONE_USD_IN_FEED_DECIMALS(), ONE_USD, "ONE_USD_IN_FEED_DECIMALS");
    }

    function testRevert_constructor_disablesInitializers() public {
        UsdyOracle impl = new UsdyOracle(address(nav), address(loan), address(collateral), address(feed));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(admin, _defaults());
    }

    function test_initialize_seedsReferenceAndCheckpoint() public {
        NavOracleCheckParams memory params = _defaults();
        UsdyOracle impl = new UsdyOracle(address(nav), address(loan), address(collateral), address(feed));

        vm.expectEmit(true, true, true, true);
        emit NavOracleBase.ProtectedGrowthToleranceSet(params.growthTolerance);
        vm.expectEmit(true, true, true, true);
        emit NavOracleBase.CheckParamsSet(params);
        vm.expectEmit(true, true, true, true);
        emit NavOracleBase.ReferencePriceSet(INITIAL_NAV, uint40(START), true);
        vm.expectEmit(true, true, true, true);
        emit NavOracleBase.CheckpointSet(INITIAL_NAV, uint40(START));
        UsdyOracle fresh = UsdyOracle(
            address(
                new OssifiableProxy(address(impl), admin, abi.encodeCall(NavOracleBase.initialize, (admin, params)))
            )
        );

        assertEq(fresh.referencePrice(), INITIAL_NAV, "referencePrice");
        assertEq(fresh.referencePriceSetAt(), START, "referencePriceSetAt");
        assertEq(fresh.checkpointPrice(), INITIAL_NAV, "checkpointPrice");
        assertEq(fresh.checkpointAt(), START, "checkpointAt");
        assertEq(fresh.protectedGrowthTolerance(), params.growthTolerance, "protectedGrowthTolerance");
        _assertParams(fresh.checkParams(), params);
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), admin), "admin role");
        assertEq(fresh.getRoleMemberCount(fresh.DEFAULT_ADMIN_ROLE()), 1, "one admin");
        assertEq(fresh.getRoleMemberCount(fresh.CONFIG_ROLE()), 0, "config role starts empty");
        assertEq(fresh.price(), INITIAL_NAV, "price is the source at once");
    }

    function testRevert_initialize_zeroAdmin() public {
        UsdyOracle impl = new UsdyOracle(address(nav), address(loan), address(collateral), address(feed));
        vm.expectRevert(NavOracleBase.ZeroAddress.selector);
        new OssifiableProxy(address(impl), admin, abi.encodeCall(NavOracleBase.initialize, (address(0), _defaults())));
    }

    function testRevert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(admin, _defaults());
    }

    function testRevert_initialize_sourceFails() public {
        UsdyOracle impl = new UsdyOracle(address(nav), address(loan), address(collateral), address(feed));
        bytes memory init = abi.encodeCall(NavOracleBase.initialize, (admin, _defaults()));
        nav.setPrice(0);
        vm.expectRevert(NavOracleBase.SourceReturnedZero.selector);
        new OssifiableProxy(address(impl), admin, init);
        nav.setDown(true);
        vm.expectRevert(MockNavOracle.NavOracleDown.selector);
        new OssifiableProxy(address(impl), admin, init);
    }

    function testRevert_initialize_invalidParams() public {
        NavOracleCheckParams memory params = _defaults();
        params.fallInterval = 0;
        UsdyOracle impl = new UsdyOracle(address(nav), address(loan), address(collateral), address(feed));
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidFallLimit.selector, params.maxFallPerInterval, 0));
        new OssifiableProxy(address(impl), admin, abi.encodeCall(NavOracleBase.initialize, (admin, params)));
    }

    /// @dev Initialization seeds from the source without the peg check, so an off-peg feed does not block deployment.
    function test_initialize_ignoresPeg() public {
        feed.setAnswer(0.9e8);
        UsdyOracle fresh = _deploy(_defaults());
        assertEq(fresh.referencePrice(), INITIAL_NAV, "seeded while off peg");
    }

    // ---
    // PRICE
    // ---

    /// @dev With a zero tolerance the upper bound is the expected price itself, so a source above it returns the
    ///      expected price and pins the growth formula to the wei.
    function testFuzz_expectedPrice_matchesFormula(uint256 rate, uint256 elapsed, uint256 navValue) public {
        rate = bound(rate, 0, 0.5e18);
        elapsed = bound(elapsed, 0, 3 * 365 days);
        navValue = bound(navValue, 1e6, 1e30);
        NavOracleCheckParams memory params = _defaults();
        params.yearlyGrowthRate = rate;
        params.growthTolerance = 0;
        params.maxOvershoot = 0.5e18;
        params.maxDrawdown = 0.1e18;
        params.minPriceRatio = 1;
        params.referenceInterval = 365 days;
        nav.setPrice(navValue);
        oracle = _deploy(params);

        vm.warp(START + elapsed);
        uint256 expected = navValue * (WAD + rate * elapsed / 365 days) / WAD;
        nav.setPrice(expected + expected / 10);
        assertEq(oracle.price(), expected, "price at a zero tolerance is the expected price");
        assertEq(_read().expectedPrice(block.timestamp), expected, "model agrees with the written-out formula");
    }

    /// @dev Above the upper bound and inside the band the price is `expectedPrice × (1 + growthTolerance)`.
    function testFuzz_upperBound_clampsSource(uint256 elapsed, uint256 excess) public {
        elapsed = bound(elapsed, 0, 89 days);
        vm.warp(START + elapsed);
        NavOracleState memory s = _read();
        uint256 bound_ = s.upperBound(block.timestamp);
        uint256 source = bound(excess, bound_, s.bandHigh(block.timestamp));
        nav.setPrice(source);
        assertEq(oracle.price(), bound_, "clamped at the upper bound");
    }

    /// @dev A source under the floor and inside the band returns the floor, which falls one step per whole interval.
    function testFuzz_floor_holdsSourceAndFallsPerInterval(uint256 intervals, uint256 offset, uint256 drop) public {
        NavOracleCheckParams memory params = _wideBand();
        oracle = _deploy(params);
        intervals = bound(intervals, 0, 150);
        offset = bound(offset, 0, params.fallInterval - 1);
        vm.warp(START + intervals * params.fallInterval + offset);
        NavOracleState memory s = _read();
        uint256 floor_ = INITIAL_NAV * (WAD - intervals * params.maxFallPerInterval) / WAD;
        assertEq(s.floor(block.timestamp), floor_, "model agrees with the written-out floor");
        uint256 source = bound(drop, s.bandLow(block.timestamp), floor_);
        nav.setPrice(source);
        assertEq(oracle.price(), Math.max(source, floor_), "held at the floor");
    }

    /// @dev Once the steps add up to the whole price the floor is zero and the price is the source.
    function test_floor_reachesZero() public {
        NavOracleCheckParams memory params = _wideBand();
        params.maxFallPerInterval = 0.3e18;
        params.referenceInterval = 10 days;
        oracle = _deploy(params);
        vm.warp(START + 4 days);
        assertEq(_read().floor(block.timestamp), 0, "four steps of 30% reach zero");
        uint256 source = _read().bandLow(block.timestamp);
        nav.setPrice(source);
        assertEq(oracle.price(), source, "no floor left");
    }

    /// @dev Both band edges are inside the band, one wei beyond either reverts with both edges.
    function testFuzz_bandEdges_inclusive(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 89 days);
        vm.warp(START + elapsed);
        NavOracleState memory s = _read();
        uint256 low = s.bandLow(block.timestamp);
        uint256 high = s.bandHigh(block.timestamp);

        nav.setPrice(low);
        assertEq(oracle.price(), s.boundedPrice(low, block.timestamp), "low edge prices");
        nav.setPrice(high);
        assertEq(oracle.price(), s.upperBound(block.timestamp), "high edge is clamped");
        nav.setPrice(low - 1);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.PriceOutOfBounds.selector, low - 1, low, high));
        oracle.price();
        nav.setPrice(high + 1);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.PriceOutOfBounds.selector, high + 1, low, high));
        oracle.price();
    }

    /// @dev Any history of source moves, checkpoints and time: `price()` is the rule over the stored state, or the
    ///      band revert.
    function testFuzz_price_matchesRule(uint256 first, uint256 second, uint256 wait, uint256 later, bool checkpoint_)
        public
    {
        wait = bound(wait, 1 days, 60 days);
        later = bound(later, 0, 20 days);
        vm.warp(START + wait);
        nav.setPrice(_sourceAround(first));
        if (checkpoint_ && _read().inBand(nav.navPrice(), block.timestamp)) {
            if (nav.navPrice() >= _read().floor(block.timestamp)) oracle.checkpoint();
        }
        vm.warp(block.timestamp + later);
        nav.setPrice(_sourceAround(second));
        _assertPriceMatchesRule();
    }

    function testRevert_price_sourceFails() public {
        nav.setPrice(0);
        vm.expectRevert(NavOracleBase.SourceReturnedZero.selector);
        oracle.price();
        nav.setDown(true);
        vm.expectRevert(MockNavOracle.NavOracleDown.selector);
        oracle.price();
    }

    // ---
    // LOAN TOKEN PEG
    // ---

    /// @dev 1 USD ± the allowed deviation is on peg, one feed unit further is off peg, on either side.
    function test_peg_edgesInclusive() public {
        uint256 allowed = 0.005e18 * ONE_USD / WAD;
        feed.setAnswer(int256(ONE_USD - allowed));
        oracle.price();
        feed.setAnswer(int256(ONE_USD + allowed));
        oracle.price();
        feed.setAnswer(int256(ONE_USD - allowed - 1));
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.price();
        feed.setAnswer(int256(ONE_USD + allowed + 1));
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.price();
    }

    function testFuzz_peg_matchesRule(int256 answer, uint256 deviation) public {
        deviation = bound(deviation, 0, WAD - 1);
        vm.prank(configurator);
        oracle.setLoanTokenPegCheck(deviation);
        answer = bound(answer, -2e8, 3e8);
        feed.setAnswer(answer);
        if (NavOracleModel.isOffPeg(answer, ONE_USD, deviation)) {
            vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
            oracle.price();
        } else {
            assertEq(oracle.price(), INITIAL_NAV, "on peg or ignored");
        }
    }

    /// @dev The check reads the answer whatever the round's age: a stale off-peg round still reverts.
    function test_peg_staleOffPegAnswerStillReverts() public {
        vm.warp(START + 30 days);
        vm.mockCall(
            address(feed),
            abi.encodeCall(IChainlinkAggregator.latestRoundData, ()),
            abi.encode(uint80(7), int256(0.97e8), uint256(1), uint256(1), uint80(7))
        );
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.price();
    }

    function test_peg_revertingFeedIgnored() public {
        feed.setAnswer(0.5e8);
        vm.mockCallRevert(address(feed), abi.encodeCall(IChainlinkAggregator.latestRoundData, ()), "feed down");
        assertEq(oracle.price(), INITIAL_NAV, "a reverting feed is ignored");
    }

    /// @dev Fewer than five words back is ignored, whatever the answer word says.
    function test_peg_shortReturnIgnored() public {
        bytes4 selector = IChainlinkAggregator.latestRoundData.selector;
        vm.mockCall(address(feed), abi.encodeWithSelector(selector), "");
        assertEq(oracle.price(), INITIAL_NAV, "empty return ignored");
        vm.mockCall(
            address(feed),
            abi.encodeWithSelector(selector),
            abi.encode(uint256(1), int256(0.5e8), uint256(0), uint256(0))
        );
        assertEq(oracle.price(), INITIAL_NAV, "128 bytes ignored");
        vm.mockCall(
            address(feed),
            abi.encodeWithSelector(selector),
            bytes.concat(abi.encode(uint256(1), int256(0.5e8), uint256(0), uint256(0)), bytes31(0))
        );
        assertEq(oracle.price(), INITIAL_NAV, "159 bytes ignored");
    }

    /// @dev Five words whose round id, timestamps and answered-in-round overflow their types: only the answer word is
    ///      read, so the check still works on it.
    function test_peg_outOfTypeFieldsReadsAnswerOnly() public {
        bytes4 selector = IChainlinkAggregator.latestRoundData.selector;
        uint256 junk = type(uint256).max;
        vm.mockCall(address(feed), abi.encodeWithSelector(selector), abi.encode(junk, int256(1e8), junk, junk, junk));
        assertEq(oracle.price(), INITIAL_NAV, "on-peg answer amid junk");
        vm.mockCall(address(feed), abi.encodeWithSelector(selector), abi.encode(junk, int256(0.9e8), junk, junk, junk));
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.price();
        vm.mockCall(
            address(feed),
            abi.encodeWithSelector(selector),
            bytes.concat(abi.encode(junk, int256(0.9e8), junk, junk, junk), hex"deadbeef")
        );
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.price();
    }

    function test_peg_nonPositiveAnswerIgnored() public {
        feed.setAnswer(0);
        assertEq(oracle.price(), INITIAL_NAV, "zero ignored");
        feed.setAnswer(-1);
        assertEq(oracle.price(), INITIAL_NAV, "negative ignored");
        feed.setAnswer(type(int256).min);
        assertEq(oracle.price(), INITIAL_NAV, "most negative ignored");
    }

    /// @dev The peg is the first check: an off-peg feed reverts with its own error even when the source is down.
    function test_peg_checkedBeforeSource() public {
        feed.setAnswer(0.9e8);
        nav.setDown(true);
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.price();
    }

    /// @dev One USD follows the feed's decimals.
    function test_peg_followsFeedDecimals() public {
        vm.mockCall(address(feed), abi.encodeCall(IChainlinkAggregator.decimals, ()), abi.encode(uint8(18)));
        UsdyOracle fresh = _deploy(_defaults());
        assertEq(fresh.ONE_USD_IN_FEED_DECIMALS(), 1e18, "18-decimal feed");
        bytes4 selector = IChainlinkAggregator.latestRoundData.selector;
        vm.mockCall(address(feed), abi.encodeWithSelector(selector), abi.encode(1, int256(1.005e18), 0, 0, 1));
        assertEq(fresh.price(), INITIAL_NAV, "1.005 on peg");
        vm.mockCall(address(feed), abi.encodeWithSelector(selector), abi.encode(1, int256(1.005e18 + 1), 0, 0, 1));
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        fresh.price();
    }

    // ---
    // CHECKPOINT
    // ---

    function testRevert_checkpoint_intervalNotElapsed() public {
        vm.expectRevert(
            abi.encodeWithSelector(NavOracleBase.CheckpointIntervalNotElapsed.selector, uint40(START), 1 days)
        );
        oracle.checkpoint();
        vm.warp(START + 1 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(NavOracleBase.CheckpointIntervalNotElapsed.selector, uint40(START), 1 days)
        );
        oracle.checkpoint();
    }

    /// @dev Open to anyone: the checkpoint becomes the source under the path and the path over it.
    function test_checkpoint_setsLowerOfSourceAndExpected() public {
        vm.warp(START + 10 days);
        uint256 expected = _read().expectedPrice(block.timestamp);

        nav.setPrice(expected - 12_345);
        vm.expectEmit(true, true, true, true, address(oracle));
        emit NavOracleBase.CheckpointSet(expected - 12_345, uint40(block.timestamp));
        vm.prank(anyone);
        oracle.checkpoint();
        assertEq(oracle.checkpointPrice(), expected - 12_345, "source under the path");
        assertEq(oracle.checkpointAt(), block.timestamp, "checkpointAt");

        vm.warp(block.timestamp + 1 days);
        expected = _read().expectedPrice(block.timestamp);
        nav.setPrice(expected + 54_321);
        vm.prank(anyone);
        oracle.checkpoint();
        assertEq(oracle.checkpointPrice(), expected, "path under the source");
        assertEq(oracle.referencePrice(), INITIAL_NAV, "reference untouched");
    }

    function testRevert_checkpoint_sourceBelowFloor() public {
        vm.warp(START + 1 days);
        uint256 floor_ = _read().floor(block.timestamp);
        nav.setPrice(floor_ - 1);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.SourceBelowFloor.selector, floor_ - 1, floor_));
        oracle.checkpoint();
    }

    function testRevert_checkpoint_priceReverts() public {
        vm.warp(START + 1 days);
        NavOracleState memory s = _read();
        nav.setPrice(s.bandLow(block.timestamp) - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.PriceOutOfBounds.selector,
                s.bandLow(block.timestamp) - 1,
                s.bandLow(block.timestamp),
                s.bandHigh(block.timestamp)
            )
        );
        oracle.checkpoint();
        nav.setPrice(INITIAL_NAV);
        feed.setAnswer(1.1e8);
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.checkpoint();
        feed.setAnswer(1e8);
        nav.setDown(true);
        vm.expectRevert(MockNavOracle.NavOracleDown.selector);
        oracle.checkpoint();
    }

    /// @dev I3: a checkpoint never changes `price()`, and it leaves the floor at the lower of the source and the path.
    function testFuzz_checkpoint_keepsPrice(uint256 first, uint256 second, uint256 wait, uint256 later) public {
        wait = bound(wait, 1 days, 80 days);
        later = bound(later, 1 days, 10 days);
        vm.warp(START + wait);
        nav.setPrice(_sourceAround(first));
        _checkpointIfAllowed();
        vm.warp(block.timestamp + later);
        nav.setPrice(_sourceAround(second));
        NavOracleState memory s = _read();
        uint256 source = nav.navPrice();
        if (!s.inBand(source, block.timestamp) || source < s.floor(block.timestamp)) return;

        uint256 before = oracle.price();
        oracle.checkpoint();
        assertEq(oracle.price(), before, "checkpoint changed the price");
        assertEq(oracle.checkpointPrice(), Math.min(source, s.expectedPrice(block.timestamp)), "checkpoint value");
    }

    // ---
    // OPEN REFERENCE MOVE
    // ---

    function testRevert_moveReferencePrice_intervalNotElapsed() public {
        vm.warp(START + 90 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(NavOracleBase.ReferenceIntervalNotElapsed.selector, uint40(START), 90 days)
        );
        oracle.moveReferencePrice();
    }

    function test_moveReferencePrice_setsReferenceToSource() public {
        vm.warp(START + 90 days);
        uint256 source = _read().expectedPrice(block.timestamp) - 777;
        nav.setPrice(source);
        vm.expectEmit(true, true, true, true, address(oracle));
        emit NavOracleBase.ReferencePriceSet(source, uint40(block.timestamp), false);
        vm.prank(anyone);
        oracle.moveReferencePrice();
        assertEq(oracle.referencePrice(), source, "reference");
        assertEq(oracle.referencePriceSetAt(), block.timestamp, "referencePriceSetAt");
        assertEq(oracle.checkpointPrice(), INITIAL_NAV, "checkpoint untouched");
        assertEq(oracle.checkpointAt(), START, "checkpointAt untouched");
    }

    /// @dev The source must sit no lower than one tolerance under the path, to the wei.
    function testRevert_moveReferencePrice_belowGrowthTolerance() public {
        vm.warp(START + 90 days);
        uint256 lowest = _read().expectedPrice(block.timestamp) * (WAD - 0.002e18) / WAD;
        nav.setPrice(lowest);
        uint256 snapshot = vm.snapshotState();
        oracle.moveReferencePrice();
        vm.revertToState(snapshot);
        nav.setPrice(lowest - 1);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.SourceBelowGrowthTolerance.selector, lowest - 1, lowest));
        oracle.moveReferencePrice();
    }

    function testRevert_moveReferencePrice_aboveUpperBound() public {
        vm.warp(START + 90 days);
        NavOracleState memory s = _read();
        uint256 upper = s.upperBound(block.timestamp);
        nav.setPrice(upper);
        uint256 snapshot = vm.snapshotState();
        oracle.moveReferencePrice();
        vm.revertToState(snapshot);
        nav.setPrice(upper + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.SourceOutsideFloorAndBound.selector, upper + 1, s.floor(block.timestamp), upper
            )
        );
        oracle.moveReferencePrice();
    }

    /// @dev A source inside the tolerance but under a fresh floor cannot move the path.
    function testRevert_moveReferencePrice_belowFloor() public {
        vm.warp(START + 90 days);
        NavOracleState memory s = _read();
        nav.setPrice(s.expectedPrice(block.timestamp) + 1);
        oracle.checkpoint();
        s = _read();
        uint256 floor_ = s.floor(block.timestamp);
        nav.setPrice(floor_ - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.SourceOutsideFloorAndBound.selector, floor_ - 1, floor_, s.upperBound(block.timestamp)
            )
        );
        oracle.moveReferencePrice();
    }

    function testRevert_moveReferencePrice_priceReverts() public {
        vm.warp(START + 90 days);
        feed.setAnswer(0.9e8);
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.moveReferencePrice();
        feed.setAnswer(1e8);
        NavOracleState memory s = _read();
        nav.setPrice(s.bandHigh(block.timestamp) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.PriceOutOfBounds.selector,
                s.bandHigh(block.timestamp) + 1,
                s.bandLow(block.timestamp),
                s.bandHigh(block.timestamp)
            )
        );
        oracle.moveReferencePrice();
    }

    /// @dev I3: a reference move never changes `price()` and never touches the checkpoint.
    function testFuzz_moveReferencePrice_keepsPrice(uint256 first, uint256 second, uint256 wait, bool checkpoint_)
        public
    {
        wait = bound(wait, 90 days, 200 days);
        vm.warp(START + wait - 1 days);
        nav.setPrice(_sourceAround(first));
        if (checkpoint_) _checkpointIfAllowed();
        vm.warp(START + wait);
        uint256 expected = _read().expectedPrice(block.timestamp);
        // Mostly inside the move's window of ±0.2%, with room on both sides for the refused cases.
        nav.setPrice(bound(second, expected * 0.997e18 / WAD, expected * 1.003e18 / WAD));
        NavOracleState memory s = _read();
        uint256 source = nav.navPrice();
        bool allowed = s.inBand(source, block.timestamp) && source >= expected * (WAD - 0.002e18) / WAD
            && source >= s.floor(block.timestamp) && source <= s.upperBound(block.timestamp);
        if (!allowed) return;

        uint256 before = oracle.price();
        oracle.moveReferencePrice();
        assertEq(oracle.price(), before, "move changed the price");
        assertEq(oracle.checkpointPrice(), s.checkpointPrice, "move touched the checkpoint");
        assertEq(oracle.checkpointAt(), s.checkpointAt, "move touched checkpointAt");
    }

    // ---
    // ACCEPTANCE
    // ---

    function testRevert_acceptCurrentPrice_notConfigurator() public {
        bytes32 role = oracle.CONFIG_ROLE();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, anyone, role));
        vm.prank(anyone);
        oracle.acceptCurrentPrice(0, type(uint256).max);
    }

    function testRevert_acceptCurrentPrice_invalidRange() public {
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidAcceptRange.selector, 2, 1));
        vm.prank(configurator);
        oracle.acceptCurrentPrice(2, 1);
    }

    function testRevert_acceptCurrentPrice_outsideRange() public {
        uint256 source = INITIAL_NAV;
        vm.startPrank(configurator);
        vm.expectRevert(
            abi.encodeWithSelector(NavOracleBase.SourceOutsideAcceptRange.selector, source, source + 1, source + 2)
        );
        oracle.acceptCurrentPrice(source + 1, source + 2);
        vm.expectRevert(
            abi.encodeWithSelector(NavOracleBase.SourceOutsideAcceptRange.selector, source, source - 2, source - 1)
        );
        oracle.acceptCurrentPrice(source - 2, source - 1);
        vm.stopPrank();
    }

    /// @dev Acceptance clears a band revert and a fall faster than the floor at once, sets both stored prices with
    ///      their times, and needs neither the band nor the peg.
    function test_acceptCurrentPrice_setsReferenceAndCheckpoint() public {
        vm.warp(START + 10 days);
        uint256 crashed = INITIAL_NAV * 9 / 10;
        nav.setPrice(crashed);
        feed.setAnswer(0.9e8);
        vm.expectRevert(NavOracleBase.LoanTokenOffPeg.selector);
        oracle.price();

        vm.expectEmit(true, true, true, true, address(oracle));
        emit NavOracleBase.ReferencePriceSet(crashed, uint40(block.timestamp), true);
        vm.expectEmit(true, true, true, true, address(oracle));
        emit NavOracleBase.CheckpointSet(crashed, uint40(block.timestamp));
        vm.prank(configurator);
        oracle.acceptCurrentPrice(crashed, crashed);

        assertEq(oracle.referencePrice(), crashed, "reference");
        assertEq(oracle.checkpointPrice(), crashed, "checkpoint");
        assertEq(oracle.referencePriceSetAt(), block.timestamp, "referencePriceSetAt");
        assertEq(oracle.checkpointAt(), block.timestamp, "checkpointAt");
        feed.setAnswer(1e8);
        assertEq(oracle.price(), crashed, "price lands on the source");
    }

    function testRevert_acceptCurrentPrice_sourceFails() public {
        nav.setPrice(0);
        vm.expectRevert(NavOracleBase.SourceReturnedZero.selector);
        vm.prank(configurator);
        oracle.acceptCurrentPrice(0, type(uint256).max);
    }

    // ---
    // SETTERS AND THE VALIDATOR
    // ---

    function testRevert_setters_requireConfigRole() public {
        bytes32 role = oracle.CONFIG_ROLE();
        bytes memory err = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role);
        vm.startPrank(admin);
        vm.expectRevert(err);
        oracle.setGrowthLimit(0.04e18, 0.002e18);
        vm.expectRevert(err);
        oracle.setFallLimit(0.0025e18, 1 days);
        vm.expectRevert(err);
        oracle.setRevertBand(0.01e18, 0.03e18, 90 days);
        vm.expectRevert(err);
        oracle.setMarketLimits(0.9e18, 0);
        vm.expectRevert(err);
        oracle.setLoanTokenPegCheck(0.01e18);
        vm.expectRevert(err);
        oracle.releaseGrowthTolerance(0.002e18);
        vm.stopPrank();
    }

    /// @dev Every setter stores its fields, leaves the others alone and emits the whole new set.
    function test_setters_storeParams() public {
        NavOracleCheckParams memory expected = _defaults();
        vm.startPrank(configurator);

        expected.yearlyGrowthRate = 0.04e18;
        expected.growthTolerance = 0.001e18;
        vm.expectEmit(true, true, true, true, address(oracle));
        emit NavOracleBase.CheckParamsSet(expected);
        oracle.setGrowthLimit(0.04e18, 0.001e18);
        _assertParams(oracle.checkParams(), expected);

        expected.maxFallPerInterval = 0.003e18;
        expected.fallInterval = 12 hours;
        oracle.setFallLimit(0.003e18, 12 hours);
        _assertParams(oracle.checkParams(), expected);

        expected.maxDrawdown = 0.009e18;
        expected.maxOvershoot = 0.02e18;
        expected.referenceInterval = 30 days;
        oracle.setRevertBand(0.009e18, 0.02e18, 30 days);
        _assertParams(oracle.checkParams(), expected);

        expected.minPriceRatio = 0.98e18;
        expected.maxBorrowRate = 1e9;
        oracle.setMarketLimits(0.98e18, 1e9);
        _assertParams(oracle.checkParams(), expected);

        expected.maxLoanTokenDeviation = 0.02e18;
        oracle.setLoanTokenPegCheck(0.02e18);
        _assertParams(oracle.checkParams(), expected);
        vm.stopPrank();
    }

    /// @dev I4: a new rate moves the reference to the current expected price at the current time, so the expected
    ///      price, the band and the price stay where they were and only the slope changes. An unchanged rate moves
    ///      nothing.
    function testFuzz_setGrowthLimit_keepsExpectedPrice(uint256 elapsed, uint256 newRate, uint256 source) public {
        elapsed = bound(elapsed, 1, 89 days);
        newRate = bound(newRate, 0, 0.2e18);
        vm.warp(START + elapsed);
        NavOracleState memory s = _read();
        nav.setPrice(bound(source, s.bandLow(block.timestamp), s.bandHigh(block.timestamp)));
        uint256 expected = s.expectedPrice(block.timestamp);
        uint256 before = oracle.price();

        vm.prank(configurator);
        oracle.setGrowthLimit(newRate, 0.002e18);

        if (newRate == s.params.yearlyGrowthRate) {
            assertEq(oracle.referencePriceSetAt(), START, "unchanged rate moves nothing");
        } else {
            assertEq(oracle.referencePrice(), expected, "reference is the old expected price");
            assertEq(oracle.referencePriceSetAt(), block.timestamp, "reference time is now");
        }
        assertEq(_read().expectedPrice(block.timestamp), expected, "expected price kept");
        assertEq(oracle.price(), before, "price kept");
        assertEq(oracle.checkpointPrice(), INITIAL_NAV, "checkpoint untouched");
    }

    /// @dev A changed tolerance moves the upper bound at once, so a clamped price follows it either way. The
    ///      protected tolerance rises with a higher tolerance and stays when it is lowered.
    function test_setGrowthLimit_toleranceMovesClampedPrice() public {
        vm.prank(configurator);
        oracle.setMarketLimits(0.98e18, NavOracleModel.MAX_BORROW_RATE);
        vm.warp(START + 30 days);
        NavOracleState memory s = _read();
        nav.setPrice(s.bandHigh(block.timestamp));
        uint256 expected = s.expectedPrice(block.timestamp);
        assertEq(oracle.price(), expected * (WAD + 0.002e18) / WAD, "clamped at 0.2%");

        vm.prank(configurator);
        oracle.setGrowthLimit(s.params.yearlyGrowthRate, 0.001e18);
        assertEq(oracle.price(), expected * (WAD + 0.001e18) / WAD, "lowered with the bound");
        assertEq(oracle.protectedGrowthTolerance(), 0.002e18, "protected tolerance stays");

        vm.expectEmit(true, true, true, true, address(oracle));
        emit NavOracleBase.ProtectedGrowthToleranceSet(0.003e18);
        vm.prank(configurator);
        oracle.setGrowthLimit(s.params.yearlyGrowthRate, 0.003e18);
        assertEq(oracle.price(), expected * (WAD + 0.003e18) / WAD, "raised with the bound");
        assertEq(oracle.protectedGrowthTolerance(), 0.003e18, "protected tolerance rises");
    }

    /// @dev I4: a new step or interval moves the checkpoint to the current floor at the current time, so the floor
    ///      and the price stay where they were and the next step lands one new interval later.
    function testFuzz_setFallLimit_keepsFloor(uint256 elapsed, uint256 newStep, uint40 newInterval, uint256 source)
        public
    {
        NavOracleCheckParams memory params = _wideBand();
        oracle = _deploy(params);
        elapsed = bound(elapsed, 1, 40 days);
        newStep = bound(newStep, 0.001e18, 0.05e18);
        newInterval = uint40(bound(newInterval, 1 hours, 2 days));
        vm.warp(START + elapsed);
        NavOracleState memory s = _read();
        uint256 floor_ = s.floor(block.timestamp);
        nav.setPrice(bound(source, s.bandLow(block.timestamp), s.bandHigh(block.timestamp)));
        uint256 before = oracle.price();
        params.maxFallPerInterval = newStep;
        params.fallInterval = newInterval;
        if (params.referenceInterval < NavOracleModel.leastReferenceInterval(params)) return;

        vm.prank(configurator);
        oracle.setFallLimit(newStep, newInterval);

        if (newStep == s.params.maxFallPerInterval && newInterval == s.params.fallInterval) {
            assertEq(oracle.checkpointAt(), START, "unchanged limit moves nothing");
        } else {
            assertEq(oracle.checkpointPrice(), floor_, "checkpoint is the old floor");
            assertEq(oracle.checkpointAt(), block.timestamp, "checkpoint time is now");
            vm.warp(block.timestamp + newInterval - 1);
            assertEq(_read().floor(block.timestamp), floor_, "no step before one new interval");
            vm.warp(block.timestamp + 1);
            assertEq(_read().floor(block.timestamp), floor_ * (WAD - newStep) / WAD, "one new step");
            vm.warp(block.timestamp - newInterval);
        }
        assertEq(_read().floor(block.timestamp), floor_, "floor kept");
        assertEq(oracle.price(), before, "price kept");
    }

    function test_validator_fallLimit() public {
        vm.startPrank(configurator);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidFallLimit.selector, 0.0025e18, 0));
        oracle.setFallLimit(0.0025e18, 0);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidFallLimit.selector, 0, 1 days));
        oracle.setFallLimit(0, 1 days);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidFallLimit.selector, WAD, 1 days));
        oracle.setFallLimit(WAD, 1 days);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidFallLimit.selector, WAD + 1, 1 days));
        oracle.setFallLimit(WAD + 1, 1 days);
        oracle.setFallLimit(WAD - 1, 1 days);
        vm.stopPrank();
    }

    function test_validator_revertBand() public {
        vm.startPrank(configurator);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidRevertBand.selector, WAD, 0.03e18, 0.002e18));
        oracle.setRevertBand(WAD, 0.03e18, 90 days);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidRevertBand.selector, 0.01e18, 0.002e18, 0.002e18));
        oracle.setRevertBand(0.01e18, 0.002e18, 90 days);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidRevertBand.selector, 0.01e18, 0.001e18, 0.002e18));
        oracle.setRevertBand(0.01e18, 0.001e18, 90 days);
        oracle.setRevertBand(0.008e18, 0.002e18 + 1, 90 days);
        vm.stopPrank();
    }

    /// @dev The least reference interval is the corridor crossing in whole steps, and one fall interval when the
    ///      corridor is empty.
    function test_validator_referenceInterval() public {
        vm.startPrank(configurator);
        oracle.setMarketLimits(0.9e18, NavOracleModel.MAX_BORROW_RATE);
        // ceil((1% + 0.2%) / 0.25%) = 5 steps of one day.
        oracle.setRevertBand(0.01e18, 0.03e18, 5 days);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.ReferenceIntervalTooShort.selector, 5 days - 1, 5 days));
        oracle.setRevertBand(0.01e18, 0.03e18, 5 days - 1);
        // Exactly 4.8 steps of 0.25% round up to 5, exactly 5 steps stay at 5.
        oracle.setRevertBand(0.0105e18, 0.03e18, 5 days);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.ReferenceIntervalTooShort.selector, 5 days, 6 days));
        oracle.setRevertBand(0.0105e18 + 1, 0.03e18, 5 days);
        oracle.setGrowthLimit(0.0375e18, 0);
        oracle.setRevertBand(0, 0.03e18, 1 days);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.ReferenceIntervalTooShort.selector, 1 days - 1, 1 days));
        oracle.setRevertBand(0, 0.03e18, 1 days - 1);
        vm.stopPrank();
    }

    function test_validator_pegAndRatio() public {
        vm.startPrank(configurator);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidLoanTokenDeviation.selector, WAD));
        oracle.setLoanTokenPegCheck(WAD);
        oracle.setLoanTokenPegCheck(WAD - 1);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.InvalidMinPriceRatio.selector, 0));
        oracle.setMarketLimits(0, NavOracleModel.MAX_BORROW_RATE);

        // The largest minimum the corridor answers for once grown by the interest held over one crossing.
        NavOracleCheckParams memory p = oracle.checkParams();
        uint256 ratio = NavOracleModel.corridorRatio(p.maxDrawdown, p.growthTolerance, p.growthTolerance);
        p.minPriceRatio = ratio * WAD / (WAD + NavOracleModel.heldInterest(p));
        oracle.setMarketLimits(p.minPriceRatio, p.maxBorrowRate);
        p.minPriceRatio += 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.PriceRatioBelowMinimum.selector, ratio, NavOracleModel.leastPriceRatio(p)
            )
        );
        oracle.setMarketLimits(p.minPriceRatio, p.maxBorrowRate);
        vm.stopPrank();
    }

    /// @dev The minimum ratio grows by the interest debt accrues at `maxBorrowRate` over one corridor crossing. A 1%
    ///      drawdown that the bare ratio admits is refused at 16% a year, and a slower floor, which lengthens the
    ///      crossing from four days to five, is refused at the default drawdown.
    function test_validator_heldInterest() public {
        NavOracleCheckParams memory p = oracle.checkParams();
        uint256 wideRatio = NavOracleModel.corridorRatio(0.01e18, 0.002e18, 0.002e18);
        assertGe(wideRatio, p.minPriceRatio, "the bare ratio admits a 1% drawdown");
        p.maxDrawdown = 0.01e18;
        assertEq(NavOracleModel.corridorCrossing(p), 5 days, "five steps to cross 1.2%");

        vm.startPrank(configurator);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.PriceRatioBelowMinimum.selector, wideRatio, NavOracleModel.leastPriceRatio(p)
            )
        );
        oracle.setRevertBand(0.01e18, 0.03e18, 90 days);
        oracle.setMarketLimits(p.minPriceRatio, 0);
        oracle.setRevertBand(0.01e18, 0.03e18, 90 days);
        oracle.setRevertBand(0.008e18, 0.03e18, 90 days);
        oracle.setMarketLimits(p.minPriceRatio, NavOracleModel.MAX_BORROW_RATE);

        NavOracleCheckParams memory slower = oracle.checkParams();
        assertEq(NavOracleModel.corridorCrossing(slower), 4 days, "four steps to cross 1.0%");
        slower.maxFallPerInterval = 0.002e18;
        vm.expectRevert(
            abi.encodeWithSelector(
                NavOracleBase.PriceRatioBelowMinimum.selector,
                NavOracleModel.corridorRatio(0.008e18, 0.002e18, 0.002e18),
                NavOracleModel.leastPriceRatio(slower)
            )
        );
        oracle.setFallLimit(0.002e18, 1 days);
        vm.stopPrank();
    }

    /// @dev A tolerance of one or more leaves no corridor, which the ratio check refuses.
    function test_validator_toleranceAtOneRefused() public {
        vm.startPrank(configurator);
        oracle.setMarketLimits(1, 0);
        oracle.setRevertBand(0.01e18, 2e18, 3000 days);
        vm.expectRevert(abi.encodeWithSelector(NavOracleBase.PriceRatioBelowMinimum.selector, 0, 1));
        oracle.setGrowthLimit(0.0375e18, WAD);
        vm.expectRevert(stdError.arithmeticError);
        oracle.setGrowthLimit(0.0375e18, WAD + 1);
        vm.stopPrank();
    }

    /// @dev I5: the validator accepts a drawdown, tolerance and borrow rate exactly when the corridor ratio against
    ///      the protected tolerance reaches the minimum grown by the interest held over one crossing.
    function testFuzz_corridorRatio_matchesValidator(
        uint256 raised,
        uint256 lowered,
        uint256 drawdown,
        uint256 ratio,
        uint256 rate
    ) public {
        raised = bound(raised, 0, 0.02e18);
        lowered = bound(lowered, 0, raised);
        drawdown = bound(drawdown, 0, 0.05e18);
        ratio = bound(ratio, 0.9e18, WAD);
        rate = bound(rate, 0, 2e10);
        vm.startPrank(configurator);
        oracle.setMarketLimits(0.5e18, 0);
        oracle.setRevertBand(0.01e18, 0.05e18, 365 days);
        oracle.setGrowthLimit(0.0375e18, raised);
        oracle.setGrowthLimit(0.0375e18, lowered);
        uint256 protected_ = Math.max(raised, 0.002e18);
        assertEq(oracle.protectedGrowthTolerance(), protected_, "protected tolerance is the highest set");
        oracle.setRevertBand(drawdown, 0.05e18, 365 days);

        NavOracleCheckParams memory p = oracle.checkParams();
        p.minPriceRatio = ratio;
        p.maxBorrowRate = rate;
        uint256 modelRatio = NavOracleModel.corridorRatio(drawdown, lowered, protected_);
        uint256 least = NavOracleModel.leastPriceRatio(p);
        if (modelRatio >= least) {
            oracle.setMarketLimits(ratio, rate);
            assertEq(oracle.checkParams().minPriceRatio, ratio, "accepted ratio");
            assertEq(oracle.checkParams().maxBorrowRate, rate, "accepted rate");
        } else {
            vm.expectRevert(abi.encodeWithSelector(NavOracleBase.PriceRatioBelowMinimum.selector, modelRatio, least));
            oracle.setMarketLimits(ratio, rate);
        }
        vm.stopPrank();
    }

    function test_releaseGrowthTolerance_bounds() public {
        vm.startPrank(configurator);
        oracle.setMarketLimits(0.97e18, NavOracleModel.MAX_BORROW_RATE);
        oracle.setGrowthLimit(0.0375e18, 0.004e18);
        oracle.setGrowthLimit(0.0375e18, 0.001e18);
        vm.expectRevert(
            abi.encodeWithSelector(NavOracleBase.InvalidReleasedTolerance.selector, 0.001e18 - 1, 0.001e18, 0.004e18)
        );
        oracle.releaseGrowthTolerance(0.001e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(NavOracleBase.InvalidReleasedTolerance.selector, 0.004e18 + 1, 0.001e18, 0.004e18)
        );
        oracle.releaseGrowthTolerance(0.004e18 + 1);
        oracle.releaseGrowthTolerance(0.004e18);
        assertEq(oracle.protectedGrowthTolerance(), 0.004e18, "upper edge");
        vm.expectEmit(true, true, true, true, address(oracle));
        emit NavOracleBase.ProtectedGrowthToleranceSet(0.001e18);
        oracle.releaseGrowthTolerance(0.001e18);
        assertEq(oracle.protectedGrowthTolerance(), 0.001e18, "lower edge");
        vm.stopPrank();
    }

    // ---
    // STORAGE
    // ---

    /// @dev Every adapter keeps its state in the same namespace, so the proxy can move from one adapter to another and
    ///      the new adapter prices from the stored reference, checkpoint, tolerance and parameters the old one wrote.
    function test_storage_sharedAcrossAdapters() public {
        vm.prank(configurator);
        oracle.setGrowthLimit(0.04e18, 0.001e18);
        vm.warp(START + 10 days);
        // A source on a whole 1e-8, so the 8-decimal feed below answers the same value.
        uint256 source = (_read().expectedPrice(block.timestamp) / 1e10 - 1) * 1e10;
        nav.setPrice(source);
        oracle.checkpoint();
        NavOracleState memory before = _read();

        // An 8-decimal NAV feed answering the same value: `ChainlinkNavOracle` scales it by 1e10.
        MockUsdFeed navFeed = new MockUsdFeed();
        navFeed.setAnswer(int256(source / 1e10));
        ChainlinkNavOracle next =
            new ChainlinkNavOracle(address(navFeed), address(loan), address(collateral), address(feed));
        vm.prank(admin);
        OssifiableProxy(payable(address(oracle))).proxy__upgradeTo(address(next));

        NavOracleState memory after_ = _read();
        assertEq(keccak256(abi.encode(after_)), keccak256(abi.encode(before)), "stored state survives the switch");
        assertTrue(oracle.hasRole(oracle.CONFIG_ROLE(), configurator), "roles survive the switch");
        assertEq(address(ChainlinkNavOracle(address(oracle)).SOURCE()), address(navFeed), "the new adapter reads");
        assertEq(oracle.price(), after_.boundedPrice(source, block.timestamp), "the rule over the old state");
    }

    // ---
    // HELPERS
    // ---

    function _defaults() internal pure returns (NavOracleCheckParams memory) {
        return NavOracleModel.workingDefaults(0.0375e18);
    }

    /// @dev A wide band and a small minimum ratio, so the floor can fall many steps before it meets the band.
    function _wideBand() internal pure returns (NavOracleCheckParams memory params) {
        params = _defaults();
        params.maxDrawdown = 0.5e18;
        params.maxOvershoot = 0.5e18;
        params.minPriceRatio = 0.1e18;
        params.referenceInterval = 365 days;
    }

    function _deploy(NavOracleCheckParams memory params) internal returns (UsdyOracle) {
        UsdyOracle impl = new UsdyOracle(address(nav), address(loan), address(collateral), address(feed));
        bytes memory init = abi.encodeCall(NavOracleBase.initialize, (admin, params));
        UsdyOracle deployed = UsdyOracle(address(new OssifiableProxy(address(impl), admin, init)));
        if (address(oracle) != address(0)) {
            bytes32 role = deployed.CONFIG_ROLE();
            vm.prank(admin);
            deployed.grantRole(role, configurator);
        }
        return deployed;
    }

    function _read() internal view returns (NavOracleState memory) {
        return NavOracleModel.read(oracle);
    }

    /// @dev A source between 2% under and 4% over the current expected price: both band edges are reachable.
    function _sourceAround(uint256 seed) internal view returns (uint256) {
        uint256 expected = _read().expectedPrice(block.timestamp);
        return bound(seed, expected * 0.98e18 / WAD, expected * 1.04e18 / WAD);
    }

    function _checkpointIfAllowed() internal {
        NavOracleState memory s = _read();
        uint256 source = nav.navPrice();
        if (block.timestamp - s.checkpointAt < s.params.fallInterval) return;
        if (!s.inBand(source, block.timestamp) || source < s.floor(block.timestamp)) return;
        oracle.checkpoint();
    }

    function _assertPriceMatchesRule() internal {
        NavOracleState memory s = _read();
        uint256 source = nav.navPrice();
        if (!s.inBand(source, block.timestamp)) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    NavOracleBase.PriceOutOfBounds.selector,
                    source,
                    s.bandLow(block.timestamp),
                    s.bandHigh(block.timestamp)
                )
            );
            oracle.price();
            return;
        }
        assertEq(oracle.price(), s.boundedPrice(source, block.timestamp), "price != min(bound, max(source, floor))");
    }

    function _assertParams(NavOracleCheckParams memory actual, NavOracleCheckParams memory expected) internal pure {
        assertEq(actual.yearlyGrowthRate, expected.yearlyGrowthRate, "yearlyGrowthRate");
        assertEq(actual.growthTolerance, expected.growthTolerance, "growthTolerance");
        assertEq(actual.maxFallPerInterval, expected.maxFallPerInterval, "maxFallPerInterval");
        assertEq(actual.maxDrawdown, expected.maxDrawdown, "maxDrawdown");
        assertEq(actual.maxOvershoot, expected.maxOvershoot, "maxOvershoot");
        assertEq(actual.maxLoanTokenDeviation, expected.maxLoanTokenDeviation, "maxLoanTokenDeviation");
        assertEq(actual.minPriceRatio, expected.minPriceRatio, "minPriceRatio");
        assertEq(actual.maxBorrowRate, expected.maxBorrowRate, "maxBorrowRate");
        assertEq(actual.fallInterval, expected.fallInterval, "fallInterval");
        assertEq(actual.referenceInterval, expected.referenceInterval, "referenceInterval");
    }
}
