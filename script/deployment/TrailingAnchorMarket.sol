// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {console2} from "forge-std/console2.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {
    ProtocolAddresses,
    MarketParameters,
    MarketDeploymentResult,
    TrailingAnchorPriceFeedSpec
} from "./DeploymentTypes.sol";
import {IPriceFeedProxyView, MarketDeployment} from "./MarketDeployment.sol";
import {TrailingAnchorPriceFeed} from "./TrailingAnchorPriceFeed.sol";

/// @notice Deploys a market over a trailing anchor oracle. A new oracle is initialized in its proxy's constructor, so
///         no other account can initialize it first, and the Agent then holds each of its roles alone. A market over
///         an existing oracle requires the same parameters and roles.
abstract contract TrailingAnchorMarket is MarketDeployment {
    /// @notice The deployer renounces its admin role after the handoff, which would leave the Agent without it.
    error DeployerIsAgent();
    /// @notice The base deployment would leave the oracle's proxy uninitialized.
    error PriceFeedNotDeployed();
    /// @notice A field that a spec leaves out reads as zero, so the recipe refuses a zero in any parameter and in the
    ///         seed range.
    error ZeroSpecValue(bytes32 field);

    bytes32 private immutable TRAILING_ANCHOR_CODEHASH;

    TrailingAnchorPriceFeedSpec internal trailingAnchorSpec;

    constructor(TrailingAnchorPriceFeedSpec memory spec) {
        _requireNonZero(spec);
        trailingAnchorSpec = spec;
        TRAILING_ANCHOR_CODEHASH = TrailingAnchorPriceFeed.implementation(spec).codehash;
    }

    /// @notice Deploys the market, and first its oracle when `parameters.market.oracle` is zero.
    /// @param deployer The account that sends the calls: the oracle's first admin until the handoff.
    function _deployTrailingAnchorMarket(
        ProtocolAddresses memory p,
        MarketParameters memory parameters,
        address deployer
    ) internal returns (MarketDeploymentResult memory) {
        _checkProtocol(p);
        _checkTokens(parameters);
        if (deployer == p.agent) revert DeployerIsAgent();
        if (parameters.market.oracle == address(0)) {
            parameters.market.oracle = _deployTrailingAnchorPriceFeed(p, parameters, deployer);
        }
        return _deployMarket(p, parameters);
    }

    function _reportTrailingAnchor(address oracle) internal view {
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(oracle);
        console2.log("price feed kind:", TrailingAnchorPriceFeed.kindName(trailingAnchorSpec.kind));
        console2.log("price feed source:", trailingAnchorSpec.source);
        console2.log("price feed implementation:", IPriceFeedProxyView(oracle).proxy__getImplementation());
        console2.log("anchor price:", uint256(nav.anchorPrice()));
        console2.log("base price:", uint256(nav.basePrice()));
    }

    function _deployPriceFeedImplementation(MarketParameters memory) internal override returns (address) {
        return TrailingAnchorPriceFeed.implementation(trailingAnchorSpec);
    }

    function _deployPriceFeed(ProtocolAddresses memory, MarketParameters memory)
        internal
        pure
        override
        returns (address)
    {
        revert PriceFeedNotDeployed();
    }

    function _checkPriceFeed(ProtocolAddresses memory p, MarketParameters memory parameters) internal view override {
        _checkTokens(parameters);
        address oracle = parameters.market.oracle;
        _checkPriceFeedProxy(oracle, p.agent, TRAILING_ANCHOR_CODEHASH);
        TrailingAnchorPriceFeed.checkLaunch(oracle, trailingAnchorSpec, p.agent);
        TrailingAnchorPriceFeed.checkLive(oracle, parameters.market.lltv);
    }

    function _deployTrailingAnchorPriceFeed(
        ProtocolAddresses memory p,
        MarketParameters memory parameters,
        address deployer
    ) private returns (address oracle) {
        TrailingAnchorPriceFeedSpec memory spec = trailingAnchorSpec;
        bytes memory initData = abi.encodeCall(
            TrailingAnchorOracleBase.initialize, (deployer, spec.parameters, spec.seedMinPrice, spec.seedMaxPrice)
        );
        oracle = address(new OssifiableProxy(_deployPriceFeedImplementation(parameters), p.agent, initData));
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(oracle);
        nav.grantRole(nav.MANAGER_ROLE(), p.agent);
        nav.grantRole(nav.PRICE_ACCEPTOR_ROLE(), p.agent);
        nav.grantRole(nav.DEFAULT_ADMIN_ROLE(), p.agent);
        nav.renounceRole(nav.DEFAULT_ADMIN_ROLE(), deployer);
    }

    function _requireNonZero(TrailingAnchorPriceFeedSpec memory spec) private pure {
        TrailingAnchorOracleBase.Parameters memory p = spec.parameters;
        _nonZero("maxPriceAboveAnchor", p.maxPriceAboveAnchor);
        _nonZero("maxPriceBelowAnchor", p.maxPriceBelowAnchor);
        _nonZero("maxAnchorContinuousRiseRate", p.maxAnchorContinuousRiseRate);
        _nonZero("maxAnchorContinuousFallRate", p.maxAnchorContinuousFallRate);
        _nonZero("maxAnchorBelowBase", p.maxAnchorBelowBase);
        _nonZero("maxAnchorAboveBase", p.maxAnchorAboveBase);
        _nonZero("reanchorDelay", p.reanchorDelay);
        _nonZero("reanchorWindow", p.reanchorWindow);
        _nonZero("seedMinPrice", spec.seedMinPrice);
        _nonZero("seedMaxPrice", spec.seedMaxPrice);
    }

    function _nonZero(bytes32 field, uint256 value) private pure {
        if (value == 0) revert ZeroSpecValue(field);
    }

    function _checkTokens(MarketParameters memory parameters) private view {
        _same("loanToken", trailingAnchorSpec.loanToken, parameters.market.loanToken);
        _same("collateralToken", trailingAnchorSpec.collateralToken, parameters.market.collateralToken);
    }
}
