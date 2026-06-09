// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {MathLib, WAD} from "@lido-blue/src/libraries/MathLib.sol";
import {UtilsLib} from "@lido-blue/src/libraries/UtilsLib.sol";

/// @title ActivationLib
/// @author Lido Lending contributors.
/// @notice Collateral activation state machine for a single market. New collateral starts as dust,
///         crosses a threshold into a timed `activating` lot, then settles into `active` (borrowable).
///         dust is not stored: it is derived as rawCollateral - active - activating (saturating), so
///         the per-position struct only tracks the activation pipeline.
/// @dev Delay model: the base delay is set once at deposit from a decaying leaky-bucket load
///      accumulator that charges on every lot entering activation. A larger or sustained inflow pushes
///      the delay toward the cap and throttles later inflow (the accumulator is market-wide, so
///      address-splitting cannot dodge it). The load drains at a rate proportional to its size, so any
///      spike fully clears in `maxDecayDuration` regardless of magnitude (no separate cap to tune). On top
///      of the frozen base, a live suspicion surcharge from the registry is added at settle time, so a flag
///      raised after the deposit lengthens it and a banned address never settles. The load a deposit
///      charges is tracked per-transaction (transient) and reversed when that collateral leaves through
///      `withdraw` in the same tx, so a flash-loan deposit/withdraw round-trip cannot pump the load while
///      genuine cross-tx inflow still weighs on it.
/// @dev Self-contained module: the caller embeds `State` and forwards calls, supplying the external
///      reads the lib must not make itself (raw collateral from core, suspicion from the registry,
///      the market freeze flag). It makes no external calls; its only state outside `State` is a per-tx
///      transient counter for the flash-loan undo, so it stays unit-testable in isolation.
library ActivationLib {
    using MathLib for uint256;
    using UtilsLib for uint256;

    /// @dev Banned (suspicion == 100): an unreachable unlock so the lot never settles until cleared.
    uint256 internal constant NEVER_DELAY = 2 ** 64 - 1;
    /// @dev Suspicion is reported on a 0..100 scale.
    uint256 internal constant SUSPICION_SCALE = 100;
    /// @dev Sanity ceiling for governance-set delays.
    uint256 internal constant MAX_DELAY_BOUND = 7 days;

    /// @dev Transient-storage namespace for the load a position charged in the current tx (flash-loan
    ///      undo). Transient resets each tx, so only an atomic same-tx deposit/withdraw reaches it. The
    ///      lib's functions are `internal`, so this lives in the embedding contract's transient space.
    bytes32 private constant TX_LOAD_CHARGED_NAMESPACE = keccak256("lido.lending.ActivationLib.tx-load-charged.v1");

    event Activated(address indexed borrower, uint256 amount);

    error BadConfig();

    struct Position {
        uint128 active; // matured collateral, counts for borrow capacity
        uint128 activating; // inside the activation timer, not yet borrowable
        uint64 activatingStart; // 0 when there is no active timer
        uint64 activatingDelay; // base (load-scaled) delay, frozen at deposit; suspicion is added live
    }

    struct Config {
        uint64 minActivationDelay; // base delay floor (zero load)
        uint64 maxActivationDelay; // base delay cap (load >= maxDelayLoad, or scaling disabled)
        uint64 maxSuspicionDelay; // suspicion surcharge cap (suspicion approaching 100)
        uint64 maxDecayDuration; // seconds for the load to fully drain after the last charge
        uint128 maxDelayLoad; // load reference at which the base delay reaches the cap
        uint128 minActivationAmount; // dust threshold, collateral below it does not enter activation
        uint128 minDecayAmount; // floor of the decay-rate basis, so a small load still drains in bounded time
    }

    struct State {
        Config config;
        uint128 load; // leaky-bucket accumulator snapshot
        uint64 loadUpdatedAt; // timestamp `load` was snapshotted at
        mapping(address borrower => Position) positions;
    }

    /// @notice Validate and store the governance-tunable config.
    function setConfig(State storage $, Config memory cfg) internal {
        if (cfg.minActivationDelay == 0) revert BadConfig();
        if (cfg.minActivationDelay > cfg.maxActivationDelay) revert BadConfig();
        if (cfg.maxActivationDelay > MAX_DELAY_BOUND) revert BadConfig();
        if (cfg.maxSuspicionDelay > MAX_DELAY_BOUND) revert BadConfig();
        if (cfg.minActivationAmount == 0) revert BadConfig();
        // load-scaling is always on: reference, decay window (the divisor) and rate floor must be positive
        if (cfg.maxDelayLoad == 0 || cfg.maxDecayDuration == 0 || cfg.minDecayAmount == 0) revert BadConfig();
        $.config = cfg;
    }

    /// @notice Book a new collateral deposit. It joins dust; once dust + this deposit crosses the
    ///         activation threshold the whole dormant amount is promoted into the activation timer and
    ///         charged against the load accumulator.
    /// @param raw Borrower raw collateral in core, pre-deposit (core applies the increment after the hook).
    function deposit(State storage $, address borrower, uint256 assets, uint256 raw) internal {
        Position storage position = $.positions[borrower];
        uint256 dormant = _dust(position, raw) + assets;
        if (dormant < $.config.minActivationAmount) return; // stays dust (derived), nothing to write

        uint64 delay = _computeDelay($, dormant); // load-scaled, folds in this lot's own size
        position.activating += dormant.toUint128();
        _increaseLoad($, dormant); // charge the accumulator for the lot entering activation
        _extendTimer(position, delay);
        // record this tx's charge so a same-tx withdrawal reverses it (flash-loan undo)
        _setTxLoadCharged(borrower, _txLoadCharged(borrower) + dormant);
    }

    /// @notice Settle an elapsed activation lot into `active`. Returns the post-settle `active` so the
    ///         caller can gate borrow/withdraw without re-reading. A freeze defers settlement (the timer
    ///         keeps running); a banned address never settles until it is cleared. The load accumulator
    ///         is untouched: it only decays with time, so a matured lot still weighs on the delay until
    ///         it drains.
    function syncActivation(State storage $, address borrower, uint256 suspicion, bool frozen)
        internal
        returns (uint256 active)
    {
        Position storage position = $.positions[borrower];
        if (position.activatingStart == 0) return position.active; // no active timer
        if (frozen) return position.active; // freeze defers settlement
        // not elapsed yet (a banned address never elapses)
        if (block.timestamp < _unlock($, position, suspicion)) return position.active;

        uint128 activated = position.activating;
        position.active += activated;
        position.activating = 0;
        position.activatingStart = 0;
        position.activatingDelay = 0;
        emit Activated(borrower, activated);
        return position.active;
    }

    /// @notice Debit `amount` of collateral leaving the position, waterfall order: dust (derived, no
    ///         write), then activating above `activatingFloor`, then active. Returns the post-debit
    ///         `active` so the caller can gate the remaining debt without re-reading. The load
    ///         accumulator is untouched.
    /// @param raw Borrower raw collateral in core, pre-decrement (core applies the decrement after the hook).
    /// @param activatingFloor Activating collateral held back (unwithdrawable) until it matures. Pass 0 on
    ///        forced paths (liquidation, deleverage), which must be able to reach all collateral.
    function consume(State storage $, address borrower, uint256 amount, uint256 raw, uint256 activatingFloor)
        internal
        returns (uint256 active)
    {
        Position storage position = $.positions[borrower];
        uint128 remaining = amount.toUint128();

        uint128 dust = _dust(position, raw).toUint128();
        uint128 fromDust = remaining < dust ? remaining : dust;
        remaining -= fromDust; // dust is derived from raw, nothing to write

        // hold up to `activatingFloor` of activating; only the surplus is withdrawable on this path
        uint128 held = activatingFloor < position.activating ? uint128(activatingFloor) : position.activating;
        uint128 withdrawable = position.activating - held;
        uint128 fromActivating = remaining < withdrawable ? remaining : withdrawable;
        if (fromActivating != 0) {
            position.activating -= fromActivating;
            remaining -= fromActivating;
        }

        // reverts on underflow if the request reaches into the held floor or the buckets drift from raw
        if (remaining != 0) position.active -= remaining;

        if (position.activating == 0) {
            position.activatingStart = 0;
            position.activatingDelay = 0;
        }
        return position.active;
    }

    /// @notice Voluntary collateral withdrawal: debit the buckets honoring `activatingFloor` (the Sybil
    ///         hold), then reverse any load this position charged earlier in the same tx for collateral
    ///         that just left activating (flash-loan undo). Returns post-debit `active` so the caller can
    ///         gate the remaining debt without re-reading.
    /// @dev Forced seizure (liquidation, deleverage) must reach all collateral and must NOT reverse load,
    ///      so it calls `consume` directly with floor 0 instead of this.
    function withdraw(State storage $, address borrower, uint256 amount, uint256 raw, uint256 activatingFloor)
        internal
        returns (uint256 active)
    {
        uint256 activatingBefore = $.positions[borrower].activating;
        active = consume($, borrower, amount, raw, activatingFloor);
        _unchargeFresh($, borrower, activatingBefore);
        return active;
    }

    /// @notice Unlock timestamp of the borrower's activating lot, 0 if none, NEVER_DELAY if banned.
    function unlockAt(State storage $, address borrower, uint256 suspicion) internal view returns (uint256) {
        Position storage position = $.positions[borrower];
        if (position.activatingStart == 0) return 0;
        return _unlock($, position, suspicion);
    }

    /// @notice Dust held by the borrower: deposited and withdrawable, below the activation threshold.
    function dustOf(State storage $, address borrower, uint256 raw) internal view returns (uint256) {
        return _dust($.positions[borrower], raw);
    }

    /// @notice Borrower's collateral split: active (matured), activating (in timer), dust (derived).
    function bucketsOf(State storage $, address borrower, uint256 raw)
        internal
        view
        returns (uint256 active, uint256 activating, uint256 dust)
    {
        Position storage position = $.positions[borrower];
        return (position.active, position.activating, _dust(position, raw));
    }

    /// @notice Current decayed leaky-bucket load. One source for both the delay formula and monitors.
    function currentLoad(State storage $) internal view returns (uint256) {
        return _currentLoad($);
    }

    /// @dev Unlock = start + frozen base delay + live suspicion surcharge.
    function _unlock(State storage $, Position storage position, uint256 suspicion) private view returns (uint256) {
        if (suspicion >= SUSPICION_SCALE) return NEVER_DELAY; // banned, unreachable
        uint256 surcharge = suspicion * $.config.maxSuspicionDelay / SUSPICION_SCALE;
        return uint256(position.activatingStart) + position.activatingDelay + surcharge;
    }

    /// @dev Load-scaled base delay. `depositSize` folds into the load so a lot's own size lengthens its
    ///      delay. Linear ramp minActivationDelay -> maxActivationDelay over [0, maxDelayLoad].
    function _computeDelay(State storage $, uint256 depositSize) private view returns (uint64) {
        Config storage cfg = $.config;
        uint256 span = uint256(cfg.maxActivationDelay) - cfg.minActivationDelay;
        uint256 effectiveLoad = _currentLoad($) + depositSize;
        uint256 ratioWad = effectiveLoad.wDivDown(cfg.maxDelayLoad);
        if (ratioWad >= WAD) return cfg.maxActivationDelay;
        return uint64(uint256(cfg.minActivationDelay) + span * ratioWad / WAD);
    }

    /// @dev Decayed accumulator: linear drain at a rate proportional to the snapshot, so any spike fully
    ///      drains in `maxDecayDuration` regardless of size. The rate basis is floored at `minDecayAmount`
    ///      so a small load still reaches 0 in bounded time (and never stalls on integer rounding).
    ///      Result floored at 0; the `load == 0` short-circuit covers the state before the first charge.
    function _currentLoad(State storage $) private view returns (uint256) {
        if ($.load == 0) return 0;
        uint256 elapsed = block.timestamp - $.loadUpdatedAt;
        uint256 rateBasis = $.load >= $.config.minDecayAmount ? $.load : $.config.minDecayAmount;
        uint256 decay = rateBasis * elapsed / $.config.maxDecayDuration;
        if (decay >= $.load) return 0;
        return uint256($.load) - decay;
    }

    /// @dev Charge the accumulator for a lot entering activation. No cap: the proportional decay bounds
    ///      the tail (a higher load just drains proportionally faster).
    function _increaseLoad(State storage $, uint256 added) private {
        $.load = uint128(_currentLoad($) + added);
        $.loadUpdatedAt = uint64(block.timestamp);
    }

    /// @dev Reverse part of the accumulator (same-tx flash undo). Floored at 0. No time elapses within a
    ///      tx, so paired with the same tx's `_increaseLoad` it nets exactly.
    function _decreaseLoad(State storage $, uint256 amount) private {
        uint256 cur = _currentLoad($);
        $.load = amount < cur ? uint128(cur - amount) : 0;
        $.loadUpdatedAt = uint64(block.timestamp);
    }

    /// @dev Flash-loan undo: reverse the part of this tx's load charge matching collateral that just left
    ///      activating (`activatingBefore` minus post-consume activating), capped at the tx charge. No-op
    ///      cross-tx (the transient counter has reset) or when no fresh activating was withdrawn.
    function _unchargeFresh(State storage $, address borrower, uint256 activatingBefore) private {
        uint256 charged = _txLoadCharged(borrower);
        if (charged == 0) return;
        uint256 undo = UtilsLib.min(charged, activatingBefore - $.positions[borrower].activating);
        if (undo == 0) return;
        _decreaseLoad($, undo);
        _setTxLoadCharged(borrower, charged - undo);
    }

    /// @dev Per-tx, per-borrower transient slot for load charged on deposit this tx (flash-loan undo).
    function _txLoadChargedSlot(address borrower) private pure returns (bytes32 slot) {
        slot = keccak256(abi.encode(TX_LOAD_CHARGED_NAMESPACE, borrower));
    }

    function _txLoadCharged(address borrower) private view returns (uint256 value) {
        bytes32 slot = _txLoadChargedSlot(borrower);
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _setTxLoadCharged(address borrower, uint256 value) private {
        bytes32 slot = _txLoadChargedSlot(borrower);
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /// @dev max-unlock with the frozen base delay: a top-up moves the shared unlock only if it earns a
    ///      later one, so a tiny late deposit cannot reset the timer.
    function _extendTimer(Position storage position, uint64 delay) private {
        uint256 newUnlock = block.timestamp + delay;
        uint256 oldUnlock = uint256(position.activatingStart) + position.activatingDelay;
        if (newUnlock <= oldUnlock) return;
        position.activatingStart = uint64(block.timestamp);
        position.activatingDelay = delay;
    }

    /// @dev dust = raw - active - activating, saturating to 0 if the buckets ever exceed raw.
    function _dust(Position storage position, uint256 raw) private view returns (uint256) {
        uint256 accounted = uint256(position.active) + position.activating;
        return raw > accounted ? raw - accounted : 0;
    }
}
