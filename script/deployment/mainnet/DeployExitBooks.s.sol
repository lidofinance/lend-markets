// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {ProtocolDeployer} from "../../lib/ProtocolDeployer.sol";
import {ExitBookConfig} from "../ExitBookPlan.sol";
import {ExitBookAddresses} from "../DeploymentTypes.sol";
import {ExitBookPlan} from "./ExitBookPlan.sol";

contract DeployExitBooks is Script, ProtocolDeployer {
    error CoreNotContract(address core);
    error MissingGovernanceActor();

    function run() external returns (ExitBookAddresses memory books) {
        (uint256 chainId, ExitBookConfig memory plan) = ExitBookPlan.get();
        _requireChainId(chainId);
        if (plan.core.code.length == 0) revert CoreNotContract(plan.core);
        if (plan.agent == address(0) || plan.evmScriptExecutor == address(0)) revert MissingGovernanceActor();
        books.chainId = chainId;
        vm.startBroadcast();
        (books.morpho, books.erc4626) = _deployExitBooks(plan, msg.sender);
        vm.stopBroadcast();

        console2.log("Morpho exit book:", books.morpho);
        console2.log("ERC4626 exit book:", books.erc4626);
    }
}
