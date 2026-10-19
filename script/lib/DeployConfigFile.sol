// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {ConfigToml} from "./ConfigToml.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

struct DeployConfig {
    string network;
    uint256 chainId;
    bytes32 configHash;
    bytes32 compatibilityHash;
    address agent;
    address evmScriptExecutor;
    address resealManager;
    string circuitBreakerArtifact; // one fixed CircuitBreaker per deployed core/factory
    bool exitBooks; // deploy the protocol's two exit books
    address exitBookPauser; // Risk Steward Committee for integrated or standalone Exit Book deployment
    uint256 exitBookMaxRequestLifetime;
    address pauserCommittee; // CircuitBreaker pauser the activation registers; the Agent stands in when unset
}

interface ILidoLendMarketFactoryBindings {
    function LIDO_LEND() external view returns (address);

    function IRM_ROUTER() external view returns (address);

    function RESEAL_MANAGER() external view returns (address);
}

library DeployConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error AgentCannotBeDeployer();
    error AgentCannotBeExecutor();
    error ExitBookPauserCannotBeAgent();
    error ExitBookPauserCannotBeDeployer();
    error ExitBookPauserCannotBeExecutor();
    error ExecutorCannotBeDeployer();
    error PauserCommitteeCannotBeAgent();
    error PauserCommitteeCannotBeDeployer();
    error PauserCommitteeCannotBeExecutor();
    error RegistryAgentMismatch(address expected, address actual);
    error RegistryArtifactChainIdMismatch(uint256 artifactChainId, uint256 protocolChainId);
    error RegistryCompatibilityHashMismatch(bytes32 expected, bytes32 actual);
    error RegistryConfigHashMismatch(bytes32 artifactHash, bytes32 protocolHash);
    error RegistryChainIdMismatch(uint256 expected, uint256 actual);
    error RegistryCoreNotContract(address core);
    error RegistryDeploymentMismatch(string artifactDeployment, string protocolDeployment);
    error RegistryExecutorMismatch(address expected, address actual);
    error RegistryFactoryCoreMismatch(address expected, address actual);
    error RegistryFactoryNotContract(address factory);
    error RegistryFactoryIrmRouterMismatch(address expected, address actual);
    error RegistryFactoryResealManagerMismatch(address expected, address actual);
    error RegistryNetworkMismatch(string expected, string actual);
    error RegistryResealManagerMismatch(address expected, address actual);
    error UnexpectedChainId(uint256 expected, uint256 actual);

    function read(string memory name) internal view returns (DeployConfig memory cfg) {
        string memory toml = vm.readFile(configPath(name));
        return parse(toml);
    }

    function parse(string memory toml) internal view returns (DeployConfig memory cfg) {
        cfg.configHash = keccak256(bytes(toml));
        cfg.network = ConfigToml.requireString(toml, ".network");
        cfg.chainId = ConfigToml.requireUint(toml, ".chain_id");
        cfg.agent = ConfigToml.requireAddress(toml, ".agent");
        cfg.evmScriptExecutor = ConfigToml.requireAddress(toml, ".evm_script_executor");
        cfg.resealManager = ConfigToml.requireAddress(toml, ".reseal_manager");
        cfg.circuitBreakerArtifact = ConfigToml.requireString(toml, ".circuit_breaker_artifact");
        cfg.compatibilityHash = canonicalCompatibilityHash(
            cfg.network, cfg.chainId, cfg.agent, cfg.evmScriptExecutor, cfg.resealManager, cfg.circuitBreakerArtifact
        );
        cfg.exitBooks = vm.parseTomlBool(toml, ".exit_books");
        if (vm.keyExistsToml(toml, ".exit_book_pauser")) {
            cfg.exitBookPauser = vm.parseTomlAddress(toml, ".exit_book_pauser");
        }
        if (cfg.exitBooks || vm.keyExistsToml(toml, ".exit_book_max_request_lifetime")) {
            cfg.exitBookMaxRequestLifetime = ConfigToml.requireUint(toml, ".exit_book_max_request_lifetime");
        }
        if (vm.keyExistsToml(toml, ".pauser_committee")) {
            cfg.pauserCommittee = vm.parseTomlAddress(toml, ".pauser_committee");
        }
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
        if (cfg.exitBookPauser != address(0)) {
            if (cfg.exitBookPauser == deployer) revert ExitBookPauserCannotBeDeployer();
            if (cfg.exitBookPauser == cfg.agent) revert ExitBookPauserCannotBeAgent();
            if (cfg.exitBookPauser == cfg.evmScriptExecutor) revert ExitBookPauserCannotBeExecutor();
        }
        if (cfg.pauserCommittee != address(0)) {
            if (cfg.pauserCommittee == deployer) revert PauserCommitteeCannotBeDeployer();
            if (cfg.pauserCommittee == cfg.agent) revert PauserCommitteeCannotBeAgent();
            if (cfg.pauserCommittee == cfg.evmScriptExecutor) revert PauserCommitteeCannotBeExecutor();
        }
    }

    function artifactMetadata(DeployConfig memory cfg) internal view returns (ArtifactMetadata memory) {
        return ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: cfg.chainId,
            configHash: cfg.configHash,
            compatibilityHash: cfg.compatibilityHash
        });
    }

    function canonicalCompatibilityHash(
        string memory network,
        uint256 chainId,
        address agent,
        address evmScriptExecutor,
        address resealManager,
        string memory circuitBreakerArtifact
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(network, chainId, agent, evmScriptExecutor, resealManager, circuitBreakerArtifact));
    }

    function requireProtocolArtifactCompatibility(string memory registry) internal view {
        bytes32 expected = canonicalCompatibilityHash(
            vm.parseTomlString(registry, ".protocol.network"),
            vm.parseTomlUint(registry, ".protocol.chain_id"),
            vm.parseTomlAddress(registry, ".protocol.agent"),
            vm.parseTomlAddress(registry, ".protocol.evm_script_executor"),
            vm.parseTomlAddress(registry, ".protocol.reseal_manager"),
            vm.parseTomlString(registry, ".protocol.circuit_breaker_artifact")
        );
        bytes32 actual = vm.parseTomlBytes32(registry, ".artifact.compatibility_hash");
        if (actual != expected) revert RegistryCompatibilityHashMismatch(expected, actual);
    }

    function requireRunResourcesCompatible(ArtifactMetadata memory expected) internal view {
        ArtifactMetadataFile.requireRunResourcesCompatible(expected);
    }

    function requireExistingProtocolCompatible(DeployConfig memory cfg) internal view returns (string memory registry) {
        string memory path = string.concat(ArtifactMetadataFile.artifactsDir(), "/protocol.toml");
        if (!vm.exists(path)) return "";
        registry = ArtifactMetadataFile.requireCompatible(path, artifactMetadata(cfg));
        requireRegistryGovernance(cfg, registry);
        requireProtocolBackboneLive(registry);
    }

    function requireProtocolBackboneLive(string memory registry) internal view {
        address core = vm.parseTomlAddress(registry, ".protocol.core");
        if (core.code.length == 0) revert RegistryCoreNotContract(core);

        address factory = vm.parseTomlAddress(registry, ".protocol.factory");
        if (factory.code.length == 0) revert RegistryFactoryNotContract(factory);

        address factoryCore = ILidoLendMarketFactoryBindings(factory).LIDO_LEND();
        if (factoryCore != core) revert RegistryFactoryCoreMismatch(core, factoryCore);

        address irmRouter = vm.parseTomlAddress(registry, ".protocol.irm_router");
        address factoryIrmRouter = ILidoLendMarketFactoryBindings(factory).IRM_ROUTER();
        if (factoryIrmRouter != irmRouter) revert RegistryFactoryIrmRouterMismatch(irmRouter, factoryIrmRouter);

        address resealManager = vm.parseTomlAddress(registry, ".protocol.reseal_manager");
        address factoryResealManager = ILidoLendMarketFactoryBindings(factory).RESEAL_MANAGER();
        if (factoryResealManager != resealManager) {
            revert RegistryFactoryResealManagerMismatch(resealManager, factoryResealManager);
        }
    }

    function requireRegistryGovernance(DeployConfig memory cfg, string memory registry) internal view {
        string memory registryNetwork = vm.parseTomlString(registry, ".protocol.network");
        if (keccak256(bytes(registryNetwork)) != keccak256(bytes(cfg.network))) {
            revert RegistryNetworkMismatch(cfg.network, registryNetwork);
        }

        uint256 registryChainId = vm.parseTomlUint(registry, ".protocol.chain_id");
        if (registryChainId != cfg.chainId) revert RegistryChainIdMismatch(cfg.chainId, registryChainId);

        address registryAgent = vm.parseTomlAddress(registry, ".protocol.agent");
        if (registryAgent != cfg.agent) revert RegistryAgentMismatch(cfg.agent, registryAgent);

        address registryExecutor = vm.parseTomlAddress(registry, ".protocol.evm_script_executor");
        if (registryExecutor != cfg.evmScriptExecutor) {
            revert RegistryExecutorMismatch(cfg.evmScriptExecutor, registryExecutor);
        }

        address registryResealManager = vm.parseTomlAddress(registry, ".protocol.reseal_manager");
        if (registryResealManager != cfg.resealManager) {
            revert RegistryResealManagerMismatch(cfg.resealManager, registryResealManager);
        }

        uint256 artifactChainId = vm.parseTomlUint(registry, ".artifact.chain_id");
        if (artifactChainId != registryChainId) {
            revert RegistryArtifactChainIdMismatch(artifactChainId, registryChainId);
        }

        string memory artifactDeployment = vm.parseTomlString(registry, ".artifact.deployment");
        string memory protocolDeployment = vm.parseTomlString(registry, ".protocol.deployment");
        if (keccak256(bytes(artifactDeployment)) != keccak256(bytes(protocolDeployment))) {
            revert RegistryDeploymentMismatch(artifactDeployment, protocolDeployment);
        }

        bytes32 artifactConfigHash = vm.parseTomlBytes32(registry, ".artifact.config_hash");
        bytes32 protocolConfigHash = vm.parseTomlBytes32(registry, ".protocol.config_hash");
        if (artifactConfigHash != protocolConfigHash) {
            revert RegistryConfigHashMismatch(artifactConfigHash, protocolConfigHash);
        }

        requireProtocolArtifactCompatibility(registry);

        ArtifactMetadata memory expected = ArtifactMetadata({
            deployment: artifactDeployment,
            chainId: cfg.chainId,
            configHash: cfg.configHash,
            compatibilityHash: cfg.compatibilityHash
        });
        requireRunResourcesCompatible(expected);
    }
}
