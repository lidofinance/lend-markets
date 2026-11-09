// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {ArtifactMetadata} from "../../script/legacy/lib/ArtifactMetadata.sol";

library HistoricalArtifacts {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function header(ArtifactMetadata memory metadata, string memory kind) internal pure returns (string memory s) {
        s = "[artifact]\n";
        s = string.concat(s, "kind = \"", kind, "\"\n");
        s = string.concat(s, "deployment = \"", metadata.deployment, "\"\n");
        s = string.concat(s, "chain_id = ", vm.toString(metadata.chainId), "\n");
        s = string.concat(s, "config_hash = \"", vm.toString(metadata.configHash), "\"\n");
        s = string.concat(s, "compatibility_hash = \"", vm.toString(metadata.compatibilityHash), "\"\n");
    }
}
