// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

struct ProtocolConfig {
    address agent;
    address evmScriptExecutor;
    address circuitBreaker;
    address resealManager;
}

struct ProtocolDeployment {
    string deployment;
    string network;
    uint256 chainId;
    bytes32 configHash;
    string circuitBreakerArtifact;
    address core;
    address ownerFacade;
    address irmRouter;
    address adaptiveCurveIrm;
    address irmConfigFactory;
    address factory;
    address riskStewardDashboard;
    address circuitBreaker;
    address resealManager;
    address guardianSignalsImpl;
    uint256 deployedBlock;
    address deployer;
    address agent;
    address evmScriptExecutor;
    address pauserCommittee; // zero when the Agent stands in for the committee
}
