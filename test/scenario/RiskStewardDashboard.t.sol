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

    /// @dev Pins open finding I-M005: a governance motion writes a whole config fixed at its creation, so it undoes
    ///      every steward tightening made inside its window. A fix changes this outcome; update this test with the fix.
    function test_IM005_absoluteConfigMotion_undoesInWindowStewardTightening() public {
        Market storage market = protocol.markets[0];
        CollateralActivationConfig memory created = market.controller.collateralActivationConfig();
        CollateralActivationConfig memory motionConfig = created;
        motionConfig.maxDelayInflow = 20_000 ether;
        uint256 createdDelay = market.controller.currentActivationDelay(10 ether);

        vm.startPrank(STEWARD);
        dashboard.increaseActivationDelays(market.id, 30 minutes, 6 hours, 7 hours);
        dashboard.increaseActivatingLockDuration(market.id, 2 days);
        dashboard.increaseMinDepositAmount(market.id, 5 ether);
        vm.stopPrank();
        uint256 tightenedDelay = market.controller.currentActivationDelay(10 ether);
        assertGt(tightenedDelay, createdDelay, "setup: the steward tightened");

        market.setActivationConfig(motionConfig);

        CollateralActivationConfig memory enacted = market.controller.collateralActivationConfig();
        assertEq(enacted.minActivationDelay, created.minActivationDelay, "min delay undone");
        assertEq(enacted.maxActivationDelay, created.maxActivationDelay, "max delay undone");
        assertEq(enacted.maxGuardiansQuorumDelay, created.maxGuardiansQuorumDelay, "quorum fallback undone");
        assertEq(enacted.activatingLockDuration, created.activatingLockDuration, "lock undone");
        assertEq(enacted.minDepositAmount, created.minDepositAmount, "min deposit undone");
        assertLt(market.controller.currentActivationDelay(10 ether), tightenedDelay, "deposit delay loosened");
    }
}
