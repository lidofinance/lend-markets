// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {DeploymentHeader, DeploymentSchema} from "./DeploymentRecord.sol";

library DeploymentArtifact {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function isToml(string memory file) internal pure returns (bool) {
        bytes memory b = bytes(file);
        uint256 n = b.length;
        return n >= 5 && b[n - 5] == "." && b[n - 4] == "t" && b[n - 3] == "o" && b[n - 2] == "m" && b[n - 1] == "l";
    }

    function directory(string memory runName) internal pure returns (string memory) {
        requireName(runName);
        return string.concat("deployed/", runName);
    }

    function requireName(string memory name) internal pure {
        bytes memory b = bytes(name);
        require(
            b.length != 0 && keccak256(b) != keccak256(".") && keccak256(b) != keccak256(".."), "Invalid artifact name"
        );
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            require(
                (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_"
                    || c == ".",
                "Invalid artifact name"
            );
        }
    }

    function path(DeploymentHeader memory h) internal pure returns (string memory) {
        string memory dir = directory(h.run);
        requireName(h.name);
        bytes32 kind = keccak256(bytes(h.kind));
        if (kind == keccak256("protocol")) return string.concat(dir, "/protocol.toml");
        if (kind == keccak256("market")) return string.concat(dir, "/markets/", h.name, ".toml");
        if (kind == keccak256("exit-books")) return string.concat(dir, "/exit-books.toml");
        if (kind == keccak256("bundler")) return string.concat(dir, "/bundler.toml");
        require(kind == keccak256("vault"), "Unknown deployment kind");
        return string.concat(dir, "/vaults/", h.name, ".toml");
    }

    function read(string memory file, string memory runName, string memory kind, string memory schema)
        internal
        view
        returns (bytes memory)
    {
        string memory toml = vm.readFile(file);
        DeploymentHeader memory h =
            abi.decode(vm.parseTomlType(toml, ".header", DeploymentSchema.DEPLOYMENTHEADER), (DeploymentHeader));
        require(h.version == 1, "Unsupported deployment artifact version");
        require(keccak256(bytes(h.run)) == keccak256(bytes(runName)), "Deployment run mismatch");
        require(keccak256(bytes(h.kind)) == keccak256(bytes(kind)), "Deployment kind mismatch");
        require(keccak256(bytes(file)) == keccak256(bytes(path(h))), "Deployment path mismatch");
        return vm.parseTomlType(toml, schema);
    }
}
