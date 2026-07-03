// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";

/// @dev Mock wstETH: `getStETHByWstETH(amount) = amount * rate / 1e18`, where `rate` is stETH per 1e18
///      wstETH (1e18-scaled), mirroring Lido's linear conversion.
contract MockWstETH {
    uint256 public rate;

    function set(uint256 newRate) external {
        rate = newRate;
    }

    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256) {
        return wstETHAmount * rate / 1e18;
    }
}

/// @notice Coverage for `WstEthRateOracle`: ETH per 1 wstETH at Morpho's 1e36 scale (stETH/ETH par),
///         derived from the wstETH accounting rate. Deployed as in production: immutable-config impl
///         behind an `OssifiableProxy`.
contract WstEthRateOracleTest is Test {
    MockWstETH internal wsteth;
    WstEthRateOracle internal oracle;

    function setUp() public {
        wsteth = new MockWstETH();
        // Immutable-config impl behind an OssifiableProxy, deployed with no init call — the proxy allows
        // empty init data and the config lives in the impl's immutables.
        address impl = address(new WstEthRateOracle(address(wsteth)));
        oracle = WstEthRateOracle(address(new OssifiableProxy(impl, address(this), "")));
    }

    /// @notice price() = getStETHByWstETH(1e36): the 1e36-scaled ETH-per-wstETH rate under stETH/ETH par.
    function test_price_returns1e36ScaledRate() public {
        wsteth.set(1.2e18); // 1 wstETH = 1.2 stETH
        assertEq(oracle.price(), 1.2e36, "1.2 ETH per wstETH at 1e36 scale");
    }

    /// @notice Price tracks the wstETH rate linearly.
    function test_price_scalesWithRate() public {
        wsteth.set(1e18);
        uint256 p0 = oracle.price();
        wsteth.set(2e18);
        assertEq(oracle.price(), p0 * 2, "price tracks the wstETH rate linearly");
    }

    /// @notice Reading at the 1e36 input yields `rate * 1e18` — the convention re-derivation.
    function testFuzz_price_matchesRateScaled(uint256 rate) public {
        rate = bound(rate, 1, 1e24);
        wsteth.set(rate);
        // getStETHByWstETH(1e36) = 1e36 * rate / 1e18 = rate * 1e18
        assertEq(oracle.price(), rate * 1e18, "price == rate * 1e18");
    }

    function testRevert_constructorZeroWstEth() public {
        vm.expectRevert(WstEthRateOracle.ZeroAddress.selector);
        new WstEthRateOracle(address(0));
    }
}
