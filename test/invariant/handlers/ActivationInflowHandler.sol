// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CollateralActivationLib} from "../../../src/libs/CollateralActivationLib.sol";
import {CollateralActivationConfig} from "../../../src/types/CollateralActivationTypes.sol";

/// @notice Library-level handler for the activation-inflow invariant (ACT-04/05/06). Drives the throttle
///         accounting functions directly — `credit`, voluntary `debit` (active-only within the matured
///         balance, all-or-nothing over the inactive one), forced `seize` (the shared liquidation/settlement
///         path, active collateral first, then dust, then activating) — with NO instant activation, so the
///         inflow accumulator is actually exercised (the protocol-level invariants short-circuit it via
///         instant activation).
/// @dev The per-tx inflow invariant `storedInflow == min(cap, baseline + net)` is TRANSIENT (baseline/net reset
///      between txs), so it is asserted INSIDE `step` after each op in one tx, not in an `invariant_` function.
///      `net` is derived from the OBSERVED `activating` delta (via `getActivationState`), independently of the
///      library's internal transient tracking, so the two only agree if the library's accounting is correct.
///      Revert-bounded (`fail-on-revert = true`): every op self-bounds so only a real accounting mismatch reverts.
contract ActivationInflowHandler is Test {
    using CollateralActivationLib for CollateralActivationLib.State;

    CollateralActivationLib.State internal $;

    uint256 public constant CAP = 10_000 ether; // maxDelayInflow
    uint256 public constant MIN_ACT = 1 ether; // minActivationAmount
    uint256 internal constant MAX_DELAY = 1 hours;

    address[4] internal actors;
    mapping(address => uint256) internal _total; // raw collateral per actor (bounds withdraw/seize)
    bool[4] public activatingWasSeized; // per-actor: an unverified nonzero activating remainder left by a seize

    constructor() {
        $.setConfig(
            CollateralActivationConfig({
                minActivationDelay: 1 minutes,
                maxActivationDelay: uint40(MAX_DELAY),
                activatingLockDuration: 0,
                maxDelayInflow: uint128(CAP),
                minActivationAmount: uint128(MIN_ACT),
                minDepositAmount: 0,
                maxGuardiansQuorumDelay: 0,
                delayPerStrike: 0,
                delayPerSuspect: 0
            })
        );
        actors[0] = address(0xA1);
        actors[1] = address(0xA2);
        actors[2] = address(0xA3);
        actors[3] = address(0xA4);
    }

    function currentInflow() external view returns (uint256) {
        return $.calcDecayedInflow();
    }

    function activationState(uint256 actorIndex) external view returns (uint256 activating, uint256 dust) {
        return $.getActivationState(actors[actorIndex]);
    }

    /// @notice A fuzzed batch of activation mutations in ONE tx, asserting the per-tx inflow invariant after each.
    ///         Baseline is captured once (tx start); `net` accumulates the observed `activating` deltas, reversals
    ///         clamped to each actor's own gross contribution — mirroring the accounting the library must produce.
    function step(uint256 seed, uint256 nOps) external {
        nOps = bound(nOps, 1, 6);

        uint256 baseline = $.calcDecayedInflow(); // prior-tx floor; unchanged within this tx
        uint256 net = 0;
        uint256[4] memory contrib; // per-actor gross contribution this tx (transient-mirror, resets per step)

        for (uint256 i = 0; i < nOps; ++i) {
            uint256 s = uint256(keccak256(abi.encode(seed, i)));
            uint256 ai = s % 4;
            address a = actors[ai];
            uint256 opKind = (s >> 8) % 3; // 0 credit, 1 voluntary debit, 2 forced seize

            (uint256 actBefore, uint256 dustBefore) = $.getActivationState(a);

            if (opKind == 0) {
                // With dust pending the deposit must promote (a sub-threshold bound here would revert
                // DustNotResolved). Otherwise, ~1 in 4 deliberately forms fresh dust (bounded below threshold)
                // so the promote-or-revert rule and `dust < threshold` are actually exercised — a draw from the
                // full [lo, lo + 2*CAP] range lands sub-threshold only by ~5e-5 chance. The rest promotes.
                uint256 lo = dustBefore == 0 ? 1 : MIN_ACT - dustBefore;
                bool formsDust = dustBefore == 0 && (s >> 16) % 4 == 0;
                uint256 hi = formsDust ? MIN_ACT - 1 : lo + 2 * CAP;
                uint256 amt = bound(uint256(keccak256(abi.encode(s, "amt"))), lo, hi);
                _total[a] += amt;
                $.credit(a, amt, false);
                (uint256 actAfter,) = $.getActivationState(a);
                uint256 added = actAfter - actBefore;
                // A promoting credit (added != 0) guarantees activating >= MIN_ACT, proving compliance. A
                // dust-only credit (added == 0) proves nothing about an existing seize remainder — it can still
                // leave `activating + dust < threshold` — so it must NOT clear the flag below.
                if (added != 0) activatingWasSeized[ai] = false;
                net += added;
                contrib[ai] += added;
            } else if (opKind == 1) {
                uint256 inactive = actBefore + dustBefore;
                if (_total[a] == 0) continue;
                // Valid voluntary amounts: within the active balance (buckets untouched) or covering the whole
                // inactive balance (all-or-nothing clear). Draw from the full range, then snap the invalid
                // middle (active, inactive) up to the clearing bound.
                uint256 amt = bound(uint256(keccak256(abi.encode(s, "amt"))), 1, _total[a]);
                if (amt > _total[a] - inactive && amt < inactive) amt = inactive;
                uint256 totalBefore = _total[a];
                _total[a] -= amt;
                $.debit(a, amt, totalBefore);
                (uint256 actAfter,) = $.getActivationState(a);
                // A clearing debit leaves activating == 0 and is trivially compliant; an active-only debit
                // leaves the buckets untouched, so an existing seize-remainder flag must survive it.
                if (actAfter == 0) activatingWasSeized[ai] = false;
                uint256 reversed = Math.min(contrib[ai], actBefore - actAfter);
                net -= reversed;
                contrib[ai] -= reversed;
            } else if (_total[a] != 0) {
                uint256 amt = bound(uint256(keccak256(abi.encode(s, "amt"))), 1, _total[a]);
                uint256 totalBefore = _total[a];
                _total[a] -= amt;
                $.seize(a, amt, totalBefore);
                (uint256 actAfter,) = $.getActivationState(a);
                // Only a seize that actually touches activating updates the flag — a dust-only seize
                // (actAfter == actBefore) must leave an existing flag untouched. A full drain (actAfter == 0) is
                // trivially compliant and clears it; any nonzero remainder is flagged unverified (no demotion —
                // it can legitimately be sub-threshold) until a promoting credit or a debit proves it compliant.
                if (actAfter < actBefore) activatingWasSeized[ai] = actAfter != 0;
                uint256 reversed = Math.min(contrib[ai], actBefore - actAfter);
                net -= reversed;
                contrib[ai] -= reversed;
            }

            assertEq($.calcDecayedInflow(), Math.min(CAP, baseline + net), "inflow must equal min(cap, baseline + net)");
        }
    }

    /// @notice Advance time so the accumulator decays between txs, varying the baseline of later steps.
    function warp(uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 0, MAX_DELAY));
    }
}
