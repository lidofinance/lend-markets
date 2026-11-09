// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {RecordedDeployment} from "./RecordedDeployment.sol";

/// @notice Exports the validated deployment snapshot for off-chain verification tools.
contract ExportDeployment is Script {
    string private constant SCHEMA =
        "DeploymentSnapshot(ProtocolAddresses protocol,CircuitBreakerPlan circuitBreakerPlan,uint256 bookLifetime,address weth,address wstEth,address stEth,address usdt,address usdy,address ondoOracle,address usdyBlocklist,ExitBookAddresses books,address bookPauser,address bundler,address generalAdapter,address vaultAdapter,RecordedMarket[] markets)AdaptiveCurveParams(int256 curveSteepness,int256 adjustmentSpeed,int256 targetUtilization,int256 initialRateAtTarget,int256 minRateAtTarget,int256 maxRateAtTarget,uint256 maxBorrowRate)CircuitBreakerPlan(uint256 minPauseDuration,uint256 maxPauseDuration,uint256 minHeartbeatInterval,uint256 maxHeartbeatInterval,uint256 initialPauseDuration,uint256 initialHeartbeatInterval)CollateralActivationConfig(uint40 minActivationDelay,uint40 maxActivationDelay,uint128 maxDelayInflow,uint128 minDepositAmount,uint40 activatingLockDuration,uint128 minActivationAmount,uint40 maxGuardiansQuorumDelay,uint40 delayPerStrike,uint40 delayPerSuspect)ExitBookAddresses(uint256 chainId,address morpho,address erc4626)ERC4626WrapperSpec(string name,string symbol)GuardianSpec(address[] guardians,uint256 quorum,uint256 suspectWindow)MarketSpec(address loanToken,address collateralToken,address oracle,uint256 lltv,address guardianSignals,uint256 supplyCap,CollateralActivationConfig activationConfig,SettlementConfig settlementConfig)MarketDeploymentResult(bytes32 id,MarketParams params,address controller,address vault,address guardianSignals,address irmConfig)MarketParams(address loanToken,address collateralToken,address oracle,address irm,uint256 lltv)MarketPlan(string name,bytes32 guardianGroup,MarketSpec market,ERC4626WrapperSpec wrapper,GuardianSpec committee,AdaptiveCurveParams curve)PriceFeedRecord(address wstEth,address usdySource,address feed,address loanToken,address collateralToken,uint256 minPrice,uint256 maxPrice)ProtocolAddresses(uint256 chainId,address core,address factory,address ownerFacade,address irmRouter,address adaptiveCurveIrm,address irmConfigFactory,address dashboard,address circuitBreaker,address resealManager,address agent,address executor)RecordedMarket(uint256 deployedBlock,PriceFeedRecord priceFeed,string priceFeedKind,string role,MarketPlan plan,MarketDeploymentResult contracts,address vaultV2,address adapter)SettlementConfig(uint16 sliceFloorBps,uint96 sliceFloorAssets,uint96 fullCutBelowCollateral,uint16 ltvStepBps)";

    function run(string memory runName) external view returns (string memory json) {
        return vm.serializeJsonType(SCHEMA, abi.encode(RecordedDeployment.load(runName)));
    }
}
