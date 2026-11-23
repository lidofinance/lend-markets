// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {CollateralActivationConfig} from "../../../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../../../src/types/SettlementTypes.sol";
import {CentrifugeNavOracle} from "../../../../src/oracle/CentrifugeNavOracle.sol";
import {CentrifugeMocks} from "../CentrifugeMocks.sol";
import {TrailingAnchorOracleBase} from "../../../../src/oracle/TrailingAnchorOracleBase.sol";
import {ActivationMotionConfig, MarketDeployConfig} from "../../DeployMarketBase.s.sol";
import {DeployTrailingAnchorMarketBase} from "../../DeployTrailingAnchorMarketBase.s.sol";

/// @notice USDC/JTRSY over the trailing anchor oracle on the Hoodi mock Spoke: the Hoodi WETH/wstETH market's
///         parameters with its amounts in USD at ETH $1,704, rounded up to 2.5, 5, 7.5 or 10 × 10^n.
contract DeployUsdcJtrsyHoodi is DeployTrailingAnchorMarketBase {
    address internal constant USDC = 0x97bb030B93faF4684eAC76bA0bf3be5ec7140F36; // hUSDC

    function getDeployConfig() public pure override returns (MarketDeployConfig memory c) {
        // The APR of the collateral's NAV over 90 days sets the rates, as the stETH APR does on WETH/wstETH; the Hoodi
        // source's price is fixed, so it is the mainnet JTRSY over 2026-08-21 to 2026-11-19.
        int256 navAPR90d = 0.0324992886213873 ether;

        c.guardianGroup = keccak256("shared");

        c.market.loanToken = USDC;
        c.market.collateralToken = CentrifugeMocks.jtrsy();
        c.market.guardianSignals = 0xF46eB3bf7783825B0ffb5f532C148A261Ec518a9; // shared by the Hoodi markets
        c.market.lltv = 0.95e18;
        c.market.supplyCap = 25_000_000e6;
        c.market.activationConfig = CollateralActivationConfig({
            minActivationDelay: 10 minutes,
            maxActivationDelay: 2 hours,
            maxDelayInflow: 25_000_000e6,
            minDepositAmount: 2_500e6,
            activatingLockDuration: 0,
            minActivationAmount: 25_000e6,
            maxGuardiansQuorumDelay: 36 hours,
            delayPerStrike: 2 hours,
            delayPerSuspect: 2 hours
        });
        c.market.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 25_000e6, fullCutBelowCollateral: 25_000e6, ltvStepBps: 100
        });

        c.wrapper.name = "Lido USDC/JTRSY Vault (hoodi)";
        c.wrapper.symbol = "hoodiUSDC-JTRSY";

        c.committee.guardians = new address[](2);
        c.committee.guardians[0] = 0xe9bFDBB915b734D10aA53B3838371F67a7704102; // Hoodi guardian EOA
        c.committee.guardians[1] = 0xA6b2dbCCE7895347A62b4409d29bA7ce29A74655; // Hoodi multisig, the backup
        c.committee.quorum = 1;
        c.committee.suspectWindow = 1 days;

        c.curve = AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: 0.9e18,
            initialRateAtTarget: navAPR90d * 9 / 10 / int256(365 days),
            minRateAtTarget: 0.001 ether / int256(365 days),
            maxRateAtTarget: 2 * navAPR90d / int256(365 days),
            maxBorrowRate: 2 * uint256(navAPR90d) / 365 days
        });
    }

    function getActivationMotionConfig() public pure override returns (ActivationMotionConfig memory a) {
        // The choices of the Hoodi activation motions.
        a.pauser = 0x8223d372898CA8f185F24b5EDA373FDaea16B1c6; // pauser committee
        a.steward = 0xe65b86bB03Bd1B11BF39C6d87060c7A52236988D; // Risk Steward Committee Safe
        a.enableSettlement = true;
    }

    function getOrDeployPriceOracle() internal override returns (address oracle) {
        // The seed range is about 1% around 1.1229, the mock Spoke's JTRSY price.
        oracle = _deployTrailingAnchorOracle({
            implementation: address(
                new CentrifugeNavOracle({
                    spoke: CentrifugeMocks.spoke(),
                    poolId: CentrifugeMocks.JTRSY_POOL,
                    scId: CentrifugeMocks.JTRSY_CLASS,
                    maxPriceAge: 7 days,
                    loanToken: USDC,
                    collateralToken: CentrifugeMocks.jtrsy()
                })
            ),
            parameters: TrailingAnchorOracleBase.Parameters({
                maxPriceAboveAnchor: 0.0005e18,
                maxPriceBelowAnchor: 0.001e18,
                maxAnchorContinuousRiseRate: 0.06e18,
                maxAnchorContinuousFallRate: 0.01e18,
                maxAnchorBelowBase: 0.01e18,
                maxAnchorAboveBase: 0.002e18,
                reanchorDelay: 6 hours,
                reanchorWindow: 1 days
            }),
            seedMinPrice: 1.111e18,
            seedMaxPrice: 1.134e18
        });
    }
}
