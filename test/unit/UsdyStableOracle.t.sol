// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

/// @dev Ondo RWA dynamic oracle stub (USDY/USD, 1e18).
contract MockRWAOracle {
    uint256 public p = 1.08e18;

    function setPrice(uint256 v) external {
        p = v;
    }

    function getPrice() external view returns (uint256) {
        return p;
    }
}

/// @dev Chainlink USD aggregator stub (8 decimals).
contract MockChainlinkFeed {
    int256 public answer = 1e8;
    uint256 public updatedAt = 1;

    function setAnswer(int256 a) external {
        answer = a;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 0, updatedAt, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @dev Loan stablecoin stub: only `decimals()` is read by the oracle to size SCALE (USDC-like, 6 dec).
contract MockLoanToken {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @dev 18-decimal loan stablecoin (e.g. DAI), to exercise the dynamic SCALE at a different decimal config.
contract MockLoanToken18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice Unit/fuzz for `UsdyStableOracle`: price = mulDiv(USDY/USD price,
///         SCALE, stable/USD price) with SCALE = 1e14 = 10^(36+6+8-18-18) for an 18-dec USDY collateral /
///         6-dec stablecoin loan market (Morpho scale 36+6-18 = 24). Recomputed independently. A non-positive
///         feed answer is rejected (`InvalidStablePrice`); a result outside the immutable
///         [`MIN_PRICE`, `MAX_PRICE`] band is rejected (`PriceOutOfBounds`); the adapter performs no on-chain
///         staleness check.
contract UsdyStableOracleTest is Test {
    uint256 internal constant SCALE = 1e14;

    /// @dev Band for the default fixture, in the returned domain (Morpho scale 24): [$0.5, $10] of loan
    ///      token per USDY. Wide enough that every in-band case below returns a price.
    uint256 internal constant MIN_PRICE = 0.5e24;
    uint256 internal constant MAX_PRICE = 10e24;

    MockRWAOracle internal usdy;
    MockChainlinkFeed internal feed;
    MockLoanToken internal loan;
    UsdyStableOracle internal oracle;

    function setUp() public {
        usdy = new MockRWAOracle();
        feed = new MockChainlinkFeed();
        loan = new MockLoanToken();
        // SCALE is derived from decimals in initialize: loan 6 + feed 8 -> 10^(36+6+8-18-18) = 1e14.
        oracle = _deploy(address(usdy), address(feed), address(loan));
    }

    /// @dev Deploy as in production: shared impl (USDY oracle immutable) behind an OssifiableProxy, with the
    ///      per-market stable feed + scale bound via `initialize`.
    function _deploy(address usdyOracle, address stableFeed, address loanToken) internal returns (UsdyStableOracle) {
        return _deploy(usdyOracle, stableFeed, loanToken, MIN_PRICE, MAX_PRICE);
    }

    /// @dev Same, at an explicit price band.
    function _deploy(address usdyOracle, address stableFeed, address loanToken, uint256 minPrice, uint256 maxPrice)
        internal
        returns (UsdyStableOracle)
    {
        address impl = address(new UsdyStableOracle(usdyOracle, minPrice, maxPrice));
        bytes memory initData = abi.encodeCall(UsdyStableOracle.initialize, (stableFeed, loanToken));
        return UsdyStableOracle(address(new OssifiableProxy(impl, address(this), initData)));
    }

    /// @dev An instance whose band accepts everything, for the tests that probe the arithmetic domain rather
    ///      than the guard: `price()` is then the plain quotient at any input the sources can produce.
    function _unbounded() internal returns (UsdyStableOracle) {
        return _deploy(address(usdy), address(feed), address(loan), 1, type(uint256).max);
    }

    function _expected(uint256 getPrice, int256 answer) internal pure returns (uint256) {
        return getPrice * SCALE / uint256(answer); // in-domain, equals mulDiv
    }

    // ── mutations ──

    /// @dev Constructing with a zero USDY oracle address reverts ZeroAddress.
    function testRevert_constructor_zeroUsdyOracle() public {
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new UsdyStableOracle(address(0), MIN_PRICE, MAX_PRICE);
    }

    /// @dev A zero lower bound is rejected: it would admit a fully collapsed price, the fail-open case the
    ///      band exists to close.
    function testRevert_constructor_zeroMinPrice() public {
        vm.expectRevert(abi.encodeWithSelector(UsdyStableOracle.InvalidPriceBounds.selector, 0, MAX_PRICE));
        new UsdyStableOracle(address(usdy), 0, MAX_PRICE);
    }

    /// @dev An upper bound below the lower one is an empty band — every price would revert.
    function testRevert_constructor_invertedBounds() public {
        vm.expectRevert(abi.encodeWithSelector(UsdyStableOracle.InvalidPriceBounds.selector, MAX_PRICE, MAX_PRICE - 1));
        new UsdyStableOracle(address(usdy), MAX_PRICE, MAX_PRICE - 1);
    }

    /// @dev A degenerate but non-empty band (min == max) is accepted, and only that price passes it.
    function test_constructor_equalBoundsAccepted() public {
        UsdyStableOracle o = _deploy(address(usdy), address(feed), address(loan), 1.08e24, 1.08e24);
        assertEq(o.MIN_PRICE(), 1.08e24, "MIN_PRICE");
        assertEq(o.MAX_PRICE(), 1.08e24, "MAX_PRICE");
        assertEq(o.price(), 1.08e24, "the single in-band price");
    }

    /// @dev Initializing with a zero stable feed address reverts ZeroAddress.
    function testRevert_initialize_zeroStableFeed() public {
        address impl = address(new UsdyStableOracle(address(usdy), MIN_PRICE, MAX_PRICE));
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new OssifiableProxy(
            impl, address(this), abi.encodeCall(UsdyStableOracle.initialize, (address(0), address(loan)))
        );
    }

    /// @dev Initializing with a zero loan token address reverts ZeroAddress.
    function testRevert_initialize_zeroLoanToken() public {
        address impl = address(new UsdyStableOracle(address(usdy), MIN_PRICE, MAX_PRICE));
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new OssifiableProxy(
            impl, address(this), abi.encodeCall(UsdyStableOracle.initialize, (address(feed), address(0)))
        );
    }

    // ── views ──

    /// @dev At USDY $1.08 against a $1.00 feed, price equals mulDiv(nav, SCALE, feed) = 1.08e24 at Morpho scale 24.
    function test_price_recompute() public {
        usdy.setPrice(1.08e18); // USDY ≈ $1.08
        feed.setAnswer(1e8); // stablecoin ≈ $1.00
        // price = 1.08e18 * 1e14 / 1e8 = 1.08e24 (Morpho scale 24 for 18-dec collateral / 6-dec loan).
        assertEq(oracle.price(), _expected(1.08e18, 1e8), "mulDiv recompute");
        assertEq(oracle.price(), 1.08e24, "explicit value");
    }

    /// @dev A stablecoin feed below $1 raises the collateral price above its $1.00-peg value, matching the recompute.
    function test_price_stablecoinDepeg_raisesCollateralPrice() public {
        usdy.setPrice(1.08e18);
        feed.setAnswer(0.98e8); // stablecoin de-pegs below $1 -> USDY worth more stablecoin units
        // Exact recompute; the depeg (feed < 1e8) makes this strictly larger than the $1.00 peg value 1.08e24.
        assertEq(oracle.price(), _expected(1.08e18, 0.98e8), "exact recompute under depeg");
    }

    /// @dev SCALE is derived from the loan and feed decimals as 10^(36+6+8-18-18) = 1e14.
    function test_scale_isDerivedFromDecimals() public view {
        assertEq(oracle.scale(), 1e14, "scale = 10^(36+6+8-18-18) from loan/feed decimals");
    }

    /// @dev An 18-decimal stablecoin loan (DAI-like) sizes SCALE differently: 10^(36+18+8-18-18) = 1e26.
    function test_price_eighteenDecimalStable() public {
        // The band lives in the returned domain, which is 1e12 larger here (Morpho scale 36, not 24).
        UsdyStableOracle o = _deploy(address(usdy), address(feed), address(new MockLoanToken18()), 0.5e36, 10e36);
        assertEq(o.scale(), 1e26, "18-dec loan / 8-dec feed -> scale 1e26");

        usdy.setPrice(1.08e18);
        feed.setAnswer(1e8);
        // price = 1.08e18 * 1e26 / 1e8 = 1.08e36
        assertEq(o.price(), uint256(1.08e18) * 1e26 / 1e8, "exact recompute at 18-dec");
        assertEq(o.price(), 1.08e36, "explicit value");
    }

    /// @dev Across realistic nav and feed bands, price equals mulDiv(getPrice, SCALE, answer). Run against an
    ///      all-accepting band so this pins the formula alone; the band itself is covered separately.
    function testFuzz_price_recompute(uint256 getPrice, int256 answer) public {
        UsdyStableOracle o = _unbounded();
        getPrice = bound(getPrice, 0.5e18, 5e18);
        answer = int256(bound(uint256(answer), 0.5e8, 2e8)); // positive, realistic stablecoin band
        usdy.setPrice(getPrice);
        feed.setAnswer(answer);
        assertEq(o.price(), _expected(getPrice, answer), "price == mulDiv(getPrice, SCALE, answer)");
    }

    /// @dev Even at a tiny feed answer against a large nav, price matches the recompute with no overflow —
    ///      again at an all-accepting band, so the arithmetic is what is under test.
    function testFuzz_price_noOverflow_tinyFeedLargePrice(uint256 getPrice, int256 answer) public {
        UsdyStableOracle o = _unbounded();
        getPrice = bound(getPrice, 1e18, 5e18); // up to ~$5 USDY
        answer = int256(bound(uint256(answer), 1, 1e8)); // down to 1 (8-dec) -> very large price
        usdy.setPrice(getPrice);
        feed.setAnswer(answer);
        // mulDiv has a 512-bit intermediate; getPrice*1e14 ≈ 5e32 ≪ 2^256, so no overflow even at feed=1.
        assertEq(o.price(), _expected(getPrice, answer), "no overflow across the input domain");
    }

    // ── documented no-guard behaviour (NatSpec L26-27: intentionally matches Morpho's stock oracle) ──

    /// @dev Current behaviour: `price()` reads only the feed's `answer`, with no on-chain staleness check on
    ///      `updatedAt`/`answeredInRound`, so an old round is used as-is. Adding a staleness bound would be an
    ///      explicit behaviour change; this pins the present contract.
    function test_staleFeed_isUsedAsIs() public {
        usdy.setPrice(1.08e18);
        feed.setUpdatedAt(1); // ancient round
        vm.warp(10_000_000);
        assertEq(oracle.price(), _expected(1.08e18, 1e8), "stale feed answer used without a staleness check");
    }

    /// @dev A zero feed answer is the realistic failure (an un-updated / stale-outage round). The
    ///      `stableUsdPrice <= 0` guard turns what would be a raw `mulDiv` division-by-zero into a clean
    ///      `InvalidStablePrice` revert.
    function testRevert_price_zeroAnswer() public {
        feed.setAnswer(0);
        vm.expectRevert(UsdyStableOracle.InvalidStablePrice.selector);
        oracle.price();
    }

    /// @dev A negative answer is implausible for a USD stablecoin feed but type-permitted (`int256`); without
    ///      a guard the `uint256(answer)` cast would collapse the price toward zero (fail-open). The same
    ///      `<= 0` guard rejects it cleanly — defense-in-depth on the oracle input.
    function testRevert_price_negativeAnswer() public {
        usdy.setPrice(1.08e18);
        feed.setAnswer(-1);
        vm.expectRevert(UsdyStableOracle.InvalidStablePrice.selector);
        oracle.price();
    }

    /// @dev The NAV numerator is guarded symmetrically with the divisor: a zero NAV reverts cleanly rather
    ///      than collapsing the collateral price to zero (the same fail-open class as the feed answer).
    function testRevert_price_zeroNavPrice() public {
        usdy.setPrice(0);
        vm.expectRevert(UsdyStableOracle.InvalidNavPrice.selector);
        oracle.price();
    }

    // ── price band ──

    /// @dev The band is exposed as immutables, so a deployment can be verified against its config.
    function test_priceBounds_areImmutable() public view {
        assertEq(oracle.MIN_PRICE(), MIN_PRICE, "MIN_PRICE");
        assertEq(oracle.MAX_PRICE(), MAX_PRICE, "MAX_PRICE");
    }

    /// @dev Both bounds are inclusive: a price landing exactly on either edge still prices.
    function test_price_boundsAreInclusive() public {
        // price == MIN_PRICE: nav such that nav * SCALE / 1e8 == 0.5e24, i.e. nav == 0.5e18.
        usdy.setPrice(0.5e18);
        assertEq(oracle.price(), MIN_PRICE, "price at the lower edge is accepted");

        // price == MAX_PRICE at nav == 10e18.
        usdy.setPrice(10e18);
        assertEq(oracle.price(), MAX_PRICE, "price at the upper edge is accepted");
    }

    /// @dev One NAV wei below the lower edge reverts with the offending value, so a mis-scaled or collapsing
    ///      NAV source fails closed instead of repricing every position. At a $1.00 feed one NAV wei is 1e6 of
    ///      returned price, so this is the smallest out-of-band price the sources can produce.
    function testRevert_price_belowMinPrice() public {
        uint256 nav = 0.5e18 - 1; // MIN_PRICE is exactly nav 0.5e18
        usdy.setPrice(nav);
        uint256 expected = _expected(nav, 1e8);
        assertLt(expected, MIN_PRICE, "setup is below the band");
        vm.expectRevert(abi.encodeWithSelector(UsdyStableOracle.PriceOutOfBounds.selector, expected));
        oracle.price();
    }

    /// @dev Symmetrically above the band: a NAV blow-up (or a near-zero feed answer) reverts.
    function testRevert_price_aboveMaxPrice() public {
        uint256 nav = 10e18 + 1; // MAX_PRICE is exactly nav 10e18
        usdy.setPrice(nav);
        uint256 expected = _expected(nav, 1e8);
        assertGt(expected, MAX_PRICE, "setup is above the band");
        vm.expectRevert(abi.encodeWithSelector(UsdyStableOracle.PriceOutOfBounds.selector, expected));
        oracle.price();
    }

    /// @dev The stablecoin leg is bounded too: a feed answer small enough to inflate the quotient past
    ///      `MAX_PRICE` reverts, where before the band it would have returned an absurd collateral value.
    function testRevert_price_tinyFeedAnswerBlowsBand() public {
        usdy.setPrice(1.08e18);
        feed.setAnswer(1); // 1e-8 USD -> price = 1.08e18 * 1e14 / 1 = 1.08e32, far above MAX_PRICE
        vm.expectRevert(abi.encodeWithSelector(UsdyStableOracle.PriceOutOfBounds.selector, uint256(1.08e32)));
        oracle.price();
    }

    /// @dev Inside the band the guard is transparent: the returned value is the unaltered quotient.
    function testFuzz_price_inBandIsUnchanged(uint256 getPrice, int256 answer) public {
        getPrice = bound(getPrice, 0.9e18, 1.5e18);
        answer = int256(bound(uint256(answer), 0.9e8, 1.1e8));
        usdy.setPrice(getPrice);
        feed.setAnswer(answer);
        uint256 expected = _expected(getPrice, answer);
        assertGe(expected, MIN_PRICE, "fuzz band setup stays inside MIN_PRICE");
        assertLe(expected, MAX_PRICE, "fuzz band setup stays inside MAX_PRICE");
        assertEq(oracle.price(), expected, "in-band price is the plain quotient");
    }

    /// @dev Outside the band, on either side, `price()` reverts rather than returning a value.
    function testFuzz_price_outOfBandReverts(uint256 getPrice, bool low) public {
        // Below: nav < 0.5e18 -> price < MIN_PRICE. Above: nav > 10e18 -> price > MAX_PRICE. Feed stays $1.
        getPrice = low ? bound(getPrice, 1, 0.5e18 - 1) : bound(getPrice, 10e18 + 1, 1e30);
        usdy.setPrice(getPrice);
        vm.expectRevert(abi.encodeWithSelector(UsdyStableOracle.PriceOutOfBounds.selector, _expected(getPrice, 1e8)));
        oracle.price();
    }
}
