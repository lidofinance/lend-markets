// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev Liquidation must be able to seize maturing collateral. Unlike a user withdrawal (where
///      maturing is locked), seizure consumes dust -> maturing -> matured so an immature, possibly
///      toxic lot is always liquidatable and cannot shelter behind the maturation lock.
contract LidoMarketControllerLiquidationTest is LidoMarketControllerTestBase {
    address internal borrower = address(0xB0B);

    // Maturing collateral is seizable by liquidation even though a user cannot withdraw it.
    function test_LiquidationSeizesMaturing() public {
        _supplyCollateral(borrower, 100e18); // maturing = 100e18 (not matured)

        harness.exposed_handleLiquidate(MARKET, address(this), borrower, 60e18, 0);

        assertEq(_maturingOf(borrower), 40e18, "maturing reduced by seizure");
        assertEq(_maturedOf(borrower), 0, "no matured involved");
    }

    // Seizure order is dust -> maturing -> matured: it exhausts maturing before touching matured.
    function test_LiquidationConsumesMaturingBeforeMatured() public {
        _supplyCollateral(borrower, 100e18);
        skip(MAX_DELAY + 1);
        harness.exposed_syncMaturation(MARKET, borrower); // matured = 100e18
        _supplyCollateral(borrower, 50e18); // maturing = 50e18

        harness.exposed_handleLiquidate(MARKET, address(this), borrower, 70e18, 0);

        // 50 from maturing (exhausted) + 20 from matured.
        assertEq(_maturingOf(borrower), 0, "maturing exhausted first");
        assertEq(_maturedOf(borrower), 80e18, "remainder taken from matured");
    }
}
