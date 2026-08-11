// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";
import {ForkTest} from "../fork/helpers/ForkTest.sol";
import {ForkStack} from "../fork/helpers/ForkStack.sol";

/// @dev Exposes {ForkTest}'s run binding and artifact readers so they can be exercised without creating an
///      RPC fork: everything except `_fork`'s `createSelectFork` + chain-id assertion is pure file IO.
contract ForkArtifactsHarness is ForkTest {
    function bindRun(string memory runName) external {
        _bindRun(runName);
    }

    function ext(string memory key) external view returns (address) {
        return _ext(key);
    }

    function protocolAddr(string memory key) external view returns (address) {
        return _protocol(key);
    }

    function protocolUint(string memory key) external view returns (uint256) {
        return _protocolUint(key);
    }

    function market(string memory name, string memory key) external view returns (address) {
        return _market(name, key);
    }

    function marketId(string memory name) external view returns (bytes32) {
        return _marketId(name);
    }

    function artifactAddr(string memory relPath, string memory key) external view returns (address) {
        return _artifactAddr(relPath, key);
    }
}

contract ForkStackRoleHarness is ForkStack {
    function bindRun(string memory runName) external {
        _bindRun(runName);
    }

    function marketForRole(string memory role) external returns (string memory) {
        return _marketForRole(role);
    }
}

