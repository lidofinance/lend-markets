// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice End-to-end scenario for the ALREADY-DEPLOYED `RiskStewardDashboard` driving the bound market's
///         controller (see {ForkStack}). The suite drives the tighten-only levers
///         against the production controller: raising activation delays and the activating lock, revoking
///         instant activation, and the controller's own bound validation still gating every write.
///
///         Production wiring is ASSERTED, not arranged: the deploy already grants the dashboard the
///         controller's `MANAGER_ROLE` (so its levers can write config) and grants the EasyTrack executor the
///         dashboard's `STEWARD_ADMIN_ROLE` (so it can appoint stewards). `setUp` cross-checks both against the
///         live stack and fails loudly on a mismatch — a wiring miss is a real deployment bug, not something
///         the test papers over with a fresh grant.
///
///         State-robustness contract: the deployed market may already carry supply/borrow and its activation
///         config is read live (never assumed to equal the deploy defaults). Delay/lock levers drive
///         tighten-only DELTAS off the captured live config; collateral is a fresh, market-clean borrower sized
///         from the live dust threshold, so its per-borrower activation buckets are asserted in isolation.
contract RiskStewardDashboardScenarioTest is ForkStack {
    RiskStewardDashboard internal dashboard;

    // The EasyTrack executor: the live holder of the dashboard's STEWARD_ADMIN_ROLE (deploy-wired).
    address internal executor;
    // A steward appointed through the real executor path in `setUp`.
    address internal STEWARD;

    function setUp() public {
        _setUpTarget();
        _accrueInterest(); // fold in pending interest so live-config reads and per-borrower asserts are exact

        dashboard = RiskStewardDashboard(protocol.dashboard);

        // Production wiring, asserted not arranged: the deploy grants the dashboard the controller's
        // MANAGER_ROLE so its tighten-only levers can write config. A miss is a real deploy-wiring bug.
        require(
            market.controller.hasRole(market.controller.MANAGER_ROLE(), address(dashboard)),
            "RiskStewardDashboardScenario: deployed dashboard is not the controller MANAGER_ROLE holder (deploy wiring bug)"
        );

        // The deploy grants the EasyTrack executor the dashboard's STEWARD_ADMIN_ROLE. Cross-check it holds
        // that role before pranking it, then appoint the test steward through it — the real appointment path,
        // not a test-minted self-grant. `_executor()` is the EVMScriptExecutor the run recorded.
        executor = _executor();
        require(
            dashboard.hasRole(dashboard.STEWARD_ADMIN_ROLE(), executor),
            "RiskStewardDashboardScenario: EasyTrack executor does not hold the dashboard STEWARD_ADMIN_ROLE (deploy wiring bug)"
        );

        STEWARD = makeAddr("riskStewardDashboard.steward");
        vm.prank(executor);
        dashboard.addMarketSteward(market.id, STEWARD);
    }

    /// @notice The dashboard drives every important lever against the live controller: it raises the activation
    ///         delays and the activating lock by a tighten-only delta over the LIVE config (read back from the
    ///         controller), then revokes instant activation and shows a fresh deposit re-enters the timer
    ///         instead of going straight active.
    function test_dashboard_drivesRealController_endToEnd() public {
        CollateralActivationConfig memory cfg0 = market.controller.collateralActivationConfig();

        // 1) Raise the activation delays through the dashboard by a tighten-only delta; the live controller
        //    stores them. `+1 hours` on a market whose live cap is hours keeps the raise inside MAX_DELAY_DURATION.
        uint40 newMin = cfg0.minActivationDelay + 10 minutes;
        uint40 newMax = cfg0.maxActivationDelay + 1 hours;
        vm.prank(STEWARD);
        dashboard.increaseActivationDelays(market.id, newMin, newMax, cfg0.maxGuardiansQuorumDelay);

        CollateralActivationConfig memory cfg1 = market.controller.collateralActivationConfig();
        assertEq(cfg1.minActivationDelay, newMin, "floor raised on the live controller");
        assertEq(cfg1.maxActivationDelay, newMax, "cap raised on the live controller");
        assertEq(cfg1.minActivationAmount, cfg0.minActivationAmount, "unrelated field preserved by the RMW");
        assertEq(cfg1.maxDelayInflow, cfg0.maxDelayInflow, "unrelated field preserved by the RMW");

        // 2) Raise the activating-lock duration through the dashboard by a tighten-only delta.
        uint40 newDuration = cfg0.activatingLockDuration + 1 hours;
        vm.prank(STEWARD);
        dashboard.increaseActivatingLockDuration(market.id, newDuration);

        CollateralActivationConfig memory cfg2 = market.controller.collateralActivationConfig();
        assertEq(cfg2.activatingLockDuration, newDuration, "lock duration raised on the live controller");
        assertEq(cfg2.minActivationDelay, newMin, "delays from step 1 preserved");

        // 3) Revoke instant activation through the dashboard; the live controller's behavior flips. The borrower
        //    is fresh and market-clean, so its per-borrower activation buckets are asserted in isolation. Size
        //    collateral from the LIVE dust threshold, three times it.
        address borrower = _freshActor(market, "riskStewardDashboard.borrower");
        uint256 col = 3 * uint256(cfg0.minActivationAmount);

        _setInstantActivation(borrower, true);
        collateralIssuer.dealCollateral(borrower, 2 * col);
        _approve(address(market.collateralToken), borrower, address(market.core), type(uint256).max);
        vm.prank(borrower);
        market.core.supplyCollateral(market.params, col, borrower, "");
        _assertCollateralState(borrower, col, 0, 0); // instant: straight to active

        vm.prank(STEWARD);
        dashboard.revokeInstantActivation(market.id, borrower);
        assertFalse(market.controller.hasInstantActivation(borrower), "instant revoked on the live controller");

        uint256 more = col;
        vm.prank(borrower);
        market.core.supplyCollateral(market.params, more, borrower, "");
        _assertCollateralState(borrower, col, more, 0); // fresh deposit now enters the timer
    }

    /// @notice The dashboard's tighten-only guard blocks lowering a delay below the controller's current value.
    function testRevert_dashboard_tightenOnlyBlocksLowering() public {
        CollateralActivationConfig memory cfg0 = market.controller.collateralActivationConfig();
        // Need a positive live floor to have something to lower below.
        require(cfg0.minActivationDelay > 0, "RiskStewardDashboardScenario: live min activation delay must be positive");

        vm.prank(STEWARD);
        vm.expectRevert(IRiskStewardDashboard.NotTightened.selector);
        // Hold the cap, drop the floor by one second: a lowering, so the tighten-only guard rejects it.
        dashboard.increaseActivationDelays(
            market.id, cfg0.minActivationDelay - 1, cfg0.maxActivationDelay, cfg0.maxGuardiansQuorumDelay
        );
    }

    /// @notice The dashboard only adds the direction guard: a raise that is in-direction but past the
    ///         controller's own bound is still rejected by the controller's validator, not the dashboard.
    function testRevert_dashboard_controllerStillBoundsTheRaise() public {
        CollateralActivationConfig memory cfg0 = market.controller.collateralActivationConfig();

        vm.prank(STEWARD);
        vm.expectRevert(CollateralActivationLib.MaxActivationDelayExceeded.selector);
        // In-direction (hold the floor, raise the cap) but above MAX_DELAY_DURATION (7 days): passes the
        // tighten-only guard, then the controller's bound validation rejects it.
        dashboard.increaseActivationDelays(market.id, cfg0.minActivationDelay, 8 days, cfg0.maxGuardiansQuorumDelay);
    }

    /// @notice A non-steward cannot pull a lever.
    function testRevert_dashboard_nonStewardBlocked() public {
        address stranger = makeAddr("riskStewardDashboard.stranger");

        vm.prank(stranger);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.increaseActivationDelays(market.id, 20 minutes, 3 hours, 0);
    }

    /// @notice A market id the core has no controller for is rejected, even for an appointed steward.
    function testRevert_dashboard_unknownMarket() public {
        Id bogus = Id.wrap(bytes32(uint256(0xDEAD)));
        vm.prank(executor);
        dashboard.addMarketSteward(bogus, STEWARD); // appointed, but the core has no controller for `bogus`

        vm.prank(STEWARD);
        vm.expectRevert(abi.encodeWithSelector(IRiskStewardDashboard.UnknownMarket.selector, bogus));
        dashboard.increaseActivationDelays(bogus, 20 minutes, 3 hours, 0);
    }

    /// @notice An appointed steward freezes the already-deployed controller through the live dashboard wiring,
    ///         and the owner facade — the only `UNFREEZER_ROLE` holder — undoes it. The starting state is
    ///         asserted, not assumed: without that, a deployment that is already frozen would pass this test
    ///         while the freeze call did nothing.
    function test_dashboard_freezesRealController_facadeUnfreezes() public {
        assertFalse(market.controller.isFrozen(), "setup: the bound market starts live");

        vm.prank(STEWARD);
        dashboard.freezeMarket(market.id);
        assertTrue(market.controller.isFrozen(), "dashboard froze the live controller");

        // The steward can freeze but cannot unfreeze: the two directions sit on different roles, and only the
        // facade holds `UNFREEZER_ROLE`.
        _unfreeze();
        assertFalse(market.controller.isFrozen(), "facade unfroze the live controller");
    }

    // ---
    // HELPERS
    // ---

    function _assertCollateralState(address borrower, uint256 active, uint256 activating, uint256 dust) internal view {
        ILidoLendMarketController.BorrowerPosition memory pv = market.controller.positionOf(borrower);
        assertEq(pv.active, active, "matured (active) collateral");
        assertEq(pv.activating, activating, "maturing (activating) collateral");
        assertEq(pv.dust, dust, "dust collateral");
    }
}
