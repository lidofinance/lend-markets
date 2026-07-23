// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ForkTest} from "../fork/helpers/ForkTest.sol";

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

    function validateNetworkChainId() external view {
        _validateNetworkChainId();
    }

    function validateRegistryChainId() external view {
        _validateRegistryChainId();
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

    function testRevert_deployed_requiresRegistry() public {
        ForkRegistryHarness h2 = new ForkRegistryHarness();
        vm.expectRevert(bytes("ForkTest: FORK_REGISTRY is required for deployed addresses"));
        h2.deployed("protocol.core");
    }

    function testRevert_networkChainIdMismatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(ForkTest.ForkChainIdMismatch.selector, "network config", 1, block.chainid)
        );
        h.validateNetworkChainId();
    }

    function test_networkChainIdMatch() public {
        vm.chainId(1);
        h.validateNetworkChainId();
    }

    function testRevert_registryChainIdMismatch() public {
        string memory path = "deployed/fork-registry-unit-chain.toml";
        vm.writeFile(path, "[artifact]\nchain_id = 1\n");
        h.loadRegistry(path);
        vm.removeFile(path);

        vm.expectRevert(
            abi.encodeWithSelector(ForkTest.ForkChainIdMismatch.selector, "fork registry artifact", 1, block.chainid)
        );
        h.validateRegistryChainId();
    }

    function testRevert_registryConflictingChainIds() public {
        string memory path = "deployed/fork-registry-unit-conflicting-chain.toml";
        vm.writeFile(path, "[artifact]\nchain_id = 1\n\n[protocol]\nchain_id = 11155111\n");
        h.loadRegistry(path);
        vm.removeFile(path);
        vm.chainId(1);

        vm.expectRevert(abi.encodeWithSelector(ForkTest.ForkRegistryChainIdConflict.selector, 1, 11155111));
        h.validateRegistryChainId();
    }

    function test_registryProtocolChainIdFallbackMatches() public {
        string memory path = "deployed/fork-registry-unit-protocol-chain.toml";
        vm.writeFile(path, "[protocol]\nchain_id = 1\n");
        h.loadRegistry(path);
        vm.removeFile(path);
        vm.chainId(1);

        h.validateRegistryChainId();
    }
}
