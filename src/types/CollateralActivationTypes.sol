// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Value types of the collateral-activation subsystem, kept at file scope so the controller and its
///         interface can import `CollateralActivationConfig` without pulling in the logic library
///         `CollateralActivationLib`.

// ---
// TYPES
// ---

/// @notice Governance-tunable activation parameters, validated by `CollateralActivationLib.setConfig`.
/// @param minActivationDelay Base delay floor, at zero inflow.
/// @param maxActivationDelay Base delay cap, reached at inflow >= maxDelayInflow. Also the inflow decay
///        horizon: the accumulator drains from `maxDelayInflow` to zero over this duration.
/// @param maxDelayInflow Inflow reference at which the base delay reaches the cap, and the ceiling the
///        inflow accumulator saturates at.
/// @param activatingLockAmount Lock on activating collateral, honored by `withdraw`. 0 disables it. Forced
///        paths pass floor 0.
/// @param activatingLockDuration How long, from `activatingStart`, the `activatingLockAmount` portion stays
///        unwithdrawable. Once it elapses the locked collateral becomes withdrawable even if the lot has not
///        matured. 0 disables the lock.
/// @param minActivationAmount Dust threshold. Collateral below it does not enter activation.
/// @param maxGuardiansQuorumDelay Liveness fallback for the quorum gate, measured from the lot's start. A lot can
///        mature only after its full unlock time, including guardian surcharges; after that, it needs either a
///        frontier covering the unlock or this fallback timestamp to have elapsed. A nonzero value must exceed the
///        base-delay cap (`maxActivationDelay`) and cannot exceed 7 days. 0 removes the additional quorum wait after
///        the full unlock.
/// @param delayPerStrike Activation-delay surcharge added per guardian strike. 0 disables it, so strikes do not
///        slow activation and only the ban gates a flagged borrower.
/// @param delayPerSuspect Activation-delay surcharge added per active suspect report, applied only to lots whose
///        activation started before the suspect snapshot lapses. 0 disables it.
struct CollateralActivationConfig {
    uint40 minActivationDelay;
    uint40 maxActivationDelay;
    uint128 maxDelayInflow;
    uint128 activatingLockAmount;
    uint40 activatingLockDuration;
    uint128 minActivationAmount;
    uint40 maxGuardiansQuorumDelay;
    uint40 delayPerStrike;
    uint40 delayPerSuspect;
}
