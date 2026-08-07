// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

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
/// @param maxGuardiansQuorumDelay Liveness fallback for the quorum gate, measured from the lot's start. Once
///        it elapses the lot matures even if the guardian quorum has not scanned past the unlock. Must exceed
///        the base-delay cap (maxActivationDelay), else it fires at the unlock and the quorum gets no window.
///        0 matures at the base unlock (no gate). A nonzero value cannot exceed 7 days.
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
