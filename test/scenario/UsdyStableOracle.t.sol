// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";

/// @dev Mock of Ondo's USDY dynamic-rate (NAV) oracle: getPrice() scaled 1e18.
contract MockRwaOracle {
    uint256 public price;

    function set(uint256 newPrice) external {
        price = newPrice;
    }

    function getPrice() external view returns (uint256) {
        return price;
    }
}

/// @dev Mock Chainlink USD aggregator: only `answer` matters here (8-dec USD price).
contract MockChainlinkFeed {
    int256 internal answer;

    function set(int256 newAnswer) external {
        answer = newAnswer;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, answer, 0, 0, 0);
    }
}

/// @notice Coverage for `UsdyStableOracle`: USDY NAV (1e18) quoted in a 6-dec stablecoin via its 8-dec
///         Chainlink USD feed, scaled to Morpho's 1e36 convention. Expected values are re-derived from
///         the convention (collateral 18 dec, loan 6 dec) independently of the contract's SCALE.
contract UsdyStableOracleTest is Test {
    uint256 internal constant USDY_DEC = 1e18; // USDY token + Ondo getPrice() scale
    uint256 internal constant FEED_DEC = 1e8; // Chainlink USD feed scale
    uint256 internal constant LOAN_UNIT = 1e6; // USDC/USDT (6 dec)

    MockRwaOracle internal usdy;
    MockChainlinkFeed internal feed;
    UsdyStableOracle internal oracle;

    function setUp() public {
        usdy = new MockRwaOracle();
        feed = new MockChainlinkFeed();
        // Storage-config oracle: deploy the impl, then run `initialize` through a proxy (the impl
        // disables initializers, so it is only usable behind a proxy).
        oracle = UsdyStableOracle(address(_deployOracle(address(usdy), address(feed))));
    }

    function _deployOracle(address usdyOracle_, address stableFeed_) internal returns (address) {
        address impl = address(new UsdyStableOracle());
        bytes memory initData = abi.encodeWithSignature("initialize(address,address)", usdyOracle_, stableFeed_);
        return address(new OssifiableProxy(impl, address(this), initData));
    }

    /// @dev Independent re-derivation of Morpho's IOracle value: price of 1 collateral (USDY, 18 dec)
    ///      quoted in the loan (stable, 6 dec), scaled 1e36.
    ///      usdyUsd = usdyRaw / 1e18 ; stableUsd = stableRaw / 1e8
    ///      price = (usdyUsd / stableUsd) * 1e36 * 10^loanDec / 10^collDec
    function _expected(uint256 usdyRaw, uint256 stableRaw) internal pure returns (uint256) {
        // = usdyRaw * FEED_DEC * 1e36 * LOAN_UNIT / (USDY_DEC * stableRaw * USDY_DEC)
        return Math.mulDiv(usdyRaw * FEED_DEC, 1e36 * LOAN_UNIT, USDY_DEC * stableRaw * USDY_DEC);
    }

    /// @notice At par ($1.00 stable): 1 USDY at NAV $1.14 → 1.14 USDC, i.e. 1.14e24 at 1e36 scale.
    function test_price_atPar() public {
        usdy.set(114 * USDY_DEC / 100); // $1.14
        feed.set(int256(FEED_DEC)); // $1.00

        uint256 p = oracle.price();
        assertEq(p, 1.14e24, "1.14 USDC per USDY at 1e36 scale");
        assertEq(p, _expected(114 * USDY_DEC / 100, FEED_DEC), "matches convention re-derivation");

        // Sanity via Morpho's usage: 1 USDY of collateral (1e18) is worth 1.14 USDC (1.14e6).
        assertEq(uint256(1e18) * p / 1e36, 1.14e6, "1 USDY collateral -> 1.14 USDC borrow units");
    }

    /// @notice Stablecoin depeg below $1 makes 1 USDY worth MORE stablecoin units (feed in denominator).
    function test_price_stableDepeg_raisesCollateralValue() public {
        usdy.set(114 * USDY_DEC / 100); // $1.14
        feed.set(int256(95 * FEED_DEC / 100)); // USDC at $0.95

        uint256 p = oracle.price();
        assertEq(p, _expected(114 * USDY_DEC / 100, 95 * FEED_DEC / 100), "matches re-derivation");
        assertGt(p, 1.14e24, "depegged stable -> more stable units per USDY");
        // 1.14 / 0.95 = 1.2 USDC per USDY.
        assertEq(uint256(1e18) * p / 1e36, 1.2e6, "1 USDY -> 1.2 USDC when USDC = $0.95");
    }

    /// @notice USDY NAV accrues over time → price scales linearly with getPrice().
    function test_price_usdyAccrual_scalesLinearly() public {
        feed.set(int256(FEED_DEC));
        usdy.set(USDY_DEC); // $1.00
        uint256 p0 = oracle.price();
        usdy.set(USDY_DEC * 2); // $2.00 (hypothetical accrual)
        uint256 p1 = oracle.price();
        assertEq(p1, p0 * 2, "price tracks NAV linearly");
    }

    /// @notice The contract value always equals the convention re-derivation across a range of inputs.
    function testFuzz_matchesConvention(uint256 usdyRaw, uint256 stableRaw) public {
        usdyRaw = bound(usdyRaw, 1, 1e24); // up to ~$1e6 NAV, generous
        stableRaw = bound(stableRaw, 1, 100 * FEED_DEC); // $0 < stable <= $100
        usdy.set(usdyRaw);
        feed.set(int256(stableRaw));
        assertEq(oracle.price(), _expected(usdyRaw, stableRaw), "price == convention re-derivation");
    }

    function testRevert_initializeZeroUsdyOracle() public {
        address impl = address(new UsdyStableOracle());
        bytes memory initData = abi.encodeWithSignature("initialize(address,address)", address(0), address(feed));
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new OssifiableProxy(impl, address(this), initData);
    }

    function testRevert_initializeZeroFeed() public {
        address impl = address(new UsdyStableOracle());
        bytes memory initData = abi.encodeWithSignature("initialize(address,address)", address(usdy), address(0));
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new OssifiableProxy(impl, address(this), initData);
    }
}
