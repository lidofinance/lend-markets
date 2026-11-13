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

struct ExitBookConfig {
    address agent; // DEFAULT_ADMIN_ROLE and initial fee recipient
    address evmScriptExecutor; // ALLOWLIST_MANAGER_ROLE (EasyTrack motions)
    address pauser; // PAUSER_ROLE (Risk Steward Committee)
    address core; // MorphoExitBook only — the LidoLend core its requests draw from
    uint256 maxRequestLifetime; // cap on a request's lifetime (seconds); must be non-zero
}

struct ExitBookAddresses {
    uint256 chainId;
    address morpho;
    address erc4626;
}

struct MarketParameters {
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

struct CircuitBreakerParameters {
    uint256 minPauseDuration;
    uint256 maxPauseDuration;
    uint256 minHeartbeatInterval;
    uint256 maxHeartbeatInterval;
    uint256 initialPauseDuration;
    uint256 initialHeartbeatInterval;
}

struct ProtocolParameters {
    uint256 chainId;
    address agent;
    address executor;
    address resealManager;
    address circuitBreaker;
    CircuitBreakerParameters circuitBreakerParameters;
}

struct PriceFeedRecord {
    address wstEth;
    address usdySource;
    address feed;
    address loanToken;
    address collateralToken;
    uint256 minPrice;
    uint256 maxPrice;
}

struct RecordedMarket {
    uint256 deployedBlock;
    PriceFeedRecord priceFeed;
    string priceFeedKind;
    string role;
    MarketParameters parameters;
    MarketDeploymentResult contracts;
    address collateralBlocklist;
    address vaultV2;
    address adapter;
}

struct DeploymentSnapshot {
    ProtocolAddresses protocol;
    CircuitBreakerParameters circuitBreakerParameters;
    uint256 bookLifetime;
    address weth;
    address wstEth;
    address stEth;
    ExitBookAddresses books;
    address bookPauser;
    address bundler;
    address generalAdapter;
    address vaultAdapter;
    RecordedMarket[] markets;
}

struct BundlerParameters {
    address weth;
    address wstEth;
}

struct BundlerAddresses {
    address bundler;
    address generalAdapter;
    address vaultAdapter;
}

struct VaultV2Parameters {
    string name;
    address owner;
    address asset;
}

struct VaultV2Addresses {
    address vault;
    address adapter;
}
