// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {GuardiansOpinion} from "../../src/types/GuardianSignalsTypes.sol";

/// @dev Storage harness so the internal library can operate on a real storage struct. The guardian surcharge is
///      computed inside the lib from the counters in `GuardiansOpinion`, so the harness just supplies those
///      counters to `sync`, mirroring how the controller feeds them from GuardianSignals.
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

    function maxGuardiansQuorumDelay() external view returns (uint40) {
        return $.config.maxGuardiansQuorumDelay;
    }

    function deposit(address borrower, uint256 assets) external {
        _total[borrower] += assets;
        $.credit(borrower, assets, false);
    }

    function depositInstant(address borrower, uint256 assets) external {
        _total[borrower] += assets;
        $.credit(borrower, assets, true);
    }

    /// @dev Forced seizure path ($.seize): consumes active collateral first, then the un-matured buckets,
    ///      ignoring the lock, and runs the same-tx inflow undo. `totalBefore` mirrors what the controller
    ///      reads from core as the borrower's pre-seizure collateral.
    function seize(address borrower, uint256 amount) external returns (uint256) {
        uint256 totalBefore = _total[borrower];
        _total[borrower] -= amount;
        $.seize(borrower, amount, totalBefore);
        (uint256 activating, uint256 dust) = $.getActivationState(borrower);
        return _total[borrower] - activating - dust;
    }

    /// @dev Voluntary withdrawal path ($.debit), which honors the lock and runs the same-tx inflow undo.
    ///      `debit` takes the pre-withdrawal total, mirroring what the controller reads from core.
    function withdraw(address borrower, uint256 amount) external returns (uint256) {
        uint256 totalBefore = _total[borrower];
        _total[borrower] -= amount;
        $.debit(borrower, amount, totalBefore);
        (uint256 activating, uint256 dust) = $.getActivationState(borrower);
        return _total[borrower] - activating - dust;
    }

    function sync(address borrower, uint256 strikes) external returns (uint256) {
        // The lib turns the strike count into a surcharge via `config.delayPerStrike`; the quorum frontier is
        // "now" so the quorum gate is satisfied.
        GuardiansOpinion memory opinion = GuardiansOpinion({
            banned: false,
            strikeCount: strikes,
            suspectCount: 0,
            suspectExpiryTimestamp: 0,
            quorumFrontierTimestamp: block.timestamp
        });
        return _total[borrower] - $.sync(false, borrower, opinion);
    }

    /// @dev Sync with an explicit quorum-frontier timestamp (and no surcharge), to exercise the gate.
    function syncWithQuorum(address borrower, uint40 quorumTimestamp) external returns (uint256) {
        GuardiansOpinion memory opinion = GuardiansOpinion({
            banned: false,
            strikeCount: 0,
            suspectCount: 0,
            suspectExpiryTimestamp: 0,
            quorumFrontierTimestamp: quorumTimestamp
        });
        return _total[borrower] - $.sync(false, borrower, opinion);
    }

    /// @dev Direct read of the unlock time for a caller-supplied opinion, to exercise the banned and suspect
    ///      surcharge branches the `sync` helpers don't reach.
    function getUnlockTime(address borrower, GuardiansOpinion memory opinion) external view returns (uint256) {
        return $.getUnlockTime(borrower, opinion);
    }

    function currentInflow() external view returns (uint256) {
        return $.calcDecayedInflow();
    }

    /// @dev Test-only: prime the persistent accumulator as if a prior tx left it here, without touching the
    ///      per-tx transient state — so the next activation mutation snapshots this value as its baseline.
    function primeInflow(uint128 value) external {
        $.inflow = value;
        $.inflowUpdatedAt = uint40(block.timestamp);
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
                activatingLockDuration: 0,
                maxDelayInflow: 10_000 ether,
                minActivationAmount: 1,
                minDepositAmount: 0,
                maxGuardiansQuorumDelay: 1 days,
                delayPerStrike: 1 hours,
                delayPerSuspect: 30 minutes
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

    /// @notice A flash-loaned deposit cannot inflate the throttle. The deposit bumps the inflow, but clearing the
    ///         whole inactive balance (dust plus activating) in the same tx undoes that bump entirely — the
    ///         all-or-nothing rule means the flash-loaned amount cannot leave without also taking the dust top-up
    ///         with it, so nothing is left behind to keep throttled or otherwise.
    function test_flashDepositDustWithdraw_doesNotInflateThrottle() public {
        h.setMinActivationAmount(1 ether); // raise the threshold so a sub-threshold dust deposit is possible

        address attacker = address(0xBAD);

        // flash-loaned 10 ether crosses the threshold into activating and bumps the inflow
        h.deposit(attacker, 10 ether);
        assertEq(h.currentInflow(), 10 ether, "the crossing deposit bumps the inflow");

        // a sub-threshold top-up stays dust and leaves the inflow alone
        h.deposit(attacker, 0.5 ether);
        assertEq(h.currentInflow(), 10 ether, "dust does not bump the inflow");

        // repay the flash loan: clear the whole inactive balance (dust + activating) in the same tx, so the
        // transient undo applies to all of it
        h.withdraw(attacker, 10.5 ether);

        assertEq(h.currentInflow(), 0, "same-tx undo reverses all inflow");

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(attacker);
        assertEq(active, 0, "no matured collateral");
        assertEq(activating, 0, "activating cleared");
        assertEq(dust, 0, "dust cleared too, inactive leaves all-or-nothing");
    }

    /// @notice Dust that predates a crossing deposit is released into the timed lot: a sub-threshold deposit parks
    ///         as dust, then a later deposit that (with the dust) crosses the threshold clears the dust and folds
    ///         the whole amount into `activating`. Exercises the "dust already present when the threshold is
    ///         crossed" path, distinct from the flash test where the crossing deposit comes first.
    function test_dustThenCrossThreshold_releasesDustIntoActivating() public {
        h.setMinActivationAmount(10 ether); // a real threshold so a sub-threshold deposit is possible
        address borrower = address(0xD05);

        h.deposit(borrower, 4 ether); // below 10 -> parks as dust, nothing timed
        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(dust, 4 ether, "sub-threshold deposit parks as dust");
        assertEq(activating, 0, "nothing activating yet");
        assertEq(active, 0, "nothing active yet");

        h.deposit(borrower, 8 ether); // 8 + 4 dust = 12 >= 10 -> crosses; the dust is released with it
        (active, activating, dust) = h.bucketsOf(borrower);
        assertEq(dust, 0, "dust cleared once the threshold is crossed");
        assertEq(activating, 12 ether, "dust joins the crossing deposit in the timed lot");
        assertEq(active, 0, "still timed, not yet matured");
    }

    /// @notice Only one unresolved dust lot is allowed per borrower: once dust is pending, a second sub-threshold
    ///         supply reverts instead of accumulating.
    function testRevert_deposit_ontoDust_belowThreshold() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 1 ether); // one dust lot is allowed
        vm.expectRevert(
            abi.encodeWithSelector(CollateralActivationLib.DustNotResolved.selector, 1 ether, 1 ether, 10 ether)
        );
        h.deposit(address(0xB1), 1 ether); // a second sub-threshold supply is not
    }

    /// @notice A deposit onto existing dust that lifts the combined amount to exactly the threshold promotes the
    ///         whole lot — the boundary between the revert above and the ordinary crossing path.
    function test_deposit_ontoDust_atThreshold_promotesWholeLot() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 1 ether);
        h.deposit(address(0xB1), 9 ether); // D + assets == M exactly
        (, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(activating, 10 ether, "whole lot promotes");
        assertEq(dust, 0, "dust folded in");
    }

    /// @notice A sub-threshold deposit is still accepted when the dust bucket is empty, even with an existing
    ///         activating lot — the "at most one unresolved dust lot" rule tracks the dust bucket, not the position
    ///         as a whole.
    function test_deposit_subThreshold_withActivatingLot_createsSingleDustLot() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether); // activating lot
        h.deposit(address(0xB1), 1 ether); // allowed: dust bucket was empty
        (, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(activating, 10 ether);
        assertEq(dust, 1 ether);
    }

    function testRevert_credit_belowMinDepositAmount() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 1 ether;
        h.setConfig(cfg);

        vm.expectRevert(abi.encodeWithSelector(CollateralActivationLib.DepositTooSmall.selector, 1 ether - 1, 1 ether));
        h.deposit(address(0xB1), 1 ether - 1);
    }

    function test_credit_atMinDepositAmount_accepted() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 1 ether;
        h.setConfig(cfg);

        h.deposit(address(0xB1), 1 ether);
        (, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(dust, 1 ether, "an accepted sub-threshold deposit is dust");
        assertEq(activating, 0, "it does not enter the timer");
    }

    function test_credit_zeroMinDepositAmount_disablesFloor() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 0;
        h.setConfig(cfg);

        h.deposit(address(0xB1), 1);
        (,, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(dust, 1, "with no floor a one-wei deposit is accepted as dust");
    }

    function test_instantDeposit_bypassesMinDepositAmount() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 1 ether;
        h.setConfig(cfg);

        h.depositInstant(address(0xB1), 1);
        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(active, 1, "a sub-floor instant deposit is active at once");
        assertEq(activating, 0, "instant deposit skips the timer");
        assertEq(dust, 0, "instant deposit never lands in dust");
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

    /// @notice Even when existing dust plus an instant deposit reaches the threshold exactly, only the trusted
    ///         deposit becomes active; the dust remains dormant.
    function test_instantDeposit_dustPlusDepositAtThreshold_activatesOnlyDeposit() public {
        address borrower = address(0xC2);
        h.setMinActivationAmount(10 ether);
        uint256 dustBefore = 10 ether - 1;
        h.deposit(borrower, dustBefore);

        h.depositInstant(borrower, 1);

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active, 1, "instant deposit is active regardless of the threshold");
        assertEq(activating, 0, "instant deposit skips the timer");
        assertEq(dust, dustBefore, "instant deposit does not activate existing dust");
        assertEq(h.currentInflow(), 0, "instant deposit does not touch the inflow throttle");
    }

    /// @notice Quorum-scan gate: past the base timer, a lot stays activating until the guardian frontier has
    ///         scanned past its unlock; once it does, the lot matures.
    function test_sync_gateHoldsUntilQuorumScansPastUnlock() public {
        vm.warp(1_000_000);
        h.deposit(address(0xD1), 100 ether);
        uint40 depositTime = uint40(block.timestamp);
        // Derive the post-warp timestamp from `depositTime` instead of re-reading `block.timestamp` after the warp.
        // Under --via-ir the optimizer caches the TIMESTAMP opcode within this frame, so a second read folds back to
        // the pre-warp value (vm.warp mutates block.timestamp mid-frame, which never happens on real EVM).
        uint40 scannedPastUnlock = depositTime + 2 hours; // past the base unlock (cap 1 hour)
        vm.warp(scannedPastUnlock);

        // Frontier still behind the unlock: the gate holds the lot.
        h.syncWithQuorum(address(0xD1), depositTime - 1);
        (uint256 active, uint256 activating,) = h.bucketsOf(address(0xD1));
        assertEq(active, 0, "gate holds: quorum has not scanned past the unlock");
        assertEq(activating, 100 ether, "still activating");

        // Frontier scans past the unlock: the lot matures.
        h.syncWithQuorum(address(0xD1), scannedPastUnlock);
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

    /// @dev Setting the min activation delay within bounds updates the stored floor.
    function test_setMinActivationDelay_updatesFloor() public {
        h.setMinActivationDelay(30 minutes);
        (uint40 minActivationDelay,) = h.delays();
        assertEq(minActivationDelay, 30 minutes, "floor updated");
    }

    /// @dev Setting the max activation delay within bounds updates the stored cap.
    function test_setMaxActivationDelay_updatesCap() public {
        h.setMaxActivationDelay(2 hours);
        (, uint40 maxActivationDelay) = h.delays();
        assertEq(maxActivationDelay, 2 hours, "cap updated");
    }

    /// @dev A zero min activation delay reverts ZeroMinActivationDelay.
    function testRevert_setMinActivationDelay_zero() public {
        vm.expectRevert(CollateralActivationLib.ZeroMinActivationDelay.selector);
        h.setMinActivationDelay(0);
    }

    /// @dev A min activation delay above the current max cap reverts InvalidActivationDelays.
    function testRevert_setMinActivationDelay_aboveCap() public {
        vm.expectRevert(CollateralActivationLib.InvalidActivationDelays.selector);
        h.setMinActivationDelay(2 hours);
    }

    /// @dev A max activation delay below the current min floor reverts InvalidActivationDelays.
    function testRevert_setMaxActivationDelay_belowFloor() public {
        vm.expectRevert(CollateralActivationLib.InvalidActivationDelays.selector);
        h.setMaxActivationDelay(30 seconds);
    }

    /// @dev A max activation delay above the hard MAX_DELAY_DURATION bound reverts MaxActivationDelayExceeded.
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

    /// @dev The hard MAX_DELAY_DURATION boundary itself is accepted.
    function test_setMaxGuardiansQuorumDelay_atBound() public {
        h.setMaxGuardiansQuorumDelay(7 days);
        assertEq(h.maxGuardiansQuorumDelay(), 7 days, "quorum fallback stored at the upper bound");
    }

    /// @dev A quorum-fallback delay above the hard MAX_DELAY_DURATION bound reverts.
    function testRevert_setMaxGuardiansQuorumDelay_aboveBound() public {
        vm.expectRevert(CollateralActivationLib.MaxGuardiansQuorumDelayExceeded.selector);
        h.setMaxGuardiansQuorumDelay(7 days + 1);
    }

    /// @notice Inactive collateral (`dust + activating`) leaves all-or-nothing: a voluntary withdrawal that would
    ///         remove only part of it reverts instead of draining partially.
    function testRevert_withdraw_partialInactive() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether); // A = 10
        vm.expectRevert(
            abi.encodeWithSelector(CollateralActivationLib.InactiveCollateralNotCleared.selector, 5 ether, 10 ether)
        );
        h.withdraw(address(0xB1), 5 ether);
    }

    /// @notice A withdrawal covering the whole inactive balance (`dust + activating`) clears both buckets and the
    ///         timer, and reverses the activating portion's same-tx inflow contribution.
    function test_withdraw_fullInactive_clearsBucketsTimerAndInflow() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether); // A = 10
        h.deposit(address(0xB1), 1 ether); // D = 1 (allowed from empty dust)
        uint256 inflowBefore = h.currentInflow();

        vm.expectEmit(address(h));
        emit CollateralActivationLib.CollateralDrained(
            address(0xB1),
            11 ether, // the full inactive balance (dust + activating), not just the activating portion
            CollateralActivationLib.Position({dust: 0, activating: 0, activatingStart: 0, activatingDelay: 0})
        );
        h.withdraw(address(0xB1), 11 ether); // exactly D + A

        (, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(activating + dust, 0, "inactive cleared");
        assertEq(h.currentInflow(), inflowBefore - 10 ether, "same-tx activating contribution reversed");

        GuardiansOpinion memory opinion;
        assertEq(h.getUnlockTime(address(0xB1), opinion), 0, "timer stopped on the full clear");
    }

    /// @notice With no inactive balance (`dust + activating == 0`), a voluntary withdrawal is unrestricted by
    ///         activation — it is a plain draw against active collateral.
    function test_withdraw_activeOnly_isUnrestricted() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        h.sync(address(0xB1), 0); // matured: active = 10, D + A = 0
        h.withdraw(address(0xB1), 4 ether); // no inactive — nothing to clear
        (uint256 active,,) = h.bucketsOf(address(0xB1));
        assertEq(active, 6 ether, "active-only withdrawal draws down active, untouched by activation");
    }

    /// @notice The mixed shape `amount > inactive > 0`: a withdrawal larger than the inactive balance clears
    ///         dust (there is no activating lot here) in full, then takes the remainder out of active. The
    ///         clearing path takes precedence over the active-only one, so a request covering the inactive
    ///         balance ejects it even when it would also fit within active.
    function test_withdraw_amountAboveInactive_clearsInactiveThenDrawsFromActive() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether); // A = 10
        vm.warp(block.timestamp + 1 hours + 1);
        h.sync(address(0xB1), 0); // matured: active = 10, D + A = 0
        h.deposit(address(0xB1), 1 ether); // fresh dust: D = 1 (allowed from empty dust)

        h.withdraw(address(0xB1), 5 ether); // covers the 1 dust, remainder 4 comes from active

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(dust, 0, "dust cleared in full");
        assertEq(activating, 0, "no activating lot in this shape");
        assertEq(active, 6 ether, "remainder drawn from active");
    }

    /// @notice While the activating lock is in force, a voluntary withdrawal beyond the active balance reverts —
    ///         and with no matured active collateral, that is any withdrawal at all.
    function testRevert_withdraw_lockedActivating_blocksClearing() public {
        h.setConfig(_lockCfg());
        h.deposit(address(0xB1), 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralActivationLib.ActivatingCollateralLocked.selector, 10 ether, block.timestamp + 1 days
            )
        );
        h.withdraw(address(0xB1), 10 ether);
    }

    /// @notice The lock binds only the inactive buckets: a withdrawal within the matured active balance passes
    ///         while the lock is in force, leaving the buckets, the timer, and the lot's same-tx inflow untouched.
    function test_withdraw_activeWithinLock_ignoresLock() public {
        h.setConfig(_lockCfg());
        address borrower = address(0xB1);

        h.deposit(borrower, 10 ether);
        vm.warp(block.timestamp + 1 days); // past the 1-hour delay cap and the 1-day lock
        h.sync(borrower, 0); // matured: active = 10

        h.deposit(borrower, 10 ether); // fresh lot, locked for 1 day from now
        uint256 inflowBefore = h.currentInflow();
        assertGt(inflowBefore, 0, "fresh lot bumps the inflow");

        h.withdraw(borrower, 4 ether); // within active, during the lock

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active, 6 ether, "drawn from active only");
        assertEq(activating, 10 ether, "locked lot untouched");
        assertEq(dust, 0, "no dust in this shape");
        assertEq(h.currentInflow(), inflowBefore, "active-only withdrawal reverses no inflow");

        GuardiansOpinion memory opinion;
        assertGt(h.getUnlockTime(borrower, opinion), 0, "timer keeps running");
    }

    /// @notice The boundary of the active-only path during the lock: exactly the active balance passes, one wei
    ///         beyond it dips into the locked lot and reverts.
    function testRevert_withdraw_lockedBeyondActive() public {
        h.setConfig(_lockCfg());
        address borrower = address(0xB1);

        h.deposit(borrower, 10 ether);
        vm.warp(block.timestamp + 1 days);
        h.sync(borrower, 0); // matured: active = 10
        h.deposit(borrower, 10 ether); // fresh lot, locked

        h.withdraw(borrower, 10 ether); // exactly the active balance: passes
        (uint256 active, uint256 activating,) = h.bucketsOf(borrower);
        assertEq(active, 0, "active fully drawn");
        assertEq(activating, 10 ether, "locked lot untouched");

        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralActivationLib.ActivatingCollateralLocked.selector, 10 ether, block.timestamp + 1 days
            )
        );
        h.withdraw(borrower, 1); // one wei into the locked lot
    }

    /// @notice Unlocked but below the inactive balance: a withdrawal that fits within active passes and leaves
    ///         the maturing lot untouched — the shape that reverted `InactiveCollateralNotCleared` before the
    ///         lock was narrowed to the inactive buckets.
    function test_withdraw_belowInactiveWithinActive_leavesBucketsUntouched() public {
        h.setMinActivationAmount(10 ether); // default config: lock disabled
        address borrower = address(0xB1);

        h.deposit(borrower, 10 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        h.sync(borrower, 0); // matured: active = 10
        h.deposit(borrower, 20 ether); // fresh maturing lot: inactive = 20 > active

        h.withdraw(borrower, 5 ether); // < inactive, but within active

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active, 5 ether, "drawn from active only");
        assertEq(activating, 20 ether, "maturing lot untouched");
        assertEq(dust, 0);
    }

    /// @notice The lock binds only while an activating lot exists: a dust-only position clears in full even
    ///         inside what would be the lock window, since dust never starts the timer.
    function test_withdraw_dustOnly_unaffectedByLockWindow() public {
        h.setConfig(_lockCfg());
        address borrower = address(0xB1);

        h.deposit(borrower, 1 ether); // sub-threshold: dust, no timer, nothing to lock
        h.withdraw(borrower, 1 ether); // same tx: clears

        (, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(activating + dust, 0, "dust cleared with no lock in the way");
    }

    /// @notice Once the activating lock's own window elapses, the lot can be cleared like any other inactive
    ///         balance — the lot need not have matured, only the lock's duration must have passed.
    function test_withdraw_afterLockExpiry_clearsInactive() public {
        h.setConfig(_lockCfg());
        h.deposit(address(0xB1), 10 ether);
        vm.warp(block.timestamp + 1 days); // lock window over (timer need not have matured)
        h.withdraw(address(0xB1), 10 ether);
        (, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(activating + dust, 0, "inactive cleared once the lock window has passed");
    }

    /// @notice A zero `activatingLockDuration` disables the lock outright: its deadline is the lot's own start,
    ///         so the lock never binds, not even in the same transaction the lot was opened in.
    function test_withdraw_zeroLockDuration_allowsImmediateSameTxClear() public {
        CollateralActivationConfig memory cfg = _lockCfg();
        cfg.activatingLockDuration = 0;
        h.setConfig(cfg);

        h.deposit(address(0xB1), 10 ether);
        h.withdraw(address(0xB1), 10 ether); // same transaction as the deposit above; must not revert

        (, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(activating + dust, 0, "lock disabled at zero duration: full clear succeeds immediately");
    }

    /// @dev Shared config for the activating-lock tests above: the nonzero `activatingLockDuration` blocks
    ///      clearing the whole lot until it elapses.
    function _lockCfg() internal pure returns (CollateralActivationConfig memory) {
        return CollateralActivationConfig({
            minActivationDelay: 1 minutes,
            maxActivationDelay: 1 hours,
            activatingLockDuration: 1 days,
            maxDelayInflow: 10_000 ether,
            minActivationAmount: 10 ether,
            minDepositAmount: 0,
            maxGuardiansQuorumDelay: 0,
            delayPerStrike: 0,
            delayPerSuspect: 0
        });
    }

    // ── ACT-04: full-clear withdrawal reverses the same-tx inflow of the cleared activating lot ──

    /// @notice Demotion is gone, but the inflow-reversal guarantee it protected still holds: a borrower can
    ///         freely cycle deposit(M) -> withdraw(M) many times in one tx — the only voluntary withdrawal an
    ///         un-matured lot admits — without the throttle accumulating a phantom balance across cycles. Each
    ///         cycle's same-tx contribution is fully reversed by the all-or-nothing clear, so the accumulator
    ///         returns to its pre-cycle baseline every time, never climbing toward the cap.
    function test_debit_repeatedFullClearCycles_noInflowAccumulation() public {
        uint128 m = 1_000 ether; // 11 pre-fix cycles would have reached the 10_000 ether cap
        h.setMinActivationAmount(m);
        address borrower = address(0xC04C);

        for (uint256 i = 0; i < 15; ++i) {
            h.deposit(borrower, m);
            h.withdraw(borrower, m); // all-or-nothing: the whole freshly-deposited lot, same tx
            assertEq(h.currentInflow(), 0, "no phantom accumulates across cycles");
        }

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active + activating + dust, 0, "position empty after all cycles");
        assertEq(h.currentInflow(), 0, "throttle stays at zero, never climbs toward maxDelayInflow");
    }

    /// @notice Invariant: once a position is fully emptied in the same tx it added its inflow, nothing of that
    ///         contribution remains in the throttle. All-or-nothing means the only voluntary withdrawal an
    ///         un-matured lot admits IS the full-emptying one, for any threshold and deposit size.
    function testFuzz_debit_emptyPositionHasNoResidualInflow(uint128 minAmount, uint256 depositAmount) public {
        minAmount = uint128(bound(minAmount, 1, 1_000 ether));
        depositAmount = bound(depositAmount, minAmount, 100_000 ether); // crosses the threshold
        h.setMinActivationAmount(minAmount);
        address borrower = address(0xF04C);

        h.deposit(borrower, depositAmount);
        h.withdraw(borrower, depositAmount); // all-or-nothing: the whole lot, in the same tx it was deposited

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active + activating + dust, 0, "position emptied");
        assertEq(h.currentInflow(), 0, "an emptied position leaves no reversible same-tx inflow behind");
    }

    // ── ACT-05: forced seizure reverses the same-tx inflow of the seized activating collateral ──

    /// @notice A forced seizure in the same tx as the deposit reverses its inflow, just as a voluntary withdrawal
    ///         does. Both forced entry points — liquidation and settlement — route the seized collateral through
    ///         `seize`, so this is the shared reversal both rely on. Pre-fix `seize` left the inflow stale.
    function test_seize_reversesSameTxInflow() public {
        h.setMinActivationAmount(1 ether);
        address borrower = address(0xAC05);

        h.deposit(borrower, 10 ether); // crosses -> activating = 10, inflow = 10
        assertEq(h.currentInflow(), 10 ether, "deposit bumps inflow");

        h.seize(borrower, 10 ether); // forced full seizure (liquidation / self-settlement)
        assertEq(h.currentInflow(), 0, "seizure reverses the full same-tx inflow, no stale amount left");
    }

    /// @notice A seizure that removes only part of the fresh activating collateral reverses inflow proportionally,
    ///         leaving the inflow matched to the activating that survives.
    function test_seize_partialActivating_reversesProportionally() public {
        h.setMinActivationAmount(1 ether);
        address borrower = address(0xAC5A);

        h.deposit(borrower, 10 ether); // activating = 10, inflow = 10
        h.seize(borrower, 4 ether); // drains 4 activating

        (, uint256 activating,) = h.bucketsOf(borrower);
        assertEq(activating, 6 ether, "partial seizure leaves the remainder activating");
        assertEq(h.currentInflow(), 6 ether, "inflow reversed by exactly the seized activating (10 - 4)");
    }

    /// @notice A seizure with no matured active collateral waterfalls dust first, then activating (the
    ///         active-first order coincides with the old dust-then-activating order here, since active is
    ///         zero). Only the activating it drains carries throttle inflow, so the reversal counts that
    ///         alone — the dust it consumes moves no inflow.
    function test_seize_noActive_drainsDustThenActivating() public {
        h.setMinActivationAmount(1 ether);
        address borrower = address(0xAC5D);

        h.deposit(borrower, 10 ether); // activating = 10, inflow = 10
        h.deposit(borrower, 0.5 ether); // sub-threshold -> dust = 0.5, inflow unchanged
        assertEq(h.currentInflow(), 10 ether, "dust top-up does not bump inflow");

        h.seize(borrower, 3 ether); // drains 0.5 dust, then 2.5 activating
        (, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(dust, 0, "dust drained first");
        assertEq(activating, 7.5 ether, "then 2.5 of activating drained");
        assertEq(h.currentInflow(), 7.5 ether, "inflow reversed by the 2.5 activating only, not the 0.5 dust");
    }

    /// @notice Reconciliation at the `maxDelayInflow` cap: a deposit above the cap records only the capped inflow
    ///         it actually applied, so seizing it back reverses the whole applied amount to zero (the decrement
    ///         clamps to the same-tx contribution).
    function test_seize_reconciliationAtMaxDelayInflow() public {
        h.setMinActivationAmount(1 ether);
        address borrower = address(0xAC5C);

        h.deposit(borrower, 15_000 ether); // activating = 15_000, inflow caps at 10_000 (maxDelayInflow)
        assertEq(h.currentInflow(), 10_000 ether, "inflow saturates at the cap");

        h.seize(borrower, 15_000 ether); // full seizure
        assertEq(h.currentInflow(), 0, "the capped same-tx contribution is fully reversed");
    }

    /// @notice Invariant: seizing a borrower's entire fresh activating in the same tx it was deposited leaves no
    ///         residual inflow, for any threshold and deposit size.
    function testFuzz_seize_fullSeizureLeavesNoResidualInflow(uint128 minAmount, uint256 depositAmount) public {
        minAmount = uint128(bound(minAmount, 1, 1_000 ether));
        depositAmount = bound(depositAmount, minAmount, 100_000 ether); // crosses the threshold
        h.setMinActivationAmount(minAmount);
        address borrower = address(0xF05C);

        h.deposit(borrower, depositAmount);
        h.seize(borrower, depositAmount); // forced full seizure in the same tx
        assertEq(h.currentInflow(), 0, "full same-tx seizure leaves no residual inflow");
    }

    // ── seize: active-first waterfall, no demotion, residual keeps its timer ──

    /// @notice A seizure covered entirely by matured active collateral never touches the un-matured buckets.
    function test_seize_consumesActiveBeforeBuckets() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        h.sync(address(0xB1), 0); // matured: active = 10
        h.deposit(address(0xB1), 10 ether); // fresh lot: A = 10
        h.deposit(address(0xB1), 1 ether); // dust: D = 1

        h.seize(address(0xB1), 10 ether); // covered entirely by active

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(active, 0, "active consumed first");
        assertEq(activating, 10 ether, "activating untouched");
        assertEq(dust, 1 ether, "dust untouched");
    }

    /// @notice Once active is exhausted, a seizure spills into dust before activating.
    function test_seize_spilloverOrder_dustThenActivating() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        h.sync(address(0xB1), 0); // active = 10
        h.deposit(address(0xB1), 10 ether); // A = 10
        h.deposit(address(0xB1), 1 ether); // D = 1

        h.seize(address(0xB1), 13 ether); // 10 active + 1 dust + 2 activating

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(active, 0);
        assertEq(dust, 0, "dust drained before activating");
        assertEq(activating, 8 ether, "activating covers the tail");
    }

    /// @notice A seizure that leaves a sub-threshold activating remainder no longer demotes it to dust: the
    ///         remainder stays activating and matures on its original timer.
    function test_seize_residualActivatingKeepsTimer() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether); // A = 10, timer quoted now

        h.seize(address(0xB1), 9 ether); // residual A = 1 < minActivationAmount

        (, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(activating, 1 ether, "residual stays activating - no demotion");
        assertEq(dust, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 active = h.sync(address(0xB1), 0);
        assertEq(active, 1 ether, "residual matures on its original timer");
    }

    /// @notice A seizure that empties the activating lot entirely clears its timer, so a later deposit starts a
    ///         fresh one rather than inheriting the cleared lot's stale start.
    function test_seize_fullActivating_clearsTimer() public {
        h.setMinActivationAmount(10 ether);
        h.deposit(address(0xB1), 10 ether);
        h.seize(address(0xB1), 10 ether);
        (, uint256 activating,) = h.bucketsOf(address(0xB1));
        assertEq(activating, 0);
        // a fresh deposit must start a fresh timer, not inherit a stale one
        h.deposit(address(0xB1), 10 ether);
        (, uint256 activatingAfter,) = h.bucketsOf(address(0xB1));
        assertEq(activatingAfter, 10 ether);
    }

    /// @notice Fuzzed waterfall model: a seizure of any size consumes active, then dust, then activating, in
    ///         that order, matching a hand-computed reference split.
    function testFuzz_seize_matchesWaterfallModel(uint256 activeSeed, uint256 seizeSeed) public {
        h.setMinActivationAmount(10 ether);
        uint256 active = bound(activeSeed, 10 ether, 100 ether);
        h.deposit(address(0xB1), active);
        vm.warp(block.timestamp + 1 hours + 1);
        h.sync(address(0xB1), 0);
        h.deposit(address(0xB1), 20 ether); // A = 20
        h.deposit(address(0xB1), 3 ether); // D = 3

        uint256 amount = bound(seizeSeed, 1, active + 23 ether);
        h.seize(address(0xB1), amount);

        uint256 fromActive = Math.min(active, amount);
        uint256 fromDust = Math.min(3 ether, amount - fromActive);
        uint256 fromActivating = amount - fromActive - fromDust;
        (uint256 gotActive, uint256 gotActivating, uint256 gotDust) = h.bucketsOf(address(0xB1));
        assertEq(gotActive, active - fromActive);
        assertEq(gotDust, 3 ether - fromDust);
        assertEq(gotActivating, 20 ether - fromActivating);
    }

    // ── ACT-06: post-cap attribution no longer erases activation inflow ──

    /// @notice The two-borrower exploit, temp filling the cap BEFORE the permanent deposit. A temporary borrower
    ///         fills the accumulator to the cap, a permanent borrower deposits on top (recorded, not dropped to a
    ///         post-cap zero), then the temp borrower withdraws in the same tx. Pre-fix the temp leg carried the
    ///         whole cap and drove the accumulator to zero; post-fix the accumulator tracks gross net, so it stays
    ///         at the permanent borrower's still-activating volume.
    function test_capFilling_tempBeforePermanent_withdrawKeepsInflow() public {
        uint256 cap = 10_000 ether; // maxDelayInflow from setUp
        h.setMinActivationAmount(1 ether);
        address temp = address(0xA6A);
        address perm = address(0xA6B);

        h.deposit(temp, cap); // fills the accumulator to the cap
        assertEq(h.currentInflow(), cap, "temp fills the cap");

        h.deposit(perm, cap); // on top of a full cap — must still be recorded as gross
        assertEq(h.currentInflow(), cap, "still capped, but the perm volume is now tracked");

        h.withdraw(temp, cap); // temp exits in the same tx
        assertEq(h.currentInflow(), cap, "accumulator holds the perm borrower's still-activating volume");
    }

    /// @notice Same exploit, temp filling the cap AFTER the permanent deposit. Order does not matter: the temp
    ///         leg only reverses its own gross contribution, so the permanent volume survives.
    function test_capFilling_tempAfterPermanent_withdrawKeepsInflow() public {
        uint256 cap = 10_000 ether;
        h.setMinActivationAmount(1 ether);
        address perm = address(0xA6C);
        address temp = address(0xA6D);

        h.deposit(perm, cap);
        h.deposit(temp, cap); // pushes gross to 2*cap, stored inflow stays capped
        assertEq(h.currentInflow(), cap, "capped");

        h.withdraw(temp, cap);
        assertEq(h.currentInflow(), cap, "perm volume preserved regardless of order");
    }

    /// @notice Several borrowers whose combined gross contribution exceeds the cap. As they exit one by one, the
    ///         accumulator tracks the surviving gross, never collapsing to zero while activating volume remains.
    function test_multipleBorrowers_grossExceedsCap_reversalTracksRemainder() public {
        uint256 cap = 10_000 ether;
        h.setMinActivationAmount(1 ether);
        address b1 = address(0xB61);
        address b2 = address(0xB62);
        address b3 = address(0xB63);

        h.deposit(b1, 5_000 ether);
        h.deposit(b2, 5_000 ether);
        h.deposit(b3, 5_000 ether); // gross 15_000 > cap 10_000
        assertEq(h.currentInflow(), cap, "capped at 10_000 with 15_000 gross");

        h.withdraw(b1, 5_000 ether); // gross net 10_000
        assertEq(h.currentInflow(), cap, "still 10_000 gross remaining");

        h.withdraw(b2, 5_000 ether); // gross net 5_000
        assertEq(h.currentInflow(), 5_000 ether, "tracks b3's surviving 5_000, not zero");
    }

    /// @notice A single-tx mix of every activation mutation — credit, voluntary debit, and forced seizure
    ///         (liquidation / settlement) — keeps the invariant `storedInflow == min(cap, baseline + net)` at
    ///         every step. Here baseline is 0 (fresh, first mutation), so it reduces to `min(cap, gross net)`.
    function test_mixedOps_maintainInvariant() public {
        uint256 cap = 10_000 ether;
        h.setMinActivationAmount(1 ether);
        address a = address(0x6A);
        address b = address(0x6B);
        address c = address(0x6C);

        h.deposit(a, 6_000 ether); // net 6_000
        assertEq(h.currentInflow(), 6_000 ether, "credit A");

        h.deposit(b, 6_000 ether); // net 12_000 -> capped
        assertEq(h.currentInflow(), cap, "credit B crosses the cap");

        h.withdraw(a, 6_000 ether); // voluntary debit, full: net 6_000
        assertEq(h.currentInflow(), 6_000 ether, "debit A reverses only A's gross, B's survives");

        h.deposit(c, 3_000 ether); // net 9_000
        assertEq(h.currentInflow(), 9_000 ether, "credit C");

        h.seize(c, 3_000 ether); // forced seizure (settlement/liquidation), full: net 6_000
        assertEq(h.currentInflow(), 6_000 ether, "seize C reverses C's gross");

        h.withdraw(b, 6_000 ether); // all-or-nothing: B's whole activating lot; net 0
        assertEq(h.currentInflow(), 0, "full clearance reverses the whole withdrawal, accumulator empty");
    }

    /// @notice The per-tx inflow invariant holds across FUZZED configs (cap and threshold), not just the default:
    ///         a two-borrower cap-crossing flow always stores `min(cap, gross net)` (baseline 0 on a fresh harness).
    function testFuzz_invariant_acrossConfigs(uint128 cap, uint128 minAct, uint256 depA, uint256 depB) public {
        cap = uint128(bound(cap, 1 ether, 1_000_000 ether));
        minAct = uint128(bound(minAct, 1, 1 ether));
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.maxDelayInflow = cap;
        cfg.minActivationAmount = minAct;
        h.setConfig(cfg);

        depA = bound(depA, minAct, 10_000_000 ether);
        depB = bound(depB, minAct, 10_000_000 ether);
        address a = address(0xC01);
        address b = address(0xC02);

        h.deposit(a, depA);
        assertEq(h.currentInflow(), Math.min(uint256(cap), depA), "after A: min(cap, depA)");
        h.deposit(b, depB);
        assertEq(h.currentInflow(), Math.min(uint256(cap), depA + depB), "after B: min(cap, depA + depB)");
        h.seize(a, depA);
        assertEq(h.currentInflow(), Math.min(uint256(cap), depB), "after A removed: min(cap, depB)");
    }

    /// @notice Invariant `storedInflow == min(cap, baseline + netTxActivating)` for a fuzzed two-borrower flow.
    ///         Baseline is 0 (fresh harness, first mutation this tx), so the stored inflow tracks the capped gross
    ///         net across deposits and a full seizure.
    function testFuzz_invariant_cappedBaselinePlusNet(uint256 depA, uint256 depB) public {
        uint256 cap = 10_000 ether; // maxDelayInflow from setUp
        h.setMinActivationAmount(1 ether);
        depA = bound(depA, 1 ether, 1_000_000 ether);
        depB = bound(depB, 1 ether, 1_000_000 ether);
        address a = address(0xF6A);
        address b = address(0xF6B);

        h.deposit(a, depA);
        assertEq(h.currentInflow(), Math.min(cap, depA), "after A: min(cap, depA)");

        h.deposit(b, depB);
        assertEq(h.currentInflow(), Math.min(cap, depA + depB), "after B: min(cap, depA + depB)");

        h.seize(a, depA); // full seizure of A -> net = depB
        assertEq(h.currentInflow(), Math.min(cap, depB), "after A removed: min(cap, depB)");
    }

    /// @notice Governance lowers `maxDelayInflow` below the standing accumulator. The next activation mutation
    ///         snapshots a baseline that exceeds the new cap, so the stored inflow must clamp to the cap instead
    ///         of underflowing.
    function test_capLoweredBelowBaseline_clampsWithoutUnderflow() public {
        h.primeInflow(10_000 ether); // prior-tx accumulator at the old cap
        assertEq(h.currentInflow(), 10_000 ether, "primed to the old cap");

        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.maxDelayInflow = 5_000 ether; // governance cut, below the standing accumulator
        h.setConfig(cfg);

        // baseline snapshot = 10_000 > cap 5_000 -> must clamp to 5_000 without reverting on underflow.
        h.deposit(address(0xCA9), 1 ether);
        assertEq(h.currentInflow(), 5_000 ether, "clamped to the new cap, no underflow");
    }

    // ── setConfig bound reverts not reached by the single-field setter helpers ──

    /// @dev A valid config to mutate one field at a time. Mirrors `setUp`.
    function _baseConfig() internal pure returns (CollateralActivationConfig memory) {
        return CollateralActivationConfig({
            minActivationDelay: 1 minutes,
            maxActivationDelay: 1 hours,
            activatingLockDuration: 0,
            maxDelayInflow: 10_000 ether,
            minActivationAmount: 1,
            minDepositAmount: 0,
            maxGuardiansQuorumDelay: 1 days,
            delayPerStrike: 1 hours,
            delayPerSuspect: 30 minutes
        });
    }

    /// @dev A config whose activatingLockDuration exceeds the bound reverts MaxActivatingLockDurationExceeded.
    function testRevert_setConfig_activatingLockDurationAboveBound() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.activatingLockDuration = uint40(7 days + 1);
        vm.expectRevert(CollateralActivationLib.MaxActivatingLockDurationExceeded.selector);
        h.setConfig(cfg);
    }

    /// @dev A config with a zero minActivationAmount reverts ZeroMinActivationAmount.
    function testRevert_setConfig_zeroMinActivationAmount() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.minActivationAmount = 0;
        vm.expectRevert(CollateralActivationLib.ZeroMinActivationAmount.selector);
        h.setConfig(cfg);
    }

    function testRevert_setConfig_minDepositAmountAboveActivationAmount() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 10 ether + 1;
        vm.expectRevert(CollateralActivationLib.InvalidMinDepositAmount.selector);
        h.setConfig(cfg);
    }

    function test_setConfig_minDepositAmountAtActivationAmount() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 10 ether;
        h.setConfig(cfg);

        h.deposit(address(0xB1), 10 ether);
        (, uint256 activating, uint256 dust) = h.bucketsOf(address(0xB1));
        assertEq(activating, 10 ether, "a threshold-sized deposit enters the timer");
        assertEq(dust, 0, "no dust can form at this setting");
    }

    /// @dev A config with a zero maxDelayInflow reverts ZeroMaxDelayInflow.
    function testRevert_setConfig_zeroMaxDelayInflow() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.maxDelayInflow = 0;
        vm.expectRevert(CollateralActivationLib.ZeroMaxDelayInflow.selector);
        h.setConfig(cfg);
    }

    /// @dev A config whose delayPerStrike exceeds the bound reverts MaxDelayPerStrikeExceeded.
    function testRevert_setConfig_delayPerStrikeAboveBound() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.delayPerStrike = uint40(7 days + 1);
        vm.expectRevert(CollateralActivationLib.MaxDelayPerStrikeExceeded.selector);
        h.setConfig(cfg);
    }

    /// @dev A config whose delayPerSuspect exceeds the bound reverts MaxDelayPerSuspectExceeded.
    function testRevert_setConfig_delayPerSuspectAboveBound() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.delayPerSuspect = uint40(7 days + 1);
        vm.expectRevert(CollateralActivationLib.MaxDelayPerSuspectExceeded.selector);
        h.setConfig(cfg);
    }

    // ── _getUnlockTime branches ──

    /// @dev A banned borrower's unlock time is uint256 max, so the lot can never mature.
    function test_getUnlockTime_bannedNeverUnlocks() public {
        address borrower = address(0xBEEF);
        h.deposit(borrower, 5 ether);
        GuardiansOpinion memory op = GuardiansOpinion({
            banned: true, strikeCount: 0, suspectCount: 0, suspectExpiryTimestamp: 0, quorumFrontierTimestamp: 0
        });
        assertEq(h.getUnlockTime(borrower, op), type(uint256).max, "banned borrower never unlocks");
    }

    /// @dev The suspect surcharge (suspectCount * delayPerSuspect) applies only when the lot started before the
    ///      suspect expiry; a zero expiry adds no surcharge.
    function test_getUnlockTime_suspectSurchargeWhenLotBeforeExpiry() public {
        address borrower = address(0xBEEF);
        h.deposit(borrower, 5 ether); // activatingStart = now

        // suspectExpiry = 0: the lot's start is not before it, so no surcharge.
        GuardiansOpinion memory noSurcharge = GuardiansOpinion({
            banned: false, strikeCount: 0, suspectCount: 2, suspectExpiryTimestamp: 0, quorumFrontierTimestamp: 0
        });
        // future expiry: the lot started before it, so the suspect surcharge applies.
        GuardiansOpinion memory surcharge = GuardiansOpinion({
            banned: false,
            strikeCount: 0,
            suspectCount: 2,
            suspectExpiryTimestamp: block.timestamp + 1 hours,
            quorumFrontierTimestamp: 0
        });

        assertEq(
            h.getUnlockTime(borrower, surcharge) - h.getUnlockTime(borrower, noSurcharge),
            2 * 30 minutes,
            "surcharge = suspectCount * delayPerSuspect when the lot started before the suspect expiry"
        );
    }

    function test_drain_noopEmitsNothing() public {
        address borrower = address(0xD1);
        h.depositInstant(borrower, 100 ether); // active collateral, no un-matured buckets to drain

        vm.recordLogs();
        h.seize(borrower, 50 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != CollateralActivationLib.CollateralDrained.selector,
                "no CollateralDrained on a no-op drain"
            );
        }
    }

    function test_drain_emitsDrainedAmount() public {
        address borrower = address(0xD2);
        h.deposit(borrower, 100 ether); // activating bucket

        vm.recordLogs();
        h.seize(borrower, 30 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == CollateralActivationLib.CollateralDrained.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), borrower, "borrower topic");
                (uint256 amount,) = abi.decode(logs[i].data, (uint256, CollateralActivationLib.Position));
                assertEq(amount, 30 ether, "drained amount carried by the event");
                found++;
            }
        }
        assertEq(found, 1, "exactly one CollateralDrained");
    }
}

