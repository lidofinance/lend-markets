// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {GuardiansOpinion, Status} from "../types/GuardianSignalsTypes.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";

/// @title CollateralActivationLib
/// @author Lido
/// @notice Collateral activation state machine for a single market. New collateral starts as dust,
///         crosses a threshold into a timed `activating` lot, then matures into `active` (borrowable).
/// @dev Per-borrower collateral occupies three buckets, traversed left to right over its lifecycle:
///
///                  deposit crosses                 timer elapsed,
///                  minActivationAmount              not frozen/banned
///       +--------+     promote     +------------+      mature      +--------+
///       |  dust  | --------------> | activating | --------------> | active |
///       | (free) |                 |  (timed)   |                 |(borrow)|
///       +--------+                 +------------+                 +--------+
///
///      A sub-threshold deposit stays in dust. Withdrawal and seizure debit in waterfall order:
///      dust, then activating above the lock, then active.
/// @dev The base delay is frozen at deposit from the market-wide recent inflow, the same for every position
///      regardless of the depositing address. The inflow is capped at `maxDelayInflow` and decays at a fixed
///      rate, draining from the cap to zero over `maxActivationDelay`.
/// @dev The caller embeds `State`, forwards calls, and supplies the external reads the lib cannot make
///      (the guardian opinion). The only state outside `State` is the per-tx transient counter for the
///      same-tx undo.
library CollateralActivationLib {
    using SafeCast for uint256;

    // ---
    // CONSTANTS
    // ---

    /// @dev Sanity ceiling for governance-set delays.
    uint256 internal constant MAX_DELAY_DURATION = 7 days;

    /// @dev Transient-storage namespace for the inflow a position added in the current tx (same-tx undo).
    bytes32 private constant TRANSIENT_INFLOW_INCREASE_NAMESPACE =
        keccak256("lido.lending.CollateralActivationLib.TransientInflowIncrease");

    // ---
    // EVENTS
    // ---

    /// @notice Emitted when collateral enters the activation timer: a deposit promotes the dormant amount
    ///         past the dust threshold. `unlockTime` is the base unlock (`activatingStart + delay`), before
    ///         any strike surcharge.
    event CollateralActivating(address indexed borrower, uint256 amount, uint256 unlockTime);

    /// @notice Emitted when a borrower's activating lot matures into active collateral.
    event CollateralActivated(address indexed borrower, uint256 amount);

    /// @notice Emitted when a deposit stays below the activation threshold and is held as dust.
    event CollateralDusted(address indexed borrower, uint256 amount);

    /// @notice Emitted when collateral leaves the position, split by the bucket it was debited from.
    event CollateralDebited(address indexed borrower, uint256 fromDust, uint256 fromActivating, uint256 fromActive);

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

    /// @notice The per-strike delay surcharge exceeds `MAX_DELAY_DURATION`.
    error DelayPerStrikeExceeded();

    /// @notice The activating-lock duration exceeds `MAX_DELAY_DURATION`.
    error MaxActivatingLockDurationExceeded();

    /// @notice The dust threshold (`minActivationAmount`) is zero.
    error ZeroMinActivationAmount();

    /// @notice The inflow reference (`maxDelayInflow`) is zero.
    error ZeroMaxDelayInflow();

    /// @notice A debit request exceeds the total collateral across all buckets.
    error DebitOverflow(uint256 amount);

    // ---
    // TYPES
    // ---

    /// @notice Per-borrower collateral split, summing to the borrower's raw collateral in core.
    /// @param active Matured collateral, counts for borrow capacity.
    /// @param activating Collateral inside the activation timer, not yet borrowable.
    /// @param dust Free collateral below the activation threshold, withdrawable.
    /// @param activatingStart Activation timer start, 0 when there is no active timer.
    /// @param activatingDelay Base inflow-scaled delay, frozen at deposit.
    struct Position {
        uint128 active;
        uint128 activating;
        uint128 dust;
        uint40 activatingStart;
        uint40 activatingDelay;
    }

    /// @notice Market-wide activation state.
    /// @param config Governance-tunable parameters.
    /// @param inflow Recent collateral inflow, time-decayed. The throttle accumulator snapshot.
    /// @param inflowUpdatedAt Timestamp `inflow` was snapshotted at. The decay clock starts here.
    /// @param positions Per-borrower collateral split.
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
        if (cfg.delayPerStrike > MAX_DELAY_DURATION) revert DelayPerStrikeExceeded();
        if (cfg.activatingLockDuration > MAX_DELAY_DURATION) revert MaxActivatingLockDurationExceeded();
        if (cfg.minActivationAmount == 0) revert ZeroMinActivationAmount();
        if (cfg.maxDelayInflow == 0) revert ZeroMaxDelayInflow();

        $.config = cfg;

        emit CollateralActivationConfigSet(cfg);
    }

    // ---
    // ACTIONS
    // ---

    /// @notice Book a new collateral deposit. It joins dust, and once dust plus this deposit crosses the
    ///         threshold the whole dormant amount enters the activation timer and is added to the market inflow.
    ///         When `instant` (a trusted caller) the amount crosses straight into `active`, skipping the timer
    ///         and the inflow throttle. The dust threshold still applies, so a sub-threshold deposit stays dust.
    /// @param instant Whether the supplying caller is trusted to skip the activation timer and inflow throttle.
    function deposit(State storage $, address borrower, uint256 assets, bool instant) internal {
        Position storage position = $.positions[borrower];

        uint256 dust = position.dust;
        uint256 assetsWithDust = assets + dust;

        if (assetsWithDust < $.config.minActivationAmount) {
            position.dust = assetsWithDust.toUint128();
            emit CollateralDusted(borrower, assets);
            return;
        } else if (dust > 0) {
            position.dust = 0;
        }

        if (instant) {
            position.active += assetsWithDust.toUint128();
            emit CollateralActivated(borrower, assetsWithDust);
            return;
        }

        position.activating += assetsWithDust.toUint128();

        uint256 newInflow = _applyInflowIncrement($, borrower, assetsWithDust);
        uint256 delay = _computeDelay($, newInflow);

        if (block.timestamp + delay > position.activatingStart + position.activatingDelay) {
            position.activatingStart = block.timestamp.toUint40();
            position.activatingDelay = delay.toUint40();
        }

        emit CollateralActivating(borrower, assetsWithDust, position.activatingStart + position.activatingDelay);
    }

    /// @notice Voluntary withdrawal: debit honoring the activating lock, then reverse any inflow this
    ///         collateral added earlier in the same tx. Returns post-debit `active`.
    /// @dev Forced seizure calls `debit` instead (no lock floor), to reach all collateral without undoing inflow.
    function withdraw(State storage $, address borrower, uint256 amount) internal returns (uint256 active) {
        Position storage position = $.positions[borrower];

        uint256 activatingBefore = position.activating;
        // The lock lapses after activatingLockDuration from activatingStart, so a never-maturing lot
        // (e.g. a banned borrower) is only delayed out, never trapped.
        uint256 activatingLockAmount = block.timestamp < position.activatingStart + $.config.activatingLockDuration
            ? $.config.activatingLockAmount
            : 0;

        active = _debit($, borrower, amount, activatingLockAmount);
        _applyInflowDecrement($, borrower, activatingBefore - position.activating);
    }

    /// @notice Mature the borrower's activating lot into `active` once its timer has elapsed and the guardian
    ///         quorum has scanned past the unlock (or the `maxGuardiansQuorumDelay` fallback has elapsed), or
    ///         immediately when the borrower has instant activation. Returns the post-mature `active`. A freeze
    ///         skips maturation, and a banned borrower never matures (its unlock is pushed to infinity). The
    ///         inflow is untouched: it only decays with time, so a matured lot still weighs on the delay.
    function syncActivation(State storage $, bool isFrozen, address borrower, GuardiansOpinion memory opinion)
        internal
        returns (uint256)
    {
        Position storage position = $.positions[borrower];

        if (!isFrozen && position.activatingStart > 0) {
            uint256 unlockTime = _getUnlockTime($, borrower, opinion);
            bool isUnlockTimePassed = block.timestamp >= unlockTime;
            bool hasGuardiansQuorum = unlockTime <= opinion.quorumBlock.timestamp;
            bool maxQuorumDelayElapsed = block.timestamp >= position.activatingStart + $.config.maxGuardiansQuorumDelay;

            if (isUnlockTimePassed && (hasGuardiansQuorum || maxQuorumDelayElapsed)) {
                uint128 activatedAmount = position.activating;
                position.active += activatedAmount;
                position.activating = 0;
                _clearTimer(position);
                emit CollateralActivated(borrower, activatedAmount);
            }
        }

        return position.active;
    }

    /// @notice Forced debit `amount` leaving the position (liquidation, settle): reaches all collateral with no
    ///         lock floor. Returns the post-debit `active`.
    function debit(State storage $, address borrower, uint256 amount) internal returns (uint256 active) {
        return _debit($, borrower, amount, 0);
    }

    // ---
    // GETTERS
    // ---

    /// @notice Unlock timestamp of the borrower's activating lot, 0 if none.
    function getUnlockTime(State storage $, address borrower, GuardiansOpinion memory opinion)
        internal
        view
        returns (uint256)
    {
        Position storage position = $.positions[borrower];
        if (position.activatingStart == 0) return 0;
        return _getUnlockTime($, borrower, opinion);
    }

    /// @notice Borrower's collateral split: active (matured), activating (in timer), dust.
    function getCollateralSplit(State storage $, address borrower)
        internal
        view
        returns (uint256 active, uint256 activating, uint256 dust)
    {
        Position storage position = $.positions[borrower];
        return (position.active, position.activating, position.dust);
    }

    /// @notice Current decayed inflow.
    /// @dev Fixed-rate decay: the inflow loses `maxDelayInflow` units over `maxActivationDelay`, independent
    ///      of the current value. A constant rate is invariant under clock resets, so a deposit (or its
    ///      same-tx undo) cannot defer the decay of prior volume. Saturates at 0.
    function calcDecayedInflow(State storage $) internal view returns (uint256) {
        uint256 decayAmount =
            Math.mulDiv($.config.maxDelayInflow, block.timestamp - $.inflowUpdatedAt, $.config.maxActivationDelay);
        return Math.saturatingSub($.inflow, decayAmount);
    }

    /// @notice Base activation delay a deposit incurs at the current inflow, before the deposit's own inflow
    ///         contribution. A larger deposit folds into the inflow and may incur more, up to the cap.
    function currentActivationDelay(State storage $) internal view returns (uint256) {
        return _computeDelay($, calcDecayedInflow($));
    }

    // ---
    // PRIVATE HELPERS
    // ---

    /// @dev Debit `amount` leaving the position, waterfall: dust, then activating above `activatingLockAmount`,
    ///      then active. `activatingLockAmount` is the floor `withdraw` keeps locked; forced paths pass 0.
    function _debit(State storage $, address borrower, uint256 amount, uint256 activatingLockAmount)
        private
        returns (uint256 active)
    {
        Position storage position = $.positions[borrower];
        (uint256 activeBucket, uint256 activating, uint256 dust) = getCollateralSplit($, borrower);

        uint256 fromDust = Math.min(dust, amount);
        uint256 remaining = amount - fromDust;

        uint256 unlockedActivating = Math.saturatingSub(activating, activatingLockAmount);
        uint256 fromActivating = Math.min(remaining, unlockedActivating);
        remaining -= fromActivating;

        uint256 fromActive = remaining;
        if (fromActive > activeBucket) revert DebitOverflow(amount);

        position.dust = uint128(dust - fromDust);
        position.activating = uint128(activating - fromActivating);
        position.active = uint128(activeBucket - fromActive);

        if (position.activating == 0) _clearTimer(position);

        emit CollateralDebited(borrower, fromDust, fromActivating, fromActive);
        return position.active;
    }

    function _applyInflowIncrement(State storage $, address borrower, uint256 increment)
        private
        returns (uint256 newInflow)
    {
        uint256 prevInflow = calcDecayedInflow($);
        // Cap the throttle accumulator at maxDelayInflow: the delay already clamps there, so a higher inflow
        // would only lengthen the drain, and the cap keeps the uint128 store unwrappable.
        newInflow = Math.min(prevInflow + increment, $.config.maxDelayInflow);

        $.inflow = uint128(newInflow);
        $.inflowUpdatedAt = block.timestamp.toUint40();

        // Record the *applied* delta (post-cap), not the raw increment, so the same-tx undo reverses exactly
        // what was added. Reversing the raw amount when saturated would push inflow below its pre-deposit
        // value, letting a deposit-and-undo suppress the throttle. Zero-floored for a governance cap-lowering.
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

    /// @dev Unlock = start + frozen base delay + strike surcharge (strikes * delayPerStrike). A banned borrower
    ///      never unlocks (returns max).
    function _getUnlockTime(State storage $, address borrower, GuardiansOpinion memory opinion)
        private
        view
        returns (uint256)
    {
        if (opinion.status == Status.Banned) return type(uint256).max;

        Position storage position = $.positions[borrower];
        uint256 delaySurcharge = opinion.strikes * $.config.delayPerStrike;
        return uint256(position.activatingStart) + position.activatingDelay + delaySurcharge;
    }

    /// @dev Base delay scales linearly with the inflow, clamped at both ends. The dormant lot's size is
    ///      folded into `effectiveInflow` before the call, so a lot's own size lengthens its delay.
    ///
    ///        delay
    ///          ^
    ///      max |             ___________   clamp at maxActivationDelay (inflow >= maxDelayInflow)
    ///          |           /
    ///          |         /
    ///          |       /     delay = min + (max - min) * inflow / maxDelayInflow
    ///          |     /
    ///          |   /
    ///      min | /                         minActivationDelay at zero inflow
    ///          +-+------------------> inflow = current inflow + incoming lot
    ///            maxDelayInflow
    function _computeDelay(State storage $, uint256 effectiveInflow) private view returns (uint256) {
        CollateralActivationConfig memory cfg = $.config;

        if (effectiveInflow >= cfg.maxDelayInflow) {
            return cfg.maxActivationDelay;
        }

        uint256 delaySpan = cfg.maxActivationDelay - cfg.minActivationDelay;
        return cfg.minActivationDelay + delaySpan * effectiveInflow / cfg.maxDelayInflow;
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
