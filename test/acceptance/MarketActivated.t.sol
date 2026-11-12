// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {AcceptanceBase} from "./AcceptanceBase.t.sol";

/// @notice Acceptance: after the activation motion runs, the market is fully connected, configured, and live.
///         Skips while the market is inert. Once activated, it verifies the existing state against the
///         independently supplied motion inputs: `ACCEPTANCE_PAUSER_COMMITTEE` as the expected CircuitBreaker pauser,
///         `ACCEPTANCE_MARKET_STEWARD` as the only market steward, and `ACCEPTANCE_MARKET_FEE` as the market fee.
contract MarketActivatedAcceptance is AcceptanceBase {
    function setUp() public override {
        super.setUp();
        if (core.code.length == 0) return; // base skipped: no ACCEPTANCE_REGISTRY configured
        if (!_isMarketActivated()) vm.skip(true, "acceptance: market is not activated");
        _loadExpectedSettlementChoice();
        _loadExpectedPauserCommittee();
        _loadExpectedMarketSteward();
        _loadExpectedMarketFee();
    }

    function test_fullyConnectedConfiguredAndLive() external {
        _assertComponentsDeployed();
        _assertWiring();
        _assertConfig();
        _assertFactoryValidation();
        _assertRoles();
        _assertRoleHolderCompleteness();
        _assertActivated();
        _assertExitBooksAllowed();
    }

    function test_circuitBreakerPausesControllerAndClearsRegistration() external {
        _assertCircuitBreakerPausePath();
    }

    function test_exitBookPauserPausesBothBooks() external {
        _assertExitBookPausePath();
    }
}
