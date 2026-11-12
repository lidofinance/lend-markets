// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice The steward dashboard drives coordinated delay changes through a real market controller.
contract RiskStewardDashboardScenarioTest is LidoLendSetup {
    using MarketActions for Market;

    address internal constant STEWARD = address(0x57E);

    RiskStewardDashboard internal dashboard;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.activation.maxGuardiansQuorumDelay = 3 hours;
        _deployProtocol(cfg);

        Market storage market = protocol.markets[0];
        dashboard = new RiskStewardDashboard(address(this), protocol.core);
        dashboard.grantRole(dashboard.STEWARD_ADMIN_ROLE(), address(this));
        dashboard.addMarketSteward(market.id, STEWARD);
        market.controller.grantRole(market.controller.MANAGER_ROLE(), address(dashboard));
    }

    /// @dev Fixed issue: `increaseActivationDelays` reverted on a valid cap increase when the quorum fallback was set.
    ///      Root cause: the old `increaseActivationDelays` wrote the new floor and cap but kept the old
    ///      `maxGuardiansQuorumDelay`. `setConfig` requires a nonzero fallback above the cap, so a cap at or above the
    ///      fallback reverted. Now: `increaseActivationDelays` takes a new `maxGuardiansQuorumDelay` and writes all
    ///      three delays in one config update.
    ///      Same cause: any cap raise that reaches the old fallback, on any market with a nonzero fallback. A steward
    ///      can now raise the fallback with the cap.
    function test_increaseActivationDelays_raisesQuorumFallbackAtomically() public {
        Market storage market = protocol.markets[0];

        vm.prank(STEWARD);
        dashboard.increaseActivationDelays(market.id, 15 minutes, 3 hours, 4 hours);

        CollateralActivationConfig memory cfg = market.controller.collateralActivationConfig();
        assertEq(cfg.minActivationDelay, 15 minutes, "floor raised");
        assertEq(cfg.maxActivationDelay, 3 hours, "cap raised");
        assertEq(cfg.maxGuardiansQuorumDelay, 4 hours, "quorum fallback raised");
    }

    function testRevert_increaseActivationDelays_quorumFallbackMustExceedCap() public {
        Market storage market = protocol.markets[0];

        vm.prank(STEWARD);
        vm.expectRevert(CollateralActivationLib.InvalidMaxGuardiansQuorumDelay.selector);
        dashboard.increaseActivationDelays(market.id, 15 minutes, 3 hours, 3 hours);
    }

    /// @dev A floor above the new cap passes the dashboard tighten-only guard and reverts in the controller with
    ///      `InvalidActivationDelays`. Only a market steward can make this call.
    function testRevert_increaseActivationDelays_floorAboveCap_downstreamError() public {
        Market storage market = protocol.markets[0];
        CollateralActivationConfig memory before = market.controller.collateralActivationConfig();
        uint40 heldCap = before.maxActivationDelay;

        vm.prank(STEWARD);
        vm.expectRevert(CollateralActivationLib.InvalidActivationDelays.selector);
        dashboard.increaseActivationDelays(market.id, heldCap + 1, heldCap, before.maxGuardiansQuorumDelay);
    }

    /// @dev `setCollateralActivationConfig` replaces the whole config, so the last write wins. A manager write of a
    ///      config that was read before a steward tightening undoes that tightening. This test makes the write as
    ///      the market admin. It does not run a governance motion.
    function test_staleWholeConfigWrite_undoesStewardTightening() public {
        Market storage market = protocol.markets[0];
        CollateralActivationConfig memory staleConfig = market.controller.collateralActivationConfig();
        staleConfig.maxDelayInflow = 20_000 ether;
        uint256 delayBefore = market.controller.currentActivationDelay(10 ether);

        vm.startPrank(STEWARD);
        dashboard.increaseActivationDelays(market.id, 30 minutes, 6 hours, 7 hours);
        dashboard.increaseActivatingLockDuration(market.id, 2 days);
        dashboard.increaseMinDepositAmount(market.id, 5 ether);
        vm.stopPrank();
        CollateralActivationConfig memory tightened = market.controller.collateralActivationConfig();
        uint256 tightenedDelay = market.controller.currentActivationDelay(10 ether);
        assertGt(tightenedDelay, delayBefore, "setup: the steward raised the delay");
        assertGt(tightened.activatingLockDuration, staleConfig.activatingLockDuration, "setup: lock raised");
        assertGt(tightened.minDepositAmount, staleConfig.minDepositAmount, "setup: min deposit raised");

        // The helper asserts that the stored config equals `staleConfig`, so no steward value is left.
        market.setActivationConfig(staleConfig);

        assertLt(market.controller.currentActivationDelay(10 ether), tightenedDelay, "deposit delay loosened");
    }
}
