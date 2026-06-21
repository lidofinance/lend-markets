// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {GuardiansOpinion, Status, BlockInfo} from "../../src/interfaces/GuardianSignalsTypes.sol";

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

    function depositInstant(address borrower, uint256 assets) external {
        $.setInstantActivation(borrower, true);
        $.deposit(borrower, assets);
    }

    function sync(address borrower, uint256 strikes, bool instant) external returns (uint256) {
        if (instant) $.setInstantActivation(borrower, true);
        GuardiansOpinion memory opinion = GuardiansOpinion({
            status: Status.Normal,
            strikes: strikes,
            flagCount: strikes,
            quorumBlock: BlockInfo({number: uint40(block.number), timestamp: uint40(block.timestamp)})
        });
        return $.syncActivation(false, borrower, opinion);
    }

    /// @dev Sync with an explicit quorum-frontier timestamp, to exercise the activation gate.
    function syncWithQuorum(address borrower, uint40 quorumTimestamp) external returns (uint256) {
        GuardiansOpinion memory opinion = GuardiansOpinion({
            status: Status.Normal,
            strikes: 0,
            flagCount: 0,
            quorumBlock: BlockInfo({number: 0, timestamp: quorumTimestamp})
        });
        return $.syncActivation(false, borrower, opinion);
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
                minActivationAmount: 1,
                maxGuardiansQuorumDelay: 1 days
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

    /// @notice A trusted (instant) deposit crosses straight into `active`, with no timer and no inflow bump.
    function test_instantDeposit_activatesImmediatelyWithoutInflow() public {
        h.depositInstant(address(0xC1), 100 ether);
        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(address(0xC1));
        assertEq(active, 100 ether, "instant deposit is active at once");
        assertEq(activating, 0, "no timed lot");
        assertEq(dust, 0, "no dust");
        assertEq(h.currentInflow(), 0, "instant deposit does not touch the inflow throttle");
    }

    /// @notice Whitelisting an already-deposited borrower: an instant sync matures the pending lot before its
    ///         timer elapses.
    function test_syncActivation_instantMaturesPendingLotBeforeTimer() public {
        h.deposit(address(0xC3), 100 ether); // normal: enters the timer
        (, uint256 activating,) = h.bucketsOf(address(0xC3));
        assertEq(activating, 100 ether, "lot is timed");

        h.sync(address(0xC3), 0, true); // instant sync, no warp
        (uint256 active, uint256 activatingAfter,) = h.bucketsOf(address(0xC3));
        assertEq(active, 100 ether, "instant sync matured the lot before the timer");
        assertEq(activatingAfter, 0, "lot left the timer");
    }

    /// @notice Quorum-scan gate: past the base timer, a lot stays activating until the guardian frontier has
    ///         scanned past its unlock; once it does, the lot matures.
    function test_syncActivation_gateHoldsUntilQuorumScansPastUnlock() public {
        vm.warp(1_000_000);
        h.deposit(address(0xD1), 100 ether);
        uint40 depositTime = uint40(block.timestamp);
        vm.warp(block.timestamp + 2 hours); // past the base unlock (cap 1 hour)

        // Frontier still behind the unlock: the gate holds the lot.
        h.syncWithQuorum(address(0xD1), depositTime - 1);
        (uint256 active, uint256 activating,) = h.bucketsOf(address(0xD1));
        assertEq(active, 0, "gate holds: quorum has not scanned past the unlock");
        assertEq(activating, 100 ether, "still activating");

        // Frontier scans past the unlock: the lot matures.
        h.syncWithQuorum(address(0xD1), uint40(block.timestamp));
        (uint256 activeAfter,,) = h.bucketsOf(address(0xD1));
        assertEq(activeAfter, 100 ether, "matured once the quorum scanned past the unlock");
    }

    /// @notice Liveness fallback: once total activating time passes `maxGuardiansQuorumDelay` (1 day here), the
    ///         lot matures even if the quorum never scans past the unlock.
    function test_syncActivation_maxGuardiansQuorumDelayFallbackMatures() public {
        vm.warp(1_000_000);
        h.deposit(address(0xD2), 100 ether);
        uint40 depositTime = uint40(block.timestamp);

        vm.warp(block.timestamp + 1 days + 1); // past the cap, quorum never scans
        h.syncWithQuorum(address(0xD2), depositTime - 1); // frontier still behind
        (uint256 active,,) = h.bucketsOf(address(0xD2));
        assertEq(active, 100 ether, "fallback matured the lot after maxGuardiansQuorumDelay despite a stalled quorum");
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
