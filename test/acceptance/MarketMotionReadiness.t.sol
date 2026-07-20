// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {AcceptanceBase} from "./AcceptanceBase.t.sol";

/// @notice Acceptance: the deployed market is INERT but fully prepared, so the EasyTrack activation motion
///         (`LidoLendActivateMarket`, run by the EVMScriptExecutor) can bind it in one shot. Asserts every
///         component/role/config is in place AND that the market is not yet bound on the core — i.e. the only
///         thing left is governance flipping it on.
contract MarketMotionReadinessAcceptance is AcceptanceBase {
    function test_deployedInertAndReadyForMotion() external {
        _assertComponentsDeployed();
        _assertWiring();
        _assertConfig();
        _assertBuilderValidation();
        _assertRoles();
        _assertRoleHolderCompleteness();
        // the executor (motion runner) holds every privilege the motion needs
        _assertCircuitBreakerReadyAsPauser();
        // ...and nothing is bound yet — the motion has work to do
        _assertNotYetActivated();
    }
}
