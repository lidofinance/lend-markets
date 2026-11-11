// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";

/// @dev Minimal wstETH stub: `getStETHByWstETH(amt) = amt * stEthPerToken / 1e18` (the real formula).
contract MockWstETH {
    uint256 public stEthPerToken = 1.15e18;

    function setStEthPerToken(uint256 v) external {
        stEthPerToken = v;
    }

    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256) {
        return wstETHAmount * stEthPerToken / 1e18;
    }
}

/// @dev wstETH as Lido computes it, `amount * totalPooledEther / totalShares` floored, over a ratio a 1e18 query
///      cannot represent in full.
contract ShareRatioWstETH {
    uint256 public constant TOTAL_POOLED_ETHER = 1_150_000_000_000_000_000_001;
    uint256 public constant TOTAL_SHARES = 1e21;

    function getStETHByWstETH(uint256 wstETHAmount) external pure returns (uint256) {
        return wstETHAmount * TOTAL_POOLED_ETHER / TOTAL_SHARES;
    }
}

/// @notice Unit/fuzz for `WstEthRateOracle`: a Morpho IOracle adapter returning
///         the wstETH->stETH rate at the 1e36 query point, scaled to 1e36 (loan WETH 18, collateral wstETH
///         18 -> 36+18-18). Recomputed independently from `stEthPerToken`. Deployed directly (immutable
///         config in the constructor; `initialize()` is a proxy no-op).
contract WstEthRateOracleTest is Test {
    MockWstETH internal wsteth;
    WstEthRateOracle internal oracle;

    function setUp() public {
        wsteth = new MockWstETH();
        oracle = new WstEthRateOracle(address(wsteth));
    }

    // ── mutations ──

    /// @dev Constructing with a zero wstETH address reverts ZeroAddress.
    function testRevert_constructor_zeroAddress() public {
        vm.expectRevert(WstEthRateOracle.ZeroAddress.selector);
        new WstEthRateOracle(address(0));
    }

    // ── views ──

    /// @dev price returns the wstETH->stETH rate scaled to 1e36, recomputed independently from stEthPerToken.
    function test_price_recomputeFromRate() public {
        wsteth.setStEthPerToken(1.15e18);
        // price = getStETHByWstETH(1e36) = 1e36 * 1.15e18 / 1e18 = 1.15e36.
        assertEq(oracle.price(), uint256(1e36) * 1.15e18 / 1e18, "price = rate scaled to 1e36");
        assertEq(oracle.price(), 1.15e36, "explicit value");
    }

    /// @dev The rate is 1.15 + 1e-21: a 1e18 query floors the tail away, the 1e36 query keeps 1e15 of it.
    function test_price_1e36Query_keepsDigitsA1e18QueryFloors() public {
        ShareRatioWstETH ratio = new ShareRatioWstETH();
        WstEthRateOracle precise = new WstEthRateOracle(address(ratio));
        uint256 expected = uint256(1e36) * ratio.TOTAL_POOLED_ETHER() / ratio.TOTAL_SHARES();

        assertEq(precise.price(), expected, "price = 1e36 * pooled / shares");
        assertEq(precise.price(), 1.15e36 + 1e15, "explicit value");
        assertEq(ratio.getStETHByWstETH(1e18) * 1e18, 1.15e36, "a scaled 1e18 query loses the tail");
    }

    /// @dev Across a realistic rate band, price equals the rate scaled to 1e36.
    function testFuzz_price_equalsScaledRate(uint256 ratePerToken) public {
        ratePerToken = bound(ratePerToken, 1e18, 2e18); // wstETH ≥ stETH, realistic band
        wsteth.setStEthPerToken(ratePerToken);
        assertEq(oracle.price(), uint256(1e36) * ratePerToken / 1e18, "price tracks the rate, scaled to 1e36");
    }

    /// @dev There is no zero/sanity floor: a 0 rate propagates as price 0 (the rate is Lido's monotonic
    ///      pooled-ETH accounting, so 0 implies a broken core, out of trust scope — documented, not guarded).
    function test_price_zeroRate_propagates() public {
        wsteth.setStEthPerToken(0);
        assertEq(oracle.price(), 0, "zero rate propagates as zero price, no floor");
    }

    /// @dev A rate far above any real value passes through to price without overflow.
    function test_price_largeRate_noOverflow() public {
        wsteth.setStEthPerToken(10e18); // far above any real wstETH rate
        assertEq(oracle.price(), 10e36, "large rate passes through without overflow");
    }
}
