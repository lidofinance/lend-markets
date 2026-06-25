// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";

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
}

/// @notice Unit/fuzz for `UsdyStableOracle`: price = mulDiv(USDY/USD price,
///         SCALE, stable/USD price) with SCALE = 1e14 = 10^(36+6+8-18-18) for an 18-dec USDY collateral /
///         6-dec stablecoin loan market (Morpho scale 36+6-18 = 24). Recomputed independently. Includes
///         documenting tests for the missing Chainlink staleness / non-positive-answer guards.
contract UsdyStableOracleTest is Test {
    uint256 internal constant SCALE = 1e14;

    MockRWAOracle internal usdy;
    MockChainlinkFeed internal feed;
    UsdyStableOracle internal oracle;

    function setUp() public {
        usdy = new MockRWAOracle();
        feed = new MockChainlinkFeed();
        oracle = new UsdyStableOracle(address(usdy), address(feed));
    }

    function _expected(uint256 getPrice, int256 answer) internal pure returns (uint256) {
        return getPrice * SCALE / uint256(answer); // in-domain, equals mulDiv
    }

    function test_price_recompute() public {
        usdy.setPrice(1.08e18); // USDY ≈ $1.08
        feed.setAnswer(1e8); // stablecoin ≈ $1.00
        // price = 1.08e18 * 1e14 / 1e8 = 1.08e24 (Morpho scale 24 for 18-dec collateral / 6-dec loan).
        assertEq(oracle.price(), _expected(1.08e18, 1e8), "mulDiv recompute");
        assertEq(oracle.price(), 1.08e24, "explicit value");
    }

    function test_price_stablecoinDepeg_raisesCollateralPrice() public {
        usdy.setPrice(1.08e18);
        feed.setAnswer(0.98e8); // stablecoin de-pegs below $1 -> USDY worth more stablecoin units
        // Exact recompute; the depeg (feed < 1e8) makes this strictly larger than the $1.00 peg value 1.08e24.
        assertEq(oracle.price(), _expected(1.08e18, 0.98e8), "exact recompute under depeg");
    }

    function testRevert_constructor_zeroUsdyOracle() public {
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new UsdyStableOracle(address(0), address(feed));
    }

    function testRevert_constructor_zeroStableFeed() public {
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new UsdyStableOracle(address(usdy), address(0));
    }

    function testFuzz_price_recompute(uint256 getPrice, int256 answer) public {
        getPrice = bound(getPrice, 0.5e18, 5e18);
        answer = int256(bound(uint256(answer), 0.5e8, 2e8)); // positive, realistic stablecoin band
        usdy.setPrice(getPrice);
        feed.setAnswer(answer);
        assertEq(oracle.price(), _expected(getPrice, answer), "price == mulDiv(getPrice, SCALE, answer)");
    }

    function testFuzz_price_noOverflow_tinyFeedLargePrice(uint256 getPrice, int256 answer) public {
        getPrice = bound(getPrice, 1e18, 5e18); // up to ~$5 USDY
        answer = int256(bound(uint256(answer), 1, 1e8)); // down to 1 (8-dec) -> very large price
        usdy.setPrice(getPrice);
        feed.setAnswer(answer);
        // mulDiv has a 512-bit intermediate; getPrice*1e14 ≈ 5e32 ≪ 2^256, so no overflow even at feed=1.
        assertEq(oracle.price(), _expected(getPrice, answer), "no overflow across the input domain");
    }

    // ── documented no-guard behaviour (NatSpec L26-27: intentionally matches Morpho's stock oracle) ──

    /// @dev The adapter ignores `updatedAt`/`answeredInRound` — a stale feed is used as-is. This regression-
    ///      pins the deliberate no-staleness-guard behaviour; any future guard is then an explicit change.
    function test_staleFeed_isUsedAnyway() public {
        usdy.setPrice(1.08e18);
        feed.setUpdatedAt(1); // ancient round
        vm.warp(10_000_000);
        assertEq(oracle.price(), _expected(1.08e18, 1e8), "stale feed price returned without a guard");
    }

    /// @dev FINDING: no `stableUsdPrice <= 0` guard. Zero -> `mulDiv` div-by-zero
    ///      reverts (DoS, fail-closed). The omission is documented as intended, but the zero path bricks
    ///      price() for the whole market — pinned here.
    function testRevert_FINDING_price_zeroAnswer_bricks() public {
        feed.setAnswer(0);
        vm.expectRevert(); // div-by-zero in mulDiv
        oracle.price();
    }

    /// @dev FINDING (the dangerous fail-OPEN branch): a NEGATIVE answer is cast
    ///      `uint256(answer)` to ~2^256, so price() collapses to ~0 — USDY collateral valued at nothing,
    ///      triggering mass/unjust liquidations. A cheap `answer > 0` guard would remove this path; flag.
    function test_FINDING_price_negativeAnswer_collapsesToZero() public {
        usdy.setPrice(1.08e18);
        feed.setAnswer(-1); // uint256(-1) = 2^256-1 -> price ≈ 0
        assertEq(oracle.price(), 0, "FINDING: negative feed answer collapses the collateral price to 0");
    }
}
