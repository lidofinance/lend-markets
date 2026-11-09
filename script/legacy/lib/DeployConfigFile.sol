// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";

library DeployConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    error RegistryCompatibilityHashMismatch(bytes32 expected, bytes32 actual);

    function configPath(string memory name) internal pure returns (string memory) {
        return string.concat(configDir(name), "/protocol.toml");
    }

    function configDir(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/", name);
    }

    function canonicalCompatibilityHash(
        string memory network,
        uint256 chainId,
        address agent,
        address evmScriptExecutor,
        address resealManager,
        string memory circuitBreakerArtifact
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(network, chainId, agent, evmScriptExecutor, resealManager, circuitBreakerArtifact));
    }

    function requireProtocolArtifactCompatibility(string memory registry) internal view {
        bytes32 expected = canonicalCompatibilityHash(
            vm.parseTomlString(registry, ".protocol.network"),
            vm.parseTomlUint(registry, ".protocol.chain_id"),
            vm.parseTomlAddress(registry, ".protocol.agent"),
            vm.parseTomlAddress(registry, ".protocol.evm_script_executor"),
            vm.parseTomlAddress(registry, ".protocol.reseal_manager"),
            vm.parseTomlString(registry, ".protocol.circuit_breaker_artifact")
        );
        bytes32 actual = vm.parseTomlBytes32(registry, ".artifact.compatibility_hash");
        if (actual != expected) revert RegistryCompatibilityHashMismatch(expected, actual);
    }
}
