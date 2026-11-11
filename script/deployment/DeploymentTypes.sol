// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";

struct ProtocolConfig {
    address agent;
    address evmScriptExecutor;
    address circuitBreaker;
    address resealManager;
}

struct ProtocolAddresses {
    uint256 chainId;
    address core;
    address factory;
    address ownerFacade;
    address irmRouter;
    address adaptiveCurveIrm;
    address irmConfigFactory;
    address dashboard;
    address circuitBreaker;
    address resealManager;
    address agent;
    address executor;
}

struct ExitBookAddresses {
    uint256 chainId;
    address morpho;
    address erc4626;
}

struct MarketPlan {
    string name;
    bytes32 guardianGroup;
    LidoLendMarketFactory.MarketSpec market;
    LidoLendMarketFactory.ERC4626WrapperSpec wrapper;
    LidoLendMarketFactory.GuardianSpec committee;
    AdaptiveCurveParams curve;
}

struct MarketDeploymentResult {
    Id id;
    MarketParams params;
    address controller;
    address vault;
    address guardianSignals;
    address irmConfig;
}

struct MarketActivation {
    address pauser;
    address steward;
    bool enableSettlement;
    ExitBookAddresses exitBooks;
}

struct CircuitBreakerPlan {
    uint256 minPauseDuration;
    uint256 maxPauseDuration;
    uint256 minHeartbeatInterval;
    uint256 maxHeartbeatInterval;
    uint256 initialPauseDuration;
    uint256 initialHeartbeatInterval;
}

struct ProtocolPlan {
    uint256 chainId;
    address agent;
    address executor;
    address resealManager;
    address circuitBreaker;
    CircuitBreakerPlan circuitBreakerPlan;
}
