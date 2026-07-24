// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {DeployConfig, DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";

contract DeployConfigFileHarness {
    function requireActorSeparation(DeployConfig memory cfg, address deployer) external pure {
        DeployConfigFile.requireActorSeparation(cfg, deployer);
    }

    function requireRegistryGovernance(DeployConfig memory cfg, string memory registry) external view {
        DeployConfigFile.requireRegistryGovernance(cfg, registry);
    }
}

contract DeployConfigFileTest is Test {
    DeployConfigFileHarness internal harness;

    function setUp() external {
        harness = new DeployConfigFileHarness();
    }

    function test_requireActorSeparation_acceptsDistinctActors() external {
        harness.requireActorSeparation(_config(makeAddr("agent"), makeAddr("executor")), makeAddr("deployer"));
    }

    function testRevert_requireActorSeparation_agentIsDeployer() external {
        address agent = makeAddr("agent");

        vm.expectRevert(DeployConfigFile.AgentCannotBeDeployer.selector);
        harness.requireActorSeparation(_config(agent, makeAddr("executor")), agent);
    }

    function testRevert_requireActorSeparation_executorIsDeployer() external {
        address executor = makeAddr("executor");

        vm.expectRevert(DeployConfigFile.ExecutorCannotBeDeployer.selector);
        harness.requireActorSeparation(_config(makeAddr("agent"), executor), executor);
    }

    function testRevert_requireActorSeparation_agentIsExecutor() external {
        address agent = makeAddr("agent");

        vm.expectRevert(DeployConfigFile.AgentCannotBeExecutor.selector);
        harness.requireActorSeparation(_config(agent, agent), makeAddr("deployer"));
    }

    function test_requireRegistryGovernance_acceptsMatchingRegistry() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");

        harness.requireRegistryGovernance(_config(agent, executor), _registry(1, agent, executor));
    }

    function testRevert_requireRegistryGovernance_chainIdMismatch() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");

        vm.expectRevert(abi.encodeWithSelector(DeployConfigFile.RegistryChainIdMismatch.selector, 1, 2));
        harness.requireRegistryGovernance(_config(agent, executor), _registry(2, agent, executor));
    }

    function testRevert_requireRegistryGovernance_agentMismatch() external {
        address agent = makeAddr("agent");
        address registryAgent = makeAddr("registryAgent");
        address executor = makeAddr("executor");

        vm.expectRevert(abi.encodeWithSelector(DeployConfigFile.RegistryAgentMismatch.selector, agent, registryAgent));
        harness.requireRegistryGovernance(_config(agent, executor), _registry(1, registryAgent, executor));
    }

    function testRevert_requireRegistryGovernance_executorMismatch() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");
        address registryExecutor = makeAddr("registryExecutor");

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfigFile.RegistryExecutorMismatch.selector, executor, registryExecutor)
        );
        harness.requireRegistryGovernance(_config(agent, executor), _registry(1, agent, registryExecutor));
    }

    function _config(address agent, address executor) private pure returns (DeployConfig memory cfg) {
        cfg.chainId = 1;
        cfg.agent = agent;
        cfg.evmScriptExecutor = executor;
    }

    function _registry(uint256 chainId, address agent, address executor) private view returns (string memory) {
        return string.concat(
            "[protocol]\n",
            "chain_id = ",
            vm.toString(chainId),
            "\nagent = \"",
            vm.toString(agent),
            "\"\nevm_script_executor = \"",
            vm.toString(executor),
            "\"\n"
        );
    }
}
