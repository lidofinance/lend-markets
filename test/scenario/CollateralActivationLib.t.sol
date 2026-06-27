// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {GuardiansOpinion, Status, BlockInfo} from "../../src/types/GuardianSignalsTypes.sol";

/// @dev Storage harness so the internal library can operate on a real storage struct.
contract ActivationHarness {
    using CollateralActivationLib for CollateralActivationLib.State;

    CollateralActivationLib.State internal $;

    /// @dev Mirrors the borrower's raw collateral in core, so the harness can derive `active = total - inactive`.
    mapping(address => uint256) internal _total;

    function setConfig(CollateralActivationConfig memory cfg) external {
        $.setConfig(cfg);
    }

    function setMinActivationDelay(uint40 minDelay) external {
        CollateralActivationConfig memory cfg = $.config;
        cfg.minActivationDelay = minDelay;
        $.setConfig(cfg);
    }

    function setMaxActivationDelay(uint40 maxDelay) external {
        CollateralActivationConfig memory cfg = $.config;
        cfg.maxActivationDelay = maxDelay;
        $.setConfig(cfg);
    }

    function setMinActivationAmount(uint128 amount) external {
        CollateralActivationConfig memory cfg = $.config;
        cfg.minActivationAmount = amount;
        $.setConfig(cfg);
    }

    function setMaxGuardiansQuorumDelay(uint40 quorumDelay) external {
        CollateralActivationConfig memory cfg = $.config;
        cfg.maxGuardiansQuorumDelay = quorumDelay;
        $.setConfig(cfg);
    }

    function delays() external view returns (uint40 minActivationDelay, uint40 maxActivationDelay) {
        return ($.config.minActivationDelay, $.config.maxActivationDelay);
    }

    function deposit(address borrower, uint256 assets) external {
        _total[borrower] += assets;
        $.credit(borrower, assets, false);
    }

    function depositInstant(address borrower, uint256 assets) external {
        _total[borrower] += assets;
        $.credit(borrower, assets, true);
    }

    function debit(address borrower, uint256 amount) external returns (uint256) {
        _total[borrower] -= amount;
        uint256 inactive = $.seize(borrower, amount);
        return _total[borrower] - inactive;
    }

    /// @dev Voluntary withdrawal path ($.debit), which honors the lock and runs the same-tx inflow undo.
    function withdraw(address borrower, uint256 amount) external returns (uint256) {
        _total[borrower] -= amount;
        uint256 inactive = $.debit(borrower, amount);
        return _total[borrower] - inactive;
    }

    function sync(address borrower, uint256 strikes) external returns (uint256) {
        GuardiansOpinion memory opinion = GuardiansOpinion({
            status: Status.Normal,
            strikes: strikes,
            flagCount: strikes,
            quorumBlock: BlockInfo({number: uint40(block.number), timestamp: uint40(block.timestamp)})
        });
        return _total[borrower] - $.sync(false, borrower, opinion);
    }

    /// @dev Sync with an explicit quorum-frontier timestamp, to exercise the activation gate.
    function syncWithQuorum(address borrower, uint40 quorumTimestamp) external returns (uint256) {
        GuardiansOpinion memory opinion = GuardiansOpinion({
            status: Status.Normal,
            strikes: 0,
            flagCount: 0,
            quorumBlock: BlockInfo({number: 0, timestamp: quorumTimestamp})
        });
        return _total[borrower] - $.sync(false, borrower, opinion);
    }

    function currentInflow() external view returns (uint256) {
        return $.calcDecayedInflow();
    }

    function bucketsOf(address borrower) external view returns (uint256 active, uint256 activating, uint256 dust) {
        (activating, dust) = $.getActivationState(borrower);
        active = _total[borrower] - activating - dust;
    }
}

