// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {
    ProtocolAddresses,
    ProtocolPlan,
    MarketPlan,
    MarketDeploymentResult,
    ExitBookAddresses
} from "./DeploymentTypes.sol";
import {ExitBookConfig} from "./ExitBookPlan.sol";
import {BundlerPlan, BundlerAddresses, VaultV2Plan, VaultV2Addresses} from "./PeripheryDeployment.sol";

struct DeploymentHeader {
    uint256 version;
    string run;
    string kind;
    string name;
    uint256 chainId;
    address sender;
    uint256 blockNumber;
}

struct ProtocolRecord {
    DeploymentHeader header;
    ProtocolAddresses addresses;
    ProtocolPlan plan;
}

struct MarketRecord {
    DeploymentHeader header;
    address core;
    string role;
    MarketPlan plan;
    MarketDeploymentResult addresses;
}

struct ExitBooksRecord {
    DeploymentHeader header;
    ExitBookConfig plan;
    ExitBookAddresses addresses;
}

struct BundlerRecord {
    DeploymentHeader header;
    address core;
    BundlerPlan plan;
    BundlerAddresses addresses;
}

struct VaultV2Record {
    DeploymentHeader header;
    address core;
    address irmRouter;
    VaultV2Plan plan;
    VaultV2Addresses addresses;
}

/// @dev Named schemas preserve struct field names in TOML serialization.
library DeploymentSchema {
    string internal constant DEPLOYMENTHEADER =
        "DeploymentHeader(uint256 version,string run,string kind,string name,uint256 chainId,address sender,uint256 blockNumber)";
    string internal constant PROTOCOLRECORD =
        "ProtocolRecord(DeploymentHeader header,ProtocolAddresses addresses,ProtocolPlan plan)CircuitBreakerPlan(uint256 minPauseDuration,uint256 maxPauseDuration,uint256 minHeartbeatInterval,uint256 maxHeartbeatInterval,uint256 initialPauseDuration,uint256 initialHeartbeatInterval)DeploymentHeader(uint256 version,string run,string kind,string name,uint256 chainId,address sender,uint256 blockNumber)ProtocolAddresses(uint256 chainId,address core,address factory,address ownerFacade,address irmRouter,address adaptiveCurveIrm,address irmConfigFactory,address dashboard,address circuitBreaker,address resealManager,address agent,address executor)ProtocolPlan(uint256 chainId,address agent,address executor,address resealManager,address circuitBreaker,CircuitBreakerPlan circuitBreakerPlan)";
    string internal constant MARKETRECORD =
        "MarketRecord(DeploymentHeader header,address core,string role,MarketPlan plan,MarketDeploymentResult addresses)AdaptiveCurveParams(int256 curveSteepness,int256 adjustmentSpeed,int256 targetUtilization,int256 initialRateAtTarget,int256 minRateAtTarget,int256 maxRateAtTarget,uint256 maxBorrowRate)CollateralActivationConfig(uint40 minActivationDelay,uint40 maxActivationDelay,uint128 maxDelayInflow,uint128 minDepositAmount,uint40 activatingLockDuration,uint128 minActivationAmount,uint40 maxGuardiansQuorumDelay,uint40 delayPerStrike,uint40 delayPerSuspect)DeploymentHeader(uint256 version,string run,string kind,string name,uint256 chainId,address sender,uint256 blockNumber)ERC4626WrapperSpec(string name,string symbol)GuardianSpec(address[] guardians,uint256 quorum,uint256 suspectWindow)MarketDeploymentResult(bytes32 id,MarketParams params,address controller,address vault,address guardianSignals,address irmConfig)MarketParams(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)MarketPlan(string name,bytes32 guardianGroup,MarketSpec market,ERC4626WrapperSpec wrapper,GuardianSpec committee,AdaptiveCurveParams curve)MarketSpec(address loanToken,address collateralToken,address oracle,uint256 lltv,address guardianSignals,uint256 supplyCap,CollateralActivationConfig activationConfig,SettlementConfig settlementConfig)SettlementConfig(uint16 sliceFloorBps,uint96 sliceFloorAssets,uint96 fullCutBelowCollateral,uint16 ltvStepBps)";
    string internal constant EXITBOOKSRECORD =
        "ExitBooksRecord(DeploymentHeader header,ExitBookConfig plan,ExitBookAddresses addresses)DeploymentHeader(uint256 version,string run,string kind,string name,uint256 chainId,address sender,uint256 blockNumber)ExitBookAddresses(uint256 chainId,address morpho,address erc4626)ExitBookConfig(address agent,address evmScriptExecutor,address pauser,address core,uint256 maxRequestLifetime)";
    string internal constant BUNDLERRECORD =
        "BundlerRecord(DeploymentHeader header,address core,BundlerPlan plan,BundlerAddresses addresses)BundlerAddresses(address bundler,address generalAdapter,address vaultAdapter)BundlerPlan(address weth,address wstEth)DeploymentHeader(uint256 version,string run,string kind,string name,uint256 chainId,address sender,uint256 blockNumber)";
    string internal constant VAULTV2RECORD =
        "VaultV2Record(DeploymentHeader header,address core,address irmRouter,VaultV2Plan plan,VaultV2Addresses addresses)DeploymentHeader(uint256 version,string run,string kind,string name,uint256 chainId,address sender,uint256 blockNumber)VaultV2Addresses(address vault,address adapter)VaultV2Plan(string name,address owner,address asset)";
}
