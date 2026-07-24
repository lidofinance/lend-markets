// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

struct ArtifactMetadata {
    string deployment;
    uint256 chainId;
    bytes32 configHash;
}

library ArtifactMetadataFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error InvalidArtifactsDir(string value);

    function header(ArtifactMetadata memory metadata, string memory kind) internal pure returns (string memory s) {
        s = "[artifact]\n";
        s = string.concat(s, "kind = \"", kind, "\"\n");
        s = string.concat(s, "deployment = \"", metadata.deployment, "\"\n");
        s = string.concat(s, "chain_id = ", vm.toString(metadata.chainId), "\n");
        s = string.concat(s, "config_hash = \"", vm.toString(metadata.configHash), "\"\n");
    }

    /// @dev `ARTIFACTS_DIR` must be one directory name below `deployed/`.
    function artifactsDir() internal view returns (string memory dir) {
        string memory name = vm.envString("ARTIFACTS_DIR");
        bytes memory raw = bytes(name);
        if (raw.length == 0) revert InvalidArtifactsDir(name);
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == "/" || raw[i] == "\\") revert InvalidArtifactsDir(name);
        }
        return string.concat("deployed/", name);
    }

    function ensureArtifactsDir() internal {
        string memory dir = artifactsDir();
        if (!vm.exists(dir)) vm.createDir(dir, false);
    }

    function deployment() internal view returns (string memory) {
        return vm.envString("ARTIFACTS_DIR");
    }
}
