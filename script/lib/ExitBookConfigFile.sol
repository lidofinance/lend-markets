// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

struct ExitBookConfig {
    address agent; // DEFAULT_ADMIN_ROLE + FEE_MANAGER_ROLE + RECOVERER_ROLE
    address evmScriptExecutor; // ALLOWLIST_MANAGER_ROLE (allow-list a market/vault via an EasyTrack motion)
    address pauser; // PAUSER_ROLE (Risk Steward Committee)
    address core; // MorphoExitBook only — the LidoLend core its requests draw from
    uint256 maxRequestLifetime; // cap on a request's lifetime (seconds); must be non-zero
}
