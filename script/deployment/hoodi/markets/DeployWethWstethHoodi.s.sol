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

contract DeployWethWstethHoodi is DeployMarketBase {
    function getDeployConfig() public pure override returns (MarketDeployConfig memory c) {
        // Testnet value. As on mainnet, the initial rate is 0.9 APR and the maximum 2 APR, so 20/9 of the initial rate.
        int256 initialApr = 0.0225 ether;

        c.guardianGroup = keccak256("shared");

        c.market.loanToken = 0xE69a5c6dd88cA798b93c3C92fc50c51Fd5305eB4; // WETH
        c.market.collateralToken = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4; // wstETH
        c.market.guardianSignals = 0xF46eB3bf7783825B0ffb5f532C148A261Ec518a9; // shared by the Hoodi markets
        c.market.lltv = 0.95e18;
        c.market.supplyCap = 10_000 ether;
        c.market.activationConfig = CollateralActivationConfig({
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
        c.market.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 10 ether, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
        });

        c.wrapper.name = "Lido wstETH/WETH Vault (hoodi)";
        c.wrapper.symbol = "hoodiWSTETH-WETH";

        c.committee.guardians = new address[](2);
        c.committee.guardians[0] = 0xe9bFDBB915b734D10aA53B3838371F67a7704102; // Hoodi guardian EOA
        c.committee.guardians[1] = 0xA6b2dbCCE7895347A62b4409d29bA7ce29A74655; // Hoodi multisig, the backup
        c.committee.quorum = 1;
        c.committee.suspectWindow = 1 days;

        c.curve = AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: 0.9e18,
            initialRateAtTarget: initialApr / int256(365 days),
            minRateAtTarget: 0.001 ether / int256(365 days),
            maxRateAtTarget: initialApr / int256(365 days) * 20 / 9,
            maxBorrowRate: uint256(initialApr) / 365 days * 20 / 9
        });
    }

    function getActivationMotionConfig() public pure override returns (ActivationMotionConfig memory a) {
        // The choices of the Hoodi activation motions.
        a.pauser = 0x8223d372898CA8f185F24b5EDA373FDaea16B1c6; // pauser committee
        a.steward = 0xe65b86bB03Bd1B11BF39C6d87060c7A52236988D; // Risk Steward Committee Safe
        a.enableSettlement = true;
    }

    function getOrDeployPriceOracle() internal override returns (address) {
        return _deployProxy(address(new WstEthRateOracle(0x7E99eE3C66636DE415D2d7C880938F2f40f94De4)), "");
    }

    function getDeployment() internal pure override returns (MarketDeploymentRecord memory d) {
        d.deployedBlock = 3641152;
        d.oracle = 0x2ae747342805632E4909c1230AC2124937074545;
        d.guardianSignals = 0xF46eB3bf7783825B0ffb5f532C148A261Ec518a9;
        d.controller = 0x567032366c3Ccc84Af77647fffb3e7a00B8b3008;
        d.vault = 0xA5597eF950A9BAA5e00f7138E0fdC9F8bA5a43eE;
        d.irmConfig = 0xe01a9F7FB41B7557f00Db1B485bb51cda1A2a003;
    }
}
