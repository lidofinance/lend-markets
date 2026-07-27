// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {ConfigToml} from "./ConfigToml.sol";

struct DeployConfig {
    string network;
    uint256 chainId;
    bytes32 configHash;
    address agent;
    address evmScriptExecutor;
    bool exitBooks; // deploy the protocol's two exit books
    uint256 exitBookMaxRequestLifetime; // used only when exitBooks is true
}

library DeployConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error AgentCannotBeDeployer();
    error AgentCannotBeExecutor();
    error ExecutorCannotBeDeployer();
    error RegistryAgentMismatch(address expected, address actual);
    error RegistryChainIdMismatch(uint256 expected, uint256 actual);
    error RegistryExecutorMismatch(address expected, address actual);
    error UnexpectedChainId(uint256 expected, uint256 actual);

    function read(string memory name) internal view returns (DeployConfig memory cfg) {
        string memory toml = vm.readFile(configPath(name));
        cfg.configHash = keccak256(bytes(toml));
        cfg.network = ConfigToml.requireString(toml, ".network");
        cfg.chainId = ConfigToml.requireUint(toml, ".chain_id");
        cfg.agent = ConfigToml.requireAddress(toml, ".agent");
        cfg.evmScriptExecutor = ConfigToml.requireAddress(toml, ".evm_script_executor");
        cfg.exitBooks = vm.parseTomlBool(toml, ".exit_books");
        cfg.exitBookMaxRequestLifetime = vm.parseTomlUint(toml, ".exit_book_max_request_lifetime");
    }

    function configPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/", name, ".toml");
    }

    function requireChainId(DeployConfig memory cfg) internal view {
        if (block.chainid != cfg.chainId) revert UnexpectedChainId(cfg.chainId, block.chainid);
    }

    function requireActorSeparation(DeployConfig memory cfg, address deployer) internal pure {
        if (cfg.agent == deployer) revert AgentCannotBeDeployer();
        if (cfg.evmScriptExecutor == deployer) revert ExecutorCannotBeDeployer();
        if (cfg.agent == cfg.evmScriptExecutor) revert AgentCannotBeExecutor();
    }

    function requireRegistryGovernance(DeployConfig memory cfg, string memory registry) internal view {
        uint256 registryChainId = vm.parseTomlUint(registry, ".protocol.chain_id");
        if (registryChainId != cfg.chainId) revert RegistryChainIdMismatch(cfg.chainId, registryChainId);

        address registryAgent = vm.parseTomlAddress(registry, ".protocol.agent");
        if (registryAgent != cfg.agent) revert RegistryAgentMismatch(cfg.agent, registryAgent);

        address registryExecutor = vm.parseTomlAddress(registry, ".protocol.evm_script_executor");
        if (registryExecutor != cfg.evmScriptExecutor) {
            revert RegistryExecutorMismatch(cfg.evmScriptExecutor, registryExecutor);
        }
    }
}
