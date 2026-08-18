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

    function setMinActivationDelay(uint32 minDelay) external {
        CollateralActivationConfig memory cfg = $.config;
        cfg.minActivationDelay = minDelay;
        $.setConfig(cfg);
    }

    function setMaxActivationDelay(uint32 maxDelay) external {
        CollateralActivationConfig memory cfg = $.config;
        cfg.maxActivationDelay = maxDelay;
        $.setConfig(cfg);
    }

    function setMinActivationAmount(uint128 amount) external {
        CollateralActivationConfig memory cfg = $.config;
        cfg.minActivationAmount = amount;
        $.setConfig(cfg);
    }

    function setMaxGuardiansQuorumDelay(uint32 quorumDelay) external {
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

    /// @dev Forced seizure path ($.seize): drains with no lock floor and runs the same-tx inflow undo.
    function seize(address borrower, uint256 amount) external returns (uint256) {
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
                activatingLockAmount: 0,
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

    /// @notice A flash-loaned deposit cannot inflate the throttle. The deposit bumps the inflow, but withdrawing
    ///         it in the same tx undoes that bump. The withdrawal leaves a sub-threshold remainder, which is
    ///         demoted to dust; dust is off the throttle, so its inflow is reversed too (ACT-04) and the throttle
    ///         returns to zero even though the dust collateral stays behind — dust is not borrowable, so it need
    ///         not be throttled.
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

        // The drain leaves 0.5 ether activating, which is demoted to dust; demoted collateral leaves the throttle,
        // so its inflow is reversed alongside the drained amount and the throttle falls to zero.
        assertEq(h.currentInflow(), 0, "same-tx undo reverses all inflow, including the demoted remainder");

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(attacker);
        assertEq(active, 0, "no matured collateral");
        assertEq(activating, 0, "remainder demoted out of activating");
        assertEq(dust, 0.5 ether, "the sub-threshold remainder stays as dust, carrying no throttle inflow");
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

    /// @notice A withdrawal that drains an activating lot below the threshold folds the remainder into dust: it
    ///         leaves the timer, so it never matures and stays off the guardian scan, and only a fresh crossing
    ///         deposit re-throttles it. The inactive total is unchanged, so `active` is too.
    function test_withdraw_demotesSubThresholdActivatingToDust() public {
        h.setMinActivationAmount(1 ether);
        address borrower = address(0xDE);

        h.deposit(borrower, 10 ether);
        (, uint256 activating0, uint256 dust0) = h.bucketsOf(borrower);
        assertEq(activating0, 10 ether, "deposit enters activating");
        assertEq(dust0, 0, "no dust");

        // Drain to 0.5 ether activating (< 1 ether threshold): the remainder is demoted to dust.
        h.withdraw(borrower, 9.5 ether);
        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(activating, 0, "sub-threshold remainder no longer activating");
        assertEq(dust, 0.5 ether, "remainder folded into dust");
        assertEq(active, 0, "dust is not active");

        // Off the timer: even past the unlock, sync leaves it dust — it never matures.
        vm.warp(block.timestamp + 2 hours);
        h.sync(borrower, 0);
        (uint256 activeAfter,, uint256 dustAfter) = h.bucketsOf(borrower);
        assertEq(activeAfter, 0, "demoted collateral never matures");
        assertEq(dustAfter, 0.5 ether, "still dust");
    }

    /// @notice A withdrawal that leaves the activating lot at or above the threshold keeps it activating — it
    ///         still matures on its timer.
    function test_withdraw_atThresholdStaysActivating() public {
        h.setMinActivationAmount(1 ether);
        address borrower = address(0xDF);

        h.deposit(borrower, 10 ether);
        h.withdraw(borrower, 9 ether); // leaves exactly 1 ether == threshold
        (, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(activating, 1 ether, "at-threshold remainder stays activating");
        assertEq(dust, 0, "not demoted");

        vm.warp(block.timestamp + 2 hours);
        h.sync(borrower, 0);
        (uint256 active,,) = h.bucketsOf(borrower);
        assertEq(active, 1 ether, "at-threshold lot matures on its timer");
    }

    /// @notice With an activating-lock in force, a withdrawal that drains down to the lock floor leaves the locked
    ///         remainder in `activating` — it is NOT demoted into freely-withdrawable dust, which would bypass the
    ///         lock. (Without the lock the identical sub-threshold remainder demotes; see the demote test above.)
    function test_withdraw_doesNotDemoteLockedActivating() public {
        h.setConfig(
            CollateralActivationConfig({
                minActivationDelay: 1 minutes,
                maxActivationDelay: 1 hours,
                activatingLockAmount: 1 ether,
                activatingLockDuration: 1 hours,
                maxDelayInflow: 10_000 ether,
                minActivationAmount: 2 ether, // above the lock, so the lock floor is a sub-threshold remainder
                minDepositAmount: 0,
                maxGuardiansQuorumDelay: 0,
                delayPerStrike: 1 hours,
                delayPerSuspect: 30 minutes
            })
        );
        address borrower = address(0x10C);

        h.deposit(borrower, 10 ether);
        // Drain to the 1 ether lock floor: the 1 ether remainder is sub-threshold (< 2 ether) but LOCKED.
        h.withdraw(borrower, 9 ether);

        (, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(activating, 1 ether, "locked remainder stays activating, not demoted");
        assertEq(dust, 0, "locked remainder not folded into freely-withdrawable dust");
    }

    /// @notice Once a lock expires, a sub-threshold activating remainder is not added to existing dust when their
    ///         sum reaches the threshold. The buckets stay separate instead of forming above-threshold dust.
    function test_withdraw_expiredLock_doesNotCreateAboveThresholdDust() public {
        h.setConfig(
            CollateralActivationConfig({
                minActivationDelay: 1 minutes,
                maxActivationDelay: 1 hours,
                activatingLockAmount: 9 ether,
                activatingLockDuration: 30 minutes,
                maxDelayInflow: 10_000 ether,
                minActivationAmount: 10 ether,
                minDepositAmount: 0,
                maxGuardiansQuorumDelay: 0,
                delayPerStrike: 1 hours,
                delayPerSuspect: 30 minutes
            })
        );
        address borrower = address(0x10CD);

        h.deposit(borrower, 20 ether);
        h.withdraw(borrower, 11 ether); // leaves the 9 ether lock floor activating
        h.deposit(borrower, 9 ether); // remains separate dust while the lock is active

        vm.warp(block.timestamp + 30 minutes);
        h.withdraw(borrower, 1 ether);

        (, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(activating, 9 ether, "sub-threshold activating remainder stays timed");
        assertEq(dust, 8 ether, "existing dust remains below the threshold");
    }

    // ── ACT-04: withdrawal demotion reverses the same-tx inflow of the demoted remainder ──

    /// @notice The finding's canonical sequence: deposit exactly the threshold, withdraw one raw unit so the drain
    ///         leaves a sub-threshold remainder, which is demoted to dust. The demoted remainder leaves the
    ///         throttle, so its same-tx inflow is reversed too — the throttle returns to zero, not to a phantom
    ///         `~minActivationAmount`. Then withdrawing the dust empties the position, still at zero inflow.
    function test_debit_demotionReversesSameTxInflow() public {
        uint128 m = 2 ether;
        h.setMinActivationAmount(m);
        address borrower = address(0xAC04);

        h.deposit(borrower, m); // crosses -> activating = m, inflow = m
        assertEq(h.currentInflow(), m, "deposit bumps inflow to the threshold");

        // Withdraw one raw unit: the drain leaves m - 1 activating (< m), which is demoted to dust.
        h.withdraw(borrower, 1);
        (, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(activating, 0, "sub-threshold remainder demoted out of activating");
        assertEq(dust, uint256(m) - 1, "remainder folded into dust");
        // Pre-fix this was m - 1 (phantom); post-fix the demoted remainder's inflow is reversed too.
        assertEq(h.currentInflow(), 0, "demotion reverses the full same-tx inflow, no phantom left");

        // Withdrawing the dust empties the position; dust is off the throttle, so inflow stays zero.
        h.withdraw(borrower, uint256(m) - 1);
        (uint256 active, uint256 activatingEnd, uint256 dustEnd) = h.bucketsOf(borrower);
        assertEq(active + activatingEnd + dustEnd, 0, "position fully emptied");
        assertEq(h.currentInflow(), 0, "empty position leaves no phantom inflow");
    }

    /// @notice Boundary `minActivationAmount = 1`: a remainder can never be sub-threshold (any nonzero remainder
    ///         is `>= 1 = threshold`), so demotion never fires; a full drain still reverses the inflow exactly.
    function test_debit_demotion_minAmountBoundaryOne() public {
        h.setMinActivationAmount(1);
        address borrower = address(0xAC01);

        h.deposit(borrower, 1); // activating = 1, inflow = 1
        assertEq(h.currentInflow(), 1, "deposit bumps inflow");

        h.withdraw(borrower, 1); // fully drains activating; nothing to demote
        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active + activating + dust, 0, "position emptied, no demotion");
        assertEq(h.currentInflow(), 0, "full drain reverses inflow exactly");
    }

    /// @notice Boundary `minActivationAmount = 2`: the smallest threshold that admits a sub-threshold remainder
    ///         (of 1). Withdrawing one unit demotes the remaining 1 to dust and reverses the full inflow.
    function test_debit_demotion_minAmountBoundaryTwo() public {
        h.setMinActivationAmount(2);
        address borrower = address(0xAC02);

        h.deposit(borrower, 2); // activating = 2, inflow = 2
        h.withdraw(borrower, 1); // leaves 1 (< 2) -> demoted to dust
        (, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(activating, 0, "remainder demoted");
        assertEq(dust, 1, "1 unit held as dust");
        assertEq(h.currentInflow(), 0, "demoted remainder's inflow reversed too");
    }

    /// @notice With an active lock, the sub-threshold remainder is NOT demoted (that would bypass the lock via
    ///         freely-withdrawable dust). The inflow is still reconciled correctly: the drained amount is reversed
    ///         and the locked remainder — which stays activating — keeps its matching inflow. No phantom either
    /// way.
    function test_debit_demotion_withActiveLock_reconcilesInflow() public {
        h.setConfig(
            CollateralActivationConfig({
                minActivationDelay: 1 minutes,
                maxActivationDelay: 1 hours,
                activatingLockAmount: 1 ether,
                activatingLockDuration: 1 hours,
                maxDelayInflow: 10_000 ether,
                minActivationAmount: 2 ether, // lock floor (1 ether) is a sub-threshold remainder
                minDepositAmount: 0,
                maxGuardiansQuorumDelay: 0,
                delayPerStrike: 1 hours,
                delayPerSuspect: 30 minutes
            })
        );
        address borrower = address(0x10CC);

        h.deposit(borrower, 10 ether); // activating = 10, inflow = 10
        h.withdraw(borrower, 9 ether); // drain to the 1 ether lock floor

        (, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(activating, 1 ether, "locked remainder stays activating (not demoted)");
        assertEq(dust, 0, "no demotion under a lock");
        // Drained 9 reversed; the locked 1 stays activating and keeps its 1 ether inflow. No phantom.
        assertEq(h.currentInflow(), 1 ether, "inflow reconciled: only the locked activating remainder's share left");
    }

    /// @notice Repeated demotion cycles in one tx never accumulate phantom inflow. Each cycle deposits the
    ///         threshold, withdraws one unit (demoting the remainder), then withdraws the dust — returning the
    ///         position to empty. Pre-fix each cycle stranded `~minActivationAmount` of inflow, accumulating to
    ///         the `maxDelayInflow` cap; post-fix every cycle fully reverses, so the throttle stays at zero.
    function test_debit_repeatedDemotionCycles_noInflowAccumulation() public {
        uint128 m = 1_000 ether; // 11 pre-fix cycles would have reached the 10_000 ether cap
        h.setMinActivationAmount(m);
        address borrower = address(0xC04C);

        for (uint256 i = 0; i < 15; ++i) {
            h.deposit(borrower, m);
            h.withdraw(borrower, 1); // demote m - 1 to dust, reverse the full inflow
            h.withdraw(borrower, uint256(m) - 1); // drain the dust back to empty
            assertEq(h.currentInflow(), 0, "no phantom accumulates across cycles");
        }

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active + activating + dust, 0, "position empty after all cycles");
        assertEq(h.currentInflow(), 0, "throttle stays at zero, never climbs toward maxDelayInflow");
    }

    /// @notice Invariant: once a position is fully emptied in the same tx it added its inflow, nothing of that
    ///         contribution remains in the throttle — whether it left via a plain drain or via demotion.
    function testFuzz_debit_emptyPositionHasNoResidualInflow(
        uint128 minAmount,
        uint256 depositAmount,
        uint256 firstWithdraw
    ) public {
        minAmount = uint128(bound(minAmount, 1, 1_000 ether));
        depositAmount = bound(depositAmount, minAmount, 100_000 ether); // crosses the threshold
        firstWithdraw = bound(firstWithdraw, 1, depositAmount); // partial or full first withdrawal
        h.setMinActivationAmount(minAmount);
        address borrower = address(0xF04C);

        h.deposit(borrower, depositAmount);
        h.withdraw(borrower, firstWithdraw);
        uint256 remaining = depositAmount - firstWithdraw;
        if (remaining != 0) h.withdraw(borrower, remaining); // drain whatever is left (dust or activating) to empty

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

    /// @notice A forced seizure that leaves less than the activation minimum demotes the remainder to untimed
    ///         dust, just like an unlocked withdrawal. The demoted amount no longer carries activation inflow and
    ///         cannot mature on the old timer.
    function test_seize_demotesSubThresholdActivatingToDust() public {
        uint256 threshold = 10 ether;
        uint256 remainder = threshold - 1;
        address borrower = address(0xAC5E);
        h.setMinActivationAmount(uint128(threshold));

        h.deposit(borrower, 2 * threshold);
        h.seize(borrower, threshold + 1);

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active, 0, "sub-threshold remainder is not active");
        assertEq(activating, 0, "sub-threshold remainder leaves the timer");
        assertEq(dust, remainder, "sub-threshold remainder becomes dust");
        assertEq(h.currentInflow(), 0, "demoted remainder carries no activation inflow");

        vm.warp(block.timestamp + 2 hours);
        h.sync(borrower, 0);
        (active, activating, dust) = h.bucketsOf(borrower);
        assertEq(active, 0, "demoted remainder does not mature");
        assertEq(activating, 0, "timer stays empty");
        assertEq(dust, remainder, "remainder stays dust");
    }

    /// @notice Regression for the audit sequence: a seizure leaves a sub-threshold remainder, another deposit
    ///         supplies just below the threshold, then a withdrawal drains one unit. The two remainders must not
    ///         be combined into an above-threshold dust bucket.
    function test_seizeRemainder_thenDustTopUpAndDebit_dustStaysBelowThreshold() public {
        uint256 threshold = 10 ether;
        uint256 remainder = threshold - 1;
        address borrower = address(0xAC5F);
        h.setMinActivationAmount(uint128(threshold));

        h.deposit(borrower, 2 * threshold);
        h.seize(borrower, threshold + 1);
        h.deposit(borrower, remainder);
        h.withdraw(borrower, 1);

        (uint256 active, uint256 activating, uint256 dust) = h.bucketsOf(borrower);
        assertEq(active, 0, "collateral remains inactive");
        assertEq(activating, 2 * remainder - 1, "threshold-crossing top-up stays in activation");
        assertEq(dust, 0, "no above-threshold dust is formed");
        assertLt(dust, threshold, "dust remains below the activation threshold");
    }

    /// @notice A seizure waterfalls dust first, then activating. Only the activating it drains carries throttle
    ///         inflow, so the reversal counts that alone — the dust it consumes moves no inflow.
    function test_seize_drainsDustThenActivating_reversesActivatingOnly() public {
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

    /// @notice Single borrower depositing above the cap then withdrawing only the pre-fix "recorded" (post-cap)
    ///         amount. Pre-fix that erased the accumulator; post-fix the gross net still exceeds the cap, so it
    ///         stays pinned at the cap.
    function test_singleDepositAboveCap_partialWithdraw_keepsCappedInflow() public {
        uint256 cap = 10_000 ether;
        h.setMinActivationAmount(1 ether);
        address borrower = address(0xA6E);

        h.deposit(borrower, 2 * cap); // gross 2*cap, stored inflow = cap
        assertEq(h.currentInflow(), cap, "stored inflow capped");

        h.withdraw(borrower, cap); // withdraw the post-cap amount; gross net still = cap
        assertEq(h.currentInflow(), cap, "gross net still at the cap, accumulator not erased");
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

    /// @notice A single-tx mix of every activation mutation — credit, voluntary debit, demotion, and forced
    ///         seizure (liquidation / settlement) — keeps the invariant `storedInflow == min(cap, baseline + net)`
    ///         at every step. Here baseline is 0 (fresh, first mutation), so it reduces to `min(cap, gross net)`.
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

        h.withdraw(b, 5_999.5 ether); // leaves 0.5 (< 1) -> demotion; full 6_000 leaves activating: net 0
        assertEq(h.currentInflow(), 0, "demotion reverses the whole remainder, accumulator empty");
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
            activatingLockAmount: 0,
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
        cfg.activatingLockDuration = uint32(7 days + 1);
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
        cfg.delayPerStrike = uint32(7 days + 1);
        vm.expectRevert(CollateralActivationLib.MaxDelayPerStrikeExceeded.selector);
        h.setConfig(cfg);
    }

    /// @dev A config whose delayPerSuspect exceeds the bound reverts MaxDelayPerSuspectExceeded.
    function testRevert_setConfig_delayPerSuspectAboveBound() public {
        CollateralActivationConfig memory cfg = _baseConfig();
        cfg.delayPerSuspect = uint32(7 days + 1);
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
                activatingLockAmount: 0,
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

        // Withdraw 120 > this-tx 50: drains 70 of the prior lot too, but only the 50 same-tx contribution
        // is reversible. The prior 100 stays (decays, never reverses).
        h.withdraw(B, 120 ether);
        assertEq(h.currentInflow(), priorInflow, "over-withdraw reversed only the same-tx contribution");
    }
}
