// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {GuardiansOpinion} from "../../src/types/GuardianSignalsTypes.sol";

import {ActivationModel} from "../setup/ActivationModel.sol";

/// @notice Storage for the model's state, so a test can drive the mutating rules and seed a lot directly.
contract ActivationModelHarness {
    ActivationModel.State internal state;
    CollateralActivationConfig internal config;

    function setConfig(CollateralActivationConfig memory c) external {
        config = c;
    }

    function setLot(address borrower, ActivationModel.Lot memory l) external {
        state.lots[borrower] = l;
    }

    function lot(address borrower) external view returns (ActivationModel.Lot memory) {
        return state.lots[borrower];
    }

    function inflow(uint256 at) external view returns (uint256) {
        return ActivationModel.decayedInflow(state, config, at);
    }

    function classify(address borrower, uint256 amount, bool instant) external returns (bytes memory) {
        return ActivationModel.classify(state, config, borrower, amount, instant);
    }

    function sync(address borrower, GuardiansOpinion memory opinion, bool frozen) external {
        ActivationModel.sync(state, config, borrower, opinion, frozen);
    }

    function reduce(address borrower, uint256 active, uint256 amount) external {
        ActivationModel.reduce(state, config, borrower, active, amount);
    }

    function beginTransaction(address[] memory borrowers) external {
        ActivationModel.beginTransaction(state, borrowers);
    }
}

