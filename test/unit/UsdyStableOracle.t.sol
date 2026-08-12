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
///         feed answer is rejected (`InvalidStablePrice`); the adapter performs no on-chain staleness check.
contract UsdyStableOracleTest is Test {
    uint256 internal constant SCALE = 1e14;

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
        address impl = address(new UsdyStableOracle(usdyOracle));
        bytes memory initData = abi.encodeCall(UsdyStableOracle.initialize, (stableFeed, loanToken));
        return UsdyStableOracle(address(new OssifiableProxy(impl, address(this), initData)));
    }

    function _expected(uint256 getPrice, int256 answer) internal pure returns (uint256) {
        return getPrice * SCALE / uint256(answer); // in-domain, equals mulDiv
    }

    // ── mutations ──

    /// @dev Constructing with a zero USDY oracle address reverts ZeroAddress.
    function testRevert_constructor_zeroUsdyOracle() public {
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new UsdyStableOracle(address(0));
    }

    /// @dev Initializing with a zero stable feed address reverts ZeroAddress.
    function testRevert_initialize_zeroStableFeed() public {
        address impl = address(new UsdyStableOracle(address(usdy)));
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new OssifiableProxy(
            impl, address(this), abi.encodeCall(UsdyStableOracle.initialize, (address(0), address(loan)))
        );
    }

    /// @dev Initializing with a zero loan token address reverts ZeroAddress.
    function testRevert_initialize_zeroLoanToken() public {
        address impl = address(new UsdyStableOracle(address(usdy)));
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
        UsdyStableOracle o = _deploy(address(usdy), address(feed), address(new MockLoanToken18()));
        assertEq(o.scale(), 1e26, "18-dec loan / 8-dec feed -> scale 1e26");

        usdy.setPrice(1.08e18);
        feed.setAnswer(1e8);
        // price = 1.08e18 * 1e26 / 1e8 = 1.08e36
        assertEq(o.price(), uint256(1.08e18) * 1e26 / 1e8, "exact recompute at 18-dec");
        assertEq(o.price(), 1.08e36, "explicit value");
    }

    /// @dev Across realistic nav and feed bands, price equals mulDiv(getPrice, SCALE, answer).
    function testFuzz_price_recompute(uint256 getPrice, int256 answer) public {
        getPrice = bound(getPrice, 0.5e18, 5e18);
        answer = int256(bound(uint256(answer), 0.5e8, 2e8)); // positive, realistic stablecoin band
        usdy.setPrice(getPrice);
        feed.setAnswer(answer);
        assertEq(oracle.price(), _expected(getPrice, answer), "price == mulDiv(getPrice, SCALE, answer)");
    }

    /// @dev Even at a tiny feed answer against a large nav, price matches the recompute with no overflow.
    function testFuzz_price_noOverflow_tinyFeedLargePrice(uint256 getPrice, int256 answer) public {
        getPrice = bound(getPrice, 1e18, 5e18); // up to ~$5 USDY
        answer = int256(bound(uint256(answer), 1, 1e8)); // down to 1 (8-dec) -> very large price
        usdy.setPrice(getPrice);
        feed.setAnswer(answer);
        // mulDiv has a 512-bit intermediate; getPrice*1e14 ≈ 5e32 ≪ 2^256, so no overflow even at feed=1.
        assertEq(oracle.price(), _expected(getPrice, answer), "no overflow across the input domain");
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
}
