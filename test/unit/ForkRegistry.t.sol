// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ForkTest} from "../fork/helpers/ForkTest.sol";

/// @dev Exercises `ForkTest`'s address-map loader and accessors WITHOUT a fork (`readFile`/`parseJson` need no
///      RPC), using the committed mainnet map as sample input. This is the ONLY no-RPC coverage of the map
///      machinery: offline, `_fork()` skips at the missing-`ETH_RPC_URL` check *before* it loads a map, so
///      `_loadRegistry`/`_hasAddr`/`_addr` would otherwise run only on a real fork. It asserts mechanism
///      (dotted-key resolution, present/absent, missing-file tolerance) using only keys that are permanently
///      present or absent regardless of deploy state — never address VALUES, which live only in the JSON.
contract ForkRegistryHarness is ForkTest {
    function load(string memory path) external {
        _loadRegistry(path);
    }

    function addr(string memory key) external view returns (address) {
        return _addr(key);
    }

    function has(string memory key) external view returns (bool) {
        return _hasAddr(key);
    }
}

contract ForkRegistryTest is Test {
    ForkRegistryHarness internal h;
    string internal constant MAP = "deployments/deployed-mainnet.json";

    function setUp() public {
        h = new ForkRegistryHarness();
        h.load(MAP);
    }

    /// @dev A present dotted key reports true and resolves to a (non-zero) address parsed from the map.
    ///      `external.wstEth` is the core collateral — permanently present in the mainnet map.
    function test_registry_presentKeyResolves() public view {
        assertTrue(h.has("external.wstEth"), "present key reads true");
        assertTrue(h.addr("external.wstEth") != address(0), "present key resolves to an address");
    }

    /// @dev Absent keys report false — including one under a section — using names that never exist, so the
    ///      assertion is stable across deploys (the `protocol` section fills in over time).
    function test_registry_absentKeyReadsFalse() public view {
        assertFalse(h.has("external.doesNotExist"), "absent key reads false");
        assertFalse(h.has("protocol.doesNotExist"), "absent key under a section reads false");
    }

    /// @dev A missing/unreadable map file loads empty rather than reverting, so suites self-skip on it.
    function test_registry_missingFileLoadsEmpty() public {
        ForkRegistryHarness h2 = new ForkRegistryHarness();
        h2.load("deployments/does-not-exist.json");
        assertFalse(h2.has("external.wstEth"), "missing map file exposes no keys");
    }

    /// @dev `_addr` on an absent key reverts (callers must guard with `_hasAddr` when the key may be absent).
    function testRevert_registry_addrAbsentKeyReverts() public {
        vm.expectRevert();
        h.addr("external.doesNotExist");
    }
}