contract CollateralActivationLibTest is Test {
    ActivationHarness internal h;

    function setUp() public {
        h = new ActivationHarness();
        h.setConfig(
            CollateralActivationConfig({
                minActivationDelay: 1 minutes,
                maxActivationDelay: 1 hours,
                delayPerStrike: 1 hours,
                activatingLockAmount: 0,
                activatingLockDuration: 0,
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

    /// @notice A flash-loaned deposit cannot inflate the throttle. The deposit bumps the inflow, but withdrawing
    ///         it in the same tx undoes that bump, bounded by the activating actually removed. A sub-threshold
    ///         dust top-up cannot shield the crossed deposit from the drain, so the only inflow left is matched
    ///         1:1 by the dust collateral left behind (no cheaper than an honest deposit of that size).
    function test_flashDepositDustWithdraw_doesNotInflateThrottle() public {
        h.setMinActivationAmount(1 ether); // raise the threshold so a sub-threshold dust deposit is possible

        address attacker = address(0xBAD);

        // flash-loaned 10 ether crosses the threshold into activating and bumps the inflow
        h.deposit(attacker, 10 ether);
        assertEq(h.currentInflow(), 10 ether, "the crossing deposit bumps the inflow");

        // a sub-threshold top-up stays dust and leaves the inflow alone
        h.deposit(attacker, 0.5 ether);
        assertEq(h.currentInflow(), 10 ether, "dust does not bump the inflow");

        // repay the flash loan: withdraw the 10 ether in the same tx, so the transient undo applies
        h.withdraw(attacker, 10 ether);

        // the inflow falls back to the 0.5 ether dust left behind, not the flash-loaned 10
        assertEq(h.currentInflow(), 0.5 ether, "same-tx undo reverses all inflow but the collateral kept");

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(attacker);
        assertEq(active, 0, "no matured collateral");
        assertEq(activating + dust, 0.5 ether, "only the sub-threshold dust remains, matched 1:1 by the inflow");
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

    /// @notice Quorum-scan gate: past the base timer, a lot stays activating until the guardian frontier has
    ///         scanned past its unlock; once it does, the lot matures.
    function test_sync_gateHoldsUntilQuorumScansPastUnlock() public {
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
    function test_sync_maxGuardiansQuorumDelayFallbackMatures() public {
        vm.warp(1_000_000);
        h.deposit(address(0xD2), 100 ether);
        uint40 depositTime = uint40(block.timestamp);

        vm.warp(block.timestamp + 1 days + 1); // past the cap, quorum never scans
        h.syncWithQuorum(address(0xD2), depositTime - 1); // frontier still behind
        (uint256 active,,) = h.bucketsOf(address(0xD2));
        assertEq(active, 100 ether, "fallback matured the lot after maxGuardiansQuorumDelay despite a stalled quorum");
    }

    // setUp config: minActivationDelay = 1 minutes, maxActivationDelay = 1 hours (MAX_DELAY_DURATION = 7 days)

    function test_setMinActivationDelay_updatesFloor() public {
        h.setMinActivationDelay(30 minutes);
        (uint40 minActivationDelay,) = h.delays();
        assertEq(minActivationDelay, 30 minutes, "floor updated");
    }

    function test_setMaxActivationDelay_updatesCap() public {
        h.setMaxActivationDelay(2 hours);
        (, uint40 maxActivationDelay) = h.delays();
        assertEq(maxActivationDelay, 2 hours, "cap updated");
    }

    function testRevert_setMinActivationDelay_zero() public {
        vm.expectRevert(CollateralActivationLib.ZeroMinActivationDelay.selector);
        h.setMinActivationDelay(0);
    }

    function testRevert_setMinActivationDelay_aboveCap() public {
        vm.expectRevert(CollateralActivationLib.InvalidActivationDelays.selector);
        h.setMinActivationDelay(2 hours);
    }

    function testRevert_setMaxActivationDelay_belowFloor() public {
        vm.expectRevert(CollateralActivationLib.InvalidActivationDelays.selector);
        h.setMaxActivationDelay(30 seconds);
    }

    function testRevert_setMaxActivationDelay_aboveBound() public {
        vm.expectRevert(CollateralActivationLib.MaxActivationDelayExceeded.selector);
        h.setMaxActivationDelay(8 days);
    }

    /// @notice A nonzero quorum-fallback delay must strictly exceed the base delay cap, else the quorum gate has
    ///         no window (the fallback fires at the unlock). Equal to `maxActivationDelay` is rejected.
    function testRevert_setMaxGuardiansQuorumDelay_notAboveMaxActivationDelay() public {
        vm.expectRevert(CollateralActivationLib.InvalidMaxGuardiansQuorumDelay.selector);
        h.setMaxGuardiansQuorumDelay(1 hours); // == maxActivationDelay
    }
}
