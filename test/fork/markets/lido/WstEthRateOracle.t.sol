// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {WstEthRateOracle} from "../../../../src/oracle/WstEthRateOracle.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @dev wstETH's stETH per token, at 18 decimals.
interface IStEthPerToken {
    function stEthPerToken() external view returns (uint256);
}

/// @notice A market on `WstEthRateOracle`, which prices wstETH by its stETH rate, on every such market.
contract WstEthRateOracleForkTest is ForkStack {
    WstEthRateOracle internal oracle;

    function setUp() public {
        _setUpTarget();
        try WstEthRateOracle(address(market.oracle)).WSTETH() {}
        catch {
            vm.skip(true, "WstEthRateOracle: the market's oracle is another kind");
        }
        oracle = WstEthRateOracle(address(market.oracle));
        vm.clearMockedCalls(); // wstETH's own rate
    }

    /// @dev The price is the real wstETH rate queried at the 1e36 point, so it keeps the low-order bits that the naive
    ///      `stEthPerToken() * 1e18` truncates: at least the naive rate, by under one unit (1e18).
    function test_price_isTheWstEthRateAtFullPrecision() public view {
        uint256 price = oracle.price();
        assertEq(price, oracle.WSTETH().getStETHByWstETH(1e36), "the wstETH rate at 1e36");
        uint256 naive = IStEthPerToken(address(oracle.WSTETH())).stEthPerToken() * 1e18;
        assertGe(price, naive, "never below the truncated naive rate");
        assertLt(price - naive, 1e18, "under one unit above the naive rate");
    }
}
