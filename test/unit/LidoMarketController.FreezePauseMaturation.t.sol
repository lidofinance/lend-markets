// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {LidoMarketController} from "../../src/controllers/LidoMarketController.sol";
import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev Freeze and pause must suspend maturation: while the market is frozen or paused, an elapsed
///      maturing lot does not become matured. The timer keeps running (it is a deferral, not an
///      extension), so once the market resumes the lot matures on the next sync. This lets risk
///      responders halt risk expansion (new borrow capacity) without seizing collateral.
contract LidoMarketControllerFreezePauseMaturationTest is LidoMarketControllerTestBase {
    address internal user = address(0xABCD);

    function _supplyElapsedLot() internal {
        _supplyCollateral(user, 100e18); // >= min => maturing
        skip(MAX_DELAY + 1); // delay elapsed
    }

    function test_FrozenMarketDoesNotMature() public {
        _supplyElapsedLot();
        harness.freeze(MARKET);

        harness.exposed_syncMaturation(MARKET, user);
        assertEq(_maturedOf(user), 0, "must not mature while frozen");
        assertEq(_maturingOf(user), 100e18, "lot stays maturing while frozen");

        harness.unfreeze(MARKET);
        harness.exposed_syncMaturation(MARKET, user);
        assertEq(_maturedOf(user), 100e18, "matures once unfrozen");
    }

    function test_PausedMarketDoesNotMature() public {
        _supplyElapsedLot();
        harness.pauseMarket(MARKET);

        harness.exposed_syncMaturation(MARKET, user);
        assertEq(_maturedOf(user), 0, "must not mature while paused");
        assertEq(_maturingOf(user), 100e18, "lot stays maturing while paused");

        harness.unpauseMarket(MARKET);
        harness.exposed_syncMaturation(MARKET, user);
        assertEq(_maturedOf(user), 100e18, "matures once unpaused");
    }

    // Freeze still blocks withdrawal for a position carrying debt (risk expansion control intact).
    function test_FrozenWithDebtCannotWithdraw() public {
        _supplyCollateral(user, 100e18);
        harness.freeze(MARKET);

        vm.expectRevert(LidoMarketController.MarketIsFrozen.selector);
        harness.exposed_handleWithdrawCollateral(MARKET, user, user, user, 100e18, 1);
    }
}
