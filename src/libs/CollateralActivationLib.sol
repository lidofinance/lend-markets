// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

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
///      the lock and return the post-op inactive (`activating + dust`). A withdrawal that leaves the activating
///      lot below the threshold folds the remainder back into dust, off the timer and the maturation scan.
/// @dev The base delay is frozen at deposit from the market-wide recent inflow, the same for every position
///      regardless of the depositing address. The inflow is capped at `maxDelayInflow` and decays at a fixed
///      rate, draining from the cap to zero over `maxActivationDelay`.
/// @dev The caller embeds `State`, forwards calls, and supplies the external reads the lib cannot make (the
///      guardian-owned activation delay surcharge and quorum-scan frontier). The only state outside `State` is
///      the per-tx transient same-tx-undo counter.
library CollateralActivationLib {
    using SafeCast for uint256;

    // ---
    // CONSTANTS
    // ---

    /// @dev Sanity ceiling for governance-set delays.
    uint256 internal constant MAX_DELAY_DURATION = 7 days;

    /// @dev Transient-storage namespace for the inflow a position added in the current tx (same-tx undo).
    bytes32 private constant TRANSIENT_INFLOW_INCREASE_NAMESPACE =
        keccak256("lido.lend.CollateralActivationLib.TransientInflowIncrease");

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
    event CollateralDrained(address indexed borrower, Position position);

    /// @notice A withdrawal folds a sub-threshold activating remainder back into dust. `position` is the
    ///         resulting state.
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
    ///         When `instant` (a trusted caller) the collateral is not held inactive: it joins neither bucket, so it
    ///         counts as active immediately, releasing any dust with it. A sub-threshold deposit stays dust.
    /// @dev All activating collateral shares one timer: a top-up that extends the deadline restarts
    ///      `activatingStart` for the whole lot, clearing the suspect surcharge if it restarts past `suspectExpiry`.
    /// @param instant Whether the supplying caller is trusted to skip the activation timer and inflow throttle.
    function credit(State storage $, address borrower, uint256 assets, bool instant) internal {
        Position storage position = $.positions[borrower];

        uint256 dust = position.dust;
        uint256 assetsWithDust = assets + dust;

        if (assetsWithDust < $.config.minActivationAmount) {
            position.dust = assetsWithDust.toUint128();
            emit CollateralDusted(borrower, assets, position);
            return;
        }

        if (dust > 0) position.dust = 0;

        if (instant) {
            emit CollateralActivated(borrower, assetsWithDust, position);
            return;
        }

        position.activating = (position.activating + assetsWithDust).toUint128();

        uint256 newInflow = _applyInflowIncrement($, borrower, assetsWithDust);
        uint256 delay = _computeDelay($, newInflow);

        if (block.timestamp + delay > position.activatingStart + position.activatingDelay) {
            position.activatingStart = block.timestamp.toUint40();
            position.activatingDelay = delay.toUint32();
        }

        emit CollateralActivating(borrower, assetsWithDust, position);
    }

    /// @notice Voluntary withdrawal: drain `amount` from the un-matured buckets honoring the lock, demote a
    ///         sub-threshold activating remainder to dust (unless locked), and reverse this collateral's same-tx
    ///         inflow over the full activating reduction. Returns the post-debit inactive (`activating + dust`).
    /// @dev Forced seizure uses `seize`, which drains with no lock floor.
    function debit(State storage $, address borrower, uint256 amount) internal returns (uint256 inactive) {
        Position storage position = $.positions[borrower];

        (uint256 activatingBefore, uint256 activatingStart) = (position.activating, position.activatingStart);
        uint256 activatingLockDeadline = activatingStart + $.config.activatingLockDuration;
        uint256 activatingLockAmount =
            activatingStart != 0 && block.timestamp < activatingLockDeadline ? $.config.activatingLockAmount : 0;

        inactive = _drain($, borrower, amount, activatingLockAmount);

        // Demote a sub-threshold remainder to dust before reconciling inflow, so the demoted amount is reversed
        // too. Skip under a lock — demoting a locked remainder into freely-withdrawable dust would bypass it.
        uint256 activatingAfterDrain = position.activating;
        if (
            activatingLockAmount == 0 && activatingAfterDrain != 0
                && activatingAfterDrain < $.config.minActivationAmount
        ) {
            position.dust += activatingAfterDrain.toUint128();
            position.activating = 0;
            _clearTimer(position);
            emit CollateralDemoted(borrower, activatingAfterDrain, position);
        }

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
    ///         then reverses the same-tx inflow the seized activating collateral added. Returns the post-seize
    ///         inactive (`activating + dust`); the caller derives `active = total - inactive`.
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

    /// @dev Drain up to `amount` from the un-matured buckets, waterfall: dust, then activating above
    ///      `lockAmount`. Returns the post-drain inactive (`activating + dust`); the caller covers any shortfall
    ///      from active. `lockAmount` is the floor `debit` keeps locked; forced paths pass 0.
    function _drain(State storage $, address borrower, uint256 amount, uint256 lockAmount)
        private
        returns (uint256 inactive)
    {
        Position storage position = $.positions[borrower];
        uint256 dust = position.dust;
        uint256 activating = position.activating;

        // Waterfall within the un-matured buckets: dust first, then activating above the lock. Whatever it
        // leaves uncovered the caller takes from active, derived as `total - inactive`.
        uint256 fromDust = Math.min(dust, amount);
        uint256 fromActivating = Math.min(amount - fromDust, Math.saturatingSub(activating, lockAmount));

        position.dust = uint128(dust - fromDust);
        position.activating = uint128(activating - fromActivating);

        if (position.activating == 0) _clearTimer(position);

        emit CollateralDrained(borrower, position);
        return position.dust + position.activating;
    }

    function _applyInflowIncrement(State storage $, address borrower, uint256 increment)
        private
        returns (uint256 newInflow)
    {
        uint256 prevInflow = calcDecayedInflow($);
        // Cap the throttle accumulator at maxDelayInflow: the delay clamps there, and the cap keeps the uint128
        // store within range.
        newInflow = Math.min(prevInflow + increment, $.config.maxDelayInflow);

        $.inflow = uint128(newInflow);
        $.inflowUpdatedAt = block.timestamp.toUint40();

        // Record the post-cap applied delta so the same-tx undo reverses exactly what was added. Zero-floored for
        // a governance cap-lowering.
        uint256 inflowIncrement = Math.saturatingSub(newInflow, prevInflow);
        _storeTransientInflowIncrease(borrower, _loadTransientInflowIncrease(borrower) + inflowIncrement);
    }

    function _applyInflowDecrement(State storage $, address borrower, uint256 decrement) private {
        uint256 inflowInTx = _loadTransientInflowIncrease(borrower);
        uint256 inflowDecrement = Math.min(inflowInTx, decrement);

        if (inflowDecrement == 0) return;

        $.inflow = uint128(Math.saturatingSub(calcDecayedInflow($), inflowDecrement));
        $.inflowUpdatedAt = block.timestamp.toUint40();

        // within a tx no time elapses, so this nets the same-tx addition exactly
        _storeTransientInflowIncrease(borrower, inflowInTx - inflowDecrement);
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
        CollateralActivationConfig memory cfg = $.config;

        if (effectiveInflow >= cfg.maxDelayInflow) return cfg.maxActivationDelay;

        uint256 delaySpan = cfg.maxActivationDelay - cfg.minActivationDelay;
        return cfg.minActivationDelay + Math.mulDiv(delaySpan, effectiveInflow, cfg.maxDelayInflow);
    }

    /// @dev Per-tx, per-borrower transient slot for the inflow added this tx (same-tx undo).
    function _borrowerTransientInflowSlot(address borrower) private pure returns (bytes32 slot) {
        slot = keccak256(abi.encode(TRANSIENT_INFLOW_INCREASE_NAMESPACE, borrower));
    }

    function _loadTransientInflowIncrease(address borrower) private view returns (uint256 value) {
        bytes32 slot = _borrowerTransientInflowSlot(borrower);
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _storeTransientInflowIncrease(address borrower, uint256 value) private {
        bytes32 slot = _borrowerTransientInflowSlot(borrower);
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
