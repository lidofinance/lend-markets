// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

library ConfigToml {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error MissingConfigValue(string key);

    function requireAddress(string memory toml, string memory key) internal pure returns (address value) {
        value = vm.parseTomlAddress(toml, key);
        if (value == address(0)) revert MissingConfigValue(key);
    }
}
