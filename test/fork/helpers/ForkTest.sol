// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CommonBase} from "forge-std/Base.sol";
import {console2} from "forge-std/Test.sol";
import {ArtifactMetadataFile} from "../../../script/lib/ArtifactMetadata.sol";

/// @notice Shared base for fork suites. `NETWORK` selects a committed network config while `FORK_REGISTRY`
///         selects one concrete generated protocol registry; neither is inferred from a mutable "latest" alias.
abstract contract ForkTest is CommonBase {
    string private _externals;
    bool private _externalsLoaded;
    string private _registry;
    bool private _registryLoaded;

    function _fork() internal {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        string memory registryPath = vm.envOr("FORK_REGISTRY", string(""));
        require(bytes(url).length != 0, "ForkTest: ETH_RPC_URL is unset (see .env.example)");
        require(bytes(registryPath).length != 0, "ForkTest: FORK_REGISTRY is unset (see .env.example)");

        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pin);

        _loadExternals(_networkConfigPath());
        _loadRegistry(registryPath);
        _requireRegistryMetadata();
        console2.log("[fork] network:", _network());
        console2.log("[fork] chainId:", block.chainid);
        console2.log("[fork] block:", block.number);
    }

    function _network() internal view returns (string memory) {
        return vm.envOr("NETWORK", string("mainnet"));
    }

    function _networkConfigPath() internal view returns (string memory) {
        return string.concat("script/config/", _network(), ".toml");
    }

    function _loadExternals(string memory path) internal {
        require(vm.isFile(path), string.concat("ForkTest: network config not found: ", path));
        _externals = vm.readFile(path);
        _externalsLoaded = true;
    }

    function _loadRegistry(string memory path) internal {
        require(vm.isFile(path), string.concat("ForkTest: registry not found: ", path));
        _registry = vm.readFile(path);
        _registryLoaded = true;
    }

    function _ext(string memory key) internal view returns (address) {
        require(_externalsLoaded, "ForkTest: _fork() not called");
        require(
            vm.keyExistsToml(_externals, string.concat(".external.", key)),
            string.concat("ForkTest: externals map missing key '", key, "'")
        );
        return vm.parseTomlAddress(_externals, string.concat(".external.", key));
    }

    /// @dev Transitional compatibility for fresh-on-fork suites. New read-only suites use `_ext` directly.
    function _addr(string memory legacyKey) internal view returns (address) {
        bytes32 key = keccak256(bytes(legacyKey));
        if (key == keccak256("external.weth")) return _ext("weth");
        if (key == keccak256("external.stEth")) return _ext("stEth");
        if (key == keccak256("external.wstEth")) return _ext("wstEth");
        if (key == keccak256("external.usdy")) return _ext("usdy");
        if (key == keccak256("external.usdt")) return _ext("usdt");
        if (key == keccak256("external.ondoOracle")) return _ext("ondoOracle");
        if (key == keccak256("external.usdtUsdFeed")) return _ext("usdtUsdFeed");
        if (key == keccak256("external.usdyBlocklist")) return _ext("usdyBlocklist");
        revert("ForkTest: unsupported legacy external key");
    }

    function _deployed(string memory key) internal view returns (address) {
        return vm.parseTomlAddress(_registry, _registryKey(key));
    }

    function _deployedBytes32(string memory key) internal view returns (bytes32) {
        return vm.parseTomlBytes32(_registry, _registryKey(key));
    }

    function _registryKey(string memory key) private view returns (string memory) {
        require(_registryLoaded, "ForkTest: _fork() not called");
        require(
            vm.keyExistsToml(_registry, string.concat(".", key)),
            string.concat("ForkTest: registry missing key '", key, "'")
        );
        return string.concat(".", key);
    }

    function _requireRegistryMetadata() private view {
        ArtifactMetadataFile.requireKindChain(_registry, "protocol-registry", block.chainid);
    }
}
