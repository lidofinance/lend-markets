// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {GuardiansOpinion} from "../../src/types/GuardianSignalsTypes.sol";

/// @notice The collateral-activation state machine of `docs/specs/market-controller.md`, restated from that
///         document alone. Tests predict each activation outcome from it and assert the controller against it.
///         Only the error selectors come from the code under test.
/// @dev Stores no collateral total. Callers pass the active balance: core collateral minus the inactive buckets.
library ActivationModel {
    // ---
    // TYPES
    // ---

    /// @notice One borrower's inactive collateral: untimed dust, and activating collateral that shares one start
    ///         and one stored base delay, which configuration changes never rewrite.
    /// @param contribution What this borrower added to the market inflow in the current transaction: the most a
    ///        reduction in the same transaction takes back out.
    /// @dev With no activating collateral, `start` and `baseDelay` are zero, so the next supply that crosses the
    ///      activation threshold always starts a new timer.
    struct Lot {
        uint256 dust;
        uint256 activating;
        uint256 start;
        uint256 baseDelay;
        uint256 contribution;
    }

    /// @notice The market-wide inflow accumulator, the time it was last written, and every borrower's lot.
    /// @param txInflow The current transaction's accumulator before the cap. It starts from the decayed
    ///        accumulator at the first contribution and does not decay within the transaction, so a contribution
    ///        and its reversal cancel exactly.
    struct State {
        uint256 inflow;
        uint256 inflowAt;
        uint256 txInflow;
        mapping(address => Lot) lots;
    }

    // ---
    // CLASSIFICATION
    // ---

    /// @notice The encoded revert a supply of `amount` must hit, or empty. It reads only dust, which the maturation
    ///         sync never changes, so it can run before that sync; a rejected supply undoes the sync.
    function supplyOutcome(Lot memory l, CollateralActivationConfig memory c, uint256 amount, bool instant)
        internal
        pure
        returns (bytes memory err)
    {
        if (instant) return err;
        if (amount < c.minDepositAmount) {
            return abi.encodeWithSelector(CollateralActivationLib.DepositTooSmall.selector, amount, c.minDepositAmount);
        }
        if (l.dust != 0 && l.dust + amount < c.minActivationAmount) {
            return abi.encodeWithSelector(
                CollateralActivationLib.DustNotResolved.selector, l.dust, amount, c.minActivationAmount
            );
        }
    }

    /// @notice Classifies a supply of `amount` for `b` after the caller has synced the lot. A rejected supply
    ///         returns its error, and an instant one is active at once; neither changes the state.
    function classify(State storage s, CollateralActivationConfig memory c, address b, uint256 amount, bool instant)
        internal
        returns (bytes memory err)
    {
        Lot storage l = s.lots[b];
        err = supplyOutcome(l, c, amount, instant);
        if (instant || err.length != 0) return err;
        uint256 combined = l.dust + amount;
        if (combined < c.minActivationAmount) {
            l.dust = combined;
            return err;
        }
        // A zero `txInflow` reads as no contribution yet. A reversal returns it to zero only from a zero start,
        // and the stored accumulator is then zero too.
        uint256 effectiveInflow = (s.txInflow == 0 ? decayedInflow(s, c, block.timestamp) : s.txInflow) + combined;
        uint256 quoted = baseDelay(c, effectiveInflow);
        // A top-up can postpone activation but never bring it forward.
        if (block.timestamp + quoted > l.start + l.baseDelay) {
            l.start = block.timestamp;
            l.baseDelay = quoted;
        }
        l.dust = 0;
        l.activating += combined;
        l.contribution += combined;
        s.txInflow = effectiveInflow;
        s.inflow = Math.min(effectiveInflow, c.maxDelayInflow);
        s.inflowAt = block.timestamp;
    }

    /// @notice The base delay quoted at `effectiveInflow`, which already includes the new supply.
    function baseDelay(CollateralActivationConfig memory c, uint256 effectiveInflow) internal pure returns (uint256) {
        if (effectiveInflow >= c.maxDelayInflow) return c.maxActivationDelay;
        uint256 span = uint256(c.maxActivationDelay) - c.minActivationDelay;
        return c.minActivationDelay + span * effectiveInflow / c.maxDelayInflow;
    }

    /// @notice The accumulator at `at`. The decay uses the current configuration, so a configuration change
    ///         reinterprets the stored value.
    function decayedInflow(State storage s, CollateralActivationConfig memory c, uint256 at)
        internal
        view
        returns (uint256)
    {
        uint256 decay = uint256(c.maxDelayInflow) * (at - s.inflowAt) / c.maxActivationDelay;
        return s.inflow > decay ? s.inflow - decay : 0;
    }

    // ---
    // MATURATION
    // ---

    /// @notice The lot's stored deadline plus the guardian surcharges. A banned borrower never unlocks.
    function unlockTime(Lot memory l, CollateralActivationConfig memory c, GuardiansOpinion memory o)
        internal
        pure
        returns (uint256)
    {
        if (o.banned) return type(uint256).max;
        uint256 unlock = l.start + l.baseDelay + o.strikeCount * c.delayPerStrike;
        if (l.start < o.suspectExpiryTimestamp) unlock += o.suspectCount * c.delayPerSuspect;
        return unlock;
    }

    /// @notice Whether a sync at `at` matures the lot: unlocked, past the guardian quorum gate, and not frozen.
    function matures(
        Lot memory l,
        CollateralActivationConfig memory c,
        GuardiansOpinion memory o,
        bool frozen,
        uint256 at
    ) internal pure returns (bool) {
        if (l.activating == 0 || frozen) return false;
        uint256 unlock = unlockTime(l, c, o);
        if (at < unlock) return false;
        return o.quorumFrontierTimestamp >= unlock || at >= l.start + c.maxGuardiansQuorumDelay;
    }

    /// @notice Matures `b`'s lot if it is due. The collateral-supply, collateral-withdrawal and borrow hooks run
    ///         this first; nothing else matures a lot.
    function sync(
        State storage s,
        CollateralActivationConfig memory c,
        address b,
        GuardiansOpinion memory o,
        bool frozen
    ) internal {
        Lot storage l = s.lots[b];
        if (!matures(l, c, o, frozen, block.timestamp)) return;
        l.activating = 0;
        l.start = 0;
        l.baseDelay = 0;
    }

    // ---
    // REDUCTIONS
    // ---

    /// @notice Whether the activation lock holds the lot at `at`. It needs activating collateral, so a dust-only
    ///         lot can always clear.
    function lockBinds(Lot memory l, CollateralActivationConfig memory c, uint256 at) internal pure returns (bool) {
        return l.activating != 0 && c.activatingLockDuration != 0 && at < l.start + c.activatingLockDuration;
    }

    /// @notice The encoded revert a voluntary withdrawal of `amount` at `at` must hit, or empty, and whether it
    ///         clears both inactive buckets. `l` is the lot as the withdrawal's maturation sync leaves it.
    function withdrawOutcome(
        Lot memory l,
        CollateralActivationConfig memory c,
        uint256 active,
        uint256 amount,
        uint256 at
    ) internal pure returns (bytes memory err, bool clearsInactive) {
        uint256 inactive = l.dust + l.activating;
        if (inactive == 0) return (err, false);
        if (lockBinds(l, c, at)) {
            if (amount <= active) return (err, false);
            return (
                abi.encodeWithSelector(
                    CollateralActivationLib.ActivatingCollateralLocked.selector,
                    l.activating,
                    l.start + c.activatingLockDuration
                ),
                false
            );
        }
        if (amount < inactive) {
            return (
                abi.encodeWithSelector(CollateralActivationLib.InactiveCollateralNotCleared.selector, amount, inactive),
                false
            );
        }
        return (err, true);
    }

    /// @notice Books a reduction of `b`'s collateral by `amount` against an active balance of `active`. It takes
    ///         active first, then dust, then activating; an activating remainder keeps its start and base delay.
    ///         Only activating collateral fed the inflow, so only what leaves that bucket comes off the inflow, up
    ///         to this borrower's contribution in the current transaction.
    /// @dev A withdrawal that clears the inactive balance takes it first, so it passes `active = 0`; a forced
    ///      reduction passes the real active balance.
    function reduce(State storage s, CollateralActivationConfig memory c, address b, uint256 active, uint256 amount)
        internal
    {
        Lot storage l = s.lots[b];
        uint256 left = amount > active ? amount - active : 0;
        uint256 fromDust = Math.min(l.dust, left);
        l.dust -= fromDust;
        uint256 fromActivating = Math.min(l.activating, left - fromDust);
        l.activating -= fromActivating;
        if (l.activating == 0) {
            l.start = 0;
            l.baseDelay = 0;
        }
        uint256 reversed = Math.min(l.contribution, fromActivating);
        if (reversed == 0) return;
        l.contribution -= reversed;
        s.txInflow -= reversed;
        // Clamped against the live cap, not the stored value, which was clamped under the cap of its own time.
        s.inflow = Math.min(s.txInflow, c.maxDelayInflow);
        s.inflowAt = block.timestamp;
    }

    /// @notice Starts a transaction; earlier contributions are no longer reversible. Call it where the running
    ///         forge starts one: each top-level test call on 1.8.x, never on 1.7.x, where a test is one transaction.
    function beginTransaction(State storage s, address[] memory borrowers) internal {
        s.txInflow = 0;
        for (uint256 i; i < borrowers.length; ++i) {
            s.lots[borrowers[i]].contribution = 0;
        }
    }
}