/// @notice The activation model against `docs/specs/market-controller.md` "Collateral activation". Every expected
///         number is computed here from the document's formulas, never read back from the model or the contracts.
contract ActivationModelTest is Test {
    /// @dev The base delay a 10 ether supply quotes against an empty accumulator under `_config()`:
    ///      `2 hours + floor(22 hours * 10 / 10 000)`.
    uint256 internal constant DELAY_AT_TEN = 2 hours + 79;

    ActivationModelHarness internal h;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        h = new ActivationModelHarness();
        h.setConfig(_config());
        vm.warp(1 days);
    }

    function _config() internal pure returns (CollateralActivationConfig memory) {
        return CollateralActivationConfig({
            minActivationDelay: 2 hours,
            maxActivationDelay: 24 hours,
            maxDelayInflow: 10_000 ether,
            minDepositAmount: 1 ether,
            activatingLockDuration: 3 hours,
            minActivationAmount: 10 ether,
            maxGuardiansQuorumDelay: 0,
            delayPerStrike: 2 hours,
            delayPerSuspect: 0
        });
    }

    function _noSignal() internal pure returns (GuardiansOpinion memory) {
        return GuardiansOpinion({
            banned: false, strikeCount: 0, suspectCount: 0, suspectExpiryTimestamp: 0, quorumFrontierTimestamp: 0
        });
    }

    function _lot(uint256 dust, uint256 activating, uint256 start, uint256 delay)
        internal
        pure
        returns (ActivationModel.Lot memory)
    {
        return
            ActivationModel.Lot({dust: dust, activating: activating, start: start, baseDelay: delay, contribution: 0});
    }

    // ---
    // CLASSIFYING A COLLATERAL SUPPLY
    // ---

    function test_classify_belowMinDeposit_reverts() public {
        bytes memory err = h.classify(alice, 0.5 ether, false);
        assertEq(
            err,
            abi.encodeWithSelector(CollateralActivationLib.DepositTooSmall.selector, 0.5 ether, 1 ether),
            "below the minimum deposit"
        );
        assertEq(h.lot(alice).dust, 0, "rejected supply left dust");
        assertEq(h.inflow(block.timestamp), 0, "rejected supply moved the inflow");
    }

    function test_classify_dustThenResolvingSupply_startsLot() public {
        uint256 t0 = block.timestamp;
        assertEq(h.classify(alice, 4 ether, false).length, 0, "dust supply rejected");
        assertEq(h.lot(alice).dust, 4 ether, "dust bucket");
        assertEq(h.lot(alice).activating, 0, "dust started a timer");
        assertEq(h.inflow(t0), 0, "dust fed the inflow");

        assertEq(h.classify(alice, 6 ether, false).length, 0, "resolving supply rejected");
        ActivationModel.Lot memory l = h.lot(alice);
        assertEq(l.dust, 0, "dust not released");
        assertEq(l.activating, 10 ether, "dust plus the supply did not enter the timer");
        assertEq(l.start, t0, "lot start");
        assertEq(l.baseDelay, DELAY_AT_TEN, "base delay at 10 ether of inflow");
        assertEq(l.contribution, 10 ether, "contribution");
        assertEq(h.inflow(t0), 10 ether, "inflow after the crossing");
    }

    function test_classify_dustThenSmallSupply_reverts() public {
        h.classify(alice, 4 ether, false);
        bytes memory err = h.classify(alice, 3 ether, false);
        assertEq(
            err,
            abi.encodeWithSelector(CollateralActivationLib.DustNotResolved.selector, 4 ether, 3 ether, 10 ether),
            "dust left unresolved"
        );
        assertEq(h.lot(alice).dust, 4 ether, "rejected supply changed the dust");
        assertEq(h.lot(alice).activating, 0, "rejected supply started a timer");
    }

    function test_classify_exactThreshold_isActivating() public {
        uint256 t0 = block.timestamp;
        assertEq(h.classify(alice, 10 ether, false).length, 0, "threshold supply rejected");
        ActivationModel.Lot memory l = h.lot(alice);
        assertEq(l.dust, 0, "threshold supply left dust");
        assertEq(l.activating, 10 ether, "activating");
        assertEq(l.start, t0, "lot start");
        assertEq(l.baseDelay, DELAY_AT_TEN, "base delay");
        assertEq(h.inflow(t0), 10 ether, "inflow");
    }

    function test_classify_oneBelowThreshold_isDust() public {
        assertEq(h.classify(alice, 10 ether - 1, false).length, 0, "sub-threshold supply rejected");
        ActivationModel.Lot memory l = h.lot(alice);
        assertEq(l.dust, 10 ether - 1, "dust");
        assertEq(l.activating, 0, "sub-threshold supply started a timer");
        assertEq(l.baseDelay, 0, "sub-threshold supply quoted a delay");
        assertEq(h.inflow(block.timestamp), 0, "sub-threshold supply fed the inflow");
    }

    function test_classify_instant_bypassesEverything() public {
        h.setLot(carol, _lot(4 ether, 0, 0, 0));
        assertEq(h.classify(carol, 0.5 ether, true).length, 0, "instant supply under the minimum deposit rejected");
        assertEq(h.classify(carol, 500 ether, true).length, 0, "large instant supply rejected");
        ActivationModel.Lot memory l = h.lot(carol);
        assertEq(l.dust, 4 ether, "instant supply touched the dust");
        assertEq(l.activating, 0, "instant supply started a timer");
        assertEq(l.contribution, 0, "instant supply contributed to the inflow");
        assertEq(h.inflow(block.timestamp), 0, "instant supply fed the inflow");
    }

    // ---
    // BASE DELAY AND MARKET INFLOW
    // ---

    function test_baseDelay_atCap_isMax() public view {
        CollateralActivationConfig memory c = _config();
        assertEq(ActivationModel.baseDelay(c, 10_000 ether), 24 hours, "at the reference inflow");
        assertEq(ActivationModel.baseDelay(c, 10_001 ether), 24 hours, "above the reference inflow");
        assertEq(ActivationModel.baseDelay(c, 0), 2 hours, "at no inflow");
        // 2 hours + floor(22 hours * 5 000 / 10 000).
        assertEq(ActivationModel.baseDelay(c, 5_000 ether), 2 hours + 39_600, "halfway");
    }

    function test_decay_afterMaxDelay_isZero() public {
        uint256 t0 = block.timestamp;
        h.classify(alice, 10_000 ether, false);
        assertEq(h.inflow(t0), 10_000 ether, "inflow at the crossing");
        // One hour drains floor(10 000 ether / 24).
        assertEq(h.inflow(t0 + 1 hours), 9_583_333_333_333_333_333_334, "inflow after one hour");
        assertEq(h.inflow(t0 + 24 hours), 0, "inflow after the decay horizon");
        assertEq(h.inflow(t0 + 48 hours), 0, "inflow past the decay horizon");
    }

    function test_topUp_laterDeadlineReplaces_earlierKeeps() public {
        uint256 t0 = block.timestamp;
        h.setLot(alice, _lot(0, 10 ether, t0, 2 hours));
        vm.warp(t0 + 1 hours);
        // Quoted deadline t0 + 1 hours + DELAY_AT_TEN, past the lot's own t0 + 2 hours.
        assertEq(h.classify(alice, 10 ether, false).length, 0, "top-up rejected");
        ActivationModel.Lot memory l = h.lot(alice);
        assertEq(l.start, t0 + 1 hours, "later quote restarts the lot");
        assertEq(l.baseDelay, DELAY_AT_TEN, "later quote replaces the base delay");
        assertEq(l.activating, 20 ether, "top-up did not join the lot");

        ActivationModelHarness fresh = new ActivationModelHarness();
        fresh.setConfig(_config());
        // One second back, so a start the top-up wrongly restarted differs from the one kept.
        uint256 seeded = block.timestamp - 1;
        fresh.setLot(bob, _lot(0, 50 ether, seeded, 10 hours));
        // Quoted deadline now + DELAY_AT_TEN, short of the lot's own seeded + 10 hours.
        assertEq(fresh.classify(bob, 10 ether, false).length, 0, "top-up rejected");
        l = fresh.lot(bob);
        assertEq(l.start, seeded, "earlier quote keeps the start");
        assertEq(l.baseDelay, 10 hours, "earlier quote keeps the base delay");
        assertEq(l.activating, 60 ether, "top-up did not join the lot");
        assertEq(fresh.inflow(block.timestamp), 10 ether, "top-up did not feed the inflow");
    }

    // ---
    // MATURATION GATE
    // ---

    function test_unlock_strikeSurcharge() public view {
        ActivationModel.Lot memory l = _lot(0, 10 ether, block.timestamp, DELAY_AT_TEN);
        GuardiansOpinion memory o = _noSignal();
        assertEq(ActivationModel.unlockTime(l, _config(), o), block.timestamp + DELAY_AT_TEN, "no strike");
        o.strikeCount = 1;
        assertEq(ActivationModel.unlockTime(l, _config(), o), block.timestamp + DELAY_AT_TEN + 2 hours, "one strike");
        o.strikeCount = 3;
        assertEq(ActivationModel.unlockTime(l, _config(), o), block.timestamp + DELAY_AT_TEN + 6 hours, "three strikes");
    }

    function test_unlock_suspectSurcharge_onlyBeforeExpiry() public view {
        CollateralActivationConfig memory c = _config();
        c.delayPerSuspect = 1 hours;
        GuardiansOpinion memory o = _noSignal();
        o.suspectCount = 2;
        o.suspectExpiryTimestamp = block.timestamp + 1;

        ActivationModel.Lot memory before = _lot(0, 10 ether, block.timestamp, DELAY_AT_TEN);
        assertEq(
            ActivationModel.unlockTime(before, c, o), block.timestamp + DELAY_AT_TEN + 2 hours, "lot before expiry"
        );
        ActivationModel.Lot memory after_ = _lot(0, 10 ether, block.timestamp + 1, DELAY_AT_TEN);
        assertEq(
            ActivationModel.unlockTime(after_, c, o), block.timestamp + 1 + DELAY_AT_TEN, "lot restarted at expiry"
        );
    }

    function test_unlock_banned_isInfinite() public view {
        ActivationModel.Lot memory l = _lot(0, 10 ether, block.timestamp - 12 hours, DELAY_AT_TEN);
        GuardiansOpinion memory o = _noSignal();
        o.banned = true;
        assertEq(ActivationModel.unlockTime(l, _config(), o), type(uint256).max, "banned borrower has an unlock");
        assertFalse(ActivationModel.matures(l, _config(), o, false, block.timestamp), "banned lot matured");
    }

    function test_matures_frozen_never() public view {
        CollateralActivationConfig memory c = _config();
        ActivationModel.Lot memory l = _lot(0, 10 ether, block.timestamp - 2 hours, 2 hours);
        GuardiansOpinion memory o = _noSignal();
        assertFalse(ActivationModel.matures(l, c, o, true, block.timestamp), "frozen market matured a lot");
        assertTrue(ActivationModel.matures(l, c, o, false, block.timestamp), "unfrozen lot at its unlock");
        assertFalse(ActivationModel.matures(l, c, o, false, block.timestamp - 1), "lot matured before its unlock");
        assertFalse(
            ActivationModel.matures(_lot(4 ether, 0, 0, 0), c, o, false, block.timestamp), "dust-only lot matured"
        );
    }

    function test_matures_quorumGate_frontierOrFallback() public view {
        CollateralActivationConfig memory c = _config();
        c.maxGuardiansQuorumDelay = 6 hours;
        uint256 start = block.timestamp - 2 hours;
        ActivationModel.Lot memory l = _lot(0, 10 ether, start, 2 hours);
        GuardiansOpinion memory o = _noSignal();
        assertFalse(ActivationModel.matures(l, c, o, false, block.timestamp), "matured with no frontier, no fallback");

        o.quorumFrontierTimestamp = start + 2 hours - 1;
        assertFalse(ActivationModel.matures(l, c, o, false, block.timestamp), "frontier short of the unlock");
        o.quorumFrontierTimestamp = start + 2 hours;
        assertTrue(ActivationModel.matures(l, c, o, false, block.timestamp), "frontier at the unlock");

        o.quorumFrontierTimestamp = 0;
        assertFalse(ActivationModel.matures(l, c, o, false, start + 6 hours - 1), "fallback before its deadline");
        assertTrue(ActivationModel.matures(l, c, o, false, start + 6 hours), "fallback at its deadline");
    }

    // ---
    // VOLUNTARY WITHDRAWALS
    // ---

    function test_withdraw_insideLock_withinActivePasses_beyondReverts() public view {
        CollateralActivationConfig memory c = _config();
        uint256 start = block.timestamp - 1 hours;
        ActivationModel.Lot memory l = _lot(0, 10 ether, start, 2 hours);

        (bytes memory err, bool clears) = ActivationModel.withdrawOutcome(l, c, 5 ether, 5 ether, block.timestamp);
        assertEq(err.length, 0, "draw within the active balance rejected");
        assertFalse(clears, "draw within the active balance cleared the buckets");

        (err, clears) = ActivationModel.withdrawOutcome(l, c, 5 ether, 5 ether + 1, block.timestamp);
        assertEq(
            err,
            abi.encodeWithSelector(
                CollateralActivationLib.ActivatingCollateralLocked.selector, 10 ether, start + 3 hours
            ),
            "draw past the active balance accepted"
        );
        assertFalse(clears, "rejected draw cleared the buckets");
    }

    function test_withdraw_afterLock_mustClearInactive() public view {
        CollateralActivationConfig memory c = _config();
        uint256 start = block.timestamp - 3 hours;
        ActivationModel.Lot memory l = _lot(2 ether, 10 ether, start, 2 hours);

        (bytes memory err, bool clears) = ActivationModel.withdrawOutcome(l, c, 5 ether, 12 ether - 1, block.timestamp);
        assertEq(
            err,
            abi.encodeWithSelector(
                CollateralActivationLib.InactiveCollateralNotCleared.selector, 12 ether - 1, 12 ether
            ),
            "partial draw on the inactive balance accepted"
        );
        assertFalse(clears, "rejected draw cleared the buckets");

        (err, clears) = ActivationModel.withdrawOutcome(l, c, 5 ether, 12 ether, block.timestamp);
        assertEq(err.length, 0, "exact inactive draw rejected");
        assertTrue(clears, "exact inactive draw did not clear the buckets");

        (err, clears) = ActivationModel.withdrawOutcome(l, c, 5 ether, 17 ether, block.timestamp);
        assertEq(err.length, 0, "draw over the inactive balance rejected");
        assertTrue(clears, "draw over the inactive balance did not clear the buckets");

        (err, clears) = ActivationModel.withdrawOutcome(_lot(0, 0, 0, 0), c, 5 ether, 5 ether, block.timestamp);
        assertEq(err.length, 0, "draw on an active-only position rejected");
        assertFalse(clears, "draw on an active-only position cleared the buckets");
    }

    // ---
    // FORCED REDUCTIONS
    // ---

    function test_reduce_orderActiveDustActivating() public {
        uint256 start = block.timestamp - 1 hours;
        h.setLot(alice, _lot(3 ether, 10 ether, start, DELAY_AT_TEN));
        // 5 ether of active collateral, then the whole 3 ether of dust, then 4 ether of the lot.
        h.reduce(alice, 5 ether, 12 ether);
        ActivationModel.Lot memory l = h.lot(alice);
        assertEq(l.dust, 0, "dust survived a reduction past the active balance");
        assertEq(l.activating, 6 ether, "activating remainder");
        assertEq(l.start, start, "remainder lost its start");
        assertEq(l.baseDelay, DELAY_AT_TEN, "remainder lost its base delay");

        h.reduce(alice, 0, 6 ether);
        l = h.lot(alice);
        assertEq(l.activating, 0, "lot survived a full reduction");
        assertEq(l.start, 0, "emptied lot kept its start");
        assertEq(l.baseDelay, 0, "emptied lot kept its base delay");
    }

    function test_reduce_inflowByContributionOnly() public {
        uint256 t0 = block.timestamp;
        h.classify(alice, 100 ether, false);
        h.classify(bob, 50 ether, false);
        assertEq(h.inflow(t0), 150 ether, "inflow after both crossings");

        // Only activating collateral fed the inflow, so taking active collateral or dust reverses nothing.
        h.reduce(alice, 1000 ether, 100 ether);
        assertEq(h.inflow(t0), 150 ether, "a reduction inside the active balance moved the inflow");
        h.setLot(carol, _lot(5 ether, 0, 0, 0));
        h.reduce(carol, 0, 5 ether);
        assertEq(h.inflow(t0), 150 ether, "a dust-only reduction moved the inflow");

        h.reduce(alice, 0, 100 ether);
        assertEq(h.inflow(t0), 50 ether, "inflow after the whole lot was taken");
        h.reduce(bob, 0, 10 ether);
        assertEq(h.inflow(t0), 40 ether, "inflow after a partial reversal");

        address[] memory borrowers = new address[](2);
        borrowers[0] = alice;
        borrowers[1] = bob;
        h.beginTransaction(borrowers);
        h.reduce(bob, 0, 40 ether);
        assertEq(h.inflow(t0), 40 ether, "a reversal reached into an earlier transaction");
    }

    /// @notice A reversal clamps the stored inflow to the cap in force now, not to the stored value, which was
    ///         clamped under whatever cap stood when it was written. Governance moving `maxDelayInflow` between the
    ///         deposit and the reversal is the only thing that separates the two, in either direction.
    /// @dev `CollateralActivationLib._storePersistentInflow` stores `min(uncapped, maxDelayInflow)` on every write,
    ///      the reversal path included. Kills `test/setup/ActivationModel.sol` with the clamp read off `s.inflow`
    ///      instead of `c.maxDelayInflow`, which pins the accumulator at a stale cap.
    function test_reduce_clampsToTheLiveCap() public {
        uint256 t0 = block.timestamp;
        h.classify(alice, 8_000 ether, false);
        h.classify(bob, 7_000 ether, false);
        // 15 000 gross, clamped to the standing cap.
        assertEq(h.inflow(t0), 10_000 ether, "stored inflow is the gross total clamped to the cap");

        CollateralActivationConfig memory raised = _config();
        raised.maxDelayInflow = 20_000 ether;
        h.setConfig(raised);

        // 14 000 gross left, under the raised cap, so the whole remainder stands.
        h.reduce(bob, 0, 1_000 ether);
        assertEq(h.inflow(t0), 14_000 ether, "a raised cap must release the gross remainder");

        CollateralActivationConfig memory lowered = _config();
        lowered.maxDelayInflow = 5_000 ether;
        h.setConfig(lowered);

        // 13 000 gross left, over the lowered cap, so the cap binds.
        h.reduce(bob, 0, 1_000 ether);
        assertEq(h.inflow(t0), 5_000 ether, "a lowered cap must bind the gross remainder");
    }

    function test_reduce_laterInTheTransaction_givesBackUndecayed() public {
        uint256 t0 = block.timestamp;
        h.classify(alice, 100 ether, false);
        // The warp stays inside one transaction, so the reversal takes 40 from 100, not from its decayed value.
        vm.warp(t0 + 1 hours);
        h.reduce(alice, 0, 40 ether);
        assertEq(h.inflow(block.timestamp), 60 ether, "the give-back decayed the accumulator first");
        // Decay restarts at the reversal: floor(10 000 ether / 86 400) per second.
        assertEq(h.inflow(block.timestamp + 1), 60 ether - 115_740_740_740_740_740, "decay did not resume from here");
    }
}
