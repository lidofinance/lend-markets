// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {DeployProtocol} from "../../script/deployment/mainnet/DeployProtocol.s.sol";
import {ProtocolDeployment} from "../../script/deployment/ProtocolDeployment.sol";
import {TrailingAnchorMarket} from "../../script/deployment/TrailingAnchorMarket.sol";
import {
    ProtocolAddresses,
    ProtocolParameters,
    MarketParameters,
    MarketDeploymentResult,
    TrailingAnchorKind,
    TrailingAnchorPriceFeedSpec
} from "../../script/deployment/DeploymentTypes.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {TrailingAnchorOracleModel} from "./TrailingAnchorOracleModel.sol";

/// @notice The trailing anchor market recipe over a protocol that the protocol recipe deploys on the local EVM. The
///         harness sends every call, so it is the deployer unless a test names another.
contract TrailingAnchorMarketHarness is ProtocolDeployment, TrailingAnchorMarket {
    constructor(TrailingAnchorPriceFeedSpec memory spec) TrailingAnchorMarket(spec) {}

    function deployProtocol(ProtocolParameters memory parameters) external returns (ProtocolAddresses memory) {
        return _deployProtocol(parameters, address(this));
    }

    function deployTrailingAnchorMarket(
        ProtocolAddresses memory p,
        MarketParameters memory parameters,
        address deployer
    ) external returns (MarketDeploymentResult memory) {
        return _deployTrailingAnchorMarket(p, parameters, deployer);
    }

    function deployMarket(ProtocolAddresses memory p, MarketParameters memory parameters)
        external
        returns (MarketDeploymentResult memory)
    {
        return _deployMarket(p, parameters);
    }

    function reportTrailingAnchor(address oracle) external view {
        _reportTrailingAnchor(oracle);
    }
}

/// @notice Inputs of a USDC/USDY market over a trailing anchor oracle: the mainnet protocol parameters with local
///         governance addresses, the working oracle parameters and a seed range around $1.10.
library TrailingAnchorMarketFixture {
    uint256 internal constant LLTV = 0.98e18;
    uint256 internal constant SEED_MIN_PRICE = 1.09e18;
    uint256 internal constant SEED_MAX_PRICE = 1.11e18;

    function protocolParameters(address agent, address executor, address resealManager)
        internal
        returns (ProtocolParameters memory p)
    {
        p = (new DeployProtocol()).parameters();
        p.chainId = block.chainid;
        p.agent = agent;
        p.executor = executor;
        p.resealManager = resealManager;
    }

    function usdySpec(address source, address loanToken, address collateralToken)
        internal
        pure
        returns (TrailingAnchorPriceFeedSpec memory spec)
    {
        spec.kind = TrailingAnchorKind.Usdy;
        spec.source = source;
        spec.loanToken = loanToken;
        spec.collateralToken = collateralToken;
        spec.parameters = TrailingAnchorOracleModel.defaultParameters();
        spec.seedMinPrice = SEED_MIN_PRICE;
        spec.seedMaxPrice = SEED_MAX_PRICE;
    }

    function marketParameters(address loanToken, address collateralToken, address guardian)
        internal
        pure
        returns (MarketParameters memory m)
    {
        m.name = "usdc-usdy";
        m.guardianGroup = keccak256("usdc-usdy");
        m.market.loanToken = loanToken;
        m.market.collateralToken = collateralToken;
        m.market.lltv = LLTV;
        m.market.supplyCap = 25_000_000e6;
        m.market.activationConfig = CollateralActivationConfig({
            minActivationDelay: 10 minutes,
            maxActivationDelay: 2 hours,
            maxDelayInflow: 25_000_000 ether,
            minDepositAmount: 2500 ether,
            activatingLockDuration: 0,
            minActivationAmount: 25_000 ether,
            maxGuardiansQuorumDelay: 36 hours,
            delayPerStrike: 2 hours,
            delayPerSuspect: 2 hours
        });
        m.market.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 25_000 ether, ltvStepBps: 100
        });
        m.wrapper.name = "Lido Lend USDC (USDY)";
        m.wrapper.symbol = "lendUSDCUSDY";
        m.committee.guardians = new address[](1);
        m.committee.guardians[0] = guardian;
        m.committee.quorum = 1;
        m.committee.suspectWindow = 1 days;
        m.curve = AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: 0.95e18,
            initialRateAtTarget: 0.032 ether / int256(365 days),
            minRateAtTarget: 0.001 ether / int256(365 days),
            maxRateAtTarget: 0.0711 ether / int256(365 days),
            maxBorrowRate: 0.0711 ether / uint256(365 days)
        });
    }
}
