// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CommonBase} from "forge-std/Base.sol";
import {ProtocolDeployer} from "../lib/ProtocolDeployer.sol";
import {ProtocolConfig, ProtocolDeployment as Backbone} from "./ProtocolTypes.sol";
import {ProtocolAddresses, ProtocolPlan, CircuitBreakerPlan} from "./DeploymentTypes.sol";

/// @notice Shared protocol creation for broadcast scripts and in-process fork fixtures.
abstract contract ProtocolDeployment is CommonBase, ProtocolDeployer {
    error MissingProtocolGovernance();

    function _deployProtocol(ProtocolPlan memory plan, address deployer) internal returns (ProtocolAddresses memory p) {
        _requireChainId(plan.chainId);
        if (plan.agent == address(0) || plan.executor == address(0) || plan.resealManager == address(0)) {
            revert MissingProtocolGovernance();
        }
        address circuitBreaker = plan.circuitBreaker;
        if (circuitBreaker == address(0)) {
            CircuitBreakerPlan memory c = plan.circuitBreakerPlan;
            // The upstream dependency pins solc 0.8.34.
            circuitBreaker = vm.deployCode(
                "CircuitBreaker.sol:CircuitBreaker",
                abi.encode(
                    plan.executor,
                    c.minPauseDuration,
                    c.maxPauseDuration,
                    c.minHeartbeatInterval,
                    c.maxHeartbeatInterval,
                    c.initialPauseDuration,
                    c.initialHeartbeatInterval
                )
            );
        }
        Backbone memory d = _deployBackbone(
            ProtocolConfig({
                agent: plan.agent,
                evmScriptExecutor: plan.executor,
                circuitBreaker: circuitBreaker,
                resealManager: plan.resealManager
            }),
            deployer
        );
        p = ProtocolAddresses({
            chainId: plan.chainId,
            core: d.core,
            factory: d.factory,
            ownerFacade: d.ownerFacade,
            irmRouter: d.irmRouter,
            adaptiveCurveIrm: d.adaptiveCurveIrm,
            irmConfigFactory: d.irmConfigFactory,
            dashboard: d.riskStewardDashboard,
            circuitBreaker: d.circuitBreaker,
            resealManager: d.resealManager,
            agent: d.agent,
            executor: d.evmScriptExecutor
        });
    }
}
