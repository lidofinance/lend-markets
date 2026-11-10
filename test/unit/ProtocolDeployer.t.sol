// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IOwnerManager} from "@lido-lend-irm/src/common/IOwnerManager.sol";

import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";
import {ExitBookConfig} from "../../script/lib/ExitBookConfigFile.sol";
import {ProtocolConfig, ProtocolDeployment} from "../../script/lib/ProtocolConfigFile.sol";

contract CircuitBreakerConfigStub {
    address public immutable ADMIN;

    constructor(address admin) {
        ADMIN = admin;
    }
}

contract ProtocolDeployerHarness is ProtocolDeployer {
    function deployBackbone(ProtocolConfig memory cfg) external returns (ProtocolDeployment memory) {
        return _deployBackbone(cfg, address(this));
    }

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

    function test_deployBackbone_setsCoreFeeRecipientToAgent() external {
        address agent = makeAddr("agent");
        ProtocolConfig memory cfg = ProtocolConfig({
            agent: agent,
            evmScriptExecutor: executor,
            circuitBreaker: address(new CircuitBreakerConfigStub(executor)),
            resealManager: makeAddr("resealManager")
        });

        ProtocolDeployment memory deployment = deployer.deployBackbone(cfg);

        assertEq(ILidoLend(deployment.core).feeRecipient(), agent);
    }

    function test_deployBackbone_assignsFeeManagerToExecutorOnly() external {
        address agent = makeAddr("agent");
        ProtocolConfig memory cfg = ProtocolConfig({
            agent: agent,
            evmScriptExecutor: executor,
            circuitBreaker: address(new CircuitBreakerConfigStub(executor)),
            resealManager: makeAddr("resealManager")
        });

        ProtocolDeployment memory deployment = deployer.deployBackbone(cfg);
        LidoLendOwner facade = LidoLendOwner(deployment.ownerFacade);
        bytes32 role = facade.FEE_MANAGER_ROLE();

        assertEq(facade.getRoleMemberCount(role), 1);
        assertTrue(facade.hasRole(role, executor));
        assertFalse(facade.hasRole(role, agent));
        assertFalse(facade.hasRole(role, address(deployer)));
    }

    /// @dev After the backbone deploy, the deployer keeps no
    ///      authority. The Agent holds every upgrade, ownership and default-admin path, and the EVMScriptExecutor
    ///      holds the manager paths.
    function test_deployBackbone_deployerKeepsNoAuthority() external {
        address agent = makeAddr("agent");
        ProtocolDeployment memory deployment = deployer.deployBackbone(
            ProtocolConfig({
                agent: agent,
                evmScriptExecutor: executor,
                circuitBreaker: address(new CircuitBreakerConfigStub(executor)),
                resealManager: makeAddr("resealManager")
            })
        );

        assertEq(OssifiableProxy(payable(deployment.core)).proxy__getAdmin(), agent, "core proxy admin");
        assertEq(OssifiableProxy(payable(deployment.irmRouter)).proxy__getAdmin(), agent, "router proxy admin");
        assertEq(ILidoLend(deployment.core).owner(), deployment.ownerFacade, "core owner");
        assertEq(IOwnerManager(deployment.irmRouter).owner(), agent, "router owner");
        assertEq(IOwnerManager(deployment.irmRouter).manager(), executor, "router manager");
        assertEq(IOwnerManager(deployment.adaptiveCurveIrm).owner(), agent, "adaptive IRM owner");
        assertEq(IOwnerManager(deployment.adaptiveCurveIrm).manager(), executor, "adaptive IRM manager");
        assertEq(LidoLendMarketFactory(deployment.factory).ADMIN(), agent, "factory admin");

        LidoLendOwner facade = LidoLendOwner(deployment.ownerFacade);
        _assertSoleMember(address(facade), facade.DEFAULT_ADMIN_ROLE(), agent);
        _assertSoleMember(address(facade), facade.MARKET_CREATOR_ROLE(), executor);
        _assertSoleMember(address(facade), facade.MARKET_MANAGER_ROLE(), executor);
        _assertSoleMember(address(facade), facade.GUARDIAN_MANAGER_ROLE(), executor);
        _assertSoleMember(address(facade), facade.FEE_MANAGER_ROLE(), executor);

        RiskStewardDashboard dashboard = RiskStewardDashboard(deployment.riskStewardDashboard);
        _assertSoleMember(address(dashboard), dashboard.DEFAULT_ADMIN_ROLE(), agent);
        _assertSoleMember(address(dashboard), dashboard.STEWARD_ADMIN_ROLE(), executor);
    }

    function test_deployExitBooks_assignsPauserAndLeavesResumerEmpty() external {
        address pauser = makeAddr("exitBookPauser");

        (address morpho, address erc4626) = deployer.deployExitBooks(_exitBookConfig(pauser));

        _assertExitBookPauseRoles(ExitBookBase(morpho), pauser);
        _assertExitBookPauseRoles(ExitBookBase(erc4626), pauser);
    }

    function test_deployExitBooks_assignsFeeManagerToExecutorOnly() external {
        ExitBookConfig memory cfg = _exitBookConfig(makeAddr("exitBookPauser"));

        (address morpho, address erc4626) = deployer.deployExitBooks(cfg);

        _assertExitBookFeeManager(ExitBookBase(morpho), cfg);
        _assertExitBookFeeManager(ExitBookBase(erc4626), cfg);
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

    function _assertSoleMember(address target, bytes32 role, address member) private view {
        IAccessControlEnumerable access = IAccessControlEnumerable(target);
        assertEq(access.getRoleMemberCount(role), 1, "one role member");
        assertEq(access.getRoleMember(role, 0), member, "role member");
        assertFalse(access.hasRole(role, address(deployer)), "deployer holds no role");
    }

    function _assertExitBookPauseRoles(ExitBookBase book, address pauser) private view {
        assertEq(book.getRoleMemberCount(book.PAUSER_ROLE()), 1);
        assertTrue(book.hasRole(book.PAUSER_ROLE(), pauser));
        assertEq(book.getRoleMemberCount(book.RESUMER_ROLE()), 0);
    }

    function _assertExitBookFeeManager(ExitBookBase book, ExitBookConfig memory cfg) private view {
        assertEq(book.getRoleMemberCount(book.FEE_MANAGER_ROLE()), 1);
        assertTrue(book.hasRole(book.FEE_MANAGER_ROLE(), cfg.evmScriptExecutor));
        assertFalse(book.hasRole(book.FEE_MANAGER_ROLE(), cfg.agent));
        assertFalse(book.hasRole(book.FEE_MANAGER_ROLE(), address(deployer)));
    }
}
