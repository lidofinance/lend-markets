// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test, stdError} from "forge-std/Test.sol";

import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {GuardiansOpinion, Status, BlockInfo} from "../../src/interfaces/GuardianSignalsTypes.sol";

/// @dev Harness exposing the internal activation library over a storage State (L0 via harness).
contract CAHarness {
    using CollateralActivationLib for CollateralActivationLib.State;

    CollateralActivationLib.State internal s;

    function setConfig(CollateralActivationLib.Config memory c) external {
        s.setConfig(c);
    }

    function setMinActivationDelay(uint40 d) external {
        s.setMinActivationDelay(d);
    }

    function setMaxActivationDelay(uint40 d) external {
        s.setMaxActivationDelay(d);
    }

    function setActivatingHold(uint128 h) external {
        s.setActivatingHold(h);
    }

    function setInstantActivation(address b, bool v) external {
        s.setInstantActivation(b, v);
    }

    function deposit(address b, uint256 a) external {
        s.deposit(b, a);
    }

    function withdraw(address b, uint256 a) external returns (uint256) {
        return s.withdraw(b, a);
    }

    function debit(address b, uint256 a, uint256 hold) external returns (uint256) {
        return s.debit(b, a, hold);
    }

    function syncActivation(bool frozen, address b, GuardiansOpinion memory o) external returns (uint256) {
        return s.syncActivation(frozen, b, o);
    }

    function getUnlockTime(address b, GuardiansOpinion memory o) external view returns (uint256) {
        return s.getUnlockTime(b, o);
    }

    function getBuckets(address b) external view returns (uint256 active, uint256 activating, uint256 dust) {
        return s.getBuckets(b);
    }

    function getInflow() external view returns (uint256) {
        return s.getInflow();
    }

    function getConfig() external view returns (CollateralActivationLib.Config memory) {
        return s.config;
    }
}

