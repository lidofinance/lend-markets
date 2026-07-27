// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CommonBase} from "forge-std/Base.sol";
import {console2} from "forge-std/Test.sol";

import {ArtifactMetadataFile} from "../../../script/lib/ArtifactMetadata.sol";

/// @notice Shared base for fork suites: a fork suite drives an ALREADY-DEPLOYED protocol on the fork and
///         deploys nothing. Every protocol address it needs comes from a deploy run's immutable artifacts
///         under `deployed/<ARTIFACTS_DIR>/` — the same tree `test/acceptance/` reads and the deploy scripts
///         write — so the fork suites need no composed registry and no preparation step of their own.
///
///         Two inputs, both required:
///           - `RPC_URL`       — the RPC to fork (any network);
///           - `ARTIFACTS_DIR` — the deploy run name, i.e. the `deployed/<ARTIFACTS_DIR>/` directory the run's
///             artifacts were written to (see `script/DEPLOYMENT.md`).
///         Optional:
///           - `FORK_BLOCK`    — pins a fixed block for replay (default: latest).
///
///         The run identifies its own network, so there is no network selector env var: `protocol.toml`
///         carries `chain_id` (asserted against the chain actually forked) and `network`, which resolves the
///         committed `script/config/<network>.toml` that `_ext` reads the `[external]` addresses from (tokens,
///         feeds, and other peripherals the deploy did not create).
///
///         A suite calls `_fork()` as the first line of `setUp`:
///
///             function setUp() public {
///                 _fork();
///                 wstEth = _ext("wstEth");
///                 core = _protocol("core");
///                 controller = _market("weth-wsteth", "controller");
///             }
///
///         `_fork()` reverts loudly (never skips) when: `RPC_URL` or `ARTIFACTS_DIR` is unset; the run has no
///         `protocol.toml`; the network config it names is missing; or the recorded `chain_id` does not match
///         the chain the fork actually landed on. Each accessor reverts on an artifact or key the run does not
///         define, naming it. `test/fork/` is the only directory that forks, so the unit / scenario /
///         invariant suites never touch an RPC.
abstract contract ForkTest is CommonBase {
    error ForkChainIdMismatch(uint256 expected, uint256 actual);

    /// @dev The deploy run directory (`deployed/<ARTIFACTS_DIR>`), resolved by `_bindRun`.
    string private _runDir;
    /// @dev The committed network config the run names, source of `[external]`. Resolved by `_bindRun`.
    string private _externalsPath;
    bool private _bound;

    /// @notice Create the fork from `RPC_URL` and bind to the deploy run named by `ARTIFACTS_DIR`, asserting
    ///         its recorded `chain_id` matches the chain actually forked. MUST be the first call in `setUp`,
    ///         before any accessor: a later `createSelectFork` would discard state read against the previous
    ///         fork.
    function _fork() internal {
        string memory url = vm.envOr("RPC_URL", string(""));
        require(bytes(url).length != 0, "ForkTest: RPC_URL is unset (see .env.example)");

        // Bind first: a missing or malformed run fails before spending any RPC time.
        _bindRun(vm.envOr("ARTIFACTS_DIR", string("")));

        // `FORK_BLOCK` unset (== 0) forks the latest block — the default, non-static canary run.
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pin);

        uint256 expected = _protocolUint("chain_id");
        if (block.chainid != expected) revert ForkChainIdMismatch(expected, block.chainid);

        // Log what we bound and forked, so a failure is reproducible via ARTIFACTS_DIR + FORK_BLOCK.
        console2.log("[fork] run:", _runDir);
        console2.log("[fork] chainId:", block.chainid);
        console2.log("[fork] block:", block.number);
    }

    /// @dev Resolve the deploy run `runName` to `deployed/<runName>/` plus the network config it names, so the
    ///      accessors below can read them. `internal` (not private) so a no-RPC harness can exercise the
    ///      artifact readers; suites always reach this through `_fork()`.
    function _bindRun(string memory runName) internal {
        string memory runDir = ArtifactMetadataFile.artifactsDir(runName);
        string memory protocol = _read(string.concat(runDir, "/protocol.toml"));

        // The run records its own network, so the externals config needs no env selector.
        string memory externalsPath =
            string.concat("script/config/", vm.parseTomlString(protocol, ".protocol.network"), ".toml");
        _requireFile(externalsPath); // fail here, not on the first `_ext` call

        _runDir = runDir;
        _externalsPath = externalsPath;
        _bound = true;
    }

    // ---
    // ACCESSORS
    // ---

    /// @notice Address at `[external].<key>` (e.g. `"wstEth"`) in the run's network config.
    function _ext(string memory key) internal view returns (address) {
        require(_bound, "ForkTest: _fork() not called");
        string memory toml = _read(_externalsPath);
        return vm.parseTomlAddress(toml, _key(toml, _externalsPath, string.concat("external.", key)));
    }

    /// @notice Address at `[protocol].<key>` (e.g. `"core"`, `"irm_router"`) in the run's `protocol.toml`.
    function _protocol(string memory key) internal view returns (address) {
        return _artifactAddr("protocol.toml", string.concat("protocol.", key));
    }

    /// @notice `uint256` at `[protocol].<key>` (e.g. `"chain_id"`) in the run's `protocol.toml`.
    function _protocolUint(string memory key) internal view returns (uint256) {
        return _artifactUint("protocol.toml", string.concat("protocol.", key));
    }

    /// @notice Address at `[market].<key>` (e.g. `"controller"`, `"vault"`, `"oracle"`) in the market artifact
    ///         `markets/<name>.toml`.
    function _market(string memory name, string memory key) internal view returns (address) {
        return _artifactAddr(_marketArtifact(name), string.concat("market.", key));
    }

    /// @notice The market id recorded at `[market].id` in `markets/<name>.toml`.
    function _marketId(string memory name) internal view returns (bytes32) {
        string memory relPath = _marketArtifact(name);
        string memory toml = _read(_artifactPath(relPath));
        return vm.parseTomlBytes32(toml, _key(toml, relPath, "market.id"));
    }

    /// @notice Address at dotted `key` in the run artifact at `relPath` (e.g. `("irms/linear-kink.toml",
    ///         "irm.address")`). The typed accessors above cover the common tables; this is the escape hatch
    ///         for the per-resource artifacts.
    function _artifactAddr(string memory relPath, string memory key) internal view returns (address) {
        string memory toml = _read(_artifactPath(relPath));
        return vm.parseTomlAddress(toml, _key(toml, relPath, key));
    }

    /// @notice `uint256` at dotted `key` in the run artifact at `relPath`. Same guard as `_artifactAddr`.
    function _artifactUint(string memory relPath, string memory key) internal view returns (uint256) {
        string memory toml = _read(_artifactPath(relPath));
        return vm.parseTomlUint(toml, _key(toml, relPath, key));
    }

    // ---
    // PRIVATE HELPERS
    // ---

    /// @dev `markets/<name>.toml`, the market artifact's path within the run directory.
    function _marketArtifact(string memory name) private pure returns (string memory) {
        return string.concat("markets/", name, ".toml");
    }

    /// @dev Absolute path of a run artifact, asserting the run is bound and the artifact exists.
    function _artifactPath(string memory relPath) private view returns (string memory path) {
        require(_bound, "ForkTest: _fork() not called");
        path = string.concat(_runDir, "/", relPath);
        require(vm.isFile(path), string.concat("ForkTest: run artifact not found: ", path));
    }

    /// @dev Revert when `path` is not a file. Loud on a half-written or wrong run.
    function _requireFile(string memory path) private view {
        require(vm.isFile(path), string.concat("ForkTest: file not found: ", path));
    }

    function _read(string memory path) private view returns (string memory) {
        _requireFile(path);
        return vm.readFile(path);
    }

    /// @dev The dotted parse path for `key`, asserting `toml` defines it. `source` names the file in the
    ///      revert message.
    function _key(string memory toml, string memory source, string memory key) private view returns (string memory k) {
        k = string.concat(".", key);
        require(vm.keyExistsToml(toml, k), string.concat("ForkTest: ", source, " is missing key '", key, "'"));
    }
}
