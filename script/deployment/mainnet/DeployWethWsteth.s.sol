// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {Protocol as MainnetProtocol} from "./artifacts/Protocol.sol";
import {ProtocolAddresses, MarketParameters, MarketDeploymentResult} from "../DeploymentTypes.sol";

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {WstEthRateOracle} from "../../../src/oracle/WstEthRateOracle.sol";
import {CollateralActivationConfig} from "../../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../../src/types/SettlementTypes.sol";
import {MarketDeployment} from "../MarketDeployment.sol";

abstract contract WethWstethMarket is MarketDeployment {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    address internal constant GUARDIAN = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E;
    string internal constant OUTPUT_DIRECTORY = "deployed/mainnet/markets";

    bytes32 private immutable PRICE_FEED_CODEHASH = address(new WstEthRateOracle(WSTETH)).codehash;

    /// @dev Draft economic parameters; review before broadcasting.
    function _wethWstethParameters(address[] memory guardians)
        internal
        pure
        returns (MarketParameters memory parameters)
    {
        int256 stethAPRma90 = 0.0223519561285827 ether; // https://dune.com/queries/9095577 2026-10-29
        parameters.name = "weth-wsteth";
        parameters.guardianGroup = keccak256("weth-wsteth");
        parameters.market.loanToken = WETH;
        parameters.market.collateralToken = WSTETH;
        parameters.market.lltv = 0.98e18;
        parameters.market.supplyCap = 5_000 ether;
        parameters.market.activationConfig = CollateralActivationConfig({
            minActivationDelay: 2 hours,
            maxActivationDelay: 8 hours,
            maxDelayInflow: 1_000 ether,
            minDepositAmount: 1 ether,
            activatingLockDuration: 0,
            minActivationAmount: 10 ether,
            maxGuardiansQuorumDelay: 48 hours,
            delayPerStrike: 12 hours,
            delayPerSuspect: 12 hours
        });
        parameters.market.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 10 ether, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
        });
        parameters.wrapper.name = "Lido Lend WETH (wstETH)";
        parameters.wrapper.symbol = "lendWETHwstETH";
        parameters.committee.guardians = guardians;
        parameters.committee.quorum = 1;
        parameters.committee.suspectWindow = 1 days;
        parameters.curve = AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: 0.9e18,
            initialRateAtTarget: stethAPRma90 * 9 / 10 / int256(365 days),
            minRateAtTarget: 0.001 ether / int256(365 days),
            maxRateAtTarget: 2 * stethAPRma90 / int256(365 days),
            maxBorrowRate: 2 * uint256(stethAPRma90) / 365 days
        });
    }

    function _deployPriceFeedImplementation(MarketParameters memory parameters) internal override returns (address) {
        return address(new WstEthRateOracle(WSTETH));
    }

    function _checkPriceFeed(ProtocolAddresses memory p, MarketParameters memory parameters) internal view override {
        _same("loanToken", WETH, parameters.market.loanToken);
        _same("collateralToken", WSTETH, parameters.market.collateralToken);
        _checkPriceFeedProxy(parameters.market.oracle, p.agent, PRICE_FEED_CODEHASH);
        _same("priceFeed.source", WSTETH, address(WstEthRateOracle(parameters.market.oracle).WSTETH()));
    }
}

contract DeployWethWsteth is Script, WethWstethMarket {
    function run() external returns (MarketDeploymentResult memory deployed) {
        ProtocolAddresses memory p = MainnetProtocol.addresses();
        address[] memory guardians = new address[](1);
        guardians[0] = GUARDIAN;
        MarketParameters memory parameters = _wethWstethParameters(guardians);
        vm.startBroadcast();
        deployed = _deployMarket(p, parameters);
        vm.stopBroadcast();

        _reportMarket(OUTPUT_DIRECTORY, p.core, parameters.name, deployed);
    }
}
