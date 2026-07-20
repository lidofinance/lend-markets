// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {AcceptanceBase} from "./AcceptanceBase.t.sol";

/// @notice Acceptance: after the activation motion runs, the market is fully connected, configured, and live.
///         `setUp` replays the `LidoLendActivateMarket` motion via the impersonated executor (route curve +
///         create on core + register pauser + allow-list on both exit books), then the test asserts the
///         complete end state — wiring, role matrix, config, and the activation bindings.
contract MarketActivatedAcceptance is AcceptanceBase {
    function setUp() public override {
        super.setUp();
        if (core.code.length == 0) return; // skipped by base (no fork / no deployment)
        _activate();
    }

    function test_fullyConnectedConfiguredAndLive() external {
        _assertComponentsDeployed();
        _assertWiring();
        _assertConfig();
        _assertBuilderValidation();
        _assertRoles();
        _assertRoleHolderCompleteness();
        _assertActivated();
    }
}
