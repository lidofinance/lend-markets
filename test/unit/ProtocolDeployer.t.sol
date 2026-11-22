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
import {
    CoreConfig,
    ExitBookAddresses,
    ExitBooksConfig,
    ProtocolAddresses,
    ProtocolDeployer
} from "../../script/lib/ProtocolDeployer.sol";

contract CircuitBreakerConfigStub {
    address public immutable ADMIN;

    constructor(address admin) {
        ADMIN = admin;
    }
}

contract ProtocolDeployerHarness is ProtocolDeployer {
    /// @dev The backbone for `agent` and `executor` over `circuitBreaker`; the CircuitBreaker durations go unused.
    function deployBackbone(address agent, address executor, address circuitBreaker, address resealManager)
        external
        returns (ProtocolAddresses memory)
    {
        CoreConfig memory c;
        c.admin = agent;
        c.manager = executor;
        c.resealManager = resealManager;
        return _deployBackbone(c, circuitBreaker, address(this));
    }

    function deployExitBooks(ProtocolAddresses memory p, ExitBooksConfig memory c)
        external
        returns (ExitBookAddresses memory)
    {
        return _deployExitBooks(p, c, address(this));
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
        ProtocolAddresses memory deployment = deployer.deployBackbone(
            agent, executor, address(new CircuitBreakerConfigStub(executor)), makeAddr("resealManager")
        );

        assertEq(ILidoLend(deployment.core).feeRecipient(), agent);
    }

    function test_deployBackbone_assignsFeeManagerToExecutorOnly() external {
        address agent = makeAddr("agent");
        ProtocolAddresses memory deployment = deployer.deployBackbone(
            agent, executor, address(new CircuitBreakerConfigStub(executor)), makeAddr("resealManager")
        );
        LidoLendOwner facade = LidoLendOwner(deployment.ownerFacade);
        bytes32 role = facade.FEE_MANAGER_ROLE();

        assertEq(facade.getRoleMemberCount(role), 1);
        assertTrue(facade.hasRole(role, executor));
        assertFalse(facade.hasRole(role, agent));
        assertFalse(facade.hasRole(role, address(deployer)));
    }

    /// @dev `_deployBackbone` gives all authority to the Agent, the owner facade, and the EVMScriptExecutor, and the
    ///      deployer keeps none. The owner facade owns the core.
    function test_deployBackbone_deployerKeepsNoAuthority() external {
        address agent = makeAddr("agent");
        ProtocolAddresses memory deployment = deployer.deployBackbone(
            agent, executor, address(new CircuitBreakerConfigStub(executor)), makeAddr("resealManager")
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

        RiskStewardDashboard dashboard = RiskStewardDashboard(deployment.dashboard);
        _assertSoleMember(address(dashboard), dashboard.DEFAULT_ADMIN_ROLE(), agent);
        _assertSoleMember(address(dashboard), dashboard.STEWARD_ADMIN_ROLE(), executor);
    }

    function test_deployExitBooks_assignsPauserAndLeavesResumerEmpty() external {
        address pauser = makeAddr("exitBookPauser");

        ExitBookAddresses memory books = deployer.deployExitBooks(_protocol(), _exitBooksConfig(pauser));

        _assertExitBookPauseRoles(ExitBookBase(books.morpho), pauser);
        _assertExitBookPauseRoles(ExitBookBase(books.erc4626), pauser);
    }

    function test_deployExitBooks_handsOverRolesAndInitializesZeroFee() external {
        ExitBooksConfig memory c = _exitBooksConfig(makeAddr("exitBookPauser"));

        ExitBookAddresses memory books = deployer.deployExitBooks(_protocol(), c);

        _assertExitBookHandover(ExitBookBase(books.morpho), c);
        _assertExitBookHandover(ExitBookBase(books.erc4626), c);
    }

    function testRevert_deployExitBooks_missingPauser() external {
        vm.expectRevert(ProtocolDeployer.MissingExitBookPauser.selector);
        deployer.deployExitBooks(_protocol(), _exitBooksConfig(address(0)));
    }

    function testRevert_deployExitBooks_pauserIsDeployer() external {
        vm.expectRevert(ProtocolDeployer.ExitBookPauserCannotBeDeployer.selector);
        deployer.deployExitBooks(_protocol(), _exitBooksConfig(address(deployer)));
    }

    function testRevert_deployExitBooks_pauserIsAgent() external {
        ExitBooksConfig memory c = _exitBooksConfig(address(0xA11CE));

        vm.expectRevert(ProtocolDeployer.ExitBookPauserCannotBeAgent.selector);
        deployer.deployExitBooks(_protocol(), c);
    }

    function testRevert_deployExitBooks_pauserIsExecutor() external {
        ExitBooksConfig memory c = _exitBooksConfig(address(0xE0E0));

        vm.expectRevert(ProtocolDeployer.ExitBookPauserCannotBeExecutor.selector);
        deployer.deployExitBooks(_protocol(), c);
    }

    /// @dev The protocol the books are deployed over: the Agent, the EVMScriptExecutor and the core.
    function _protocol() private pure returns (ProtocolAddresses memory p) {
        p.agent = address(0xA11CE);
        p.executor = address(0xE0E0);
        p.core = address(0xC0DE);
    }

    function _exitBooksConfig(address pauser) private pure returns (ExitBooksConfig memory c) {
        c = ExitBooksConfig({pauser: pauser, maxRequestLifetime: 365 days});
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

    function _assertExitBookHandover(ExitBookBase book, ExitBooksConfig memory c) private view {
        ProtocolAddresses memory p = _protocol();
        assertEq(book.getRoleMemberCount(book.DEFAULT_ADMIN_ROLE()), 1);
        assertTrue(book.hasRole(book.DEFAULT_ADMIN_ROLE(), p.agent));
        assertEq(book.getRoleMemberCount(book.ALLOWLIST_MANAGER_ROLE()), 1);
        assertTrue(book.hasRole(book.ALLOWLIST_MANAGER_ROLE(), p.executor));
        assertEq(book.getRoleMemberCount(book.FEE_MANAGER_ROLE()), 0);
        assertEq(book.getRoleMemberCount(book.RECOVERER_ROLE()), 0);
        assertEq(book.feeRecipient(), p.agent);
        assertEq(book.serviceFee(), 0);
        _assertExitBookPauseRoles(book, c.pauser);
    }
}
