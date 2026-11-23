// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CentrifugeNavOracle} from "../../../../src/oracle/CentrifugeNavOracle.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @notice A market on `CentrifugeNavOracle`, the trailing anchor oracle over a Centrifuge share class's price on the
///         Spoke, on every such market.
contract CentrifugeNavOracleForkTest is ForkStack {
    CentrifugeNavOracle internal oracle;

    function setUp() public {
        _setUpTarget();
        try CentrifugeNavOracle(address(market.oracle)).SPOKE() {}
        catch {
            vm.skip(true, "CentrifugeNavOracle: the market's oracle is another kind");
        }
        oracle = CentrifugeNavOracle(address(market.oracle));
        vm.clearMockedCalls(); // the Spoke's own price and stamp
    }

    /// @dev The price is the Spoke's share price at the oracle's scale.
    function test_price_isTheSpokesPrice() public view {
        uint256 spokePrice = oracle.SPOKE().pricePoolPerShare(oracle.POOL_ID(), oracle.SHARE_CLASS_ID(), false);
        assertEq(oracle.price(), spokePrice * oracle.PRICE_SCALE());
    }

    /// @dev The Spoke's own stamp drives the age check: the price is returned up to `MAX_PRICE_AGE` after the stamp
    ///      and refused one second later with `StalePrice(computedAt)`.
    function test_price_refusedOlderThanMaxPriceAge() public {
        (uint64 computedAt,,) = oracle.SPOKE().markersPricePoolPerShare(oracle.POOL_ID(), oracle.SHARE_CLASS_ID());
        uint256 maxAge = oracle.MAX_PRICE_AGE();
        assertLe(block.timestamp - computedAt, maxAge, "live price within the age limit");

        vm.warp(computedAt + maxAge);
        assertGt(oracle.price(), 0, "priced on the last second of the age limit");
        vm.warp(computedAt + maxAge + 1);
        vm.expectRevert(abi.encodeWithSelector(CentrifugeNavOracle.StalePrice.selector, computedAt));
        oracle.price();
    }
}
