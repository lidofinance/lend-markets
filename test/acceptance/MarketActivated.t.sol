// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {AcceptanceBase} from "./AcceptanceBase.t.sol";

/// @notice Acceptance: after the activation motion runs, the market is fully connected, configured, and live.
///         `setUp` replays the `LidoLendActivateMarket` motion and, when exit books exist, the separate
///         allow-list motion via the impersonated executor. The test then asserts the complete end state.
contract MarketActivatedAcceptance is AcceptanceBase {
    function setUp() public override {
        super.setUp();
        if (core.code.length == 0) return; // base skipped without a registry
        _activate();
        _allowlistExitBooks();
    }

    function test_fullyConnectedConfiguredAndLive() external {
        _assertComponentsDeployed();
        _assertWiring();
        _assertConfig();
        _assertBuilderValidation();
        _assertRoles();
        _assertRoleHolderCompleteness();
        _assertActivated();
        _assertExitBooksAllowed();
    }
}
