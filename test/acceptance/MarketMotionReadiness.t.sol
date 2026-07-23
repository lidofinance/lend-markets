// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {AcceptanceBase, IReadController, IReadDashboard} from "./AcceptanceBase.t.sol";

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
        _assertExitBooksNotAllowed();
    }

    function testRevert_pausedControllerIsRejected() external {
        vm.prank(circuitBreaker);
        IReadController(controller).pauseFor(1 days);
        vm.expectRevert();
        this.assertWiring();
    }

    function testRevert_wrongFacadeBytecodeIsRejected() external {
        vm.etch(facade, hex"00");
        vm.expectRevert();
        this.assertComponents();
    }

    function testRevert_frozenControllerIsRejected() external {
        vm.prank(agent);
        IAccessControl(controller).grantRole(FREEZER_ROLE, agent);
        vm.prank(agent);
        IReadController(controller).freeze();
        vm.expectRevert();
        this.assertWiring();
    }

    function testRevert_unexpectedInstantActivationCallerIsRejected() external {
        address caller = makeAddr("unexpectedInstantActivationCaller");
        vm.prank(facade);
        IReadController(controller).grantInstantActivation(caller);
        address[] memory candidates = new address[](1);
        candidates[0] = caller;
        vm.expectRevert();
        this.assertInstantActivationCallers(candidates);
    }

    function testRevert_unexpectedMarketStewardIsRejected() external {
        vm.prank(executor);
        IReadDashboard(dashboard).addMarketSteward(Id.wrap(marketId), makeAddr("unexpectedSteward"));
        vm.expectRevert();
        this.assertRoles();
    }

    function assertWiring() external {
        _assertWiring();
    }

    function assertComponents() external {
        _assertComponentsDeployed();
    }

    function assertInstantActivationCallers(address[] calldata candidates) external view {
        _assertInstantActivationCallers(candidates, new address[](0));
    }

    function assertRoles() external view {
        _assertRoles();
    }
}
