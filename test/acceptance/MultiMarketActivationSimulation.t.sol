// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {AcceptanceBase} from "./AcceptanceBase.t.sol";

/// @notice Simulation: two markets activate sequentially without overwriting shared singleton state.
contract MultiMarketActivationSimulation is AcceptanceBase {
    function test_twoMarketsActivateWithoutCrossMarketStateCollision() external {
        string memory marketA = vm.envString("MARKET_A");
        string memory marketB = vm.envString("MARKET_B");
        _loadExpectedSettlementChoice();

        _loadMarket(marketA);
        bytes32 marketIdA = marketId;
        address controllerA = controller;
        address vaultA = vault;
        address pauserA = makeAddr("acceptancePauserCommitteeA");

        _assertMarketReady();
        _activate(pauserA);
        pauserCommittee = pauserA;
        _allowlistExitBooks();
        _assertActivated();
        _assertExitBooksAllowed();

        _loadMarket(marketB);
        assertNotEq(marketId, marketIdA, "markets have the same id");
        assertNotEq(controller, controllerA, "markets share controller");
        assertNotEq(vault, vaultA, "markets share vault");

        _assertMarketReady();
        address pauserB = makeAddr("acceptancePauserCommitteeB");
        _activate(pauserB);
        pauserCommittee = pauserB;
        _allowlistExitBooks();
        _assertActivated();
        _assertExitBooksAllowed();

        // Activating B must not alter A's router, curve, controller, pauser, settlement, or allow-list state.
        _loadMarket(marketA);
        pauserCommittee = pauserA;
        _assertActivated();
        _assertExitBooksAllowed();
    }

    function _assertMarketReady() private {
        _assertComponentsDeployed();
        _assertWiring();
        _assertConfig();
        _assertFactoryValidation();
        _assertRoles();
        _assertRoleHolderCompleteness();
        _assertCircuitBreakerReadyAsPauser();
        _assertNotYetActivated();
        _assertExitBooksNotAllowed();
    }
}