contract ForkArtifactsTest is Test {
    bytes32 internal constant MARKET_ID = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes32 internal constant CONFIG_HASH = bytes32(uint256(0xCAFE));
    string internal constant CIRCUIT_BREAKER_ARTIFACT = "lido-lend";
    address internal constant CORE = address(0x1001);
    address internal constant CONTROLLER = address(0x2001);
    address internal constant ORACLE = address(0x3001);
    address internal constant AGENT = address(0xA11);
    address internal constant EXECUTOR = address(0xE11);

    ForkArtifactsHarness internal h;
    ForkStackRoleHarness internal roles;

    function setUp() public {
        h = new ForkArtifactsHarness();
        roles = new ForkStackRoleHarness();
    }

    // ---
    // BINDING
    // ---

    function testRevert_bind_emptyRunName() public {
        vm.expectRevert(abi.encodeWithSelector(ArtifactMetadataFile.InvalidArtifactsDir.selector, ""));
        h.bindRun("");
    }

    function testRevert_bind_runNameWithSeparator() public {
        vm.expectRevert(abi.encodeWithSelector(ArtifactMetadataFile.InvalidArtifactsDir.selector, "a/b"));
        h.bindRun("a/b");
    }

    function testRevert_bind_runWithoutProtocolArtifact() public {
        string memory tag = "no-protocol";
        vm.createDir(_runDir(tag), true);
        vm.expectRevert(bytes(string.concat("ForkTest: file not found: ", _runDir(tag), "/protocol.toml")));
        h.bindRun(_runName(tag));
        _cleanup(tag);
    }

    /// @dev The externals config is resolved from the run's own `network`, so an unknown network fails at bind
    ///      time rather than on the first `_ext` call.
    function testRevert_bind_unknownNetwork() public {
        string memory tag = "unknown-network";
        _writeProtocol(tag, "no-such-network");
        vm.expectRevert(bytes("ForkTest: file not found: script/config/no-such-network.toml"));
        h.bindRun(_runName(tag));
        _cleanup(tag);
    }

    function testRevert_bind_headerDeploymentDoesNotMatchRequestedRun() public {
        string memory tag = "header-deployment";
        ArtifactMetadata memory metadata = _metadata(tag);
        metadata.deployment = "another-run";
        _writeProtocol(tag, "mainnet", metadata, _runName(tag), 1, CONFIG_HASH);

        string memory path = string.concat(_runDir(tag), "/protocol.toml");
        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactDeploymentMismatch.selector, path, _runName(tag), metadata.deployment
            )
        );
        h.bindRun(_runName(tag));
        _cleanup(tag);
    }

    function testRevert_bind_protocolDeploymentDoesNotMatchHeader() public {
        string memory tag = "protocol-deployment";
        _writeProtocol(tag, "mainnet", _metadata(tag), "another-run", 1, CONFIG_HASH);

        vm.expectRevert(
            abi.encodeWithSelector(ForkTest.ProtocolDeploymentMismatch.selector, _runName(tag), "another-run")
        );
        h.bindRun(_runName(tag));
        _cleanup(tag);
    }

    function testRevert_bind_protocolHeaderChainDoesNotMatchProtocolSection() public {
        string memory tag = "header-chain";
        ArtifactMetadata memory metadata = _metadata(tag);
        metadata.chainId = 2;
        _writeProtocol(tag, "mainnet", metadata, _runName(tag), 1, CONFIG_HASH);

        string memory path = string.concat(_runDir(tag), "/protocol.toml");
        vm.expectRevert(
            abi.encodeWithSelector(ArtifactMetadataFile.ArtifactChainIdMismatch.selector, path, uint256(1), uint256(2))
        );
        h.bindRun(_runName(tag));
        _cleanup(tag);
    }

    function testRevert_bind_protocolHeaderConfigDoesNotMatchProtocolSection() public {
        string memory tag = "header-config";
        ArtifactMetadata memory metadata = _metadata(tag);
        metadata.configHash = bytes32(uint256(0xBAD));
        _writeProtocol(tag, "mainnet", metadata, _runName(tag), 1, CONFIG_HASH);

        string memory path = string.concat(_runDir(tag), "/protocol.toml");
        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactConfigHashMismatch.selector, path, CONFIG_HASH, metadata.configHash
            )
        );
        h.bindRun(_runName(tag));
        _cleanup(tag);
    }

    function testRevert_bind_protocolCompatibilityHashIsNotCanonical() public {
        string memory tag = "header-compatibility";
        ArtifactMetadata memory metadata = _metadata(tag);
        metadata.compatibilityHash = bytes32(uint256(0xBAD));
        _writeProtocol(tag, "mainnet", metadata, _runName(tag), 1, CONFIG_HASH);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployConfigFile.RegistryCompatibilityHashMismatch.selector,
                _compatibilityHash("mainnet", 1),
                metadata.compatibilityHash
            )
        );
        h.bindRun(_runName(tag));
        _cleanup(tag);
    }

    // ---
    // ACCESSORS
    // ---

    function test_ext_resolvesFromTheRunsNetworkConfig() public {
        string memory tag = "ext";
        _bind(tag);
        assertEq(h.ext("wstEth"), 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, "external.wstEth");
        _cleanup(tag);
    }

    function test_protocol_resolvesAddressAndUint() public {
        string memory tag = "protocol";
        _bind(tag);
        assertEq(h.protocolAddr("core"), CORE, "protocol.core");
        assertEq(h.protocolUint("chain_id"), 1, "protocol.chain_id");
        _cleanup(tag);
    }

    function test_market_resolvesAddressAndId() public {
        string memory tag = "market";
        _bind(tag);
        assertEq(h.market("weth-wsteth", "controller"), CONTROLLER, "market.controller");
        assertEq(h.marketId("weth-wsteth"), MARKET_ID, "market.id");
        _cleanup(tag);
    }

    /// @dev The escape hatch reaches the per-resource artifacts the typed accessors do not cover.
    function test_artifactAddr_resolvesPerResourceArtifact() public {
        string memory tag = "artifact";
        _bind(tag);
        assertEq(h.artifactAddr("oracles/weth-wsteth.toml", "oracle.address"), ORACLE, "oracles/weth-wsteth");
        _cleanup(tag);
    }

    // ---
    // ACCESSOR FAILURES
    // ---

    function testRevert_accessor_beforeBind() public {
        vm.expectRevert(bytes("ForkTest: _fork() not called"));
        h.protocolAddr("core");
    }

    function testRevert_accessor_missingKey() public {
        string memory tag = "missing-key";
        _bind(tag);
        vm.expectRevert(bytes("ForkTest: protocol.toml is missing key 'protocol.no_such_field'"));
        h.protocolAddr("no_such_field");
        _cleanup(tag);
    }

    function testRevert_ext_missingKey() public {
        string memory tag = "missing-ext";
        _bind(tag);
        vm.expectRevert(bytes("ForkTest: script/config/mainnet.toml is missing key 'external.noSuchToken'"));
        h.ext("noSuchToken");
        _cleanup(tag);
    }

    function testRevert_market_unrecordedMarket() public {
        string memory tag = "unrecorded-market";
        _bind(tag);
        vm.expectRevert(
            bytes(string.concat("ForkTest: run artifact not found: ", _runDir(tag), "/markets/no-such-market.toml"))
        );
        h.market("no-such-market", "controller");
        _cleanup(tag);
    }

    function testRevert_artifact_compatibilityMismatch() public {
        string memory tag = "artifact-compatibility";
        _bind(tag);
        ArtifactMetadata memory metadata = _metadata(tag);
        metadata.compatibilityHash = bytes32(uint256(0xBAD));
        string memory path = string.concat(_runDir(tag), "/oracles/weth-wsteth.toml");
        vm.writeFile(
            path,
            string.concat(
                ArtifactMetadataFile.header(metadata, "oracle"), "\n[oracle]\naddress = \"", vm.toString(ORACLE), "\"\n"
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactCompatibilityHashMismatch.selector,
                path,
                _compatibilityHash("mainnet", 1),
                metadata.compatibilityHash
            )
        );
        h.artifactAddr("oracles/weth-wsteth.toml", "oracle.address");
        _cleanup(tag);
    }

    function testRevert_marketForRole_missingRoleField() public {
        string memory tag = "missing-role-field";
        _writeProtocol(tag, "mainnet");
        string memory dir = _rolesDir(tag);
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/market.toml");
        vm.writeFile(
            path,
            string.concat(
                ArtifactMetadataFile.header(_metadata(tag), "market-deployment"), "\n[market]\nname = \"market\"\n"
            )
        );
        roles.bindRun(_runName(tag));

        vm.expectRevert(
            bytes(string.concat("ForkStack: market artifact is missing market.role: ", vm.projectRoot(), "/", path))
        );
        roles.marketForRole("weth-wsteth");
        _cleanup(tag);
    }

    function testRevert_marketForRole_duplicateRole() public {
        string memory tag = "duplicate-role";
        _writeProtocol(tag, "mainnet");
        string memory dir = _rolesDir(tag);
        vm.createDir(dir, true);
        _writeRoleMarket(tag, "first", "weth-wsteth");
        _writeRoleMarket(tag, "second", "weth-wsteth");
        roles.bindRun(_runName(tag));

        vm.expectRevert(bytes("ForkStack: multiple markets have role 'weth-wsteth'"));
        roles.marketForRole("weth-wsteth");
        _cleanup(tag);
    }

    function test_marketForRole_returnsUniqueMatch() public {
        string memory tag = "unique-role";
        _writeProtocol(tag, "mainnet");
        string memory dir = _rolesDir(tag);
        vm.createDir(dir, true);
        _writeRoleMarket(tag, "eth-market", "weth-wsteth");
        _writeRoleMarket(tag, "treasury-market", "usdy-usdt");
        roles.bindRun(_runName(tag));

        assertEq(roles.marketForRole("weth-wsteth"), "eth-market");
        _cleanup(tag);
    }

    function testRevert_marketForRole_compatibilityMismatch() public {
        string memory tag = "role-compatibility";
        _writeProtocol(tag, "mainnet");
        string memory dir = _rolesDir(tag);
        vm.createDir(dir, true);
        ArtifactMetadata memory metadata = _metadata(tag);
        metadata.compatibilityHash = bytes32(uint256(0xBAD));
        string memory path = string.concat(dir, "/market.toml");
        vm.writeFile(
            path,
            string.concat(
                ArtifactMetadataFile.header(metadata, "market-deployment"),
                "\n[market]\nname = \"market\"\nrole = \"weth-wsteth\"\n"
            )
        );
        roles.bindRun(_runName(tag));

        string memory absolutePath = string.concat(vm.projectRoot(), "/", path);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactCompatibilityHashMismatch.selector,
                absolutePath,
                _compatibilityHash("mainnet", 1),
                metadata.compatibilityHash
            )
        );
        roles.marketForRole("weth-wsteth");
        _cleanup(tag);
    }

    // ---
    // FIXTURE
    // ---

    /// @dev Write a minimal but structurally real run (protocol + one market + one oracle artifact) and bind it.
    ///      Each test owns its own run directory: forge runs a contract's test functions in parallel, and the
    ///      fixture lives on the real filesystem, so a shared directory would have tests clean up under each
    ///      other.
    function _bind(string memory tag) internal {
        _writeProtocol(tag, "mainnet");
        vm.createDir(string.concat(_runDir(tag), "/markets"), true);
        vm.writeFile(
            string.concat(_runDir(tag), "/markets/weth-wsteth.toml"),
            string.concat(
                ArtifactMetadataFile.header(_metadata(tag), "market-deployment"),
                "\n[market]\nname = \"weth-wsteth\"\nid = \"",
                vm.toString(MARKET_ID),
                "\"\ncontroller = \"",
                vm.toString(CONTROLLER),
                "\"\n"
            )
        );
        vm.createDir(string.concat(_runDir(tag), "/oracles"), true);
        vm.writeFile(
            string.concat(_runDir(tag), "/oracles/weth-wsteth.toml"),
            string.concat(
                ArtifactMetadataFile.header(_metadata(tag), "oracle"),
                "\n[oracle]\naddress = \"",
                vm.toString(ORACLE),
                "\"\n"
            )
        );
        h.bindRun(_runName(tag));
    }

    function _writeProtocol(string memory tag, string memory network) internal {
        ArtifactMetadata memory metadata = _metadata(tag);
        metadata.compatibilityHash = _compatibilityHash(network, 1);
        _writeProtocol(tag, network, metadata, _runName(tag), 1, CONFIG_HASH);
    }

    function _writeProtocol(
        string memory tag,
        string memory network,
        ArtifactMetadata memory metadata,
        string memory protocolDeployment,
        uint256 protocolChainId,
        bytes32 protocolConfigHash
    ) internal {
        vm.createDir(_runDir(tag), true);
        vm.writeFile(
            string.concat(_runDir(tag), "/protocol.toml"),
            string.concat(
                ArtifactMetadataFile.header(metadata, "protocol-deployment"),
                "\n[protocol]\ndeployment = \"",
                protocolDeployment,
                "\"\nnetwork = \"",
                network,
                "\"\nchain_id = ",
                vm.toString(protocolChainId),
                "\nconfig_hash = \"",
                vm.toString(protocolConfigHash),
                "\"\nagent = \"",
                vm.toString(AGENT),
                "\"\nevm_script_executor = \"",
                vm.toString(EXECUTOR),
                "\"\ncircuit_breaker_artifact = \"",
                CIRCUIT_BREAKER_ARTIFACT,
                "\"\ncore = \"",
                vm.toString(CORE),
                "\"\n"
            )
        );
    }

    function _rolesDir(string memory tag) internal pure returns (string memory) {
        return string.concat(_runDir(tag), "/markets");
    }

    function _writeRoleMarket(string memory tag, string memory name, string memory role) internal {
        vm.writeFile(
            string.concat(_rolesDir(tag), "/", name, ".toml"),
            string.concat(
                ArtifactMetadataFile.header(_metadata(tag), "market-deployment"),
                "\n[market]\nname = \"",
                name,
                "\"\nrole = \"",
                role,
                "\"\n"
            )
        );
    }

    function _metadata(string memory tag) internal pure returns (ArtifactMetadata memory) {
        return ArtifactMetadata({
            deployment: _runName(tag),
            chainId: 1,
            configHash: CONFIG_HASH,
            compatibilityHash: _compatibilityHash("mainnet", 1)
        });
    }

    function _compatibilityHash(string memory network, uint256 chainId) internal pure returns (bytes32) {
        return DeployConfigFile.canonicalCompatibilityHash(network, chainId, AGENT, EXECUTOR, CIRCUIT_BREAKER_ARTIFACT);
    }

    function _runName(string memory tag) internal pure returns (string memory) {
        return string.concat("fork-artifacts-unit-", tag);
    }

    function _runDir(string memory tag) internal pure returns (string memory) {
        return ArtifactMetadataFile.artifactsDir(_runName(tag));
    }

    function _cleanup(string memory tag) internal {
        vm.removeDir(_runDir(tag), true);
    }
}
