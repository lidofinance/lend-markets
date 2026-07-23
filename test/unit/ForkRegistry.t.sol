// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ForkTest} from "../fork/helpers/ForkTest.sol";
import {ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";

/// @dev Exercises fork artifact readers without creating an RPC fork.
contract ForkRegistryHarness is ForkTest {
    function loadExternals(string memory path) external {
        _loadExternals(path);
    }

    function loadRegistry(string memory path) external {
        _loadRegistry(path);
    }

    function ext(string memory key) external view returns (address) {
        return _ext(key);
    }

    function deployed(string memory key) external view returns (address) {
        return _deployed(key);
    }

    function validateRegistry(string memory toml, uint256 chainId) external view {
        ArtifactMetadataFile.requireKindChain(toml, "protocol-registry", chainId);
    }
}

contract ForkRegistryTest is Test {
    ForkRegistryHarness internal h;

    function setUp() public {
        h = new ForkRegistryHarness();
        h.loadExternals("script/config/mainnet.toml");
    }

    function test_externals_presentKeyResolves() public view {
        assertTrue(h.ext("wstEth") != address(0), "present key resolves");
    }

    function testRevert_externals_missingFileReverts() public {
        ForkRegistryHarness h2 = new ForkRegistryHarness();
        vm.expectRevert(bytes("ForkTest: network config not found: script/config/missing.toml"));
        h2.loadExternals("script/config/missing.toml");
    }

    function test_registry_generatedArtifactResolves() public {
        string memory path = "deployed/fork-registry-unit.toml";
        vm.writeFile(
            path,
            "[artifact]\nkind = \"protocol-registry\"\ndeployment = \"unit\"\nchain_id = 1\n\n[protocol]\ncore = \"0x0000000000000000000000000000000000001001\"\n"
        );
        h.loadRegistry(path);
        vm.removeFile(path);
        assertEq(h.deployed("protocol.core"), address(0x1001), "protocol.core");
    }

    function testRevert_registry_missingKeyReverts() public {
        string memory path = "deployed/fork-registry-unit-missing.toml";
        vm.writeFile(path, "[artifact]\nchain_id = 1\n");
        h.loadRegistry(path);
        vm.removeFile(path);
        vm.expectRevert(bytes("ForkTest: registry missing key 'protocol.core'"));
        h.deployed("protocol.core");
    }

    function testRevert_registryMetadata_wrongKindReverts() public {
        string memory registry = "[artifact]\nkind = \"activation-plan\"\nchain_id = 1\n";
        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactKindMismatch.selector, "protocol-registry", "activation-plan"
            )
        );
        h.validateRegistry(registry, 1);
    }

    function testRevert_registryMetadata_wrongChainReverts() public {
        string memory registry = "[artifact]\nkind = \"protocol-registry\"\nchain_id = 11155111\n";
        vm.expectRevert(abi.encodeWithSelector(ArtifactMetadataFile.ArtifactChainIdMismatch.selector, 1, 11155111));
        h.validateRegistry(registry, 1);
    }
}
