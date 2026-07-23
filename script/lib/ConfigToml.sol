// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

/// @title ConfigToml
/// @notice Shared guard for the script config readers: the required-address parse and its error, so each
///         config library doesn't re-declare them (and every missing-key revert carries the same selector).
library ConfigToml {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Thrown when a required address key is missing or zero.
    error MissingConfigValue(string key);

    /// @notice Parse an address that must be non-zero (a key whose zero value has no legitimate use).
    function requireAddress(string memory toml, string memory key) internal pure returns (address value) {
        value = vm.parseTomlAddress(toml, key);
        if (value == address(0)) revert MissingConfigValue(key);
    }

    /// @notice Parse an unsigned integer that must be present and non-zero.
    function requireUint(string memory toml, string memory key) internal view returns (uint256 value) {
        if (!vm.keyExistsToml(toml, key)) revert MissingConfigValue(key);
        value = vm.parseTomlUint(toml, key);
        if (value == 0) revert MissingConfigValue(key);
    }

    /// @notice Parse a non-empty string from a required TOML key.
    function requireString(string memory toml, string memory key) internal view returns (string memory value) {
        if (!vm.keyExistsToml(toml, key)) revert MissingConfigValue(key);
        value = vm.parseTomlString(toml, key);
        if (bytes(value).length == 0) revert MissingConfigValue(key);
    }
}