/// @notice ACT-06 clamp, checked across a real transaction boundary and independently of the library's `net`
///         arithmetic: a borrower's prior-tx activating collateral is committed in `setUp` (a separate tx), so
///         in the test tx only the fresh contribution is reversible. Over-withdrawing (past the fresh amount,
///         into the prior lot) must reverse ONLY the same-tx contribution — the prior inflow is untouched (it
///         decays, never reverses). Expected is computed directly (the pre-fresh baseline), not via `net`.
contract ActivationInflowCrossTxTest is Test {
    ActivationHarness internal h;
    address internal constant B = address(0xB0B);

    function setUp() public {
        h = new ActivationHarness();
        h.setConfig(
            CollateralActivationConfig({
                minActivationDelay: 1 minutes,
                maxActivationDelay: 1 hours,
                activatingLockDuration: 0,
                maxDelayInflow: 10_000 ether,
                minActivationAmount: 1 ether,
                minDepositAmount: 0,
                maxGuardiansQuorumDelay: 0,
                delayPerStrike: 0,
                delayPerSuspect: 0
            })
        );
        h.deposit(B, 100 ether); // prior tx: activating 100, inflow 100
    }

    function test_overWithdraw_reversesOnlyThisTxContribution() public {
        uint256 priorInflow = h.currentInflow(); // no warp -> undecayed prior-tx inflow
        assertEq(priorInflow, 100 ether, "prior-tx inflow present");

        h.deposit(B, 50 ether); // this tx: activating 150, contribution[B] = 50
        assertEq(h.currentInflow(), 150 ether, "this-tx deposit raised inflow");

        // All-or-nothing: the withdrawal must clear the whole 150 (prior 100 + this-tx 50) — there is no
        // matured collateral to draw down instead. It still "over-withdraws" relative to this tx's OWN 50
        // contribution, draining all 100 of the prior lot too, but only the 50 same-tx contribution is
        // reversible. The prior 100 stays (decays, never reverses).
        h.withdraw(B, 150 ether);
        assertEq(h.currentInflow(), priorInflow, "over-withdraw reversed only the same-tx contribution");
    }
}
