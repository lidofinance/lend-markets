// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

/// @notice Value types of the collateral-activation subsystem. Defined at file scope (not in
///         `CollateralActivationLib`) so the controller and its interface can reference `CollateralActivationConfig`
///         without importing the logic library.

// ---
// TYPES
// ---

/// @notice Governance-tunable activation parameters, validated by `CollateralActivationLib.setConfig`.
/// @param minActivationDelay Base delay floor, at zero inflow.
/// @param maxActivationDelay Base delay cap, reached at inflow >= maxDelayInflow. Also the inflow decay
///        horizon: the accumulator drains from `maxDelayInflow` to zero over this duration.
/// @param maxDelayInflow Inflow reference at which the base delay reaches the cap, and the ceiling the
///        inflow accumulator saturates at.
/// @param delayPerStrike Activation-delay surcharge added per strike.
/// @param activatingLockAmount Lock on activating collateral, honored by `withdraw`. 0 disables it. Forced
///        paths pass floor 0.
/// @param activatingLockDuration How long, from `activatingStart`, the `activatingLockAmount` portion stays
///        unwithdrawable. Once it elapses the locked collateral is withdrawable even if the lot has not
///        matured, so a locked deposit is only delayed out, never trapped. 0 disables the lock.
/// @param minActivationAmount Dust threshold. Collateral below it does not enter activation.
/// @param maxGuardiansQuorumDelay Cap on total time a lot may stay activating, measured from its start.
///        Once it elapses the lot matures even if the guardian quorum has not scanned past the unlock. It
///        must exceed the base delay to leave the quorum any window. 0 matures at the base unlock (no gate).
struct CollateralActivationConfig {
    uint40 minActivationDelay;
    uint40 maxActivationDelay;
    uint128 maxDelayInflow;
    uint40 delayPerStrike;
    uint128 activatingLockAmount;
    uint40 activatingLockDuration;
    uint128 minActivationAmount;
    uint40 maxGuardiansQuorumDelay;
}
