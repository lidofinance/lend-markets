// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

/// @notice Inputs for an exit-book deploy. Assembled by `DeployProtocol` from the deploy config (governance +
///         `exit_book_max_request_lifetime`) and the just-deployed core, then passed to `ProtocolDeployer`. `core`
///         is used only by the Morpho book; the ERC-4626 book ignores it.
struct ExitBookConfig {
    address agent; // DEFAULT_ADMIN_ROLE + FEE_MANAGER_ROLE + RECOVERER_ROLE
    address evmScriptExecutor; // ALLOWLIST_MANAGER_ROLE (allow-list a market/vault via an EasyTrack motion)
    address core; // MorphoExitBook only — the LidoLend core its requests draw from
    uint256 maxRequestLifetime; // cap on a request's lifetime (seconds); must be non-zero
}
