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
/// @dev Per-borrower the lib stores two un-matured buckets plus the timer. Deposits, maturity, voluntary
///      withdrawal, and forced seizure move collateral within or out of these buckets:
///
///         dust        below the threshold, untimed, freely withdrawable, not borrowable
///         activating  crossed the threshold, timed and lockable, not borrowable yet
///         active      derived by the caller as total - activating - dust
///
///      A sub-threshold deposit is held as dust only while the dust bucket is empty; a deposit onto pending
///      dust must lift the combined amount to the threshold or it reverts. The deposit that reaches the
///      threshold moves dust plus itself into `activating` and (re)starts the timer; a later deposit folds in
///      its own size and can push the unlock out, never pull it in. Maturity empties `activating`, so the
///      caller's `total - inactive` counts it as active. An instant deposit counts as active immediately.
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

    /// @notice The minimum deposit exceeds the activation threshold.
    error InvalidMinDepositAmount();

    /// @notice The guardian-quorum fallback delay is nonzero but does not exceed `maxActivationDelay`, leaving the
    ///         quorum gate no window.
    error InvalidMaxGuardiansQuorumDelay();

    /// @notice The guardian-quorum fallback delay exceeds `MAX_DELAY_DURATION`.
    error MaxGuardiansQuorumDelayExceeded();

    /// @notice The per-strike surcharge exceeds `MAX_DELAY_DURATION`.
    error MaxDelayPerStrikeExceeded();

    /// @notice The per-suspect surcharge exceeds `MAX_DELAY_DURATION`.
    error MaxDelayPerSuspectExceeded();

    /// @notice A non-instant deposit is below the configured minimum.
    error DepositTooSmall(uint256 assets, uint256 minDepositAmount);

    /// @notice A non-instant deposit onto existing dust leaves the combined amount below the activation threshold.
    error DustNotResolved(uint256 dust, uint256 assets, uint256 minActivationAmount);

    /// @notice A voluntary withdrawal would remove only part of the inactive balance (`dust + activating`);
    ///         it must remove the whole balance or none of it.
    error InactiveCollateralNotCleared(uint256 requested, uint256 inactive);

    /// @notice A voluntary withdrawal cannot remove activating collateral before the lock deadline.
    error ActivatingCollateralLocked(uint256 activating, uint256 lockDeadline);

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
        if (cfg.minDepositAmount > cfg.minActivationAmount) revert InvalidMinDepositAmount();
        if (cfg.delayPerStrike > MAX_DELAY_DURATION) revert MaxDelayPerStrikeExceeded();
        if (cfg.delayPerSuspect > MAX_DELAY_DURATION) revert MaxDelayPerSuspectExceeded();

        $.config = cfg;

        emit CollateralActivationConfigSet(cfg);
    }

    // ---
    // ACTIONS
    // ---

    /// @notice Book a new collateral deposit. A deposit below the threshold is held as dust, and only while the
    ///         dust bucket is empty; a deposit onto existing dust must lift the combined amount to the threshold
    ///         or it reverts. A deposit that reaches the threshold moves dust plus itself into the activation
    ///         timer and adds that amount to the market inflow. When `instant` (a trusted caller) the deposit
    ///         joins neither bucket and counts as active immediately; existing dust stays untouched.
    /// @dev All activating collateral shares one timer: a top-up that extends the deadline restarts
    ///      `activatingStart` for the whole lot, clearing the suspect surcharge if it restarts past `suspectExpiry`.
    /// @param instant Whether the supplying caller is trusted to skip the activation timer and inflow throttle.
    function credit(State storage $, address borrower, uint256 assets, bool instant) internal {
        Position storage position = $.positions[borrower];

        if (instant) {
            emit CollateralActivated(borrower, assets, position);
            return;
        }

        uint256 minDepositAmount = $.config.minDepositAmount;
        if (assets < minDepositAmount) revert DepositTooSmall(assets, minDepositAmount);

        uint256 dust = position.dust;
        uint256 assetsWithDust = assets + dust;

        if (assetsWithDust < $.config.minActivationAmount) {
            if (dust != 0) revert DustNotResolved(dust, assets, $.config.minActivationAmount);
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

    /// @notice Voluntary withdrawal of `amount` out of `totalCollateral`. While the activating lock is in
    ///         force, only a draw that fits within the active balance passes; `dust` and `activating` stay
    ///         untouched. Once the lock is over, the request must cover the whole inactive balance
    ///         (`dust + activating`); the call then empties both, clears the maturation timer, and reverses
    ///         this collateral's same-tx inflow. Returns the inactive balance left after the call.
    /// @dev Forced seizure goes through `seize`, which takes active collateral first and ignores the lock.
    /// @param totalCollateral The borrower's core collateral balance before this withdrawal is applied.
    function debit(State storage $, address borrower, uint256 amount, uint256 totalCollateral)
        internal
        returns (uint256 inactive)
    {
        Position storage position = $.positions[borrower];

        uint256 dust = position.dust;
        uint256 activating = position.activating;
        inactive = dust + activating;
        if (inactive == 0) return 0;

        uint256 active = totalCollateral - inactive;

        if (activating != 0) {
            uint256 lockDeadline = position.activatingStart + $.config.activatingLockDuration;
            if (block.timestamp < lockDeadline) {
                // While locked: only draws from active are allowed.
                if (amount > active) revert ActivatingCollateralLocked(activating, lockDeadline);
                return inactive;
            }
        }

        // While unlocked: the request must cover the whole inactive balance.
        if (amount < inactive) revert InactiveCollateralNotCleared(amount, inactive);

        position.dust = 0;
        position.activating = 0;
        _clearTimer(position);
        emit CollateralDrained(borrower, inactive, position);

        _applyInflowDecrement($, borrower, activating);
        return 0;
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

    /// @notice Forced seizure of `amount` (liquidation, settle): takes active collateral first, then dust, then
    ///         activating, ignoring the lock. An activating remainder of any size stays on its existing timer.
    ///         Reverses the same-tx inflow of the removed activating collateral. The amount is not checked here:
    ///         the caller guarantees `amount <= totalCollateral`.
    /// @param totalCollateral The borrower's core collateral balance before this seizure is applied.
    function seize(State storage $, address borrower, uint256 amount, uint256 totalCollateral) internal {
        Position storage position = $.positions[borrower];
        uint256 dust = position.dust;
        uint256 activating = position.activating;

        uint256 active = totalCollateral - dust - activating;
        uint256 uncovered = Math.saturatingSub(amount, active);
        if (uncovered == 0) return;

        uint256 fromDust = Math.min(dust, uncovered);
        uint256 fromActivating = Math.min(uncovered - fromDust, activating);

        position.dust = uint128(dust - fromDust);
        position.activating = uint128(activating - fromActivating);
        if (position.activating == 0) _clearTimer(position);

        uint256 drained = fromDust + fromActivating;
        if (drained != 0) emit CollateralDrained(borrower, drained, position);

        _applyInflowDecrement($, borrower, fromActivating);
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
