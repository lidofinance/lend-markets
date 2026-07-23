// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {LidoLendMarketBuilder, MarketRoles} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {ProtocolDeployer} from "../../script/lib/ProtocolDeployer.sol";

contract CircuitBreakerConfigStub {
    address public immutable ADMIN;

    constructor(address admin) {
        ADMIN = admin;
    }
}

contract ProtocolDeployerHarness is ProtocolDeployer {
    function requireMarketRolePolicy(
        MarketRoles memory roles,
        address agent,
        address executor,
        address deploymentCaller
    ) external view {
        _requireMarketRolePolicy(roles, agent, executor, deploymentCaller);
    }

    function requireUniqueMarketIds(string[] memory names, LidoLendMarketBuilder.MarketSpec[] memory markets)
        external
        pure
    {
        _requireUniqueMarketIds(names, markets);
    }
}

contract ProtocolDeployerTest is Test {
    ProtocolDeployerHarness internal deployer;
    address internal agent;
    address internal executor;
    address internal deploymentCaller;

    function setUp() external {
        deployer = new ProtocolDeployerHarness();
        agent = makeAddr("agent");
        executor = makeAddr("executor");
        deploymentCaller = makeAddr("deployer");
    }

    function testRevert_requireMarketRolePolicy_missingCircuitBreaker() external {
        MarketRoles memory roles = _roles();

        vm.expectRevert(ProtocolDeployer.MissingCircuitBreaker.selector);
        deployer.requireMarketRolePolicy(roles, agent, executor, deploymentCaller);
    }

    function test_requireMarketRolePolicy_acceptsAdditionalPausers() external {
        MarketRoles memory roles = _roles();
        roles.pausers = new address[](2);
        roles.pausers[0] = address(new CircuitBreakerConfigStub(executor));
        roles.pausers[1] = makeAddr("additional pauser");

        deployer.requireMarketRolePolicy(roles, agent, executor, deploymentCaller);
    }

    function test_requireMarketRolePolicy_acceptsExecutorAdministeredCircuitBreaker() external {
        MarketRoles memory roles = _roles();
        roles.pausers = new address[](1);
        roles.pausers[0] = address(new CircuitBreakerConfigStub(executor));

        deployer.requireMarketRolePolicy(roles, agent, executor, deploymentCaller);
    }

    function testRevert_requireMarketRolePolicy_executorHasDirectFreezerRole() external {
        MarketRoles memory roles = _rolesWithCircuitBreaker();
        roles.freezers = _arr1(executor);

        vm.expectRevert(ProtocolDeployer.ExecutorHasDirectMarketRole.selector);
        deployer.requireMarketRolePolicy(roles, agent, executor, deploymentCaller);
    }

    function testRevert_requireMarketRolePolicy_executorIsAdditionalPauser() external {
        MarketRoles memory roles = _rolesWithCircuitBreaker();
        roles.pausers = new address[](2);
        roles.pausers[0] = address(new CircuitBreakerConfigStub(executor));
        roles.pausers[1] = executor;

        vm.expectRevert(ProtocolDeployer.ExecutorHasDirectMarketRole.selector);
        deployer.requireMarketRolePolicy(roles, agent, executor, deploymentCaller);
    }

    function testRevert_requireMarketRolePolicy_deployerHasDirectResumerRole() external {
        MarketRoles memory roles = _rolesWithCircuitBreaker();
        roles.resumers = _arr1(deploymentCaller);

        vm.expectRevert(ProtocolDeployer.DeployerHasDirectMarketRole.selector);
        deployer.requireMarketRolePolicy(roles, agent, executor, deploymentCaller);
    }

    function testRevert_requireUniqueMarketIds_duplicateEconomicInputs() external {
        string[] memory names = new string[](2);
        names[0] = "market-a";
        names[1] = "market-b";
        LidoLendMarketBuilder.MarketSpec[] memory markets = new LidoLendMarketBuilder.MarketSpec[](2);
        markets[0] = _marketSpec(0.8 ether);
        markets[1] = _marketSpec(0.8 ether);

        vm.expectRevert(abi.encodeWithSelector(ProtocolDeployer.DuplicateMarketId.selector, names[0], names[1]));
        deployer.requireUniqueMarketIds(names, markets);
    }

    function test_requireUniqueMarketIds_acceptsDifferentLltv() external view {
        string[] memory names = new string[](2);
        names[0] = "market-a";
        names[1] = "market-b";
        LidoLendMarketBuilder.MarketSpec[] memory markets = new LidoLendMarketBuilder.MarketSpec[](2);
        markets[0] = _marketSpec(0.8 ether);
        markets[1] = _marketSpec(0.75 ether);

        deployer.requireUniqueMarketIds(names, markets);
    }

    function _roles() private view returns (MarketRoles memory roles) {
        roles.admin = agent;
        roles.proxyAdmin = agent;
        roles.managers = new address[](0);
        roles.pausers = new address[](0);
        roles.freezers = new address[](0);
        roles.unfreezers = new address[](0);
        roles.resumers = new address[](0);
    }

    function _rolesWithCircuitBreaker() private returns (MarketRoles memory roles) {
        roles = _roles();
        roles.pausers = _arr1(address(new CircuitBreakerConfigStub(executor)));
    }

    function _arr1(address holder) private pure returns (address[] memory holders) {
        holders = new address[](1);
        holders[0] = holder;
    }

    function _marketSpec(uint256 lltv) private pure returns (LidoLendMarketBuilder.MarketSpec memory market) {
        market.loanToken = address(0x1001);
        market.collateralToken = address(0x1002);
        market.oracle = address(0x1003);
        market.lltv = lltv;
    }
}
