// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {GuardiansOpinion} from "../types/GuardianSignalsTypes.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";

/// @title CollateralActivationLib
/// @author Lido
/// @notice Collateral activation throttle. Stores a borrower's un-matured collateral (`dust` and `activating`)
///         and the timer. The caller owns the raw `total` and derives `active = total - inactive`, where
///         `inactive = activating + dust`.
/// @dev Per-borrower the lib stores two un-matured buckets plus the timer. Maturity and debits move collateral
///      within or out of these buckets:
///
///         dust        below the threshold, untimed, freely withdrawable, not borrowable
///         activating  crossed the threshold, timed and lockable, not borrowable yet
///         active      derived by the caller as total - activating - dust
///
///      A sub-threshold deposit stays in dust and leaves the activation timer untouched. The deposit that
///      aggregates dust past the threshold folds the whole lot into the throttle and (re)starts the timer; a
///      later deposit folds in its own size and can push the unlock out, never pull it in. Maturity empties
///      `activating`, lowering the borrower's inactive total, so the caller's `total - inactive` counts it as active.
///      An instant deposit counts as active immediately. Withdrawal and seizure drain dust then activating above
///      the lock and return the post-op inactive (`activating + dust`). A drain with no lock floor that leaves the
///      inactive remainder below the threshold folds it back into dust, off the timer and the maturation scan.
/// @dev The base delay is frozen at deposit from the market-wide recent inflow, the same for every position
///      regardless of the depositing address. The inflow is capped at `maxDelayInflow` and decays at a fixed
///      rate, draining from the cap to zero over `maxActivationDelay`.
/// @dev The caller embeds `State`, forwards calls, and supplies the external reads the lib cannot make (the
///      guardian-owned activation delay surcharge and quorum-scan frontier). The only state outside `State` is
///      the per-tx transient inflow accounting (uncapped inflow and per-borrower contribution).
library CollateralActivationLib {
    using SafeCast for uint256;

    // ---
    // CONSTANTS
    // ---

    /// @dev Sanity ceiling for governance-set delays.
    uint256 internal constant MAX_DELAY_DURATION = 7 days;

    /// @dev Transient slot: uncapped tx inflow (`baseline + remaining same-tx contributions`). Zero is also the
    ///      uninitialized state: recomputing a genuinely zero value from the persistent accumulator is harmless.
    bytes32 private constant TRANSIENT_TX_UNCAPPED_INFLOW_SLOT =
        keccak256("lido.lend.CollateralActivationLib.TxUncappedInflow");

    /// @dev Transient per-borrower namespace: the borrower's reversible gross contribution this tx.
    bytes32 private constant TRANSIENT_CONTRIBUTION_NAMESPACE =
        keccak256("lido.lend.CollateralActivationLib.TxContribution");

    // ---
    // EVENTS
    // ---

    /// @notice A deposit enters or extends the activation timer. `position` is the resulting state.
    event CollateralActivating(address indexed borrower, uint256 amount, Position position);

    /// @notice An activating lot matures, or an instant deposit lands active. `position` is the resulting state.
    event CollateralActivated(address indexed borrower, uint256 amount, Position position);

    /// @notice A sub-threshold deposit is held as untimed dust. `position` is the resulting state.
    event CollateralDusted(address indexed borrower, uint256 amount, Position position);

    /// @notice Collateral is drained from the un-matured buckets. `position` is the resulting state.
    event CollateralDrained(address indexed borrower, uint256 amount, Position position);

    /// @notice A drain with no lock floor folds the activating portion of a sub-threshold inactive remainder into
    ///         dust. `amount` is the activating portion moved; `position` is the resulting state.
    event CollateralDemoted(address indexed borrower, uint256 amount, Position position);

    /// @notice Emitted when the full activation config is set.
    event CollateralActivationConfigSet(CollateralActivationConfig config);

    // ---
    // ERRORS
    // ---

    /// @notice The activation delay floor is zero.
    error ZeroMinActivationDelay();

    /// @notice The activation delay floor exceeds the cap.
    error InvalidActivationDelays();

    /// @notice The activation delay cap exceeds `MAX_DELAY_DURATION`.
    error MaxActivationDelayExceeded();

    /// @notice The activating-lock duration exceeds `MAX_DELAY_DURATION`.
    error MaxActivatingLockDurationExceeded();

    /// @notice The dust threshold (`minActivationAmount`) is zero.
    error ZeroMinActivationAmount();

    /// @notice The inflow reference (`maxDelayInflow`) is zero.
    error ZeroMaxDelayInflow();

    /// @notice The guardian-quorum fallback delay is nonzero but does not exceed `maxActivationDelay`, leaving the
    ///         quorum gate no window.
    error InvalidMaxGuardiansQuorumDelay();

    /// @notice The guardian-quorum fallback delay exceeds `MAX_DELAY_DURATION`.
    error MaxGuardiansQuorumDelayExceeded();

    /// @notice The per-strike surcharge exceeds `MAX_DELAY_DURATION`.
    error MaxDelayPerStrikeExceeded();

    /// @notice The per-suspect surcharge exceeds `MAX_DELAY_DURATION`.
    error MaxDelayPerSuspectExceeded();

    // ---
    // TYPES
    // ---

    /// @notice Per-borrower un-matured collateral. The caller derives `active` as `total - activating - dust`.
    /// @param dust            Free collateral below the activation threshold, withdrawable, never timed.
    /// @param activating      Collateral inside the activation timer, not yet borrowable.
    /// @param activatingStart Activation timer start, 0 when there is no active timer.
    /// @param activatingDelay Base inflow-scaled delay, frozen at deposit.
    struct Position {
        uint128 dust;
        uint128 activating;
        uint40 activatingStart;
        uint32 activatingDelay;
    }

    /// @notice Market-wide activation state. Per-borrower the lib stores the un-matured buckets, and the caller
    ///         derives `active` from the core `total`.
    /// @param inflow          Recent collateral inflow, time-decayed. The throttle accumulator snapshot.
    /// @param inflowUpdatedAt Timestamp `inflow` was snapshotted at. The decay clock starts here.
    /// @param config          Governance-tunable parameters.
    /// @param positions       Per-borrower un-matured collateral.
    struct State {
        uint128 inflow;
        uint40 inflowUpdatedAt;
        CollateralActivationConfig config;
        mapping(address borrower => Position) positions;
    }

    // ---
    // CONFIGURATION
    // ---

    /// @notice Validate and store the governance-tunable config.
    function setConfig(State storage $, CollateralActivationConfig memory cfg) internal {
        if (cfg.minActivationDelay == 0) revert ZeroMinActivationDelay();
        if (cfg.minActivationDelay > cfg.maxActivationDelay) revert InvalidActivationDelays();
        if (cfg.maxActivationDelay > MAX_DELAY_DURATION) revert MaxActivationDelayExceeded();
        if (cfg.activatingLockDuration > MAX_DELAY_DURATION) revert MaxActivatingLockDurationExceeded();
        if (cfg.maxGuardiansQuorumDelay != 0 && cfg.maxGuardiansQuorumDelay <= cfg.maxActivationDelay) {
            revert InvalidMaxGuardiansQuorumDelay();
        }
        if (cfg.maxGuardiansQuorumDelay > MAX_DELAY_DURATION) revert MaxGuardiansQuorumDelayExceeded();
        if (cfg.minActivationAmount == 0) revert ZeroMinActivationAmount();
        if (cfg.maxDelayInflow == 0) revert ZeroMaxDelayInflow();
        if (cfg.delayPerStrike > MAX_DELAY_DURATION) revert MaxDelayPerStrikeExceeded();
        if (cfg.delayPerSuspect > MAX_DELAY_DURATION) revert MaxDelayPerSuspectExceeded();

        $.config = cfg;

        emit CollateralActivationConfigSet(cfg);
    }

    // ---
    // ACTIONS
    // ---

    /// @notice Book a new collateral deposit. It joins dust, and once dust plus this deposit crosses the
    ///         threshold the whole dormant amount enters the activation timer and is added to the market inflow.
    ///         When `instant` (a trusted caller) the deposited collateral is not held inactive: it joins neither
    ///         bucket and counts as active immediately, while any existing dust remains dormant.
    /// @dev All activating collateral shares one timer: a top-up that extends the deadline restarts
    ///      `activatingStart` for the whole lot, clearing the suspect surcharge if it restarts past `suspectExpiry`.
    /// @param instant Whether the supplying caller is trusted to skip the activation timer and inflow throttle.
    function credit(State storage $, address borrower, uint256 assets, bool instant) internal {
        Position storage position = $.positions[borrower];

        if (instant) {
            emit CollateralActivated(borrower, assets, position);
            return;
        }

        uint256 dust = position.dust;
        uint256 assetsWithDust = assets + dust;

        if (assetsWithDust < $.config.minActivationAmount) {
            position.dust = assetsWithDust.toUint128();
            emit CollateralDusted(borrower, assets, position);
            return;
        }

        if (dust > 0) position.dust = 0;

        position.activating = (position.activating + assetsWithDust).toUint128();

        uint256 newInflow = _applyInflowIncrement($, borrower, assetsWithDust);
        uint256 delay = _computeDelay($, newInflow);

        if (block.timestamp + delay > position.activatingStart + position.activatingDelay) {
            position.activatingStart = block.timestamp.toUint40();
            position.activatingDelay = delay.toUint32();
        }

        emit CollateralActivating(borrower, assetsWithDust, position);
    }

    /// @notice Voluntary withdrawal: drain `amount` from the un-matured buckets honoring the lock, then, when no
    ///         lock floor applies, demote the activating portion if the total inactive remainder is sub-threshold.
    ///         Reverses this collateral's same-tx inflow over the full activating reduction and returns the
    ///         post-debit inactive (`activating + dust`).
    /// @dev Forced seizure uses `seize`, which drains with no lock floor.
    function debit(State storage $, address borrower, uint256 amount) internal returns (uint256 inactive) {
        Position storage position = $.positions[borrower];

        (uint256 activatingBefore, uint256 activatingStart) = (position.activating, position.activatingStart);
        uint256 activatingLockDeadline = activatingStart + $.config.activatingLockDuration;
        uint256 activatingLockAmount =
            activatingStart != 0 && block.timestamp < activatingLockDeadline ? $.config.activatingLockAmount : 0;

        inactive = _drain($, borrower, amount, activatingLockAmount);

        // Reverse the same-tx inflow over the full activating reduction (drained + demoted).
        _applyInflowDecrement($, borrower, activatingBefore - position.activating);
    }

    /// @notice Mature the borrower's activating lot once its timer has elapsed and the guardian quorum has
    ///         scanned past the unlock (or the `maxGuardiansQuorumDelay` fallback has elapsed). Maturity empties
    ///         `activating`, lowering the inactive total, so the caller's `total - inactive` counts it as active.
    ///         Returns the post-mature `inactive` (`activating + dust`). A freeze skips maturation, and a banned
    ///         borrower's unlock is pushed to infinity so it never matures.
    function sync(State storage $, bool isFrozen, address borrower, GuardiansOpinion memory opinion)
        internal
        returns (uint256 inactive)
    {
        Position storage position = $.positions[borrower];

        if (!isFrozen && position.activatingStart > 0) {
            uint256 unlockTime = _getUnlockTime($, borrower, opinion);
            bool isUnlockTimePassed = block.timestamp >= unlockTime;
            bool hasGuardiansQuorum = unlockTime <= opinion.quorumFrontierTimestamp;
            bool maxQuorumDelayElapsed = block.timestamp >= position.activatingStart + $.config.maxGuardiansQuorumDelay;

            if (isUnlockTimePassed && (hasGuardiansQuorum || maxQuorumDelayElapsed)) {
                uint128 activatedAmount = position.activating;
                position.activating = 0;
                _clearTimer(position);
                emit CollateralActivated(borrower, activatedAmount, position);
            }
        }

        return position.dust + position.activating;
    }

    /// @notice Forced seizure of `amount` (liquidation, settle): drains the un-matured buckets with no lock floor,
    ///         demotes a sub-threshold inactive remainder to dust, then reverses the same-tx inflow the removed
    ///         activating collateral added. Returns the post-seize inactive (`activating + dust`); the caller
    ///         derives `active = total - inactive`.
    function seize(State storage $, address borrower, uint256 amount) internal returns (uint256 inactive) {
        Position storage position = $.positions[borrower];
        uint256 activatingBefore = position.activating;

        inactive = _drain($, borrower, amount, 0);
        _applyInflowDecrement($, borrower, activatingBefore - position.activating);
    }

    // ---
    // GETTERS
    // ---

    /// @notice Unlock timestamp of the borrower's activating lot, 0 if none. `opinion` carries the guardian
    ///         counters this derives the surcharge from (`type(uint256).max` for a banned borrower).
    function getUnlockTime(State storage $, address borrower, GuardiansOpinion memory opinion)
        internal
        view
        returns (uint256)
    {
        if ($.positions[borrower].activatingStart == 0) return 0;
        return _getUnlockTime($, borrower, opinion);
    }

    /// @notice The borrower's activation state: how much collateral is activating (timed) versus dust (untimed).
    ///         The caller derives borrowable collateral as `total - activating - dust`.
    function getActivationState(State storage $, address borrower)
        internal
        view
        returns (uint256 activating, uint256 dust)
    {
        Position storage position = $.positions[borrower];
        return (position.activating, position.dust);
    }

    /// @notice Current decayed inflow.
    /// @dev Fixed-rate decay: the inflow loses `maxDelayInflow` units over `maxActivationDelay`. Saturates at 0.
    function calcDecayedInflow(State storage $) internal view returns (uint256) {
        uint256 decayAmount =
            Math.mulDiv($.config.maxDelayInflow, block.timestamp - $.inflowUpdatedAt, $.config.maxActivationDelay);
        return Math.saturatingSub($.inflow, decayAmount);
    }

    /// @notice Activation delay a deposit of `inflowIncrement` would incur at the current inflow: its size folds
    ///         into the inflow (as on credit), lengthening the delay up to the cap.
    function getCurrentActivationDelay(State storage $, uint256 inflowIncrement) internal view returns (uint256) {
        return _computeDelay($, Math.saturatingAdd(calcDecayedInflow($), inflowIncrement));
    }

    // ---
    // PRIVATE HELPERS
    // ---

    /// @dev Drain up to `amount` from the un-matured buckets, waterfall: dust, then activating above `drainFloor`.
    ///      A zero floor also permits demoting a sub-threshold inactive remainder to dust. Returns the post-drain
    ///      inactive (`activating + dust`); the caller covers any shortfall from active. `debit` passes its active
    ///      lock floor; forced paths pass 0, making all un-matured collateral drainable and permitting demotion of
    ///      a sub-threshold remainder.
    function _drain(State storage $, address borrower, uint256 amount, uint256 drainFloor)
        private
        returns (uint256 inactive)
    {
        Position storage position = $.positions[borrower];
        uint256 dust = position.dust;
        uint256 activating = position.activating;

        // Waterfall within the un-matured buckets: dust first, then activating above the lock. Whatever it
        // leaves uncovered the caller takes from active, derived as `total - inactive`.
        uint256 fromDust = Math.min(dust, amount);
        uint256 fromActivating = Math.min(amount - fromDust, Math.saturatingSub(activating, drainFloor));

        position.dust = uint128(dust - fromDust);
        position.activating = uint128(activating - fromActivating);

        if (position.activating == 0) _clearTimer(position);

        uint256 drained = fromDust + fromActivating;
        if (drained != 0) emit CollateralDrained(borrower, drained, position);

        uint256 activatingAfterDrain = position.activating;
        uint256 inactiveAfterDrain = position.dust + activatingAfterDrain;

        // Keep locked collateral timed. Otherwise demote only when the whole inactive remainder is dust-sized;
        // checking `activating` alone could add it to existing dust and push that bucket above the threshold.
        if (drainFloor == 0 && activatingAfterDrain != 0 && inactiveAfterDrain < $.config.minActivationAmount) {
            position.dust = inactiveAfterDrain.toUint128();
            position.activating = 0;
            _clearTimer(position);
            emit CollateralDemoted(borrower, activatingAfterDrain, position);
        }

        return inactiveAfterDrain;
    }

    /// @dev Book `increment` of gross activating into the tx-wide accumulator and the borrower's reversible
    ///      contribution, then recompute the capped persistent inflow. Returns the recomputed persistent inflow.
    function _applyInflowIncrement(State storage $, address borrower, uint256 increment)
        private
        returns (uint256 newInflow)
    {
        uint256 uncappedInflow = _loadTxUncappedInflow($) + increment;
        _tstore(TRANSIENT_TX_UNCAPPED_INFLOW_SLOT, uncappedInflow);

        bytes32 slot = _borrowerContributionSlot(borrower);
        _tstore(slot, _tload(slot) + increment);

        _storePersistentInflow($, uncappedInflow);
        return $.inflow;
    }

    /// @dev Reverse up to `decrement` of the borrower's own gross contribution (clamped so it cannot touch
    ///      another borrower's or prior-tx collateral), drop it from the uncapped inflow, and recompute persistent.
    function _applyInflowDecrement(State storage $, address borrower, uint256 decrement) private {
        bytes32 slot = _borrowerContributionSlot(borrower);
        uint256 contribution = _tload(slot);
        uint256 removed = Math.min(contribution, decrement);
        if (removed == 0) return;

        _tstore(slot, contribution - removed);

        uint256 uncappedInflow = _loadTxUncappedInflow($) - removed;
        _tstore(TRANSIENT_TX_UNCAPPED_INFLOW_SLOT, uncappedInflow);
        _storePersistentInflow($, uncappedInflow);
    }

    /// @dev Return the uncapped tx inflow, lazily initializing it from the decayed prior-tx baseline.
    function _loadTxUncappedInflow(State storage $) private view returns (uint256 uncappedInflow) {
        uncappedInflow = _tload(TRANSIENT_TX_UNCAPPED_INFLOW_SLOT);
        if (uncappedInflow == 0) uncappedInflow = calcDecayedInflow($);
    }

    /// @dev Clamp the uncapped tx inflow to the current governance cap for the persistent accumulator.
    function _storePersistentInflow(State storage $, uint256 uncappedInflow) private {
        $.inflow = uint128(Math.min(uncappedInflow, $.config.maxDelayInflow));
        $.inflowUpdatedAt = block.timestamp.toUint40();
    }

    /// @dev Unlock = start + frozen base delay + the guardian surcharge: `strikeCount * delayPerStrike`, plus
    ///      `suspectCount * delayPerSuspect` only for a lot whose activation started before the suspect snapshot
    ///      lapses (`suspectExpiryTimestamp`). A banned borrower never unlocks (returns max).
    function _getUnlockTime(State storage $, address borrower, GuardiansOpinion memory opinion)
        private
        view
        returns (uint256)
    {
        if (opinion.banned) return type(uint256).max;

        Position storage position = $.positions[borrower];
        uint256 surcharge = opinion.strikeCount * $.config.delayPerStrike;
        if (position.activatingStart < opinion.suspectExpiryTimestamp) {
            surcharge += opinion.suspectCount * $.config.delayPerSuspect;
        }
        return position.activatingStart + position.activatingDelay + surcharge;
    }

    /// @dev Base delay scales linearly with the inflow, clamped at both ends. The dormant lot's size is folded
    ///      into `effectiveInflow` before the call, so a lot's own size lengthens its delay.
    function _computeDelay(State storage $, uint256 effectiveInflow) private view returns (uint256) {
        uint256 maxDelayInflow = $.config.maxDelayInflow;
        uint256 maxActivationDelay = $.config.maxActivationDelay;
        uint256 minActivationDelay = $.config.minActivationDelay;

        if (effectiveInflow >= maxDelayInflow) return maxActivationDelay;

        uint256 delaySpan = maxActivationDelay - minActivationDelay;
        return minActivationDelay + Math.mulDiv(delaySpan, effectiveInflow, maxDelayInflow);
    }

    /// @dev Per-tx, per-borrower transient slot for the borrower's reversible gross contribution this tx.
    function _borrowerContributionSlot(address borrower) private pure returns (bytes32 slot) {
        slot = keccak256(abi.encode(TRANSIENT_CONTRIBUTION_NAMESPACE, borrower));
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /// @dev Clear the activation timer. No activating balance means no timer.
    function _clearTimer(Position storage position) private {
        position.activatingStart = 0;
        position.activatingDelay = 0;
    }
}