/// @notice L0 unit/fuzz for `CollateralActivationLib`, modelled from the "Collateral activation"
///         spec + ADR-001/014. Three buckets (dust/activating/active); fresh collateral matures through a
///         timer before it can back a loan. Delay/unlock/decay are recomputed independently from the spec
///         formulas (NOT read off the contract).
///         In particular the per-test claims here recompute:
///           delay      = inflow>=cap ? max : min + (max-min)*inflow/cap        (floor)
///           unlockTime = activatingStart + activatingDelay(snapshot) + strikes*delayPerStrike
///           decay      = maxDelayInflow * elapsed / maxActivationDelay          (floor, saturating)
contract CollateralActivationLibTest is Test {
    CAHarness internal h;

    address internal constant BOB = address(0x3001);
    address internal constant ALICE = address(0x3002);

    function setUp() public {
        h = new CAHarness();
        vm.warp(1_000_000); // non-zero base time
        h.setConfig(_config());
    }

    // ── config / opinion builders ──

    function _config() internal pure returns (CollateralActivationLib.Config memory) {
        return CollateralActivationLib.Config({
            minActivationDelay: 600, // 10 min
            maxActivationDelay: 7200, // 2 h
            maxDelayInflow: 10_000 ether,
            delayPerStrike: 1800, // 30 min
            activatingHold: 5 ether,
            minActivationAmount: 10 ether,
            maxGuardiansQuorumDelay: 0 // timer-only (no quorum-scan gate) unless overridden per test
        });
    }

    function _opinion(Status status, uint256 strikes, uint256 quorumTs)
        internal
        pure
        returns (GuardiansOpinion memory)
    {
        return GuardiansOpinion({
            status: status,
            strikes: strikes,
            flagCount: 0,
            quorumBlock: BlockInfo({number: 0, timestamp: uint40(quorumTs)})
        });
    }

    function _clean() internal pure returns (GuardiansOpinion memory) {
        return _opinion(Status.Normal, 0, 0);
    }

    /// @dev Independent recompute of the inflow-delay ramp (floor).
    function _expectedDelay(uint256 inflow) internal pure returns (uint256) {
        CollateralActivationLib.Config memory c = _config();
        if (inflow >= c.maxDelayInflow) return c.maxActivationDelay;
        return uint256(c.minActivationDelay) + (uint256(c.maxActivationDelay) - c.minActivationDelay) * inflow
            / c.maxDelayInflow;
    }

    // ── delay ramp ──

    function test_deposit_delay_recomputeFromInflow() public {
        uint256 assets = 100 ether; // < cap, >= minActivationAmount -> enters activating
        h.deposit(BOB, assets);
        // First deposit: effectiveInflow = min(0 + assets, cap) = assets.
        assertEq(h.getUnlockTime(BOB, _clean()), block.timestamp + _expectedDelay(assets), "unlock = now + ramp(delay)");
    }

    function test_deposit_inflowZero_givesMinDelay() public {
        // A deposit equal to minActivationAmount with no prior inflow ramps from the floor.
        h.deposit(BOB, 10 ether);
        assertEq(h.getUnlockTime(BOB, _clean()), block.timestamp + _expectedDelay(10 ether), "ramp from floor");
    }

    function test_deposit_inflowAtCap_givesMaxDelay() public {
        h.deposit(BOB, 20_000 ether); // >= maxDelayInflow -> delay clamps to maxActivationDelay
        assertEq(h.getUnlockTime(BOB, _clean()), block.timestamp + _config().maxActivationDelay, "clamped to max");
    }

    // ── inflow decay ──

    function test_inflowDecay_linearOverWindow() public {
        // Decay drains a full `maxDelayInflow` over `maxActivationDelay` at an absolute rate, so the inflow
        // must be large relative to the elapsed-window fraction to observe a PARTIAL (non-saturated) decay.
        h.deposit(BOB, 8_000 ether);
        uint256 inflow0 = h.getInflow();
        assertEq(inflow0, 8_000 ether, "first deposit sets inflow to the lot (under cap)");

        uint256 dt = 1800; // quarter of the 7200 window → decay = 2500e18 < 8000e18 (partial)
        vm.warp(block.timestamp + dt);
        uint256 decay = uint256(_config().maxDelayInflow) * dt / _config().maxActivationDelay;
        assertEq(h.getInflow(), inflow0 - decay, "inflow decays linearly: cap*elapsed/maxActivationDelay");
    }

    function test_inflowDecay_flooredAtZero() public {
        h.deposit(BOB, 100 ether);
        vm.warp(block.timestamp + 10 * _config().maxActivationDelay); // well past the drain window
        assertEq(h.getInflow(), 0, "inflow saturates to zero");
    }

    // ── unlockTime: snapshot, strikes, banned, instant ──

    function test_unlockTime_delayIsSnapshottedAtDeposit() public {
        h.deposit(BOB, 100 ether);
        uint256 unlock = h.getUnlockTime(BOB, _clean());
        // A later, larger deposit by ANOTHER borrower raises market inflow, but BOB's snapshot must not move.
        h.deposit(ALICE, 5_000 ether);
        assertEq(h.getUnlockTime(BOB, _clean()), unlock, "BOB's delay is frozen at his deposit");
    }

    function test_unlockTime_strikesSurchargeIsLive() public {
        h.deposit(BOB, 100 ether);
        uint256 base = h.getUnlockTime(BOB, _clean());
        uint256 withStrikes = h.getUnlockTime(BOB, _opinion(Status.Normal, 2, 0));
        assertEq(withStrikes, base + 2 * _config().delayPerStrike, "strikes add a live surcharge");
    }

    function test_unlockTime_banned_isInfinite() public {
        h.deposit(BOB, 100 ether);
        assertEq(h.getUnlockTime(BOB, _opinion(Status.Banned, 0, 0)), type(uint256).max, "banned never unlocks");
    }

    function test_unlockTime_instant_isZero() public {
        h.setInstantActivation(BOB, true);
        h.deposit(BOB, 100 ether); // instant deposit goes straight to active (no activating); unlock is 0
        (uint256 active,,) = h.getBuckets(BOB);
        assertEq(active, 100 ether, "instant deposit lands active immediately");
    }

    // ── maturation gate (syncActivation) ──

    function test_sync_maturesAfterTimer_noQuorumGate() public {
        h.deposit(BOB, 100 ether);
        vm.warp(h.getUnlockTime(BOB, _clean())); // now == unlockTime (inclusive >=)
        h.syncActivation(false, BOB, _clean());
        (uint256 active, uint256 activating,) = h.getBuckets(BOB);
        assertEq(active, 100 ether, "matured to active at the timer boundary");
        assertEq(activating, 0, "activating drained");
    }

    function test_sync_doesNotMatureBeforeTimer() public {
        h.deposit(BOB, 100 ether);
        vm.warp(h.getUnlockTime(BOB, _clean()) - 1);
        h.syncActivation(false, BOB, _clean());
        (uint256 active,,) = h.getBuckets(BOB);
        assertEq(active, 0, "not matured one second before unlock");
    }

    function test_sync_frozen_suspendsMaturation() public {
        h.deposit(BOB, 100 ether);
        vm.warp(h.getUnlockTime(BOB, _clean()) + 1000);
        h.syncActivation(true, BOB, _clean()); // frozen
        (uint256 active,,) = h.getBuckets(BOB);
        assertEq(active, 0, "frozen market does not mature");
    }

    function test_sync_banned_neverMatures_evenAfterFallbackWindow() public {
        // The trap: a banned borrower must not mature even once maxGuardiansQuorumDelay has elapsed.
        CollateralActivationLib.Config memory c = _config();
        c.maxGuardiansQuorumDelay = 2 * c.maxActivationDelay; // valid: above the base-delay ceiling
        h.setConfig(c);
        uint256 start = block.timestamp;
        h.deposit(BOB, 100 ether);
        vm.warp(start + 10 * c.maxActivationDelay); // way past both the timer and the fallback
        h.syncActivation(false, BOB, _opinion(Status.Banned, 0, 0));
        (uint256 active,,) = h.getBuckets(BOB);
        assertEq(active, 0, "banned (unlock=inf) never matures, fallback window notwithstanding");
    }

    function test_sync_quorumFrontier_gatesUntilScanned() public {
        CollateralActivationLib.Config memory c = _config();
        c.maxGuardiansQuorumDelay = 100_000; // large fallback so only the frontier can release early
        h.setConfig(c);
        h.deposit(BOB, 100 ether);
        uint256 unlock = h.getUnlockTime(BOB, _clean());
        vm.warp(unlock + 10);

        // Frontier still behind the unlock -> not matured.
        h.syncActivation(false, BOB, _opinion(Status.Normal, 0, unlock - 1));
        (uint256 active,,) = h.getBuckets(BOB);
        assertEq(active, 0, "timer passed but quorum frontier behind unlock -> still gated");

        // Frontier scanned exactly to the unlock (inclusive <=) -> matures.
        h.syncActivation(false, BOB, _opinion(Status.Normal, 0, unlock));
        (active,,) = h.getBuckets(BOB);
        assertEq(active, 100 ether, "frontier at unlock releases the lot");
    }

    function test_sync_quorumStall_fallbackMatures() public {
        CollateralActivationLib.Config memory c = _config();
        c.maxGuardiansQuorumDelay = 2 * c.maxActivationDelay; // valid; fallback sits above any lot's unlock
        h.setConfig(c);
        uint256 start = block.timestamp;
        h.deposit(BOB, 100 ether);
        // Frontier never advanced (quorumTs 0); warp past the fallback window (start + maxGuardiansQuorumDelay,
        // itself past the unlock) -> matures on the fallback alone.
        vm.warp(start + c.maxGuardiansQuorumDelay);
        h.syncActivation(false, BOB, _opinion(Status.Normal, 0, 0));
        (uint256 active,,) = h.getBuckets(BOB);
        assertEq(active, 100 ether, "stalled committee: fallback matures the lot");
    }

    // ── deposit bucket routing (dust) ──

    function test_deposit_belowMin_staysDust() public {
        h.deposit(BOB, 4 ether); // < minActivationAmount (10) -> dust, no timer
        (uint256 active, uint256 activating, uint256 dust) = h.getBuckets(BOB);
        assertEq(dust, 4 ether, "below the minimum stays in dust");
        assertEq(activating + active, 0, "nothing activating/active");
        assertEq(h.getUnlockTime(BOB, _clean()), 0, "no timer for dust");
    }

    function test_deposit_dustCrossesThreshold_promotesWhole() public {
        h.deposit(BOB, 4 ether); // dust = 4
        h.deposit(BOB, 7 ether); // 4 + 7 = 11 >= 10 -> the WHOLE 11 promotes to activating
        (uint256 active, uint256 activating, uint256 dust) = h.getBuckets(BOB);
        assertEq(dust, 0, "dust cleared on promotion");
        assertEq(activating, 11 ether, "the whole accumulated amount promotes");
        assertEq(active, 0, "not yet matured");
    }

    // ── withdrawal waterfall + hold + forced ──

    function test_withdraw_respectsHold_onActivating() public {
        h.deposit(BOB, 100 ether); // activating 100, hold 5 -> withdrawable activating = 95
        uint256 active = h.withdraw(BOB, 95 ether);
        assertEq(active, 0, "no active matured yet");
        (, uint256 activating,) = h.getBuckets(BOB);
        assertEq(activating, 5 ether, "the held 5 stays in activating");
    }

    function test_debit_forced_bypassesHold() public {
        h.deposit(BOB, 100 ether);
        // Forced path passes hold = 0 -> the whole activating bucket is reachable.
        h.debit(BOB, 100 ether, 0);
        (uint256 a, uint256 activating, uint256 dust) = h.getBuckets(BOB);
        assertEq(a + activating + dust, 0, "forced debit seizes the held collateral too");
    }

    function test_withdraw_waterfall_dustBeforeActivating() public {
        h.deposit(BOB, 4 ether); // dust 4
        h.deposit(BOB, 100 ether); // 4+100=104 >= min -> whole 104 promotes to activating, dust 0
        // re-add dust below the (now reset) threshold
        h.deposit(BOB, 3 ether); // dust 3 (104 already activating; 3 < min stays dust)
        h.withdraw(BOB, 3 ether); // comes out of dust first
        (, uint256 activating, uint256 dust) = h.getBuckets(BOB);
        assertEq(dust, 0, "dust debited first");
        assertEq(activating, 104 ether, "activating untouched");
    }

    // ── flash-loan undo ──

    function test_flashLoanUndo_sameTx_reversesInflow() public {
        // hold = 0 so the whole activating lot is voluntarily withdrawable, isolating the flash-loan undo
        // (the hold is exercised separately in test_withdraw_respectsHold_onActivating).
        CollateralActivationLib.Config memory c = _config();
        c.activatingHold = 0;
        h.setConfig(c);

        h.deposit(BOB, 100 ether);
        assertEq(h.getInflow(), 100 ether, "deposit added exactly its lot to inflow");
        h.withdraw(BOB, 100 ether); // same block -> inflow contribution fully reversed
        assertEq(h.getInflow(), 0, "inflow back to pre-deposit (exactly 0)");
    }

    // ── setConfig BadConfig (each guarded field) ──

    function testRevert_setConfig_minDelayZero() public {
        CollateralActivationLib.Config memory c = _config();
        c.minActivationDelay = 0;
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setConfig(c);
    }

    function testRevert_setConfig_minAboveMax() public {
        CollateralActivationLib.Config memory c = _config();
        c.minActivationDelay = c.maxActivationDelay + 1;
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setConfig(c);
    }

    function testRevert_setConfig_minActivationAmountZero() public {
        CollateralActivationLib.Config memory c = _config();
        c.minActivationAmount = 0;
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setConfig(c);
    }

    function testRevert_setConfig_maxDelayInflowZero() public {
        CollateralActivationLib.Config memory c = _config();
        c.maxDelayInflow = 0;
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setConfig(c);
    }

    function test_setConfig_acceptsZeroHoldAndQuorumDelay() public {
        CollateralActivationLib.Config memory c = _config();
        c.activatingHold = 0;
        c.maxGuardiansQuorumDelay = 0;
        h.setConfig(c); // both 0 are valid (no revert)
    }

    // ── delay setter: no monotonicity constraint ──

    /// @dev Current behaviour: `setMinActivationDelay` accepts any value in `(0, maxActivationDelay]` and is
    ///      NOT increase-only — it can move the floor down as well as up. Pinned so a future monotonicity
    ///      requirement would be an explicit change.
    function test_setMinActivationDelay_movesEitherDirection() public {
        h.setMinActivationDelay(1200); // raise
        assertEq(h.getConfig().minActivationDelay, 1200, "raised");
        h.setMinActivationDelay(700); // then lower -- accepted
        assertEq(h.getConfig().minActivationDelay, 700, "floor lowered (setter is not increase-only)");
    }

    /// @dev `maxGuardiansQuorumDelay` is an independent parameter — there is no cross-field validation against
    ///      the base delay. A value at or below the base delay is accepted, and a lot then matures on the
    ///      timer alone (the quorum gate is effectively skipped). Pinned as accepted config behaviour:
    ///      governance is responsible for setting a coherent value.
    function test_quorumDelayBelowBase_skipsGate_byConfig() public {
        CollateralActivationLib.Config memory c = _config();
        c.maxGuardiansQuorumDelay = 300; // below the base delay; no coupling -> accepted
        h.setConfig(c);
        h.deposit(BOB, 10 ether);
        vm.warp(h.getUnlockTime(BOB, _clean())); // timer elapsed; frontier never advanced (quorumTs 0)
        h.syncActivation(false, BOB, _clean());
        (uint256 active,,) = h.getBuckets(BOB);
        assertEq(active, 10 ether, "sub-base fallback matures on the timer alone (gate skipped)");
    }

    // -- extend / saturated undo / hold reverts / config bounds / fuzz --

    function test_deposit_whileActivating_extendsWholeBucket() public {
        h.deposit(BOB, 10 ether); // small inflow -> small delay -> unlock = now + ~606
        h.deposit(BOB, 9_000 ether); // same block: inflow 9010 -> larger delay -> extends the whole bucket
        assertEq(
            h.getUnlockTime(BOB, _clean()),
            block.timestamp + _expectedDelay(9_010 ether),
            "later larger deposit re-bases the whole bucket's unlock"
        );
        (, uint256 activating,) = h.getBuckets(BOB);
        assertEq(activating, 9_010 ether, "both lots share one activating bucket under the extended timer");
    }

    function test_flashLoanUndo_saturated_cannotPushInflowBelowZero() public {
        // Anti-suppression: the same-tx inflow that can be reversed is capped at what was actually ADDED
        // (`txInflowAdded`), not at the activating that leaves. Two deposits add 13000e of activating but
        // only 10000e of inflow (cap), recorded as applied deltas 8000e + 2000e = 10000e. Withdrawing the
        // whole 13000e therefore reverses only 10000e -> inflow lands exactly at 0, never negative.
        CollateralActivationLib.Config memory c = _config();
        c.activatingHold = 0;
        h.setConfig(c);
        h.deposit(BOB, 8_000 ether);
        h.deposit(BOB, 5_000 ether); // inflow capped at 10000e; activating now 13000e
        h.withdraw(BOB, 13_000 ether); // undo reverses min(txInflowAdded=10000e, 13000e) = 10000e
        assertEq(h.getInflow(), 0, "activating-out beyond inflow-added cannot suppress inflow below pre-tx");
    }

    function testRevert_withdraw_intoHeldActivating_reverts() public {
        h.deposit(BOB, 100 ether); // activating 100, hold 5 -> withdrawable 95
        vm.expectRevert(stdError.arithmeticError);
        h.withdraw(BOB, 96 ether); // 96 > 95 reaches into the held 5 -> underflow
    }

    function testRevert_withdraw_holdGeActivating_blocksAll() public {
        CollateralActivationLib.Config memory c = _config();
        c.activatingHold = 200 ether; // >= any activating
        h.setConfig(c);
        h.deposit(BOB, 100 ether); // activating 100, held = min(200,100) = 100, withdrawable 0
        vm.expectRevert(stdError.arithmeticError);
        h.withdraw(BOB, 1 ether);
    }

    function testRevert_setConfig_maxDelayAboveBound() public {
        CollateralActivationLib.Config memory c = _config();
        c.maxActivationDelay = uint40(7 days + 1);
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setConfig(c);
    }

    function testRevert_setConfig_delayPerStrikeAboveBound() public {
        CollateralActivationLib.Config memory c = _config();
        c.delayPerStrike = uint40(7 days + 1);
        vm.expectRevert(CollateralActivationLib.BadConfig.selector);
        h.setConfig(c);
    }

    function testFuzz_firstDeposit_delayMatchesRamp(uint256 amount) public {
        CollateralActivationLib.Config memory c = _config();
        amount = bound(amount, c.minActivationAmount, 1e30); // >= min so it enters activating
        h.deposit(BOB, amount);
        uint256 unlock = h.getUnlockTime(BOB, _clean());
        // Exact ramp recompute. `_expectedDelay` already clamps to [min, max], so the equality below
        // simultaneously pins the value AND proves the floor/cap clamp — no separate bound checks needed.
        assertEq(unlock, block.timestamp + _expectedDelay(amount), "unlock == ramp recompute (clamped)");
    }
}
