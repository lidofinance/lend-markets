// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ActivationInflowHandler} from "./handlers/ActivationInflowHandler.sol";

/// @notice L4 stateful invariants for collateral-activation buckets and the inflow throttle (ACT-04/05/06), with
///         no activating lock configured. Under any bounded same-tx sequence of credit / voluntary debit /
///         forced seizure (liquidation & settlement share the `seize` path) over several borrowers:
///           - the per-tx accounting `storedInflow == min(cap, baseline + netTxActivating)` holds after every
///             mutation (asserted inside the handler's `step`, since baseline/net are transient), and
///           - the persistent accumulator never exceeds the cap (checked here between txs), and
///           - without a lock floor, dust stays below the activation threshold, and any activating position
///             without an unverified forced-seizure remainder meets the threshold in aggregate with its dust —
///             forced seizure (liquidation/settlement) is a FORCED path that may legitimately leave a
///             sub-threshold nonzero activating remainder (no demotion; maturity alone decides when it
///             activates), so a position is excluded from that half of the check only until a later promoting
///             credit or clearing debit proves it compliant again (an active-only debit leaves the buckets,
///             and thus the exclusion, untouched).
///         The handler drives the library WITHOUT instant activation, so the inflow path is genuinely exercised
///         — unlike the protocol-level invariants, which short-circuit activation.
/// @dev Revert-bounded (`fail-on-revert = true`): every handler op self-bounds, so a run fails only on an accounting,
///      cap, or bucket-state invariant breach.
/// forge-config: default.invariant.fail-on-revert = true
contract ActivationInflowInvariant is Test {
    ActivationInflowHandler internal handler;

    function setUp() public {
        handler = new ActivationInflowHandler();
        targetContract(address(handler));
    }

    /// @notice The stored accumulator never exceeds the configured cap, in any reachable state.
    function invariant_inflowNeverExceedsCap() public view {
        assertLe(handler.currentInflow(), handler.CAP(), "inflow exceeded maxDelayInflow");
    }

    /// @notice With no lock floor, dust stays below the activation threshold. A position without an unverified
    ///         forced-seizure remainder keeps a total inactive amount (`activating + dust`) at or above the
    ///         threshold — forced seizure is a FORCED path that may legitimately leave a sub-threshold nonzero
    ///         activating remainder (maturity, not size, decides when it activates), so a position is excluded
    ///         from that half of the check only until a later promoting credit or clearing debit proves it
    ///         compliant.
    function invariant_noLockActivationBucketsRespectThreshold() public view {
        uint256 threshold = handler.MIN_ACT();
        for (uint256 i; i < 4; ++i) {
            (uint256 activating, uint256 dust) = handler.activationState(i);
            assertLt(dust, threshold, "dust reached minActivationAmount");
            if (handler.activatingWasSeized(i)) continue;
            assertTrue(
                activating == 0 || activating + dust >= threshold, "activating position fell below minActivationAmount"
            );
        }
    }
}
