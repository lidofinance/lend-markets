// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CommonBase} from "forge-std/Base.sol";
import {console2} from "forge-std/Test.sol";

/// @notice Shared base for fork test suites. The suites are **network-blind**: they need exactly two inputs and
///         do not know or care which chain they run against —
///           - `ETH_RPC_URL`  — the RPC to fork (any network);
///           - `DEPLOYMENT`   — path to a JSON address map for that network (see `deployments/`).
///         There are no per-network env vars, no `[rpc_endpoints]` aliases, and no addresses in Solidity — every
///         address a suite uses is read from the `DEPLOYMENT` JSON at runtime. Pointing the tests at a new
///         network is therefore just two env vars plus a JSON file; nothing here changes.
///
///         A suite calls `_fork()` as the first line of `setUp`:
///
///             function setUp() public {
///                 _fork();
///                 wstEth = _addr("external.wstEth");   // from the DEPLOYMENT JSON
///                 // ... deploy / drive the protocol on the fork ...
///             }
///
///         The fork setup is mandatory: `_fork()` reverts when `ETH_RPC_URL` or `DEPLOYMENT` is unset, when the
///         RPC is unreachable, or when the map file is missing, and `_addr` reverts on a key the map does not
///         define — a fork suite runs or it fails, it never skips. Fork is taken at the **latest** block by
///         default (these are drift canaries — see ADR 033); set `FORK_BLOCK` to pin a fixed block and replay
///         a failure at the block `_fork()` logs. `test/fork/` is the only directory that forks, so the
///         unit / scenario / invariant suites never touch an RPC.
abstract contract ForkTest is CommonBase {
    /// @dev Cached contents of the `DEPLOYMENT` address-map JSON, loaded by `_fork()`.
    string private _registry;
    bool private _registryLoaded;

    /// @notice Create the fork from `ETH_RPC_URL` and load the `DEPLOYMENT` address map. Reverts when either
    ///         env var is unset, the RPC is unreachable, or the map file is missing. MUST be the first call in
    ///         `setUp`, before any deployment or `_addr` lookup: a later `createSelectFork` would discard state
    ///         deployed against the previous fork.
    function _fork() internal {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        string memory deployment = vm.envOr("DEPLOYMENT", string(""));
        require(bytes(url).length != 0, "ForkTest: ETH_RPC_URL is unset (see .env.example)");
        require(bytes(deployment).length != 0, "ForkTest: DEPLOYMENT is unset (see .env.example)");

        // `FORK_BLOCK` unset (== 0) forks the latest block — the default, non-static canary run.
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pin);

        _loadRegistry(deployment);
        // Log what we actually forked (chain id + block), so a failure is reproducible via FORK_BLOCK — without
        // the suite ever naming a network.
        console2.log("[fork] chainId:", block.chainid);
        console2.log("[fork] block:", block.number);
    }

    /// @dev Load the address-map JSON at `path`; reverts when the file is missing. `fs_permissions` in
    ///      foundry.toml must grant read access to the path. `internal` (not `private`) so a no-RPC test
    ///      harness can exercise the loader.
    function _loadRegistry(string memory path) internal {
        require(vm.isFile(path), string.concat("ForkTest: DEPLOYMENT file not found: ", path));
        _registry = vm.readFile(path);
        _registryLoaded = true;
    }

    /// @notice Address at dotted `key` (e.g. `"external.wstEth"`) in the loaded map. Reverts when the map does
    ///         not define `key`.
    function _addr(string memory key) internal view returns (address) {
        require(_registryLoaded, "ForkTest: _fork() not called");
        require(
            vm.keyExistsJson(_registry, string.concat(".", key)),
            string.concat("ForkTest: address map missing key '", key, "'")
        );
        return vm.parseJsonAddress(_registry, string.concat(".", key));
    }
}
