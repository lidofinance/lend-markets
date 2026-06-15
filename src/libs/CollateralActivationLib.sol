// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {MathLib, WAD} from "@lido-lend/src/libraries/MathLib.sol";
import {UtilsLib} from "@lido-lend/src/libraries/UtilsLib.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
///      cannot dodge the throttle. The inflow decays linearly and fully clears in `inflowDecayWindow`
///      regardless of magnitude.
/// @dev The caller embeds `State`, forwards calls, and supplies the external reads the lib cannot make
///      (suspicion). The only state outside `State` is the per-tx transient counter for the
///      flash-loan undo.
library CollateralActivationLib {
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SlotDerivation for bytes32;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Uint256Slot;

    /// @dev Unlock sentinel for a banned position (suspicion == WAD): never reached.
    uint256 internal constant NEVER_UNLOCK = 2 ** 64 - 1 seconds;
    /// @dev Sanity ceiling for governance-set delays.
    uint256 internal constant MAX_DELAY_BOUND = 7 days;

    /// @dev Transient-storage namespace for the inflow a position added in the current tx (flash-loan undo).
    bytes32 private constant TX_INFLOW_ADDED_NAMESPACE =
        keccak256("lido.lending.CollateralActivationLib.tx-inflow-added.v1");

    event Activated(address indexed borrower, uint256 amount);

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
    /// @param maxActivationDelay Base delay cap, reached at inflow >= maxDelayInflow.
    /// @param maxDelayInflow Inflow reference at which the base delay reaches the cap.
    /// @param inflowDecayWindow Seconds for the inflow to fully decay after the last deposit.
    /// @param minDecayInflow Floor of the decay-rate basis, so a small inflow still decays in bounded time.
    /// @param maxSuspicionDelay Suspicion surcharge cap, approached as suspicion nears WAD.
    /// @param activatingHold Committee Sybil hold honored by `withdraw`. 0 disables it. Forced paths pass floor 0.
    /// @param minActivationAmount Dust threshold. Collateral below it does not enter activation.
    struct Config {
        // delay ramp
        uint64 minActivationDelay;
        uint64 maxActivationDelay;
        uint128 maxDelayInflow;
        // inflow decay
        uint64 inflowDecayWindow;
        uint128 minDecayInflow;
        // suspicion surcharge
        uint64 maxSuspicionDelay;
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
        if (cfg.maxSuspicionDelay > MAX_DELAY_BOUND) revert BadConfig();
        if (cfg.minActivationAmount == 0) revert BadConfig();
        if (cfg.maxDelayInflow == 0 || cfg.inflowDecayWindow == 0 || cfg.minDecayInflow == 0) revert BadConfig();
        $.config = cfg;
    }

    /// @notice Set the committee Sybil hold. 0 disables it.
    function setActivatingHold(State storage $, uint128 hold) internal {
        $.config.activatingHold = hold;
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
    ///         post-mature `active`. A banned address never matures. The inflow is untouched: it only decays
    ///         with time, so a matured lot still weighs on the delay.
    function syncActivation(State storage $, address borrower, uint256 suspicion) internal returns (uint256 active) {
        Position storage position = $.positions[borrower];

        // mature only with a timer set and elapsed (a banned address never elapses)
        if (position.activatingStart > 0 && block.timestamp >= _getUnlockTime($, position, suspicion)) {
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
        if (remaining != 0) {
            position.active -= uint128(remaining);
        }

        if (position.activating == 0) {
            _clearTimer(position);
        }

        return position.active;
    }

    /// @notice Unlock timestamp of the borrower's activating lot, 0 if none, NEVER_UNLOCK if banned.
    function getUnlockTime(State storage $, address borrower, uint256 suspicion) internal view returns (uint256) {
        Position storage position = $.positions[borrower];
        if (position.activatingStart == 0) return 0;
        return _getUnlockTime($, position, suspicion);
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
    /// @dev Decays linearly from the snapshot, the rate basis floored at `minDecayInflow` so a small inflow
    ///      still reaches 0 within the window. Saturates at 0.
    function getInflow(State storage $) internal view returns (uint256) {
        uint256 inflow = $.inflow;
        if (inflow == 0) return 0;

        uint256 elapsed = block.timestamp - $.inflowUpdatedAt;
        uint256 rateBasis = Math.max(inflow, $.config.minDecayInflow);

        uint256 decay = rateBasis * elapsed / $.config.inflowDecayWindow;
        return Math.saturatingSub(inflow, decay);
    }

    function _applyInflowIncrement(State storage $, address borrower, uint256 increment)
        private
        returns (uint256 newInflow)
    {
        newInflow = getInflow($) + increment;

        $.inflow = uint128(newInflow);
        $.inflowUpdatedAt = uint64(block.timestamp);

        _setTxInflowAdded(borrower, _getTxInflowAdded(borrower) + increment);
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

    /// @dev Unlock = start + frozen base delay + live suspicion surcharge.
    function _getUnlockTime(State storage $, Position storage position, uint256 suspicion)
        private
        view
        returns (uint256)
    {
        if (suspicion >= WAD) return NEVER_UNLOCK; // banned, unreachable
        uint256 surcharge = suspicion * $.config.maxSuspicionDelay / WAD;
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
        uint256 ratioWad = effectiveInflow.wDivDown(cfg.maxDelayInflow);

        return uint256(cfg.minActivationDelay) + span * ratioWad / WAD;
    }

    /// @dev Per-tx, per-borrower transient slot for the inflow added this tx (flash-loan undo).
    function _getTxInflowAdded(address borrower) private view returns (uint256) {
        return TX_INFLOW_ADDED_NAMESPACE.deriveMapping(borrower).asUint256().tload();
    }

    function _setTxInflowAdded(address borrower, uint256 value) private {
        TX_INFLOW_ADDED_NAMESPACE.deriveMapping(borrower).asUint256().tstore(value);
    }

    /// @dev Clear the activation timer. No activating balance means no timer.
    function _clearTimer(Position storage position) private {
        position.activatingStart = 0;
        position.activatingDelay = 0;
    }
}
