// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {WstEthRateOracle} from "../../../src/oracle/WstEthRateOracle.sol";
import {OssifiableProxy} from "../../../src/proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../../src/types/SettlementTypes.sol";
import {DeployMarketBase} from "../../DeployMarketBase.s.sol";
import {Protocol as MainnetProtocol} from "../generated/mainnet/Protocol.sol";
import {ProtocolAddresses, MarketPlan} from "../DeploymentTypes.sol";

interface IPriceFeedProxyView {
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
}

contract DeployWethWsteth is DeployMarketBase, MainnetProtocol {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    bytes32 private immutable PRICE_FEED_CODEHASH = address(new WstEthRateOracle(WSTETH)).codehash;

    error PriceFeedCodeMismatch(address component);

    function _deploymentProtocol() internal pure virtual override returns (ProtocolAddresses memory) {
        return _protocolAddresses();
    }

    function _deploymentPlan() internal pure virtual override returns (MarketPlan memory) {
        // Reviewed production committee addresses must be supplied before deployment.
        return _wethWstethPlan(new address[](0));
    }

    /// @dev Economic parameters remain draft; the committee must be supplied explicitly by the concrete deployment.
    function _wethWstethPlan(address[] memory guardians) internal pure returns (MarketPlan memory plan) {
        plan.name = "weth-wsteth";
        plan.guardianGroup = keccak256("weth-wsteth");
        plan.market.loanToken = WETH;
        plan.market.collateralToken = WSTETH;
        plan.market.lltv = 0.95e18;
        plan.market.activationConfig = CollateralActivationConfig({
            minActivationDelay: 10 minutes,
            maxActivationDelay: 2 hours,
            maxDelayInflow: 10_000 ether,
            minDepositAmount: 1 ether,
            activatingLockDuration: 0,
            minActivationAmount: 10 ether,
            maxGuardiansQuorumDelay: 36 hours,
            delayPerStrike: 2 hours,
            delayPerSuspect: 2 hours
        });
        plan.market.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 10 ether, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
        });
        plan.wrapper.name = "Lido wstETH/WETH Vault";
        plan.wrapper.symbol = "lidoWSTETH-WETH";
        plan.committee.guardians = guardians;
        plan.committee.quorum = 1;
        plan.committee.suspectWindow = 1 days;
        plan.curve = AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: 1_585_489_599_188,
            targetUtilization: 0.9e18,
            initialRateAtTarget: 713_470_319,
            minRateAtTarget: 31_709_791,
            maxRateAtTarget: 1_585_489_599,
            maxBorrowRate: 1_585_489_599
        });
    }

    function _deployPriceFeed(ProtocolAddresses memory p, MarketPlan memory plan) internal override returns (address) {
        address implementation = address(new WstEthRateOracle(plan.market.collateralToken));
        return address(new OssifiableProxy(implementation, p.agent, ""));
    }

    function _checkPriceFeed(ProtocolAddresses memory p, MarketPlan memory plan) internal view override {
        _same("loanToken", WETH, plan.market.loanToken);
        _same("collateralToken", WSTETH, plan.market.collateralToken);
        _requireCode(plan.market.oracle);
        IPriceFeedProxyView proxy = IPriceFeedProxyView(plan.market.oracle);
        _same("priceFeed.admin", p.agent, proxy.proxy__getAdmin());
        if (plan.market.oracle.codehash != keccak256(type(OssifiableProxy).runtimeCode)) {
            revert PriceFeedCodeMismatch(plan.market.oracle);
        }
        address implementation = proxy.proxy__getImplementation();
        if (implementation.codehash != PRICE_FEED_CODEHASH) revert PriceFeedCodeMismatch(implementation);
        WstEthRateOracle feed = WstEthRateOracle(plan.market.oracle);
        _same("priceFeed.source", WSTETH, address(feed.WSTETH()));
        require(feed.price() != 0, "Price feed is zero");
    }
}
