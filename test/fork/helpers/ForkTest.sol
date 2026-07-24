// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CommonBase} from "forge-std/Base.sol";
import {console2} from "forge-std/Test.sol";

/// @notice Shared base for fork suites. `NETWORK` selects committed external addresses. A suite that reads
///         deployed protocol addresses additionally requires `FORK_REGISTRY`.
abstract contract ForkTest is CommonBase {
    error ForkChainIdMismatch(string source, uint256 expected, uint256 actual);
    error ForkRegistryChainIdConflict(uint256 artifactChainId, uint256 protocolChainId);

    string private _externals;
    bool private _externalsLoaded;
    string private _registry;
    bool private _registryLoaded;

    function _fork() internal {
        string memory url = vm.envOr("RPC_URL", string(""));
        require(bytes(url).length != 0, "ForkTest: RPC_URL is unset (see .env.example)");

        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pin);

        _loadExternals(_networkConfigPath());
        _validateNetworkChainId();

        string memory registryPath = vm.envOr("FORK_REGISTRY", string(""));
        if (bytes(registryPath).length != 0) {
            _loadRegistry(registryPath);
            _validateRegistryChainId();
        }
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

    function _deployed(string memory key) internal view returns (address) {
        require(_registryLoaded, "ForkTest: FORK_REGISTRY is required for deployed addresses");
        return vm.parseTomlAddress(_registry, _registryKey(key));
    }

    function _deployedBytes32(string memory key) internal view returns (bytes32) {
        require(_registryLoaded, "ForkTest: FORK_REGISTRY is required for deployed addresses");
        return vm.parseTomlBytes32(_registry, _registryKey(key));
    }

    function _validateNetworkChainId() internal view {
        uint256 expected = vm.parseTomlUint(_externals, ".chain_id");
        if (block.chainid != expected) revert ForkChainIdMismatch("network config", expected, block.chainid);
    }

    function _validateRegistryChainId() internal view {
        bool hasArtifact = vm.keyExistsToml(_registry, ".artifact.chain_id");
        bool hasProtocol = vm.keyExistsToml(_registry, ".protocol.chain_id");
        require(hasArtifact || hasProtocol, "ForkTest: registry missing chain_id");

        uint256 artifactChainId;
        uint256 protocolChainId;
        if (hasArtifact) artifactChainId = vm.parseTomlUint(_registry, ".artifact.chain_id");
        if (hasProtocol) protocolChainId = vm.parseTomlUint(_registry, ".protocol.chain_id");

        if (hasArtifact && hasProtocol && artifactChainId != protocolChainId) {
            revert ForkRegistryChainIdConflict(artifactChainId, protocolChainId);
        }
        if (hasArtifact && block.chainid != artifactChainId) {
            revert ForkChainIdMismatch("fork registry artifact", artifactChainId, block.chainid);
        }
        if (hasProtocol && block.chainid != protocolChainId) {
            revert ForkChainIdMismatch("fork registry protocol", protocolChainId, block.chainid);
        }
    }

    function _registryKey(string memory key) private view returns (string memory) {
        require(_registryLoaded, "ForkTest: _fork() not called");
        require(
            vm.keyExistsToml(_registry, string.concat(".", key)),
            string.concat("ForkTest: registry missing key '", key, "'")
        );
        return string.concat(".", key);
    }
}
