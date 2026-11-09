// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {
    ProtocolAddresses,
    CircuitBreakerPlan,
    MarketPlan,
    MarketDeploymentResult,
    ExitBookAddresses
} from "./DeploymentTypes.sol";

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
    MarketPlan plan;
    MarketDeploymentResult contracts;
    address vaultV2;
    address adapter;
}

struct DeploymentSnapshot {
    ProtocolAddresses protocol;
    CircuitBreakerPlan circuitBreakerPlan;
    uint256 bookLifetime;
    address weth;
    address wstEth;
    address stEth;
    address usdt;
    address usdy;
    address ondoOracle;
    address usdyBlocklist;
    ExitBookAddresses books;
    address bookPauser;
    address bundler;
    address generalAdapter;
    address vaultAdapter;
    RecordedMarket[] markets;
}
