// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {LidoLendTrailingAnchorOracleAdapter} from "../../src/oracle/LidoLendTrailingAnchorOracleAdapter.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";

import {MockERC20} from "../setup/Mocks.sol";
import {UsdyNavOracleFixture} from "../setup/NavOracleFixtures.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

/// @notice `LidoLendTrailingAnchorOracleAdapter` over a real `UsdyNavOracle` behind its proxy.
contract LidoLendTrailingAnchorOracleAdapterTest is UsdyNavOracleFixture {
    uint256 internal constant START = 1_760_000_000;
    uint256 internal constant MAX_PRICING_SUSPENSION = 7 days;

    address internal admin = makeAddr("admin");
    address internal executor = makeAddr("executor");

    LidoLendTrailingAnchorOracleAdapter internal adapter;
    TrailingAnchorOracleBase internal oracle;
    TrailingAnchorOracleBase internal unmanagedOracle;

    function setUp() public {
        vm.warp(START);
        _setUpSource();
        source.setCurrentPrice(1.1e18);
        address loan = address(new MockERC20("USD Coin", "USDC", 6));
        adapter = new LidoLendTrailingAnchorOracleAdapter(executor);
        oracle = _deployOracle(loan, admin, TrailingAnchorOracleModel.initializeCall(admin));
        unmanagedOracle = _deployOracle(loan, admin, TrailingAnchorOracleModel.initializeCall(admin));
        bytes32 managerRole = oracle.MANAGER_ROLE();
        vm.prank(admin);
        oracle.grantRole(managerRole, address(adapter));
    }

    function test_constructor_storesTheExecutor() public view {
        assertEq(adapter.EVM_SCRIPT_EXECUTOR(), executor);
    }

    function testRevert_constructor_zeroExecutor() public {
        vm.expectRevert(LidoLendTrailingAnchorOracleAdapter.ZeroAddress.selector);
        new LidoLendTrailingAnchorOracleAdapter(address(0));
    }

    function test_setParameters_storesTheParametersInTheOracle() public {
        TrailingAnchorOracleBase.Parameters memory parameters = _changedParameters();
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.ParametersSet(parameters);
        vm.prank(executor);
        adapter.setParameters(address(oracle), parameters);

        assertEq(oracle.maxPriceAboveAnchor(), parameters.maxPriceAboveAnchor);
        assertEq(oracle.maxPriceBelowAnchor(), parameters.maxPriceBelowAnchor);
        assertEq(oracle.maxAnchorContinuousRiseRate(), parameters.maxAnchorContinuousRiseRate);
        assertEq(oracle.maxAnchorContinuousFallRate(), parameters.maxAnchorContinuousFallRate);
        assertEq(oracle.maxAnchorBelowBase(), parameters.maxAnchorBelowBase);
        assertEq(oracle.maxAnchorAboveBase(), parameters.maxAnchorAboveBase);
        assertEq(oracle.reanchorDelay(), parameters.reanchorDelay);
        assertEq(oracle.reanchorWindow(), parameters.reanchorWindow);
    }

    function test_setPricingResumesAt_storesTheTimeInTheOracle() public {
        uint40 resumesAt = uint40(START + MAX_PRICING_SUSPENSION);
        vm.expectEmit(address(oracle));
        emit TrailingAnchorOracleBase.PricingResumesAtSet(resumesAt);
        vm.prank(executor);
        adapter.setPricingResumesAt(address(oracle), resumesAt);

        assertEq(oracle.pricingResumesAt(), resumesAt);
    }

    function testFuzz_onlyTheExecutorCanCall(address caller) public {
        vm.assume(caller != executor);
        TrailingAnchorOracleBase.Parameters memory parameters = _changedParameters();

        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(LidoLendTrailingAnchorOracleAdapter.Unauthorized.selector, caller));
        adapter.setParameters(address(oracle), parameters);
        vm.expectRevert(abi.encodeWithSelector(LidoLendTrailingAnchorOracleAdapter.Unauthorized.selector, caller));
        adapter.setPricingResumesAt(address(oracle), uint40(START + 1));
        vm.stopPrank();
    }

    function testRevert_oracleWithoutTheRole_refusesTheCalls() public {
        bytes memory missingRole = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, address(adapter), unmanagedOracle.MANAGER_ROLE()
        );
        TrailingAnchorOracleBase.Parameters memory parameters = _changedParameters();

        vm.startPrank(executor);
        vm.expectRevert(missingRole);
        adapter.setParameters(address(unmanagedOracle), parameters);
        vm.expectRevert(missingRole);
        adapter.setPricingResumesAt(address(unmanagedOracle), uint40(START + 1));
        vm.stopPrank();
    }

    function testRevert_oracleChecks_reachTheExecutor() public {
        TrailingAnchorOracleBase.Parameters memory parameters = _changedParameters();
        parameters.reanchorWindow = 0;
        uint40 resumesAt = uint40(START + MAX_PRICING_SUSPENSION + 1);

        vm.startPrank(executor);
        vm.expectRevert(TrailingAnchorOracleBase.ReanchorWindowIsZero.selector);
        adapter.setParameters(address(oracle), parameters);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.InvalidPricingResumesAt.selector, resumesAt));
        adapter.setPricingResumesAt(address(oracle), resumesAt);
        vm.stopPrank();
    }

    /// @dev The defaults with each field changed, so a call that drops or swaps a field fails the checks.
    function _changedParameters() private pure returns (TrailingAnchorOracleBase.Parameters memory parameters) {
        parameters = TrailingAnchorOracleModel.defaultParameters();
        parameters.maxPriceAboveAnchor += 1e14;
        parameters.maxPriceBelowAnchor += 2e14;
        parameters.maxAnchorContinuousRiseRate -= 3e14;
        parameters.maxAnchorContinuousFallRate -= 4e14;
        parameters.maxAnchorBelowBase += 5e14;
        parameters.maxAnchorAboveBase += 6e14;
        parameters.reanchorDelay -= 7 minutes;
        parameters.reanchorWindow += 8 minutes;
    }
}
