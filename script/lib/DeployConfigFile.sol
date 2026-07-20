// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ConfigToml} from "./ConfigToml.sol";

/// @notice A deploy config, read from `script/config/<name>.toml`. Governance + which optional peripherals to
///         include + the list of market NAMES; each market's details live in its own `markets/`, `oracles/`,
///         `guardians/` files (composed by name, so no array-of-tables to parse).
struct DeployConfig {
    address agent;
    address evmScriptExecutor;
    address circuitBreaker; // one CircuitBreaker for all markets; each controller's PAUSER_ROLE holder
    bool exitBooks; // deploy the protocol's two exit books
    uint256 exitBookMaxRequestLifetime; // used only when exitBooks is true
    string[] markets; // per-market config names (markets/<name>.toml, oracles/<name>.toml, guardians/<name>.toml)
}

/// @title DeployConfigFile
/// @notice Reads the deploy config for `DeployProtocol.s.sol`.
library DeployConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function read(string memory name) internal view returns (DeployConfig memory cfg) {
        string memory toml = vm.readFile(configPath(name));
        cfg.agent = ConfigToml.requireAddress(toml, ".agent");
        cfg.evmScriptExecutor = ConfigToml.requireAddress(toml, ".evm_script_executor");
        // Optional: zero at the template stage. Zero deploys markets with no PAUSER_ROLE holder (inert but
        // incomplete); fill it with the deployed CircuitBreaker before a real broadcast.
        cfg.circuitBreaker = vm.parseTomlAddress(toml, ".circuit_breaker");
        cfg.exitBooks = vm.parseTomlBool(toml, ".exit_books");
        cfg.exitBookMaxRequestLifetime = vm.parseTomlUint(toml, ".exit_book_max_request_lifetime");
        cfg.markets = vm.parseTomlStringArray(toml, ".markets");
    }

    function configPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/", name, ".toml");
    }
}
