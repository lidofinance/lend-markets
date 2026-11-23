// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {CollateralActivationConfig} from "../../../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../../../src/types/SettlementTypes.sol";
import {CentrifugeNavOracle} from "../../../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../../../src/oracle/TrailingAnchorOracleBase.sol";
import {ActivationMotionConfig, MarketDeployConfig} from "../../DeployMarketBase.s.sol";
import {DeployTrailingAnchorMarketBase} from "../../DeployTrailingAnchorMarketBase.s.sol";

/// @notice Draft for review: the oracle's working defaults, and the WETH/wstETH market's parameters with its amounts
///         in USD at ETH $1,704, rounded up to 2.5, 5, 7.5 or 10 × 10^n.
contract DeployUsdcDejtrsyMainnet is DeployTrailingAnchorMarketBase {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DEJTRSY = 0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72;
    /// @dev The Centrifuge v3.1 Spoke.
    address internal constant SPOKE = 0xEC3582fcDc34078a4B7a8c75a5a3AE46f48525aB;
    /// @dev deJTRSY's pool and share class on the Spoke.
    uint64 internal constant POOL_ID = 281474976710660;
    bytes16 internal constant SHARE_CLASS_ID = 0x00010000000000040000000000000001;

    function getDeployConfig() public pure override returns (MarketDeployConfig memory c) {
        // Draft: the APR of the collateral's NAV over 90 days sets the rates, as the stETH APR does on WETH/wstETH.
        int256 navAPR90d = 0.0324938300508362 ether; // the Spoke's deJTRSY price, 2026-08-21 to 2026-11-19

        c.guardianGroup = keccak256("centrifuge"); // one guardian registry for the markets on Centrifuge tokens

        c.market.loanToken = USDC;
        c.market.collateralToken = DEJTRSY;
        c.market.lltv = 0.98e18;
        c.market.supplyCap = 10_000_000e6;
        c.market.activationConfig = CollateralActivationConfig({
            minActivationDelay: 2 hours,
            maxActivationDelay: 8 hours,
            maxDelayInflow: 2_500_000 ether,
            minDepositAmount: 2_500 ether,
            activatingLockDuration: 0,
            minActivationAmount: 25_000 ether,
            maxGuardiansQuorumDelay: 48 hours,
            delayPerStrike: 12 hours,
            delayPerSuspect: 12 hours
        });
        c.market.settlementConfig = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 25_000e6, fullCutBelowCollateral: 25_000 ether, ltvStepBps: 100
        });

        c.wrapper.name = "Lido Lend USDC (deJTRSY)";
        c.wrapper.symbol = "lendUSDCdeJTRSY";

        c.committee.guardians = new address[](1);
        c.committee.guardians[0] = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E; // Risk Steward
        c.committee.quorum = 1;
        c.committee.suspectWindow = 1 days;

        c.curve = AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: 0.95e18,
            initialRateAtTarget: navAPR90d * 9 / 10 / int256(365 days),
            minRateAtTarget: 0.001 ether / int256(365 days),
            maxRateAtTarget: 2 * navAPR90d / int256(365 days),
            maxBorrowRate: 2 * uint256(navAPR90d) / 365 days
        });
    }

    function getActivationMotionConfig() public pure override returns (ActivationMotionConfig memory a) {
        a.pauser = 0x604B13eD638663AA0C1eEF0c3482e51f228BA2E1;
        a.steward = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E; // Risk Steward
        a.enableSettlement = true;
    }

    function getOrDeployPriceOracle() internal override returns (address oracle) {
        // Draft: the seed range is about 1% around 1.0432 at block 26466654 (2026-11-22). Set it from the source on
        // the deploy day.
        oracle = _deployTrailingAnchorOracle({
            implementation: address(
                new CentrifugeNavOracle({
                    spoke: SPOKE,
                    poolId: POOL_ID,
                    scId: SHARE_CLASS_ID,
                    maxPriceAge: 7 days,
                    loanToken: USDC,
                    collateralToken: DEJTRSY
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
            seedMinPrice: 1.032e18,
            seedMaxPrice: 1.054e18
        });
    }
}
