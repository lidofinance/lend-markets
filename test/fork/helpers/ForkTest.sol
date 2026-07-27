// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CommonBase} from "forge-std/Base.sol";
import {console2} from "forge-std/Test.sol";

import {ArtifactMetadataFile} from "../../../script/lib/ArtifactMetadata.sol";

/// @notice Fork acquisition and artifact access for suites that drive an already-deployed protocol.
/// @dev `RPC_URL` is the node to fork, `ARTIFACTS_DIR` the deploy run under `deployed/`, and the optional
///      `FORK_BLOCK` pins a block. The run's `protocol.toml` carries its own `chain_id`, asserted against the
///      forked chain, and `network`, which resolves the config `_ext` reads. Missing or inconsistent inputs
///      revert; nothing skips.
abstract contract ForkTest is CommonBase {
    error ForkChainIdMismatch(uint256 expected, uint256 actual);

    string private _runDir;
    /// @dev The network config the run names, source of `[external]`.
    string private _externalsPath;
    bool private _bound;

    /// @notice Creates the fork and binds the deploy run named by `ARTIFACTS_DIR`.
    /// @dev Must be the first call in `setUp`: a later `createSelectFork` discards state read against the
    ///      previous fork.
    function _fork() internal {
        string memory url = vm.envOr("RPC_URL", string(""));
        require(bytes(url).length != 0, "ForkTest: RPC_URL is unset (see .env.example)");

        // Binding first fails an absent or malformed run before any RPC round-trip.
        _bindRun(vm.envOr("ARTIFACTS_DIR", string("")));

        // Zero selects the latest block.
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pin);

        uint256 expected = _protocolUint("chain_id");
        if (block.chainid != expected) revert ForkChainIdMismatch(expected, block.chainid);

        // Recorded so a failure is reproducible from `ARTIFACTS_DIR` and `FORK_BLOCK`.
        console2.log("[fork] run:", _runDir);
        console2.log("[fork] chainId:", block.chainid);
        console2.log("[fork] block:", block.number);
    }

    /// @dev `internal` rather than private so a harness can exercise the readers without an RPC. Suites reach
    ///      it through `_fork`.
    function _bindRun(string memory runName) internal {
        string memory runDir = ArtifactMetadataFile.artifactsDir(runName);
        string memory protocol = _read(string.concat(runDir, "/protocol.toml"));

        string memory externalsPath =
            string.concat("script/config/", vm.parseTomlString(protocol, ".protocol.network"), ".toml");
        _requireFile(externalsPath); // bind-time error, not a first-`_ext` error

        _runDir = runDir;
        _externalsPath = externalsPath;
        _bound = true;
    }

    // ---
    // ACCESSORS
    // ---

    /// @notice Address at `[external].<key>` in the run's network config.
    function _ext(string memory key) internal view returns (address) {
        require(_bound, "ForkTest: _fork() not called");
        string memory toml = _read(_externalsPath);
        return vm.parseTomlAddress(toml, _key(toml, _externalsPath, string.concat("external.", key)));
    }

    /// @notice Address at `[protocol].<key>` in the run's `protocol.toml`.
    function _protocol(string memory key) internal view returns (address) {
        return _artifactAddr("protocol.toml", string.concat("protocol.", key));
    }

    /// @notice `uint256` at `[protocol].<key>` in the run's `protocol.toml`.
    function _protocolUint(string memory key) internal view returns (uint256) {
        return _artifactUint("protocol.toml", string.concat("protocol.", key));
    }

    /// @notice Address at `[market].<key>` in `markets/<name>.toml`.
    function _market(string memory name, string memory key) internal view returns (address) {
        return _artifactAddr(_marketArtifact(name), string.concat("market.", key));
    }

    /// @notice The market id recorded in `markets/<name>.toml`.
    function _marketId(string memory name) internal view returns (bytes32) {
        string memory relPath = _marketArtifact(name);
        string memory toml = _read(_artifactPath(relPath));
        return vm.parseTomlBytes32(toml, _key(toml, relPath, "market.id"));
    }

    /// @notice Address at dotted `key` in the run artifact at `relPath`, for the per-resource artifacts the
    ///         typed accessors do not cover.
    function _artifactAddr(string memory relPath, string memory key) internal view returns (address) {
        string memory toml = _read(_artifactPath(relPath));
        return vm.parseTomlAddress(toml, _key(toml, relPath, key));
    }

    /// @notice `uint256` at dotted `key` in the run artifact at `relPath`.
    function _artifactUint(string memory relPath, string memory key) internal view returns (uint256) {
        string memory toml = _read(_artifactPath(relPath));
        return vm.parseTomlUint(toml, _key(toml, relPath, key));
    }

    // ---
    // PRIVATE HELPERS
    // ---

    function _marketArtifact(string memory name) private pure returns (string memory) {
        return string.concat("markets/", name, ".toml");
    }

    function _artifactPath(string memory relPath) private view returns (string memory path) {
        require(_bound, "ForkTest: _fork() not called");
        path = string.concat(_runDir, "/", relPath);
        require(vm.isFile(path), string.concat("ForkTest: run artifact not found: ", path));
    }

    function _requireFile(string memory path) private view {
        require(vm.isFile(path), string.concat("ForkTest: file not found: ", path));
    }

    function _read(string memory path) private view returns (string memory) {
        _requireFile(path);
        return vm.readFile(path);
    }

    /// @dev The dotted parse path for `key`, asserting `toml` defines it.
    function _key(string memory toml, string memory source, string memory key) private view returns (string memory k) {
        k = string.concat(".", key);
        require(vm.keyExistsToml(toml, k), string.concat("ForkTest: ", source, " is missing key '", key, "'"));
    }
}
