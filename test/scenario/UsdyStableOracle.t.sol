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

/// @dev Mock Chainlink USD aggregator: `answer` is the price, `decimals()` its scale.
contract MockChainlinkFeed {
    int256 internal answer;
    uint8 public immutable decimals;

    constructor(uint8 dec) {
        decimals = dec;
    }

    function set(int256 newAnswer) external {
        answer = newAnswer;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, 0, 0, 0);
    }
}

/// @dev Loan stablecoin stub exposing only `decimals()`, read by the oracle to size the scale.
contract MockToken {
    uint8 public immutable decimals;

    constructor(uint8 dec) {
        decimals = dec;
    }
}

/// @notice Coverage for `UsdyStableOracle`: USDY NAV (1e18, 18-dec collateral) quoted in a USD stablecoin via
///         its Chainlink USD feed, scaled to Morpho's 1e36 convention. The scale is computed from the loan
///         token and feed decimals, so the same contract serves any Chainlink-priced stablecoin — exercised
///         here for a 6-dec stable (USDC/USDT) and an 18-dec stable. Expected values are re-derived from the
///         convention, independent of the contract's SCALE.
contract UsdyStableOracleTest is Test {
    uint256 internal constant USDY_DEC = 1e18; // USDY token + Ondo getPrice() scale
    uint256 internal constant FEED_DEC = 1e8; // Chainlink USD feed scale
    uint256 internal constant LOAN_UNIT = 1e6; // 6-dec stable (USDC/USDT)

    MockRwaOracle internal usdy;
    MockChainlinkFeed internal feed;
    MockToken internal stable6; // 6 dec
    UsdyStableOracle internal oracle;

    function setUp() public {
        usdy = new MockRwaOracle();
        feed = new MockChainlinkFeed(8);
        stable6 = new MockToken(6);
        // Deploy as in production: immutable-config impl behind an OssifiableProxy, with no init call — the
        // config lives in the impl's immutables and the proxy allows empty init data.
        address impl = address(new UsdyStableOracle(address(usdy), address(feed), address(stable6)));
        oracle = UsdyStableOracle(_behindProxy(impl));
    }

    function _behindProxy(address impl) internal returns (address) {
        return address(new OssifiableProxy(impl, address(this), ""));
    }

    /// @dev Independent re-derivation of Morpho's IOracle value: price of 1 USDY (18 dec) in the loan (6 dec).
    ///      usdyUsd = usdyRaw / 1e18 ; stableUsd = stableRaw / 1e8
    ///      price = (usdyUsd / stableUsd) * 1e36 * 10^loanDec / 10^18
    function _expected(uint256 usdyRaw, uint256 stableRaw) internal pure returns (uint256) {
        return Math.mulDiv(usdyRaw * FEED_DEC, 1e36 * LOAN_UNIT, USDY_DEC * stableRaw * USDY_DEC);
    }

    /// @notice The scale is derived from the loan/feed decimals, not hardwired (1e14 for a 6-dec stable).
    function test_scale_derivedFromDecimals() public view {
        assertEq(oracle.SCALE(), 1e14, "10^(36 + 6 + 8 - 18 - 18)");
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

    /// @notice The same contract prices an 18-dec stablecoin loan: SCALE becomes 1e26, not the 1e14 of the
    ///         6-dec case — proving the scale comes from the loan/feed decimals, not a constant.
    function test_price_eighteenDecimalStable() public {
        MockToken stable18 = new MockToken(18);
        UsdyStableOracle o = new UsdyStableOracle(address(usdy), address(feed), address(stable18));
        assertEq(o.SCALE(), 1e26, "10^(36 + 18 + 8 - 18 - 18)");

        usdy.set(114 * USDY_DEC / 100); // $1.14
        feed.set(int256(FEED_DEC)); // $1.00
        uint256 p = o.price();
        assertEq(p, 1.14e36, "1.14 (18-dec) stable per USDY at 1e36 scale");
        assertEq(uint256(1e18) * p / 1e36, 1.14e18, "1 USDY collateral -> 1.14 stable (18 dec)");
    }

    /// @notice The contract value always equals the convention re-derivation across a range of inputs.
    function testFuzz_matchesConvention(uint256 usdyRaw, uint256 stableRaw) public {
        usdyRaw = bound(usdyRaw, 1, 1e24); // up to ~$1e6 NAV, generous
        stableRaw = bound(stableRaw, 1, 100 * FEED_DEC); // $0 < stable <= $100
        usdy.set(usdyRaw);
        feed.set(int256(stableRaw));
        assertEq(oracle.price(), _expected(usdyRaw, stableRaw), "price == convention re-derivation");
    }

    function testRevert_constructorZeroUsdyOracle() public {
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new UsdyStableOracle(address(0), address(feed), address(stable6));
    }

    function testRevert_constructorZeroFeed() public {
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new UsdyStableOracle(address(usdy), address(0), address(stable6));
    }

    function testRevert_constructorZeroLoan() public {
        vm.expectRevert(UsdyStableOracle.ZeroAddress.selector);
        new UsdyStableOracle(address(usdy), address(feed), address(0));
    }
}
