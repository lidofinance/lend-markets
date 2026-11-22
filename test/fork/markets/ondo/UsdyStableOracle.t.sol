// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {UsdyStableOracle} from "../../../../src/oracle/UsdyStableOracle.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @notice A market on `UsdyStableOracle`, which prices USDY in the loan token from Ondo's NAV and the loan token's USD
///         feed, on every such market.
contract UsdyStableOracleForkTest is ForkStack {
    UsdyStableOracle internal oracle;

    function setUp() public {
        _setUpTarget();
        try UsdyStableOracle(address(market.oracle)).USDY_ORACLE() {}
        catch {
            vm.skip(true, "UsdyStableOracle: the market's oracle is another kind");
        }
        oracle = UsdyStableOracle(address(market.oracle));
        vm.clearMockedCalls(); // Ondo's own getter
    }

    /// @dev The price is Ondo's NAV over the loan token's USD price, `getPrice() * scale / answer`, inside the
    ///      oracle's band.
    function test_price_isOndosNavInTheLoanToken() public view {
        (, int256 answer,,,) = oracle.stableUsdFeed().latestRoundData();
        uint256 expected = Math.mulDiv(oracle.USDY_ORACLE().getPrice(), oracle.scale(), uint256(answer));
        assertEq(oracle.price(), expected, "price");
        assertGe(expected, oracle.MIN_PRICE(), "above the band's floor");
        assertLe(expected, oracle.MAX_PRICE(), "below the band's ceiling");
    }
}
