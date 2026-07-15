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
///         A suite calls `_fork()` as the first line of `setUp` and early-returns when it is false:
///
///             function setUp() public {
///                 if (!_fork()) return;
///                 wstEth = _addr("external.wstEth");   // from the DEPLOYMENT JSON
///                 // ... deploy / drive the protocol on the fork ...
///             }
///
///         `_fork()` self-skips (green, no failure) when `ETH_RPC_URL` or `DEPLOYMENT` is unset or the RPC is
///         unreachable — so a plain `forge test` with nothing set stays green. Fork is taken at the **latest**
///         block by default (these are drift canaries — see ADR 033); set `FORK_BLOCK` to pin a fixed block and
///         replay a failure at the block `_fork()` logs. `test/fork/` is the only directory that forks, so the
///         unit / scenario / invariant suites never touch an RPC.
///
///         Addresses are looked up by dotted key against the map (`_addr("external.wstEth")`,
///         `_addr("protocol.core")`). A suite whose map lacks a key it needs should skip: guard with
///         `_hasAddr(key)` (e.g. the USDY market skips against a map with no USDY entry).
abstract contract ForkTest is CommonBase {
    /// @dev Cached contents of the `DEPLOYMENT` address-map JSON, loaded by `_fork()`.
    string private _registry;
    bool private _registryLoaded;

    /// @notice Create the fork from `ETH_RPC_URL` and load the `DEPLOYMENT` address map. Returns true when the
    ///         fork is live; returns false and marks the suite skipped when either env var is unset or the RPC
    ///         is unreachable. MUST be the first call in `setUp`, before any deployment or `_addr` lookup: a
    ///         later `createSelectFork` would discard state deployed against the previous fork.
    function _fork() internal returns (bool) {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        string memory deployment = vm.envOr("DEPLOYMENT", string(""));
        if (bytes(url).length == 0 || bytes(deployment).length == 0) {
            vm.skip(true);
            return false;
        }

        // `FORK_BLOCK` unset (== 0) forks the latest block — the default, non-static canary run.
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        // The RPC may be unreachable — skip rather than fail the whole run.
        if (pin == 0) {
            try vm.createSelectFork(url) {}
            catch {
                vm.skip(true);
                return false;
            }
        } else {
            try vm.createSelectFork(url, pin) {}
            catch {
                vm.skip(true);
                return false;
            }
        }

        _loadRegistry(deployment);
        // Log what we actually forked (chain id + block), so a failure is reproducible via FORK_BLOCK — without
        // the suite ever naming a network.
        console2.log("[fork] chainId:", block.chainid);
        console2.log("[fork] block:", block.number);
        return true;
    }

    /// @dev Read the address-map JSON at `path` if present; a missing/unreadable file loads empty (suites that
    ///      need an address from it then skip via `_hasAddr`). `fs_permissions` in foundry.toml must grant read
    ///      access to the path. `internal` (not `private`) so a no-RPC test harness can exercise the loader.
    function _loadRegistry(string memory path) internal {
        try vm.readFile(path) returns (string memory json) {
            _registry = json;
        } catch {
            _registry = "";
        }
        _registryLoaded = true;
    }

    /// @notice True if the loaded address map defines `key` (dotted, e.g. `"external.wstEth"`).
    function _hasAddr(string memory key) internal view returns (bool) {
        return bytes(_registry).length != 0 && vm.keyExistsJson(_registry, string.concat(".", key));
    }

    /// @notice Address at dotted `key` in the loaded map. Reverts if absent — guard with `_hasAddr` and
    ///         `vm.skip` when a suite may run against a map that lacks the key.
    function _addr(string memory key) internal view returns (address) {
        require(_registryLoaded, "ForkTest: _fork() not called");
        require(_hasAddr(key), string.concat("ForkTest: address map missing key '", key, "'"));
        return vm.parseJsonAddress(_registry, string.concat(".", key));
    }
}
