// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function wrap(uint256 stETHAmount) external returns (uint256);
}

/// @notice End-to-end scenario for the ALREADY-DEPLOYED `RiskStewardDashboard` driving the live `weth-wsteth`
///         controller (bound via {ForkStack}, never re-deployed). The suite drives the tighten-only levers
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
    BoundMarket internal m;

    RiskStewardDashboard internal dashboard;

    IStETH internal STETH;
    IWstETH internal WSTETH;

    // The EasyTrack executor: the live holder of the dashboard's STEWARD_ADMIN_ROLE (deploy-wired).
    address internal executor;
    // A steward appointed through the real executor path in `setUp`.
    address internal STEWARD;

    function setUp() public {
        _fork();
        string memory market_ = _marketForRole("weth-wsteth");
        if (bytes(market_).length == 0) return; // not applicable to this deployment
        m = _bindMarket(market_);
        _pokeAccrue(m); // fold in pending interest so live-config reads and per-borrower asserts are exact
        _grantSelfManager(m); // lets this contract call the manager-gated `grantInstantActivation` directly

        dashboard = RiskStewardDashboard(_protocol("risk_steward_dashboard"));

        STETH = IStETH(_ext("stEth"));
        WSTETH = IWstETH(address(m.collateralToken));

        // Production wiring, asserted not arranged: the deploy grants the dashboard the controller's
        // MANAGER_ROLE so its tighten-only levers can write config. A miss is a real deploy-wiring bug.
        require(
            m.controller.hasRole(m.controller.MANAGER_ROLE(), address(dashboard)),
            "RiskStewardDashboardScenario: deployed dashboard is not the controller MANAGER_ROLE holder (deploy wiring bug)"
        );

        // The deploy grants the EasyTrack executor the dashboard's STEWARD_ADMIN_ROLE. Cross-check it holds
        // that role before pranking it, then appoint the test steward through it — the real appointment path,
        // not a test-minted self-grant. `_executor(m)` resolves the executor as the IRM router's manager,
        // which the deploy assigns to the same EVMScriptExecutor.
        executor = _executor(m);
        require(
            dashboard.hasRole(dashboard.STEWARD_ADMIN_ROLE(), executor),
            "RiskStewardDashboardScenario: EasyTrack executor does not hold the dashboard STEWARD_ADMIN_ROLE (deploy wiring bug)"
        );

        STEWARD = makeAddr("riskStewardDashboard.steward");
        vm.prank(executor);
        dashboard.addMarketSteward(m.id, STEWARD);
    }

    /// @notice The dashboard drives every important lever against the live controller: it raises the activation
    ///         delays and the activating lock by a tighten-only delta over the LIVE config (read back from the
    ///         controller), then revokes instant activation and shows a fresh deposit re-enters the timer
    ///         instead of going straight active.
    function test_dashboard_drivesRealController_endToEnd() public {
        CollateralActivationConfig memory cfg0 = m.controller.collateralActivationConfig();

        // 1) Raise the activation delays through the dashboard by a tighten-only delta; the live controller
        //    stores them. `+1 hours` on a market whose live cap is hours keeps the raise inside MAX_DELAY_DURATION.
        uint40 newMin = cfg0.minActivationDelay + 10 minutes;
        uint40 newMax = cfg0.maxActivationDelay + 1 hours;
        vm.prank(STEWARD);
        dashboard.increaseActivationDelays(m.id, newMin, newMax, cfg0.maxGuardiansQuorumDelay);

        CollateralActivationConfig memory cfg1 = m.controller.collateralActivationConfig();
        assertEq(cfg1.minActivationDelay, newMin, "floor raised on the live controller");
        assertEq(cfg1.maxActivationDelay, newMax, "cap raised on the live controller");
        assertEq(cfg1.minActivationAmount, cfg0.minActivationAmount, "unrelated field preserved by the RMW");
        assertEq(cfg1.maxDelayInflow, cfg0.maxDelayInflow, "unrelated field preserved by the RMW");

        // 2) Raise the activating lock through the dashboard by a tighten-only delta.
        uint128 newAmount = cfg0.activatingLockAmount + 5 ether;
        uint40 newDuration = cfg0.activatingLockDuration + 1 hours;
        vm.prank(STEWARD);
        dashboard.increaseActivatingLock(m.id, newAmount, newDuration);

        CollateralActivationConfig memory cfg2 = m.controller.collateralActivationConfig();
        assertEq(cfg2.activatingLockAmount, newAmount, "lock amount raised on the live controller");
        assertEq(cfg2.activatingLockDuration, newDuration, "lock duration raised on the live controller");
        assertEq(cfg2.minActivationDelay, newMin, "delays from step 1 preserved");

        // 3) Revoke instant activation through the dashboard; the live controller's behavior flips. The borrower
        //    is fresh and market-clean, so its per-borrower activation buckets are asserted in isolation. Size
        //    collateral from the LIVE dust threshold (wstETH < ETH across the wrap, so mint 3x the threshold in
        //    ETH to clear it with margin).
        address borrower = _freshActor(m, "riskStewardDashboard.borrower");
        uint256 ethIn = 3 * uint256(cfg0.minActivationAmount);

        m.controller.setInstantActivation(borrower, true);
        uint256 col = _mintWstETH(borrower, ethIn);
        require(col >= uint256(cfg0.minActivationAmount), "collateral must clear the live dust threshold");
        vm.prank(borrower);
        m.core.supplyCollateral(m.params, col, borrower, "");
        _assertCollateralState(borrower, col, 0, 0); // instant: straight to active

        vm.prank(STEWARD);
        dashboard.revokeInstantActivation(m.id, borrower);
        assertFalse(m.controller.hasInstantActivation(borrower), "instant revoked on the live controller");

        uint256 more = _mintWstETH(borrower, ethIn);
        require(more >= uint256(cfg0.minActivationAmount), "top-up must clear the live dust threshold");
        vm.prank(borrower);
        m.core.supplyCollateral(m.params, more, borrower, "");
        _assertCollateralState(borrower, col, more, 0); // fresh deposit now enters the timer
    }

    /// @notice The dashboard's tighten-only guard blocks lowering a delay below the controller's current value.
    function testRevert_dashboard_tightenOnlyBlocksLowering() public {
        CollateralActivationConfig memory cfg0 = m.controller.collateralActivationConfig();
        // Need a positive live floor to have something to lower below.
        require(cfg0.minActivationDelay > 0, "RiskStewardDashboardScenario: live min activation delay must be positive");

        vm.prank(STEWARD);
        vm.expectRevert(IRiskStewardDashboard.NotTightened.selector);
        // Hold the cap, drop the floor by one second: a lowering, so the tighten-only guard rejects it.
        dashboard.increaseActivationDelays(
            m.id, cfg0.minActivationDelay - 1, cfg0.maxActivationDelay, cfg0.maxGuardiansQuorumDelay
        );
    }

    /// @notice The dashboard only adds the direction guard: a raise that is in-direction but past the
    ///         controller's own bound is still rejected by the controller's validator, not the dashboard.
    function testRevert_dashboard_controllerStillBoundsTheRaise() public {
        CollateralActivationConfig memory cfg0 = m.controller.collateralActivationConfig();

        vm.prank(STEWARD);
        vm.expectRevert(CollateralActivationLib.MaxActivationDelayExceeded.selector);
        // In-direction (hold the floor, raise the cap) but above MAX_DELAY_DURATION (7 days): passes the
        // tighten-only guard, then the controller's bound validation rejects it.
        dashboard.increaseActivationDelays(m.id, cfg0.minActivationDelay, 8 days, cfg0.maxGuardiansQuorumDelay);
    }

    /// @notice A non-steward cannot pull a lever.
    function testRevert_dashboard_nonStewardBlocked() public {
        address stranger = makeAddr("riskStewardDashboard.stranger");

        vm.prank(stranger);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.increaseActivationDelays(m.id, 20 minutes, 3 hours, 0);
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

    /// @notice An appointed steward freezes the already-deployed controller through the live dashboard wiring.
    function test_dashboard_freezesRealController() public {
        vm.prank(STEWARD);
        dashboard.freezeMarket(m.id);

        assertTrue(m.controller.isFrozen(), "dashboard froze the live controller");
    }

    // ---
    // HELPERS
    // ---

    function _mintWstETH(address user, uint256 ethAmount) internal returns (uint256) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        STETH.submit{value: ethAmount}(address(0));

        uint256 stETHAmount = STETH.balanceOf(user);
        vm.prank(user);
        STETH.approve(address(WSTETH), stETHAmount);
        vm.prank(user);
        uint256 wstETHAmount = WSTETH.wrap(stETHAmount);
        vm.prank(user);
        WSTETH.approve(address(m.core), type(uint256).max);
        return wstETHAmount;
    }

    function _assertCollateralState(address borrower, uint256 active, uint256 activating, uint256 dust) internal view {
        ILidoLendMarketController.BorrowerPosition memory pv = m.controller.positionOf(borrower);
        assertEq(pv.active, active, "matured (active) collateral");
        assertEq(pv.activating, activating, "maturing (activating) collateral");
        assertEq(pv.dust, dust, "dust collateral");
    }
}
