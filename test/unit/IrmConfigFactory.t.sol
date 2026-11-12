// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {AdaptiveCurveConfig} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/IrmConfigFactory.sol";

/// @notice Address behaviour of `IrmConfigFactory` that the deploy scripts rely on.
contract IrmConfigFactoryTest is Test {
    IrmConfigFactory internal factory;

    function setUp() external {
        factory = new IrmConfigFactory();
    }

    /// @dev Known issue: a call by another party before the reviewed call moves the reviewed IRM config away from the
    ///      address that `AddMarket` records. The recorded address then holds the other party's params.
    ///      Root cause: `IrmConfigFactory` deploys configs with `CREATE`, so each address follows a factory nonce that
    ///      any caller can advance. `AddMarket.run` writes the config address from the simulation into the market
    ///      artifact and does not check it after broadcast.
    ///      Same cause: a front-run through `getOrDeployAdaptiveCurveConfig` or `getOrDeployLinearKinkConfig` with any
    ///      new params. Two `AddMarket` runs that overlap race the same way.
    ///      This test shows the factory part only: the address that a simulation predicts goes to the first caller.
    ///      It does not run `AddMarket`, because a unit test cannot separate simulation from broadcast.
    function test_strangerDeploysFirst_reviewedConfigMovesToNextCreateAddress() external {
        AdaptiveCurveParams memory reviewed = _curve(0.9 ether);
        AdaptiveCurveParams memory stranger = _curve(0.8 ether);
        uint64 nonce = vm.getNonce(address(factory));
        address predicted = vm.computeCreateAddress(address(factory), nonce);

        vm.prank(makeAddr("stranger"));
        assertEq(factory.getOrDeployAdaptiveCurveConfig(stranger), predicted, "stranger takes predicted address");
        address actual = factory.getOrDeployAdaptiveCurveConfig(reviewed);

        assertEq(actual, vm.computeCreateAddress(address(factory), nonce + 1), "reviewed config at next nonce");
        assertEq(
            keccak256(abi.encode(AdaptiveCurveConfig(predicted).getCurveParams())),
            keccak256(abi.encode(stranger)),
            "predicted address holds stranger params"
        );
        assertEq(
            keccak256(abi.encode(AdaptiveCurveConfig(actual).getCurveParams())),
            keccak256(abi.encode(reviewed)),
            "reviewed params at moved address"
        );
        assertEq(factory.getOrDeployAdaptiveCurveConfig(reviewed), actual, "a repeated reviewed call moves nothing");
    }

    function _curve(int256 targetUtilization) private pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: 4 ether,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: targetUtilization,
            initialRateAtTarget: 0.04 ether / int256(365 days),
            minRateAtTarget: 0.001 ether / int256(365 days),
            maxRateAtTarget: 2 ether / int256(365 days),
            maxBorrowRate: 0
        });
    }
}
