// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm, VmSafe} from "forge-std/Vm.sol";

library DeploymentOutput {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function write(string memory directory, string memory name, string memory addressesJson) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        vm.createDir(directory, true);
        string memory file = string.concat(directory, "/", name, ".toml");
        require(!vm.exists(file), "Address output already exists");
        vm.writeToml(addressesJson, file);
    }
}
