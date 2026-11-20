// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {DeploymentSnapshot} from "./DeploymentTypes.sol";
import {Deployment as MainnetDeployment} from "./mainnet/artifacts/Deployment.sol";
import {Deployment as HoodiDeployment} from "./hoodi-testnet/artifacts/Deployment.sol";

library RecordedDeployment {
    function load(string memory runName) internal view returns (DeploymentSnapshot memory d) {
        bytes32 run = keccak256(bytes(runName));
        if (run == keccak256("mainnet")) d = MainnetDeployment.snapshot();
        else if (run == keccak256("hoodi-testnet")) d = HoodiDeployment.snapshot();
        else revert("Unknown deployment run");
        require(d.protocol.chainId == block.chainid, "Deployment chain mismatch");
        require(d.protocol.core.code.length != 0, "Deployment core missing code");
        for (uint256 i; i < d.markets.length; ++i) {
            require(
                bytes(d.markets[i].parameters.name).length != 0 && bytes(d.markets[i].role).length != 0,
                "Missing market identity"
            );
            for (uint256 j; j < i; ++j) {
                require(
                    keccak256(bytes(d.markets[i].parameters.name)) != keccak256(bytes(d.markets[j].parameters.name)),
                    "Duplicate market name"
                );
                require(
                    keccak256(bytes(d.markets[i].role)) != keccak256(bytes(d.markets[j].role)), "Duplicate market role"
                );
            }
        }
    }
}
