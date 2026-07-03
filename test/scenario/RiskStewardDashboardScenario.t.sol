// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function wrap(uint256 stETHAmount) external returns (uint256);
}

/// @notice End-to-end scenario for `RiskStewardDashboard` over a freshly deployed real core + controller on a
///         mainnet fork. Unlike `RiskStewardDashboard.t.sol` (mock controller, isolating the tighten-only
///         guard), this drives the levers against the live controller: the dashboard holds `MANAGER_ROLE`,
///         resolves the controller from the core by market id, and its writes land in the controller's real
///         config and instant-activation state, still gated by the controller's own bound validation.
contract RiskStewardDashboardScenarioTest is Test, LidoLendDeployer {
    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IStETH internal constant STETH = IStETH(STETH_ADDRESS);
    IWstETH internal constant WSTETH = IWstETH(WSTETH_ADDRESS);

    uint256 internal constant LLTV = 0.8e18;

    address internal constant STEWARD = address(0x57E);
    address internal constant BORROWER = address(0x2000);

    struct Ctx {
        RiskStewardDashboard dashboard;
        ILidoLendMarketController controller;
        ILidoLend core;
        Id id;
        MarketParams marketParams;
    }

    /// @notice The dashboard drives every important lever against the live controller: it raises the activation
    ///         delays and the activating lock (read back from the controller's real config), then revokes
    ///         instant activation and shows a fresh deposit re-enters the timer instead of going straight active.
    function test_dashboard_drivesRealController_endToEnd() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        Ctx memory c = _deployWithDashboard();

        CollateralActivationConfig memory cfg0 = c.controller.collateralActivationConfig();
        assertEq(cfg0.minActivationDelay, 10 minutes, "deploy floor");
        assertEq(cfg0.maxActivationDelay, 2 hours, "deploy cap");
        assertEq(cfg0.activatingLockAmount, 0, "deploy lock amount");

        // 1) Raise the activation delays through the dashboard; the live controller stores them.
        vm.prank(STEWARD);
        c.dashboard.increaseActivationDelays(c.id, 20 minutes, 3 hours);

        CollateralActivationConfig memory cfg1 = c.controller.collateralActivationConfig();
        assertEq(cfg1.minActivationDelay, 20 minutes, "floor raised on the live controller");
        assertEq(cfg1.maxActivationDelay, 3 hours, "cap raised on the live controller");
        assertEq(cfg1.minActivationAmount, cfg0.minActivationAmount, "unrelated field preserved by the RMW");
        assertEq(cfg1.maxDelayInflow, cfg0.maxDelayInflow, "unrelated field preserved by the RMW");

        // 2) Raise the activating lock through the dashboard.
        vm.prank(STEWARD);
        c.dashboard.increaseActivatingLock(c.id, 5 ether, 1 hours);

        CollateralActivationConfig memory cfg2 = c.controller.collateralActivationConfig();
        assertEq(cfg2.activatingLockAmount, 5 ether, "lock amount raised on the live controller");
        assertEq(cfg2.activatingLockDuration, 1 hours, "lock duration raised on the live controller");
        assertEq(cfg2.minActivationDelay, 20 minutes, "delays from step 1 preserved");

        // 3) Revoke instant activation through the dashboard; the live controller's behavior flips.
        c.controller.grantInstantActivation(BORROWER);
        uint256 col = _mintWstETH(c.core, BORROWER, 18 ether);
        vm.prank(BORROWER);
        c.core.supplyCollateral(c.marketParams, col, BORROWER, "");
        _assertCollateralState(c.controller, BORROWER, col, 0, 0); // instant: straight to active

        vm.prank(STEWARD);
        c.dashboard.revokeInstantActivation(c.id, BORROWER);
        assertFalse(c.controller.hasInstantActivation(BORROWER), "instant revoked on the live controller");

        uint256 more = _mintWstETH(c.core, BORROWER, 15 ether);
        vm.prank(BORROWER);
        c.core.supplyCollateral(c.marketParams, more, BORROWER, "");
        _assertCollateralState(c.controller, BORROWER, col, more, 0); // fresh deposit now enters the timer
    }

    /// @notice The dashboard's tighten-only guard blocks lowering a delay below the controller's current value.
    function testRevert_dashboard_tightenOnlyBlocksLowering() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        Ctx memory c = _deployWithDashboard();

        vm.prank(STEWARD);
        vm.expectRevert(IRiskStewardDashboard.NotTightened.selector);
        c.dashboard.increaseActivationDelays(c.id, 5 minutes, 3 hours); // 5 min < deploy floor 10 min
    }

    /// @notice The dashboard only adds the direction guard: a raise that is in-direction but past the
    ///         controller's own bound is still rejected by the controller's validator, not the dashboard.
    function testRevert_dashboard_controllerStillBoundsTheRaise() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        Ctx memory c = _deployWithDashboard();

        vm.prank(STEWARD);
        vm.expectRevert(CollateralActivationLib.MaxActivationDelayExceeded.selector);
        c.dashboard.increaseActivationDelays(c.id, 20 minutes, 8 days); // raise, but above MAX_DELAY_DURATION
    }

    /// @notice A non-steward cannot pull a lever.
    function testRevert_dashboard_nonStewardBlocked() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        Ctx memory c = _deployWithDashboard();

        vm.prank(address(0xBAD));
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        c.dashboard.increaseActivationDelays(c.id, 20 minutes, 3 hours);
    }

    /// @notice A market id the core has no controller for is rejected, even for an appointed steward.
    function testRevert_dashboard_unknownMarket() public {
        vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required");
        Ctx memory c = _deployWithDashboard();

        Id bogus = Id.wrap(bytes32(uint256(0xDEAD)));
        c.dashboard.addMarketSteward(bogus, STEWARD); // appointed, but the core has no controller for `bogus`

        vm.prank(STEWARD);
        vm.expectRevert(abi.encodeWithSelector(IRiskStewardDashboard.UnknownMarket.selector, bogus));
        c.dashboard.increaseActivationDelays(bogus, 20 minutes, 3 hours);
    }

    // ---
    // HARNESS
    // ---

    function _deployWithDashboard() internal returns (Ctx memory c) {
        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: WETH_ADDRESS,
                collateralToken: WSTETH_ADDRESS,
                oracleSource: WSTETH_ADDRESS,
                lltv: LLTV,
                enableSettlement: false,
                activation: CollateralActivationConfigParams({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    activatingLockAmount: 0,
                    activatingLockDuration: 0,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: 10 ether,
                    maxGuardiansQuorumDelay: 0,
                    delayPerStrike: 0,
                    delayPerSuspect: 0
                }),
                settlementConfig: SettlementConfigParams({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                suspectWindow: 0,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );

        c.core = ILidoLend(d.core);
        c.controller = ILidoLendMarketController(d.controllerProxy);
        c.id = d.marketId;
        c.marketParams = d.params;

        // `address(this)` holds DEFAULT_ADMIN / MANAGER_ADMIN / MANAGER from the deployer bootstrap, so it can
        // grant the dashboard MANAGER_ROLE (the role the levers call through) and appoint the steward.
        c.dashboard = new RiskStewardDashboard(address(this), c.core);
        c.controller.grantRole(c.controller.MANAGER_ROLE(), address(c.dashboard));
        c.dashboard.grantRole(c.dashboard.STEWARD_ADMIN_ROLE(), address(this));
        c.dashboard.addMarketSteward(c.id, STEWARD);
    }

    function _mintWstETH(ILidoLend market, address user, uint256 ethAmount) internal returns (uint256) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        STETH.submit{value: ethAmount}(address(0));

        uint256 stETHAmount = STETH.balanceOf(user);
        vm.prank(user);
        STETH.approve(WSTETH_ADDRESS, stETHAmount);
        vm.prank(user);
        uint256 wstETHAmount = WSTETH.wrap(stETHAmount);
        vm.prank(user);
        WSTETH.approve(address(market), type(uint256).max);
        return wstETHAmount;
    }

    function _assertCollateralState(
        ILidoLendMarketController controller,
        address borrower,
        uint256 matured,
        uint256 activating,
        uint256 dust
    ) internal view {
        ILidoLendMarketController.BorrowerPosition memory pv = controller.positionOf(borrower);
        assertEq(pv.active, matured, "matured (active) collateral");
        assertEq(pv.activating, activating, "maturing (activating) collateral");
        assertEq(pv.dust, dust, "dust collateral");
    }

    function _hasMainnetLidoContracts() internal view returns (bool) {
        return block.chainid == 1 && WETH_ADDRESS.code.length != 0 && STETH_ADDRESS.code.length != 0
            && WSTETH_ADDRESS.code.length != 0;
    }
}
