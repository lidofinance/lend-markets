// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {CollateralActivationConfig} from "../../../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../../../src/types/SettlementTypes.sol";
import {WstEthRateOracle} from "../../../../src/oracle/WstEthRateOracle.sol";
import {
    ActivationMotionConfig,
    DeployMarketBase,
    MarketDeployConfig,
    MarketDeploymentRecord
} from "../../DeployMarketBase.s.sol";

contract DeployWethWstethMainnet is DeployMarketBase {
    function getDeployConfig() public pure override returns (MarketDeployConfig memory c) {
        int256 stethAPRma90 = 0.0223519561285827 ether; // https://dune.com/queries/9095577 2026-10-29

        c.guardianGroup = keccak256("weth-wsteth");

        c.market.loanToken = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
        c.market.collateralToken = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // wstETH
        c.market.lltv = 0.98e18;
        c.market.supplyCap = 5_000 ether;
        c.market.activationConfig = CollateralActivationConfig({
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
        c.market.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 10 ether, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
        });

        c.wrapper.name = "Lido Lend WETH (wstETH)";
        c.wrapper.symbol = "lendWETHwstETH";

        c.committee.guardians = new address[](1);
        c.committee.guardians[0] = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E; // Risk Steward
        c.committee.quorum = 1;
        c.committee.suspectWindow = 1 days;

        c.curve = AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: 0.9e18,
            initialRateAtTarget: stethAPRma90 * 9 / 10 / int256(365 days),
            minRateAtTarget: 0.001 ether / int256(365 days),
            maxRateAtTarget: 2 * stethAPRma90 / int256(365 days),
            maxBorrowRate: 2 * uint256(stethAPRma90) / 365 days
        });
    }

    function getActivationMotionConfig() public pure override returns (ActivationMotionConfig memory a) {
        a.pauser = 0x604B13eD638663AA0C1eEF0c3482e51f228BA2E1;
        a.steward = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E;
        a.enableSettlement = true;
    }

    function getOrDeployPriceOracle() internal override returns (address) {
        return _deployProxy(address(new WstEthRateOracle(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0)), "");
    }

    function getDeployment() internal pure override returns (MarketDeploymentRecord memory d) {
        d.deployedBlock = 26406479;
        d.oracle = 0x20a078F9940dC05C46De4153D1bCbd54D2b5b151;
        d.guardianSignals = 0xc8a8CBBF4c55980F85332fD8470DF0fC52d690aC;
        d.controller = 0xCF1B266d320CA9c0d4e13eF2C46465962F040e88;
        d.vault = 0xd8765FA896be3D30A49B9a7d95453E34E2c7A056;
        d.irmConfig = 0x6076f89f5Cd68c526C73eA1F730d9ce8f05301a6;
    }
}
