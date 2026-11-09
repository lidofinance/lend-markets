// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {ExitBookConfig} from "./deployment/ExitBookPlan.sol";
import {ExitBookAddresses} from "./deployment/DeploymentTypes.sol";

/// @notice Deploys exit books independently from protocol and market creation.
import {DeploymentArtifact} from "./deployment/DeploymentArtifact.sol";
import {DeploymentHeader, DeploymentSchema, ExitBooksRecord} from "./deployment/DeploymentRecord.sol";

abstract contract DeployExitBooksBase is Script, ProtocolDeployer {
    error CoreNotContract(address core);
    error MissingGovernanceActor();

    function run() external returns (ExitBookAddresses memory books, string memory artifact) {
        (uint256 chainId, ExitBookConfig memory plan) = _exitBookPlan();
        DeploymentArtifact.requireProtocol(chainId, plan.core, false);
        DeploymentHeader memory h = DeploymentArtifact.header("exit-books", "exit-books", msg.sender);
        _requireChainId(chainId);
        if (plan.core.code.length == 0) revert CoreNotContract(plan.core);
        if (plan.agent == address(0) || plan.evmScriptExecutor == address(0)) revert MissingGovernanceActor();
        books.chainId = chainId;
        vm.startBroadcast();
        (books.morpho, books.erc4626) = _deployExitBooks(plan, msg.sender);
        vm.stopBroadcast();
        artifact = vm.serializeJsonType(
            DeploymentSchema.EXITBOOKSRECORD, abi.encode(ExitBooksRecord({header: h, plan: plan, addresses: books}))
        );
        console2.log("Morpho exit book:", books.morpho);
        console2.log("ERC4626 exit book:", books.erc4626);
    }

    function _exitBookPlan() internal view virtual returns (uint256 chainId, ExitBookConfig memory plan);
}
