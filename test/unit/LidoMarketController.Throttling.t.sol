// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev The hourly maturation rate cap was removed. The maturation delay is now the only throttle.
///      These tests pin the two properties the cap used to break:
///        - A global budget could starve a borrower whose delay had already elapsed.
///        - A budget smaller than a lot fragmented the matured transition into chunks.
///      With no cap, a borrower whose delay elapsed always matures its whole lot in one sync,
///      independent of any other position.
contract LidoMarketControllerThrottlingTest is LidoMarketControllerTestBase {
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function _setMinMaturationAmount() internal {
        IMarketController.MarketConfig memory cfg = _config();
        cfg.minMaturationAmount = MIN_MATURATION_AMOUNT;
        harness.setMarketConfig(MARKET, cfg);
    }

    // No global throttle can starve a second borrower.
    function test_NoGlobalThrottleStarvesSecondBorrower() public {
        _setMinMaturationAmount();

        _supplyCollateral(alice, 100e18);
        _supplyCollateral(bob, 100e18);

        // Both deposits land in the same block; with an empty matured base each gets maxDelay.
        skip(MAX_DELAY + 1);

        harness.exposed_syncMaturation(MARKET, alice);
        harness.exposed_syncMaturation(MARKET, bob);

        assertEq(_maturedOf(alice), 100e18, "alice should fully mature");
        assertEq(_maturedOf(bob), 100e18, "bob must mature fully too, independent of alice");
    }

    // The whole lot matures in a single sync, leaving no maturing remainder.
    function test_SingleLotMaturesWholeInOneSync() public {
        _setMinMaturationAmount();

        _supplyCollateral(alice, 100e18);
        skip(MAX_DELAY + 1);

        harness.exposed_syncMaturation(MARKET, alice);

        assertEq(_maturedOf(alice), 100e18, "whole lot must mature in one sync");
        assertEq(_maturingOf(alice), 0, "no maturing remainder should be left behind");
    }
}
