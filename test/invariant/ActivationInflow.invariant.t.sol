// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ActivationInflowHandler} from "./handlers/ActivationInflowHandler.sol";

/// @notice L4 stateful invariant for the collateral-activation inflow throttle (ACT-04/05/06). Under any bounded
///         same-tx sequence of credit / voluntary debit / demotion / forced seizure (liquidation & settlement
///         share the `seize` path) over several borrowers, the accumulator must never be corrupted:
///           - the per-tx accounting `storedInflow == min(cap, baseline + netTxActivating)` holds after every
///             mutation (asserted inside the handler's `step`, since baseline/net are transient), and
///           - the persistent accumulator never exceeds the cap (checked here between txs).
///         The handler drives the library WITHOUT instant activation, so the inflow path is genuinely exercised
///         — unlike the protocol-level invariants, which short-circuit activation.
/// @dev Revert-bounded (`fail-on-revert = true`): every handler op self-bounds, so the only way a run fails is a
///      real accounting mismatch (the in-handler `assertEq`) or a cap breach (the invariant below).
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
}
