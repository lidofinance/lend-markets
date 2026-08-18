// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {DeployConfig, DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";
import {ConfigToml} from "../../script/lib/ConfigToml.sol";

contract DeployConfigFileHarness {
    function read(string memory name) external view returns (DeployConfig memory) {
        return DeployConfigFile.read(name);
    }

    function parse(string memory toml) external view returns (DeployConfig memory) {
        return DeployConfigFile.parse(toml);
    }

    function requireActorSeparation(DeployConfig memory cfg, address deployer) external pure {
        DeployConfigFile.requireActorSeparation(cfg, deployer);
    }

    function requireRegistryGovernance(DeployConfig memory cfg, string memory registry) external view {
        DeployConfigFile.requireRegistryGovernance(cfg, registry);
    }

    function requireProtocolArtifactCompatibility(string memory registry) external view {
        DeployConfigFile.requireProtocolArtifactCompatibility(registry);
    }

    function requireProtocolBackboneLive(string memory registry) external view {
        DeployConfigFile.requireProtocolBackboneLive(registry);
    }

    function LIDO_LEND() external view returns (address) {
        return address(this);
    }

    function IRM_ROUTER() external view returns (address) {
        return address(this);
    }
}

contract DeployConfigFileTest is Test {
    struct RegistryFixture {
        uint256 artifactChainId;
        uint256 protocolChainId;
        address agent;
        address executor;
        string artifactDeployment;
        string protocolDeployment;
        bytes32 artifactConfigHash;
        bytes32 protocolConfigHash;
        string network;
        bytes32 compatibilityHash;
    }

    bytes32 internal constant CONFIG_HASH = bytes32(uint256(0xCAFE));
    string internal constant RUN = "deploy-config-file-unit";
    string internal constant POISON_RUN = "deploy-config-file-poison-unit";

    DeployConfigFileHarness internal harness;

    function setUp() external {
        vm.setEnv("ARTIFACTS_DIR", RUN);
        harness = new DeployConfigFileHarness();
    }

    function test_readForkMainnetConfig() external view {
        DeployConfig memory cfg = harness.read("fork-mainnet");

        assertEq(cfg.network, "mainnet");
        assertEq(cfg.chainId, 1);
        assertEq(cfg.circuitBreakerArtifact, "lido-lend");
        assertTrue(cfg.exitBooks);
        assertEq(cfg.exitBookPauser, 0x70997970C51812dc3A010C7d01b50e0d17dc79C8);
        assertEq(cfg.exitBookMaxRequestLifetime, 365 days);
    }

    function test_readConfig_withoutExitBooks_allowsMissingExitBookFields() external {
        DeployConfig memory cfg = harness.parse(_configToml(false, ""));

        assertFalse(cfg.exitBooks);
        assertEq(cfg.exitBookPauser, address(0));
        assertEq(cfg.exitBookMaxRequestLifetime, 0);
    }

    function test_parse_withoutExitBooks_readsStandaloneExitBookFields() external {
        address pauser = makeAddr("standalonePauser");
        DeployConfig memory cfg = harness.parse(
            _configToml(
                false,
                string.concat(
                    "exit_book_pauser = \"", vm.toString(pauser), "\"\nexit_book_max_request_lifetime = 31536000\n"
                )
            )
        );

        assertFalse(cfg.exitBooks);
        assertEq(cfg.exitBookPauser, pauser);
        assertEq(cfg.exitBookMaxRequestLifetime, 365 days);
    }

    function test_parse_compatibilityHashIgnoresExitBookAndProvisionFields() external {
        DeployConfig memory base = harness.parse(_configToml(false, ""));
        DeployConfig memory changed = harness.parse(
            _configToml(
                true,
                string.concat(
                    "exit_book_pauser = \"0x0000000000000000000000000000000000000003\"\n",
                    "exit_book_max_request_lifetime = 31536000\n",
                    "[provision]\nmarkets = [\"one\"]\nvaults = []\n"
                )
            )
        );

        assertNotEq(base.configHash, changed.configHash);
        assertEq(base.compatibilityHash, changed.compatibilityHash);
    }

    function testRevert_readConfig_withExitBooks_rejectsZeroLifetime() external {
        vm.expectRevert(
            abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".exit_book_max_request_lifetime")
        );
        harness.parse(_configToml(true, "exit_book_max_request_lifetime = 0\n"));
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

    function testRevert_requireActorSeparation_standaloneExitBookPauserIsDeployer() external {
        address pauser = makeAddr("exitBookPauser");
        DeployConfig memory cfg = _config(makeAddr("agent"), makeAddr("executor"));
        cfg.exitBooks = false;
        cfg.exitBookPauser = pauser;

        vm.expectRevert(DeployConfigFile.ExitBookPauserCannotBeDeployer.selector);
        harness.requireActorSeparation(cfg, pauser);
    }

    function testRevert_requireActorSeparation_exitBookPauserIsAgent() external {
        address agent = makeAddr("agent");
        DeployConfig memory cfg = _config(agent, makeAddr("executor"));
        cfg.exitBooks = true;
        cfg.exitBookPauser = agent;

        vm.expectRevert(DeployConfigFile.ExitBookPauserCannotBeAgent.selector);
        harness.requireActorSeparation(cfg, makeAddr("deployer"));
    }

    function testRevert_requireActorSeparation_exitBookPauserIsExecutor() external {
        address executor = makeAddr("executor");
        DeployConfig memory cfg = _config(makeAddr("agent"), executor);
        cfg.exitBooks = true;
        cfg.exitBookPauser = executor;

        vm.expectRevert(DeployConfigFile.ExitBookPauserCannotBeExecutor.selector);
        harness.requireActorSeparation(cfg, makeAddr("deployer"));
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

    function testRevert_requireRegistryGovernance_networkMismatch() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");

        vm.expectRevert(abi.encodeWithSelector(DeployConfigFile.RegistryNetworkMismatch.selector, "unit", "other"));
        harness.requireRegistryGovernance(_config(agent, executor), _registryWithIdentity(1, agent, executor, "other"));
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

    function testRevert_requireRegistryGovernance_rejectsIncompatibleRunResource() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");
        DeployConfig memory cfg = _config(agent, executor);
        string memory runDir = string.concat("deployed/", POISON_RUN);
        string memory oracleDir = string.concat(runDir, "/oracles");
        if (vm.exists(runDir)) vm.removeDir(runDir, true);
        vm.createDir(oracleDir, true);
        string memory path = string.concat(oracleDir, "/poison.toml");
        ArtifactMetadata memory poison = ArtifactMetadata({
            deployment: POISON_RUN, chainId: 1, configHash: CONFIG_HASH, compatibilityHash: bytes32(uint256(0xBAD))
        });
        vm.writeFile(path, ArtifactMetadataFile.header(poison, "oracle"));

        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactCompatibilityHashMismatch.selector,
                string.concat(vm.projectRoot(), "/", path),
                cfg.compatibilityHash,
                poison.compatibilityHash
            )
        );
        RegistryFixture memory fixture = _fixture(1, agent, executor);
        fixture.artifactDeployment = POISON_RUN;
        fixture.protocolDeployment = POISON_RUN;
        harness.requireRegistryGovernance(cfg, _registryRaw(fixture));
        vm.removeDir(runDir, true);
    }

    function testRevert_requireProtocolArtifactCompatibility_rejectsForgedHeader() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");
        bytes32 expected = _compatibilityHash("unit", 1, agent, executor);
        bytes32 forged = bytes32(uint256(0xBAD));

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfigFile.RegistryCompatibilityHashMismatch.selector, expected, forged)
        );
        harness.requireProtocolArtifactCompatibility(_registryWithCompatibility(1, agent, executor, forged));
    }

    function test_requireProtocolArtifactCompatibility_acceptsCanonicalHeader() external view {
        address agent = address(0xA11);
        address executor = address(0xE11);

        harness.requireProtocolArtifactCompatibility(_registry(1, agent, executor));
    }

    function testRevert_requireProtocolBackboneLive_coreNotContract() external {
        address core = makeAddr("missingCore");

        vm.expectRevert(abi.encodeWithSelector(DeployConfigFile.RegistryCoreNotContract.selector, core));
        harness.requireProtocolBackboneLive(_backboneRegistry(core, address(harness)));
    }

    function testRevert_requireProtocolBackboneLive_factoryNotContract() external {
        address factory = makeAddr("missingFactory");

        vm.expectRevert(abi.encodeWithSelector(DeployConfigFile.RegistryFactoryNotContract.selector, factory));
        harness.requireProtocolBackboneLive(_backboneRegistry(address(harness), factory));
    }

    function test_requireProtocolBackboneLive_acceptsContracts() external view {
        harness.requireProtocolBackboneLive(_backboneRegistry(address(harness), address(harness)));
    }

    function testRevert_requireRegistryGovernance_internalConfigHashMismatch() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");
        bytes32 protocolHash = bytes32(uint256(0xBAD));

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfigFile.RegistryConfigHashMismatch.selector, CONFIG_HASH, protocolHash)
        );
        harness.requireRegistryGovernance(
            _config(agent, executor), _registry(1, 1, agent, executor, RUN, CONFIG_HASH, protocolHash)
        );
    }

    function testRevert_requireRegistryGovernance_internalChainIdMismatch() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");

        vm.expectRevert(
            abi.encodeWithSelector(DeployConfigFile.RegistryArtifactChainIdMismatch.selector, uint256(2), uint256(1))
        );
        harness.requireRegistryGovernance(
            _config(agent, executor), _registry(2, 1, agent, executor, RUN, CONFIG_HASH, CONFIG_HASH)
        );
    }

    function testRevert_requireRegistryGovernance_internalDeploymentMismatch() external {
        address agent = makeAddr("agent");
        address executor = makeAddr("executor");

        vm.expectRevert(abi.encodeWithSelector(DeployConfigFile.RegistryDeploymentMismatch.selector, RUN, "other"));
        harness.requireRegistryGovernance(
            _config(agent, executor), _registry(1, 1, agent, executor, "other", CONFIG_HASH, CONFIG_HASH)
        );
    }

    function _config(address agent, address executor) private pure returns (DeployConfig memory cfg) {
        cfg.network = "unit";
        cfg.chainId = 1;
        cfg.configHash = CONFIG_HASH;
        cfg.agent = agent;
        cfg.evmScriptExecutor = executor;
        cfg.circuitBreakerArtifact = "lido-lend";
        cfg.compatibilityHash = _compatibilityHash("unit", 1, agent, executor);
    }

    function _registry(uint256 chainId, address agent, address executor) private view returns (string memory) {
        return _registry(chainId, chainId, agent, executor, RUN, CONFIG_HASH, CONFIG_HASH);
    }

    function _registry(
        uint256 artifactChainId,
        uint256 chainId,
        address agent,
        address executor,
        string memory protocolDeployment,
        bytes32 artifactConfigHash,
        bytes32 protocolConfigHash
    ) private view returns (string memory) {
        RegistryFixture memory fixture = _fixture(chainId, agent, executor);
        fixture.artifactChainId = artifactChainId;
        fixture.protocolDeployment = protocolDeployment;
        fixture.artifactConfigHash = artifactConfigHash;
        fixture.protocolConfigHash = protocolConfigHash;
        return _registryRaw(fixture);
    }

    function _registryWithIdentity(uint256 chainId, address agent, address executor, string memory network)
        private
        view
        returns (string memory)
    {
        RegistryFixture memory fixture = _fixture(chainId, agent, executor);
        fixture.network = network;
        fixture.compatibilityHash = _compatibilityHash(network, chainId, agent, executor);
        return _registryRaw(fixture);
    }

    function _registryWithCompatibility(uint256 chainId, address agent, address executor, bytes32 compatibilityHash)
        private
        view
        returns (string memory)
    {
        RegistryFixture memory fixture = _fixture(chainId, agent, executor);
        fixture.compatibilityHash = compatibilityHash;
        return _registryRaw(fixture);
    }

    function _fixture(uint256 chainId, address agent, address executor)
        private
        pure
        returns (RegistryFixture memory fixture)
    {
        fixture = RegistryFixture({
            artifactChainId: chainId,
            protocolChainId: chainId,
            agent: agent,
            executor: executor,
            artifactDeployment: RUN,
            protocolDeployment: RUN,
            artifactConfigHash: CONFIG_HASH,
            protocolConfigHash: CONFIG_HASH,
            network: "unit",
            compatibilityHash: _compatibilityHash("unit", chainId, agent, executor)
        });
    }

    function _registryRaw(RegistryFixture memory fixture) private view returns (string memory) {
        return string.concat(
            "[artifact]\n",
            "deployment = \"",
            fixture.artifactDeployment,
            "\"\n",
            "chain_id = ",
            vm.toString(fixture.artifactChainId),
            "\n",
            "config_hash = \"",
            vm.toString(fixture.artifactConfigHash),
            "\"\ncompatibility_hash = \"",
            vm.toString(fixture.compatibilityHash),
            "\"\n",
            "[protocol]\n",
            "deployment = \"",
            fixture.protocolDeployment,
            "\"\nnetwork = \"",
            fixture.network,
            "\"\n",
            "chain_id = ",
            vm.toString(fixture.protocolChainId),
            "\nagent = \"",
            vm.toString(fixture.agent),
            "\"\nevm_script_executor = \"",
            vm.toString(fixture.executor),
            "\"\ncircuit_breaker_artifact = \"lido-lend\"\nconfig_hash = \"",
            vm.toString(fixture.protocolConfigHash),
            "\"\n"
        );
    }

    function _backboneRegistry(address core, address factory) private view returns (string memory) {
        return string.concat(
            "[protocol]\ncore = \"",
            vm.toString(core),
            "\"\nfactory = \"",
            vm.toString(factory),
            "\"\nirm_router = \"",
            vm.toString(address(harness)),
            "\"\n"
        );
    }

    function _compatibilityHash(string memory network, uint256 chainId, address agent, address executor)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(network, chainId, agent, executor, "lido-lend"));
    }

    function _configToml(bool exitBooks, string memory exitBookFields) private pure returns (string memory) {
        return string.concat(
            "network = \"unit\"\n",
            "chain_id = 1\n",
            "agent = \"0x0000000000000000000000000000000000000001\"\n",
            "evm_script_executor = \"0x0000000000000000000000000000000000000002\"\n",
            "circuit_breaker_artifact = \"lido-lend\"\n",
            "exit_books = ",
            exitBooks ? "true\n" : "false\n",
            exitBookFields
        );
    }
}
