// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {CollateralActivationConfig} from "../../../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../../../src/types/SettlementTypes.sol";
import {UsdyNavOracle} from "../../../../src/oracle/UsdyNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../../../src/oracle/TrailingAnchorOracleBase.sol";
import {ActivationMotionConfig, MarketDeployConfig} from "../../DeployMarketBase.s.sol";
import {DeployTrailingAnchorMarketBase} from "../../DeployTrailingAnchorMarketBase.s.sol";

/// @notice Draft for review: the oracle's working defaults, and the WETH/wstETH market's parameters with its amounts
///         in USD at ETH $1,704, rounded up to 2.5, 5, 7.5 or 10 × 10^n.
contract DeployUsdcUsdyMainnet is DeployTrailingAnchorMarketBase {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDY = 0x96F6eF951840721AdBF46Ac996b59E0235CB985C;
    /// @dev Ondo's `RWADynamicOracle` for USDY.
    address internal constant ONDO_USDY_ORACLE = 0xA0219AA5B31e65Bc920B5b6DFb8EdF0988121De0;

    function getDeployConfig() public pure override returns (MarketDeployConfig memory c) {
        // Draft: the APR of the collateral's NAV over 90 days sets the rates, as the stETH APR does on WETH/wstETH.
        int256 navAPR90d = 0.0363444748933325 ether; // Ondo's USDY price, 2026-08-24 to 2026-11-22

        c.guardianGroup = keccak256("usdc-usdy");

        c.market.loanToken = USDC;
        c.market.collateralToken = USDY;
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

        c.wrapper.name = "Lido Lend USDC (USDY)";
        c.wrapper.symbol = "lendUSDCUSDY";

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
        // Draft: the seed range is about 1% around 1.1540 at block 26466654 (2026-11-22). Set it from the source on
        // the deploy day.
        oracle = _deployTrailingAnchorOracle({
            implementation: address(
                new UsdyNavOracle({source: ONDO_USDY_ORACLE, loanToken: USDC, collateralToken: USDY})
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
            seedMinPrice: 1.142e18,
            seedMaxPrice: 1.166e18
        });
    }
}
