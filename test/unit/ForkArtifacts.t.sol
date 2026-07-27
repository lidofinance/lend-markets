// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {ForkTest} from "../fork/helpers/ForkTest.sol";

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

contract ForkArtifactsTest is Test {
    bytes32 internal constant MARKET_ID = 0x1111111111111111111111111111111111111111111111111111111111111111;
    address internal constant CORE = address(0x1001);
    address internal constant CONTROLLER = address(0x2001);
    address internal constant KINK_IRM = address(0x3001);

    ForkArtifactsHarness internal h;

    function setUp() public {
        h = new ForkArtifactsHarness();
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
        assertEq(h.artifactAddr("irms/linear-kink.toml", "irm.address"), KINK_IRM, "irms/linear-kink");
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

    // ---
    // FIXTURE
    // ---

    /// @dev Write a minimal but structurally real run (protocol + one market + one IRM artifact) and bind it.
    ///      Each test owns its own run directory: forge runs a contract's test functions in parallel, and the
    ///      fixture lives on the real filesystem, so a shared directory would have tests clean up under each
    ///      other.
    function _bind(string memory tag) internal {
        _writeProtocol(tag, "mainnet");
        vm.createDir(string.concat(_runDir(tag), "/markets"), true);
        vm.writeFile(
            string.concat(_runDir(tag), "/markets/weth-wsteth.toml"),
            string.concat(
                "[market]\nname = \"weth-wsteth\"\nid = \"",
                vm.toString(MARKET_ID),
                "\"\ncontroller = \"",
                vm.toString(CONTROLLER),
                "\"\n"
            )
        );
        vm.createDir(string.concat(_runDir(tag), "/irms"), true);
        vm.writeFile(
            string.concat(_runDir(tag), "/irms/linear-kink.toml"),
            string.concat("[irm]\naddress = \"", vm.toString(KINK_IRM), "\"\n")
        );
        h.bindRun(_runName(tag));
    }

    function _writeProtocol(string memory tag, string memory network) internal {
        vm.createDir(_runDir(tag), true);
        vm.writeFile(
            string.concat(_runDir(tag), "/protocol.toml"),
            string.concat("[protocol]\nnetwork = \"", network, "\"\nchain_id = 1\ncore = \"", vm.toString(CORE), "\"\n")
        );
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
