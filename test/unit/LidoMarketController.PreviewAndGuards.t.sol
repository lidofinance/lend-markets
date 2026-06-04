// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {LidoMarketController} from "../../src/controllers/LidoMarketController.sol";
import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev previewMaturation reporting, plus characterization of two intentionally-kept behaviours:
///        - the load accumulator is bumped even while the market is frozen (accepted; borrowing is
///          frozen so the spiked load is harmless until resume), and
///        - pause is a full stop: it blocks withdrawal entirely, stricter than freeze (which keeps a
///          zero-debt exit).
contract LidoMarketControllerPreviewAndGuardsTest is LidoMarketControllerTestBase {
    address internal user = address(0xABCD);

    function test_PreviewReportsBucketsAndReadiness() public {
        _supplyCollateral(user, 100e18);
        (uint256 matured, uint256 maturing, uint256 dust, bool ready) = harness.previewMaturation(MARKET, user);
        assertEq(matured, 0, "no matured yet");
        assertEq(maturing, 100e18, "maturing reported");
        assertEq(dust, 0, "no dust");
        assertEq(ready, false, "not ready before timer elapses");

        skip(MAX_DELAY + 1);
        (,,, ready) = harness.previewMaturation(MARKET, user);
        assertEq(ready, true, "ready once timer elapsed");

        harness.freeze(MARKET);
        (,,, ready) = harness.previewMaturation(MARKET, user);
        assertEq(ready, false, "not ready while frozen");
    }

    // Accepted behaviour: supplying during freeze still bumps the load accumulator.
    function test_LoadBumpsEvenWhenFrozen() public {
        _enableLeakyBucket();
        harness.freeze(MARKET);

        _supplyCollateral(user, REF); // proceeds during freeze and bumps load to the cap

        assertEq(harness.exposed_computeMaturationDelay(MARKET, 0), MAX_DELAY, "load bumped during freeze");
    }

    function test_FreezeAllowsLenderSupply() public {
        harness.freeze(MARKET);
        harness.exposed_handleSupply(MARKET, user, user, 0);
    }

    function test_PauseBlocksLenderSupply() public {
        harness.pauseMarket(MARKET);
        vm.expectRevert(LidoMarketController.MarketIsPaused.selector);
        harness.exposed_handleSupply(MARKET, user, user, 0);
    }

    // Pause is a full stop: even a zero-debt matured withdrawal reverts.
    function test_PauseBlocksWithdrawEntirely() public {
        _supplyCollateral(user, 100e18);
        skip(MAX_DELAY + 1);
        harness.exposed_syncMaturation(MARKET, user); // matured = 100e18

        harness.pauseMarket(MARKET);

        vm.expectRevert(LidoMarketController.MarketIsPaused.selector);
        harness.exposed_handleWithdrawCollateral(MARKET, user, user, user, 100e18, 0);
    }
}
