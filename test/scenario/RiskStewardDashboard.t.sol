// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice The steward dashboard drives coordinated delay changes through a real market controller.
contract RiskStewardDashboardScenarioTest is LidoLendSetup {
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
}
