// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Id, IMorpho} from "@lido-lend/src/interfaces/IMorpho.sol";

import {AcceptanceBase, IReadController, IReadDashboard} from "./AcceptanceBase.t.sol";

/// @notice Acceptance: the deployed market is INERT but fully prepared, so the EasyTrack activation motion
///         (`LidoLendActivateMarket`, run by the EVMScriptExecutor) can bind it in one shot. Asserts every
///         component/role/config is in place AND that the market is not yet bound on the core — i.e. the only
///         thing left is governance flipping it on.
contract MarketMotionReadinessAcceptance is AcceptanceBase {
    function setUp() public override {
        super.setUp();
        if (core.code.length == 0) return; // base skipped: no ACCEPTANCE_REGISTRY configured
        if (_isMarketActivated()) vm.skip(true, "acceptance: market is already activated");
        _loadExpectedSettlementChoice();
        _loadExpectedPauserCommittee();
    }

    function test_deployedInertAndReadyForMotion() external {
        _assertComponentsDeployed();
        _assertWiring();
        _assertConfig();
        _assertFactoryValidation();
        _assertRoles();
        _assertRoleHolderCompleteness();
        // the executor (motion runner) holds every privilege the motion needs
        _assertCircuitBreakerReadyAsPauser();
        // ...and nothing is bound yet — the motion has work to do
        _assertNotYetActivated();
        _assertZeroState();
        _assertExitBooksNotAllowed();
    }

    function test_exitBookPauserPausesBothBooks() external {
        _assertExitBookPausePath();
    }

    function testRevert_pausedControllerIsRejected() external {
        vm.prank(circuitBreaker);
        IReadController(controller).pauseFor(1 days);
        vm.expectRevert(bytes("controller is paused"));
        this.assertWiring();
    }

    function testRevert_wrongCoreOwnerIsRejected() external {
        address wrongOwner = makeAddr("wrongCoreOwner");
        vm.prank(facade);
        IMorpho(core).setOwner(wrongOwner);
        vm.expectRevert(bytes(string.concat("core.owner: ", vm.toString(wrongOwner), " != ", vm.toString(facade))));
        this.assertWiring();
    }

    /// @dev One byte of code passes the code-length check, so the codehash check rejects it. At readiness the
    ///      deployed code equals the reference build, so the expected hash is the one before the etch.
    function testRevert_wrongFacadeBytecodeIsRejected() external {
        bytes32 referenceHash = facade.codehash;
        vm.etch(facade, hex"00");
        vm.expectRevert(_codehashMismatch("facade", referenceHash));
        this.assertComponents();
    }

    /// @dev As for the facade: the codehash check rejects one byte of code.
    function testRevert_wrongCircuitBreakerBytecodeIsRejected() external {
        bytes32 referenceHash = circuitBreaker.codehash;
        vm.etch(circuitBreaker, hex"00");
        vm.expectRevert(_codehashMismatch("CircuitBreaker", referenceHash));
        this.assertComponents();
    }

    function testRevert_frozenControllerIsRejected() external {
        vm.prank(agent);
        IAccessControl(controller).grantRole(FREEZER_ROLE, agent);
        vm.prank(agent);
        IReadController(controller).freeze();
        vm.expectRevert(bytes("controller is frozen"));
        this.assertWiring();
    }

    function testRevert_unexpectedInstantActivationCallerIsRejected() external {
        address caller = makeAddr("unexpectedInstantActivationCaller");
        vm.prank(facade);
        IReadController(controller).setInstantActivation(caller, true);
        address[] memory candidates = new address[](1);
        candidates[0] = caller;
        vm.expectRevert(bytes("unexpected instant-activation caller count: 1 != 0"));
        this.assertInstantActivationCallers(candidates);
    }

    function testRevert_unexpectedMarketStewardIsRejected() external {
        vm.prank(executor);
        IReadDashboard(dashboard).addMarketSteward(Id.wrap(marketId), makeAddr("unexpectedSteward"));
        vm.expectRevert(bytes("unexpected market steward count: 1 != 0"));
        this.assertRoles();
    }

    /// @dev Mocked rather than deposited into: the readiness phase has no market on the core to supply to, and
    ///      the assertion under test is that a non-zero balance is read and rejected at all.
    function testRevert_nonZeroVaultSupplyIsRejected() external {
        vm.mockCall(vault, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1)));
        vm.expectRevert(bytes("vault.totalSupply: 1 != 0"));
        this.assertZeroState();
    }

    function testRevert_nonZeroSettlementQueueIsRejected() external {
        vm.mockCall(controller, abi.encodeWithSignature("settlementBorrowersCount()"), abi.encode(uint256(1)));
        vm.expectRevert(bytes("controller.settlementBorrowersCount: 1 != 0"));
        this.assertZeroState();
    }

    function testRevert_wrongVaultSymbolIsRejected() external {
        vm.mockCall(vault, abi.encodeWithSignature("symbol()"), abi.encode("wrongSymbol"));
        string memory expectedSymbol = vm.parseTomlString(toml, ".market.vault_symbol");
        vm.expectRevert(bytes(string.concat("vault.symbol: wrongSymbol != ", expectedSymbol)));
        this.assertConfig();
    }

    function assertWiring() external {
        _assertWiring();
    }

    function assertConfig() external view {
        _assertConfig();
    }

    function assertZeroState() external view {
        _assertZeroState();
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

    /// @dev The revert data of a failed `assertEq(actual.codehash, expected.codehash, label)` on etched one-byte code.
    function _codehashMismatch(string memory label, bytes32 expected) private pure returns (bytes memory) {
        return bytes(string.concat(label, ": ", vm.toString(keccak256(hex"00")), " != ", vm.toString(expected)));
    }
}
