// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ForkTest} from "../fork/helpers/ForkTest.sol";

/// @dev Exercises `ForkTest`'s address-map loader and accessor WITHOUT a fork (`readFile`/`parseJson` need no
///      RPC), using the committed mainnet map as sample input. This is the ONLY no-RPC coverage of the map
///      machinery: offline, `_fork()` reverts at the missing-`ETH_RPC_URL` check *before* it loads a map, so
///      `_loadRegistry`/`_addr` would otherwise run only on a real fork. It asserts mechanism (dotted-key
///      resolution, missing-file and absent-key reverts) using only keys that are permanently present or
///      absent regardless of deploy state — never address VALUES, which live only in the JSON.
contract ForkRegistryHarness is ForkTest {
    function load(string memory path) external {
        _loadRegistry(path);
    }

    function addr(string memory key) external view returns (address) {
        return _addr(key);
    }
}

contract ForkRegistryTest is Test {
    ForkRegistryHarness internal h;
    string internal constant MAP = "deployments/deployed-mainnet.json";

    function setUp() public {
        h = new ForkRegistryHarness();
        h.load(MAP);
    }

    /// @dev A present dotted key resolves to a (non-zero) address parsed from the map. `external.wstEth` is
    ///      the core collateral — permanently present in the mainnet map.
    function test_registry_presentKeyResolves() public view {
        assertTrue(h.addr("external.wstEth") != address(0), "present key resolves to an address");
    }

    /// @dev A missing map file reverts at load — a bad `DEPLOYMENT` path fails the suite instead of exposing
    ///      an empty map.
    function testRevert_registry_missingFileReverts() public {
        ForkRegistryHarness h2 = new ForkRegistryHarness();
        vm.expectRevert(bytes("ForkTest: DEPLOYMENT file not found: deployments/does-not-exist.json"));
        h2.load("deployments/does-not-exist.json");
    }

    /// @dev `_addr` on an absent key reverts — including under a section — using names that never exist, so
    ///      the assertion is stable across deploys (the `protocol` section fills in over time).
    function testRevert_registry_addrAbsentKeyReverts() public {
        vm.expectRevert(bytes("ForkTest: address map missing key 'external.doesNotExist'"));
        h.addr("external.doesNotExist");
        vm.expectRevert(bytes("ForkTest: address map missing key 'protocol.doesNotExist'"));
        h.addr("protocol.doesNotExist");
    }
}
