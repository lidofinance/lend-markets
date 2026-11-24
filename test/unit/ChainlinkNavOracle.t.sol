// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {ChainlinkNavOracle} from "../../src/oracle/ChainlinkNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {MockChainlinkFeed} from "../setup/NavSourceMocks.sol";

/// @notice `ChainlinkNavOracle` reads a feed's `answer`, scaled from the feed's decimals to 18, as its current price,
///         and refuses a value written after the block or more than `MAX_PRICE_AGE` ago, and a negative one. The
///         anchor rules run through this adapter in `TrailingAnchorOracleBase.t.sol`.
contract ChainlinkNavOracleTest is Test {
    /// @dev Chainlink's "JTRSY NAV" answer on 2026-11-24, with 6 decimals.
    int256 internal constant JTRSY_ANSWER = 1_123_254;
    /// @dev Above the 27-hour heartbeat of Chainlink's NAV feeds.
    uint256 internal constant MAX_PRICE_AGE = 2 days;

    MockChainlinkFeed internal feed;
    MockERC20 internal usdc;
    MockERC20 internal jtrsy;

    function setUp() public {
        vm.warp(1_760_000_000);
        feed = new MockChainlinkFeed(6);
        feed.setRawAnswer(JTRSY_ANSWER);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        jtrsy = new MockERC20("JTRSY", "JTRSY", 6);
    }

    /// @dev The mock returns constant round fields, the stamp as `updatedAt`, and `currentPrice` at the feed's
    ///      decimals, rounded down.
    function test_feedMock_returnsTheRoundTuple() public {
        feed.setCurrentPrice(1.1232549e18);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 1, "roundId");
        assertEq(answer, JTRSY_ANSWER, "answer at 6 decimals, rounded down");
        assertEq(startedAt, 0, "startedAt");
        assertEq(updatedAt, block.timestamp, "updatedAt");
        assertEq(answeredInRound, 1, "answeredInRound");
    }

    function testRevert_constructor_zeroAddresses() public {
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new ChainlinkNavOracle(address(0), MAX_PRICE_AGE, address(usdc), address(jtrsy));
        vm.expectRevert(TrailingAnchorOracleBase.ZeroAddress.selector);
        new ChainlinkNavOracle(address(feed), MAX_PRICE_AGE, address(usdc), address(0));
    }

    function testRevert_constructor_zeroMaxPriceAge() public {
        vm.expectRevert(ChainlinkNavOracle.MaxPriceAgeIsZero.selector);
        new ChainlinkNavOracle(address(feed), 0, address(usdc), address(jtrsy));
    }

    /// @dev A feed with 18 decimals is taken as it is; one with 19 is refused, since its answer would need rounding.
    function testRevert_constructor_feedDecimalsAbove18() public {
        ChainlinkNavOracle impl =
            new ChainlinkNavOracle(address(new MockChainlinkFeed(18)), MAX_PRICE_AGE, address(usdc), address(jtrsy));
        assertEq(impl.ANSWER_SCALE(), 1, "18 decimals");
        MockChainlinkFeed nineteen = new MockChainlinkFeed(19);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.UnsupportedFeedDecimals.selector, uint8(19)));
        new ChainlinkNavOracle(address(nineteen), MAX_PRICE_AGE, address(usdc), address(jtrsy));
    }

    /// @dev The adapter keeps `maxPriceAge` in its own getter.
    function test_constructor_maxPriceAge() public {
        ChainlinkNavOracle impl = new ChainlinkNavOracle(address(feed), 3 days, address(usdc), address(jtrsy));
        assertEq(impl.MAX_PRICE_AGE(), 3 days, "MAX_PRICE_AGE");
    }

    /// @dev Chainlink's 6-decimal NAV for a 6-decimal share in a 6-decimal market: the answer scales by 1e12 to 18
    ///      decimals, and the oracle's price by 1e18 more.
    function test_price_sixDecimalFeed() public {
        ChainlinkNavOracle oracle = _deploy(feed, 6);
        assertEq(address(oracle.FEED()), address(feed), "FEED");
        assertEq(oracle.MAX_PRICE_AGE(), MAX_PRICE_AGE, "MAX_PRICE_AGE");
        assertEq(oracle.ANSWER_SCALE(), 1e12, "ANSWER_SCALE");
        assertEq(oracle.PRICE_SCALE(), 1e18, "PRICE_SCALE");
        assertEq(oracle.anchorPrice(), 1.123254e18, "anchor is the answer at 18 decimals");
        assertEq(oracle.price(), 1.123254e18 * 1e18, "price");
    }

    /// @dev An 18-decimal feed for an 18-decimal share in a 6-decimal market: the answer is the price as it is, and
    ///      the oracle's price scales by 1e6.
    function test_price_eighteenDecimalFeed() public {
        MockChainlinkFeed eighteen = new MockChainlinkFeed(18);
        eighteen.setCurrentPrice(1.043466e18);
        ChainlinkNavOracle oracle = _deploy(eighteen, 18);
        assertEq(oracle.ANSWER_SCALE(), 1, "ANSWER_SCALE");
        assertEq(oracle.PRICE_SCALE(), 1e6, "PRICE_SCALE");
        assertEq(oracle.anchorPrice(), 1.043466e18, "anchor is the answer");
        assertEq(oracle.price(), 1.043466e18 * 1e6, "price");
    }

    /// @dev Any feed decimals up to 18 and any answer whose price the oracle can store: the current price is the answer
    ///      times `10^(18 − feedDecimals)`, exactly.
    function testFuzz_price_scalesFromFeedDecimals(uint8 feedDecimals, uint256 answer) public {
        feedDecimals = uint8(bound(feedDecimals, 0, 18));
        uint256 answerScale = 10 ** (18 - feedDecimals);
        answer = bound(answer, 1, type(uint104).max / answerScale);
        MockChainlinkFeed fuzzed = new MockChainlinkFeed(feedDecimals);
        fuzzed.setRawAnswer(int256(answer));
        ChainlinkNavOracle oracle = _deploy(fuzzed, 6);
        assertEq(oracle.ANSWER_SCALE(), answerScale, "ANSWER_SCALE");
        assertEq(oracle.anchorPrice(), answer * answerScale, "current price");
        assertEq(oracle.price(), answer * answerScale * oracle.PRICE_SCALE(), "price");
    }

    /// @dev A value exactly `MAX_PRICE_AGE` old is returned; one second older is refused, by `price()` and by
    ///      `updateAnchor()`, with the time the feed wrote it.
    function test_price_maxPriceAgeEdge() public {
        ChainlinkNavOracle oracle = _deploy(feed, 6);
        feed.setPriceAge(MAX_PRICE_AGE);
        assertEq(oracle.price(), 1.123254e18 * 1e18, "a value on the edge");
        feed.setPriceAge(MAX_PRICE_AGE + 1);
        uint256 updatedAt = block.timestamp - MAX_PRICE_AGE - 1;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.StalePrice.selector, updatedAt));
        oracle.price();
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.StalePrice.selector, updatedAt));
        oracle.updateAnchor();
    }

    /// @dev A value written at the block time is returned; one stamped a second later is refused, by `price()` and by
    ///      `updateAnchor()`. The stamp is the feed's `uint256` as it is, so one past `uint64` is refused by name too.
    function testRevert_price_stampAfterTheBlock() public {
        ChainlinkNavOracle oracle = _deploy(feed, 6);
        assertEq(oracle.price(), 1.123254e18 * 1e18, "a value written at the block time");
        feed.setPriceAhead(1);
        uint256 updatedAt = block.timestamp + 1;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.PriceFromFuture.selector, updatedAt));
        oracle.price();
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.PriceFromFuture.selector, updatedAt));
        oracle.updateAnchor();
        uint256 beyond = uint256(type(uint64).max) + 1;
        feed.setPriceAhead(beyond - block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.PriceFromFuture.selector, beyond));
        oracle.price();
    }

    /// @dev A negative answer is refused by name; a zero one by the base's `ZeroPrice`. The stamp is checked first,
    ///      so a stale negative answer is refused as stale.
    function testRevert_price_negativeOrZeroAnswer() public {
        ChainlinkNavOracle oracle = _deploy(feed, 6);
        feed.setRawAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.NegativePrice.selector, int256(-1)));
        oracle.price();
        vm.expectRevert(abi.encodeWithSelector(ChainlinkNavOracle.NegativePrice.selector, int256(-1)));
        oracle.updateAnchor();
        feed.setPriceAge(MAX_PRICE_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ChainlinkNavOracle.StalePrice.selector, block.timestamp - MAX_PRICE_AGE - 1)
        );
        oracle.price();
        feed.setPriceAge(0);
        feed.setRawAnswer(0);
        vm.expectRevert(TrailingAnchorOracleBase.ZeroPrice.selector);
        oracle.price();
    }

    /// @dev A stale value is no seed and no accepted price: `initialize` and `acceptPrice()` refuse it as `price()`
    ///      does.
    function testRevert_seedAndAcceptance_stalePrice() public {
        ChainlinkNavOracle oracle = _deploy(feed, 6);
        bytes32 acceptorRole = oracle.PRICE_ACCEPTOR_ROLE();
        oracle.grantRole(acceptorRole, address(this));
        feed.setPriceAge(MAX_PRICE_AGE + 1);
        bytes memory stale =
            abi.encodeWithSelector(ChainlinkNavOracle.StalePrice.selector, block.timestamp - MAX_PRICE_AGE - 1);
        vm.expectRevert(stale);
        oracle.acceptPrice(0, type(uint256).max);

        address impl = OssifiableProxy(payable(address(oracle))).proxy__getImplementation();
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this));
        vm.expectRevert(stale);
        new OssifiableProxy(impl, address(this), init);
    }

    /// @dev The shared model encodes the stamp refusals of both stamped adapters with `CentrifugeNavOracle`'s
    ///      selectors, so the two adapters' stamp errors keep one signature.
    function test_stampErrors_matchCentrifugeNavOracle() public pure {
        assertEq(ChainlinkNavOracle.StalePrice.selector, CentrifugeNavOracle.StalePrice.selector, "StalePrice");
        assertEq(
            ChainlinkNavOracle.PriceFromFuture.selector, CentrifugeNavOracle.PriceFromFuture.selector, "PriceFromFuture"
        );
    }

    function _deploy(MockChainlinkFeed source, uint8 collateralDecimals) internal returns (ChainlinkNavOracle) {
        MockERC20 collateral = new MockERC20("Share", "SHARE", collateralDecimals);
        ChainlinkNavOracle impl =
            new ChainlinkNavOracle(address(source), MAX_PRICE_AGE, address(usdc), address(collateral));
        bytes memory init = TrailingAnchorOracleModel.initializeCall(address(this));
        return ChainlinkNavOracle(address(new OssifiableProxy(address(impl), address(this), init)));
    }
}
