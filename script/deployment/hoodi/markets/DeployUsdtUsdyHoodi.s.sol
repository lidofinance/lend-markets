// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {CollateralActivationConfig} from "../../../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../../../src/types/SettlementTypes.sol";
import {UsdyStableOracle} from "../../../../src/oracle/UsdyStableOracle.sol";
import {
    ActivationMotionConfig,
    DeployMarketBase,
    MarketDeployConfig,
    MarketDeploymentRecord
} from "../../DeployMarketBase.s.sol";

contract DeployUsdtUsdyHoodi is DeployMarketBase {
    function getDeployConfig() public pure override returns (MarketDeployConfig memory c) {
        // Testnet value. As on mainnet, the initial rate is 0.9 APR and the maximum 2 APR, so 20/9 of the initial rate.
        int256 initialApr = 0.032 ether;

        c.guardianGroup = keccak256("shared");

        c.market.loanToken = 0x64f1904d1b419c6889BDf3238e31A138E258eA68; // USDT
        c.market.collateralToken = 0xE22a71d42632aBAC08F44FCbd41221A8D8C56972; // USDY
        c.market.guardianSignals = 0xF46eB3bf7783825B0ffb5f532C148A261Ec518a9; // shared by the Hoodi markets
        c.market.lltv = 0.95e18;
        c.market.supplyCap = 25_000_000e6;
        c.market.activationConfig = CollateralActivationConfig({
            minActivationDelay: 10 minutes,
            maxActivationDelay: 2 hours,
            maxDelayInflow: 25_000_000 ether,
            minDepositAmount: 2_500 ether,
            activatingLockDuration: 0,
            minActivationAmount: 25_000 ether,
            maxGuardiansQuorumDelay: 36 hours,
            delayPerStrike: 2 hours,
            delayPerSuspect: 2 hours
        });
        c.market.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 25_000 ether, ltvStepBps: 100
        });

        c.wrapper.name = "Lido USDT/USDY Vault (hoodi)";
        c.wrapper.symbol = "hoodiUSDT-USDY";

        c.committee.guardians = new address[](2);
        c.committee.guardians[0] = 0xe9bFDBB915b734D10aA53B3838371F67a7704102; // Hoodi guardian EOA
        c.committee.guardians[1] = 0xA6b2dbCCE7895347A62b4409d29bA7ce29A74655; // Hoodi multisig, the backup
        c.committee.quorum = 1;
        c.committee.suspectWindow = 1 days;

        c.curve = AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: 0.95e18,
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
        return _deployProxy(
            address(new UsdyStableOracle(0xd6237FecDF9C1D9b023A5205C17549E3037EeEec, 1e23, 1e26)),
            abi.encodeCall(
                UsdyStableOracle.initialize,
                (0xeC3785b13b21c226D66B5bC2E82BB2f4226f715e, 0x64f1904d1b419c6889BDf3238e31A138E258eA68)
            )
        );
    }

    function getDeployment() internal pure override returns (MarketDeploymentRecord memory d) {
        d.deployedBlock = 3641155;
        d.oracle = 0x53D670DD018A09Af8BfBAdD9817E383fDdf2fb27;
        d.guardianSignals = 0xF46eB3bf7783825B0ffb5f532C148A261Ec518a9;
        d.controller = 0xa868D126231D32CE6e930c59E9a279f13b0D2BFe;
        d.vault = 0x823D546AD911fbC6305588448eae9EC794E7AC29;
        d.irmConfig = 0x611401E778143B4f7BAA816F49FF5A4A35cf2101;
    }
}
