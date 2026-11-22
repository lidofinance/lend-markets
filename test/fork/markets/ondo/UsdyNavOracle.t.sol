// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {UsdyNavOracle} from "../../../../src/oracle/UsdyNavOracle.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @notice A market on `UsdyNavOracle`, the trailing anchor oracle over Ondo's USDY NAV, on every such market.
contract UsdyNavOracleForkTest is ForkStack {
    UsdyNavOracle internal oracle;

    function setUp() public {
        _setUpTarget();
        try UsdyNavOracle(address(market.oracle)).SOURCE() {}
        catch {
            vm.skip(true, "UsdyNavOracle: the market's oracle is another kind");
        }
        oracle = UsdyNavOracle(address(market.oracle));
        vm.clearMockedCalls(); // Ondo's own getter
    }

    /// @dev The price is Ondo's NAV at the oracle's scale.
    function test_price_isOndosNav() public view {
        assertEq(oracle.price(), oracle.SOURCE().getPrice() * oracle.PRICE_SCALE());
    }
}
