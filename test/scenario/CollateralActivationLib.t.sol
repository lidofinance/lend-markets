// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";

/// @dev Storage harness so the internal library can operate on a real storage struct.
contract ActivationHarness {
    using CollateralActivationLib for CollateralActivationLib.State;

    CollateralActivationLib.State internal $;

    function setConfig(CollateralActivationLib.Config memory cfg) external {
        $.setConfig(cfg);
    }

    function setMinActivationDelay(uint64 minDelay) external {
        $.setMinActivationDelay(minDelay);
    }

    function setMaxActivationDelay(uint64 maxDelay) external {
        $.setMaxActivationDelay(maxDelay);
    }

    function delays() external view returns (uint64 minActivationDelay, uint64 maxActivationDelay) {
        return ($.config.minActivationDelay, $.config.maxActivationDelay);
    }

    function deposit(address borrower, uint256 assets) external {
        $.deposit(borrower, assets);
    }

    function currentInflow() external view returns (uint256) {
        return $.getInflow();
    }

    function bucketsOf(address borrower) external view returns (uint256 active, uint256 activating, uint256 dust) {
        return $.getBuckets(borrower);
    }
}

contract CollateralActivationLibTest is Test {
    ActivationHarness internal h;

    function setUp() public {
        h = new ActivationHarness();
        h.setConfig(
            CollateralActivationLib.Config({
                minActivationDelay: 1 minutes,
                maxActivationDelay: 1 hours,
                delayPerStrike: 1 hours,
                activatingHold: 0,
                maxDelayInflow: 10_000 ether,
                minActivationAmount: 1
            })
        );
    }

    /// @notice The inflow accumulator saturates at `maxDelayInflow` rather than growing past it. The delay
    ///         already clamps at the cap, so storing more would only lengthen the drain, and the cap keeps
    ///         the uint128 store unwrappable.
    function test_inflowAccumulator_capsAtMaxDelayInflow() public {
        h.deposit(address(0xB1), 8_000 ether);
        assertEq(h.currentInflow(), 8_000 ether, "below the cap, inflow accumulates linearly");

        // pushes the total past the 10_000 ether cap: saturates instead of overshooting
        h.deposit(address(0xB2), 5_000 ether);
        assertEq(h.currentInflow(), 10_000 ether, "inflow saturates at maxDelayInflow");
    }

    // setUp config: minActivationDelay = 1 minutes, maxActivationDelay = 1 hours (MAX_DELAY_BOUND = 7 days)

    function test_setMinActivationDelay_updatesFloor() public {
        h.setMinActivationDelay(30 minutes);
        (uint64 minActivationDelay,) = h.delays();
        assertEq(minActivationDelay, 30 minutes, "floor updated");
    }

    function test_setMaxActivationDelay_updatesCap() public {
        h.setMaxActivationDelay(2 hours);
        (, uint64 maxActivationDelay) = h.delays();
        assertEq(maxActivationDelay, 2 hours, "cap updated");
    }

    function testRevert_setMinActivationDelay_zero() public {
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setMinActivationDelay(0);
    }

    function testRevert_setMinActivationDelay_aboveCap() public {
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setMinActivationDelay(2 hours);
    }

    function testRevert_setMaxActivationDelay_belowFloor() public {
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setMaxActivationDelay(30 seconds);
    }

    function testRevert_setMaxActivationDelay_aboveBound() public {
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setMaxActivationDelay(8 days);
    }
}
