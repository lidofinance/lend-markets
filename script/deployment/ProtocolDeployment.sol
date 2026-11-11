// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CommonBase} from "forge-std/Base.sol";
import {ProtocolDeployer} from "../lib/ProtocolDeployer.sol";
import {ProtocolAddresses, ProtocolParameters, CircuitBreakerParameters, ProtocolConfig} from "./DeploymentTypes.sol";

abstract contract ProtocolDeployment is CommonBase, ProtocolDeployer {
    error MissingProtocolGovernance();

    function _deployProtocol(ProtocolParameters memory parameters, address deployer)
        internal
        returns (ProtocolAddresses memory p)
    {
        _requireChainId(parameters.chainId);
        if (
            parameters.agent == address(0) || parameters.executor == address(0)
                || parameters.resealManager == address(0)
        ) revert MissingProtocolGovernance();
        address circuitBreaker = parameters.circuitBreaker;
        if (circuitBreaker == address(0)) {
            CircuitBreakerParameters memory c = parameters.circuitBreakerParameters;
            // The upstream dependency pins solc 0.8.34.
            circuitBreaker = vm.deployCode(
                "CircuitBreaker.sol:CircuitBreaker",
                abi.encode(
                    parameters.executor,
                    c.minPauseDuration,
                    c.maxPauseDuration,
                    c.minHeartbeatInterval,
                    c.maxHeartbeatInterval,
                    c.initialPauseDuration,
                    c.initialHeartbeatInterval
                )
            );
        }
        p = _deployBackbone(
            ProtocolConfig({
                agent: parameters.agent,
                evmScriptExecutor: parameters.executor,
                circuitBreaker: circuitBreaker,
                resealManager: parameters.resealManager
            }),
            deployer
        );
    }
}
