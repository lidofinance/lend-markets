// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {ExitBookConfig} from "../../script/lib/ExitBookConfigFile.sol";

contract CircuitBreakerConfigStub {
    address public immutable ADMIN;

    constructor(address admin) {
        ADMIN = admin;
    }
}

contract ProtocolDeployerHarness is ProtocolDeployer {
    function deployExitBooks(ExitBookConfig memory cfg) external returns (address morpho, address erc4626) {
        return _deployExitBooks(cfg, address(this));
    }

    function requireCircuitBreakerPolicy(address circuitBreaker, address executor) external view {
        _requireCircuitBreakerPolicy(circuitBreaker, executor);
    }
}

contract ProtocolDeployerTest is Test {
    ProtocolDeployerHarness internal deployer;
    address internal executor;

    function setUp() external {
        deployer = new ProtocolDeployerHarness();
        executor = makeAddr("executor");
    }

    function testRevert_requireCircuitBreakerPolicy_missingCircuitBreaker() external {
        vm.expectRevert(ProtocolDeployer.MissingCircuitBreaker.selector);
        deployer.requireCircuitBreakerPolicy(address(0), executor);
    }

    function testRevert_requireCircuitBreakerPolicy_rejectsNonContract() external {
        address circuitBreaker = makeAddr("circuitBreaker");
        vm.expectRevert(abi.encodeWithSelector(ProtocolDeployer.CircuitBreakerNotContract.selector, circuitBreaker));
        deployer.requireCircuitBreakerPolicy(circuitBreaker, executor);
    }

    function testRevert_requireCircuitBreakerPolicy_rejectsWrongAdmin() external {
        address actualAdmin = makeAddr("actualAdmin");
        address circuitBreaker = address(new CircuitBreakerConfigStub(actualAdmin));
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolDeployer.UnexpectedCircuitBreakerAdmin.selector, executor, actualAdmin)
        );
        deployer.requireCircuitBreakerPolicy(circuitBreaker, executor);
    }

    function test_requireCircuitBreakerPolicy_acceptsExecutorAdministeredCircuitBreaker() external {
        deployer.requireCircuitBreakerPolicy(address(new CircuitBreakerConfigStub(executor)), executor);
    }

    function test_deployExitBooks_assignsPauserAndLeavesResumerEmpty() external {
        address pauser = makeAddr("exitBookPauser");

        (address morpho, address erc4626) = deployer.deployExitBooks(_exitBookConfig(pauser));

        _assertExitBookPauseRoles(ExitBookBase(morpho), pauser);
        _assertExitBookPauseRoles(ExitBookBase(erc4626), pauser);
    }

    function testRevert_deployExitBooks_missingPauser() external {
        vm.expectRevert(ProtocolDeployer.MissingExitBookPauser.selector);
        deployer.deployExitBooks(_exitBookConfig(address(0)));
    }

    function testRevert_deployExitBooks_pauserIsDeployer() external {
        vm.expectRevert(ProtocolDeployer.ExitBookPauserCannotBeDeployer.selector);
        deployer.deployExitBooks(_exitBookConfig(address(deployer)));
    }

    function testRevert_deployExitBooks_pauserIsAgent() external {
        ExitBookConfig memory cfg = _exitBookConfig(address(0xA11CE));

        vm.expectRevert(ProtocolDeployer.ExitBookPauserCannotBeAgent.selector);
        deployer.deployExitBooks(cfg);
    }

    function testRevert_deployExitBooks_pauserIsExecutor() external {
        ExitBookConfig memory cfg = _exitBookConfig(address(0xE0E0));

        vm.expectRevert(ProtocolDeployer.ExitBookPauserCannotBeExecutor.selector);
        deployer.deployExitBooks(cfg);
    }

    function _exitBookConfig(address pauser) private pure returns (ExitBookConfig memory cfg) {
        cfg = ExitBookConfig({
            agent: address(0xA11CE),
            evmScriptExecutor: address(0xE0E0),
            pauser: pauser,
            core: address(0xC0DE),
            maxRequestLifetime: 365 days
        });
    }

    function _assertExitBookPauseRoles(ExitBookBase book, address pauser) private view {
        assertEq(book.getRoleMemberCount(book.PAUSER_ROLE()), 1);
        assertTrue(book.hasRole(book.PAUSER_ROLE(), pauser));
        assertEq(book.getRoleMemberCount(book.RESUMER_ROLE()), 0);
    }
}
