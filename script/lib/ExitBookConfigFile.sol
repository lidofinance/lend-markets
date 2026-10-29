// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

struct ExitBookConfig {
    address agent; // DEFAULT_ADMIN_ROLE and initial fee recipient
    address evmScriptExecutor; // ALLOWLIST_MANAGER_ROLE (EasyTrack motions)
    address pauser; // PAUSER_ROLE (Risk Steward Committee)
    address core; // MorphoExitBook only — the LidoLend core its requests draw from
    uint256 maxRequestLifetime; // cap on a request's lifetime (seconds); must be non-zero
}
