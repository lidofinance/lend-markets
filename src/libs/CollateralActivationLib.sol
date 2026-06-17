// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title CollateralActivationLib
/// @author Lido Lending contributors.
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
///      dust, then activating above the Sybil hold, then active.
/// @dev The base delay is frozen at deposit from the market-wide recent inflow, so address-splitting
///      cannot dodge the throttle. The inflow is capped at `maxDelayInflow` and decays at a fixed rate,
///      draining from the cap to zero over `maxActivationDelay`.
/// @dev The caller embeds `State`, forwards calls, and supplies the external reads the lib cannot make
///      (the strike count). The only state outside `State` is the per-tx transient counter for the
///      flash-loan undo.
library CollateralActivationLib {
    using SafeCast for uint256;

    /// @dev Sanity ceiling for governance-set delays.
    uint256 internal constant MAX_DELAY_BOUND = 7 days;

    /// @dev Transient-storage namespace for the inflow a position added in the current tx (flash-loan undo).
    bytes32 private constant TX_INFLOW_ADDED_NAMESPACE =
        keccak256("lido.lending.CollateralActivationLib.tx-inflow-added.v1");

    /// @notice Emitted when collateral enters the activation timer: a deposit promotes the dormant amount
    ///         past the dust threshold. `unlockTime` is the base unlock (`activatingStart + delay`), before
    ///         any strike surcharge.
    event ActivationScheduled(address indexed borrower, uint256 amount, uint256 unlockTime);

    /// @notice Emitted when a borrower's activating lot matures into active collateral.
    event Activated(address indexed borrower, uint256 amount);

    /// @notice Emitted when collateral leaves the position, split by the bucket it was debited from.
    event CollateralDebited(address indexed borrower, uint256 fromDust, uint256 fromActivating, uint256 fromActive);

    /// @notice Emitted when the full activation config is set.
    event ConfigSet(Config config);

    /// @notice Emitted when the activation delay floor is raised.
    event MinActivationDelaySet(uint64 minActivationDelay);

    /// @notice Emitted when the activation delay cap is raised.
    event MaxActivationDelaySet(uint64 maxActivationDelay);

    /// @notice Emitted when the Sybil hold on activating collateral is set.
    event ActivatingHoldSet(uint128 activatingHold);

    error BadConfig();

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
        uint64 activatingStart;
        uint64 activatingDelay;
    }

    /// @notice Governance-tunable activation parameters, validated by `setConfig`.
    /// @param minActivationDelay Base delay floor, at zero inflow.
    /// @param maxActivationDelay Base delay cap, reached at inflow >= maxDelayInflow. Also the inflow decay
    ///        horizon: the accumulator drains from `maxDelayInflow` to zero over this duration.
    /// @param maxDelayInflow Inflow reference at which the base delay reaches the cap, and the ceiling the
    ///        inflow accumulator saturates at.
    /// @param delayPerStrike Activation-delay surcharge added per strike.
    /// @param activatingHold Committee Sybil hold honored by `withdraw`. 0 disables it. Forced paths pass floor 0.
    /// @param minActivationAmount Dust threshold. Collateral below it does not enter activation.
    struct Config {
        // delay ramp
        uint64 minActivationDelay;
        uint64 maxActivationDelay;
        uint128 maxDelayInflow;
        // strike surcharge
        uint64 delayPerStrike;
        // sybil hold on activating collateral
        uint128 activatingHold;
        // dust threshold (anti-griefing)
        uint128 minActivationAmount;
    }

    /// @notice Market-wide activation state.
    /// @param config Governance-tunable parameters.
    /// @param inflow Recent collateral inflow, time-decayed. The throttle accumulator snapshot.
    /// @param inflowUpdatedAt Timestamp `inflow` was snapshotted at; the decay clock starts here.
    /// @param positions Per-borrower collateral split.
    struct State {
        Config config;
        uint128 inflow;
        uint64 inflowUpdatedAt;
        mapping(address borrower => Position) positions;
    }

    /// @notice Validate and store the governance-tunable config.
    function setConfig(State storage $, Config memory cfg) internal {
        if (cfg.minActivationDelay == 0) revert BadConfig();
        if (cfg.minActivationDelay > cfg.maxActivationDelay) revert BadConfig();
        if (cfg.maxActivationDelay > MAX_DELAY_BOUND) revert BadConfig();
        if (cfg.delayPerStrike > MAX_DELAY_BOUND) revert BadConfig();
        if (cfg.minActivationAmount == 0) revert BadConfig();
        if (cfg.maxDelayInflow == 0) revert BadConfig();
        $.config = cfg;
        emit ConfigSet(cfg);
    }

    /// @notice Set the base delay floor. Reverts unless 0 < minDelay <= maxActivationDelay.
    function setMinActivationDelay(State storage $, uint64 minDelay) internal {
        if (minDelay == 0 || minDelay > $.config.maxActivationDelay) revert BadConfig();
        $.config.minActivationDelay = minDelay;
        emit MinActivationDelaySet(minDelay);
    }

    /// @notice Set the base delay cap. Reverts unless minActivationDelay <= maxDelay <= MAX_DELAY_BOUND.
    function setMaxActivationDelay(State storage $, uint64 maxDelay) internal {
        if (maxDelay < $.config.minActivationDelay || maxDelay > MAX_DELAY_BOUND) revert BadConfig();
        $.config.maxActivationDelay = maxDelay;
        emit MaxActivationDelaySet(maxDelay);
    }

    /// @notice Set the committee Sybil hold. 0 disables it.
    function setActivatingHold(State storage $, uint128 hold) internal {
        $.config.activatingHold = hold;
        emit ActivatingHoldSet(hold);
    }

    /// @notice Book a new collateral deposit. Joins dust; once dust + this deposit crosses the threshold the
    ///         whole dormant amount is promoted into the activation timer and added to the market inflow.
    function deposit(State storage $, address borrower, uint256 assets) internal {
        Position storage position = $.positions[borrower];

        uint256 assetsWithDust = assets + position.dust;

        if (assetsWithDust < $.config.minActivationAmount) {
            position.dust = assetsWithDust.toUint128();
            return;
        }

        position.dust = 0;
        position.activating += assetsWithDust.toUint128();

        uint256 currentInflow = _applyInflowIncrement($, borrower, assetsWithDust);
        uint256 delay = _computeDelay($, currentInflow);

        if (block.timestamp + delay > position.activatingStart + position.activatingDelay) {
            position.activatingStart = uint64(block.timestamp);
            position.activatingDelay = uint64(delay);
        }

        emit ActivationScheduled(borrower, assetsWithDust, position.activatingStart + position.activatingDelay);
    }

    /// @notice Voluntary withdrawal: debit honoring the committee Sybil hold, then reverse any same-tx inflow
    ///         added for collateral that just left activating (flash-loan undo). Returns post-debit `active`.
    /// @dev Forced seizure calls `debit` with floor 0 instead, to reach all collateral without undoing inflow.
    function withdraw(State storage $, address borrower, uint256 amount) internal returns (uint256 active) {
        uint256 activatingBefore = $.positions[borrower].activating;

        active = debit($, borrower, amount, $.config.activatingHold);
        _applyInflowDecrement($, borrower, activatingBefore - $.positions[borrower].activating);
    }

    /// @notice Mature the borrower's activation lot into `active` once its timer has elapsed. Returns the
    ///         post-mature `active`. The inflow is untouched: it only decays with time, so a matured lot
    ///         still weighs on the delay. The caller skips this for banned or frozen borrowers.
    function syncActivation(State storage $, address borrower, uint256 strikes) internal returns (uint256 active) {
        Position storage position = $.positions[borrower];

        // mature only with a timer set and elapsed
        if (position.activatingStart > 0 && block.timestamp >= _getUnlockTime($, position, strikes)) {
            uint128 activated = position.activating;
            position.active += activated;
            position.activating = 0;
            _clearTimer(position);
            emit Activated(borrower, activated);
        }
        return position.active;
    }

    /// @notice Debit `amount` leaving the position, waterfall: dust, then activating above `activatingHold`,
    ///         then active. Returns the post-debit `active`.
    /// @param activatingHold Activating collateral held back until it matures. Pass 0 on forced paths
    ///        (liquidation, settle), which must reach all collateral.
    function debit(State storage $, address borrower, uint256 amount, uint256 activatingHold)
        internal
        returns (uint256 active)
    {
        Position storage position = $.positions[borrower];

        (/* active */, uint256 activating, uint256 dust) = getBuckets($, borrower);

        uint256 remaining = amount.toUint128();

        uint256 fromDust = Math.min(dust, remaining);
        if (fromDust > 0) {
            position.dust = uint128(dust - fromDust);
            remaining -= uint128(fromDust);
        }

        uint256 held = Math.min(activatingHold, activating);
        uint256 withdrawable = activating - held;
        uint256 fromActivating = remaining < withdrawable ? remaining : withdrawable;

        if (fromActivating != 0) {
            position.activating -= uint128(fromActivating);
            remaining -= uint128(fromActivating);
        }

        // underflows (reverts) if the request reaches into the held hold or the buckets drift from raw
        uint256 fromActive = remaining;
        if (fromActive != 0) {
            position.active -= uint128(fromActive);
        }

        if (position.activating == 0) {
            _clearTimer(position);
        }

        emit CollateralDebited(borrower, fromDust, fromActivating, fromActive);
        return position.active;
    }

    /// @notice Unlock timestamp of the borrower's activating lot, 0 if none.
    function getUnlockTime(State storage $, address borrower, uint256 strikes) internal view returns (uint256) {
        Position storage position = $.positions[borrower];
        if (position.activatingStart == 0) return 0;
        return _getUnlockTime($, position, strikes);
    }

    /// @notice Borrower's collateral split: active (matured), activating (in timer), dust.
    function getBuckets(State storage $, address borrower)
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
    function getInflow(State storage $) internal view returns (uint256) {
        uint256 inflow = $.inflow;
        if (inflow == 0) return 0;

        uint256 elapsed = block.timestamp - $.inflowUpdatedAt;
        uint256 decay = uint256($.config.maxDelayInflow) * elapsed / $.config.maxActivationDelay;
        return Math.saturatingSub(inflow, decay);
    }

    function _applyInflowIncrement(State storage $, address borrower, uint256 increment)
        private
        returns (uint256 newInflow)
    {
        uint256 prev = getInflow($);
        // Cap the throttle accumulator at maxDelayInflow: the delay already clamps there, so a higher inflow
        // would only lengthen the drain, and the cap keeps the uint128 store unwrappable.
        newInflow = Math.min(prev + increment, $.config.maxDelayInflow);

        $.inflow = uint128(newInflow);
        $.inflowUpdatedAt = uint64(block.timestamp);

        // Record the *applied* delta (post-cap), not the raw increment, so the same-tx undo reverses exactly
        // what was added. Reversing the raw amount when saturated would push inflow below its pre-deposit
        // value, a flash-loan throttle-suppression. Zero-floored for a governance cap-lowering.
        uint256 applied = Math.saturatingSub(newInflow, prev);
        _setTxInflowAdded(borrower, _getTxInflowAdded(borrower) + applied);
    }

    function _applyInflowDecrement(State storage $, address borrower, uint256 decrement) private {
        uint256 inflowInTx = _getTxInflowAdded(borrower);
        if (inflowInTx == 0) return;

        uint256 inflowDecrement = Math.min(inflowInTx, decrement);
        if (inflowDecrement == 0) return;

        uint256 currentInflow = getInflow($);

        $.inflow = uint128(Math.saturatingSub(currentInflow, inflowDecrement));
        $.inflowUpdatedAt = uint64(block.timestamp);

        // within a tx no time elapses, so this nets the same-tx addition exactly
        _setTxInflowAdded(borrower, inflowInTx - inflowDecrement);
    }

    /// @dev Unlock = start + frozen base delay + strike surcharge (strikes * delayPerStrike).
    function _getUnlockTime(State storage $, Position storage position, uint256 strikes)
        private
        view
        returns (uint256)
    {
        uint256 surcharge = strikes * $.config.delayPerStrike;
        return uint256(position.activatingStart) + position.activatingDelay + surcharge;
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
        Config memory cfg = $.config;

        if (effectiveInflow >= cfg.maxDelayInflow) {
            return cfg.maxActivationDelay;
        }

        uint256 span = cfg.maxActivationDelay - cfg.minActivationDelay;
        return uint256(cfg.minActivationDelay) + span * effectiveInflow / cfg.maxDelayInflow;
    }

    /// @dev Per-tx, per-borrower transient slot for the inflow added this tx (flash-loan undo).
    function _getTxInflowAdded(address borrower) private view returns (uint256 added) {
        bytes32 slot = keccak256(abi.encode(TX_INFLOW_ADDED_NAMESPACE, borrower));
        assembly ("memory-safe") {
            added := tload(slot)
        }
    }

    function _setTxInflowAdded(address borrower, uint256 value) private {
        bytes32 slot = keccak256(abi.encode(TX_INFLOW_ADDED_NAMESPACE, borrower));
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
