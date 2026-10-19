// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EventsLib} from "@lido-lend/src/libraries/EventsLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

/// @notice Every owner-facade lever the EasyTrack executor holds, driven executor -> facade -> target against the
///         deployed core and controller of one market, with the effect read back and, where the lever changes
///         behaviour, the behaviour exercised. Totals are asserted as deltas, so the suite holds on a market that
///         already carries positions.
abstract contract GovernanceForkBase is ForkMarketStack {
    using MarketActions for Market;

    ILidoLendOwner internal facade;
    address internal executor;
    address internal STRANGER;

    constructor(string memory role) ForkMarketStack(role) {}

    function setUp() public {
        _fork();
        _bindRole();
        facade = _facade();
        executor = _executor();
        LENDER = _freshActor(deployed, "governance.lender");
        BORROWER = _freshActor(deployed, "governance.borrower");
        STRANGER = _freshActor(deployed, "governance.stranger");
    }

    // ---
    // SUPPLY CAP
    // ---

    /// @dev A cap set `X` above the live total leaves exactly `X` of headroom on both entry paths, a deposit of
    ///      exactly `X` passes, and the headroom is then zero.
    function test_supplyCap_depositAtCapPasses_headroomZero() public {
        uint256 headroom = _nonRoundAmount();
        uint256 cap = deployed.core.market(deployed.id).totalSupplyAssets + headroom;

        vm.expectEmit(true, true, true, true, address(deployed.controller));
        emit ILidoLendMarketController.SupplyCapSet(cap, address(facade));
        vm.prank(executor);
        facade.setMarketSupplyCap(deployed.id, cap);

        assertEq(LidoLendMarketController(address(deployed.controller)).supplyCap(), cap, "cap stored");
        assertEq(deployed.controller.maxDeposit(), headroom, "controller headroom is the gap to the cap");
        assertEq(deployed.vault.maxDeposit(LENDER), headroom, "vault defers to the controller");

        deal(address(deployed.loanToken), LENDER, headroom);
        market.vaultDeposit(LENDER, headroom);

        assertEq(deployed.controller.maxDeposit(), 0, "at the cap the headroom is zero");
    }

    function testRevert_supplyCap_coreSupplyOneUnitOverCap() public {
        uint256 headroom = _nonRoundAmount();
        uint256 totalBefore = deployed.core.market(deployed.id).totalSupplyAssets;
        uint256 cap = totalBefore + headroom;
        _setSupplyCap(deployed, cap);

        deal(address(deployed.loanToken), LENDER, headroom + 1);
        _approve(address(deployed.loanToken), LENDER, address(deployed.core), headroom + 1);
        vm.prank(LENDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILidoLendMarketController.SupplyCapExceeded.selector, cap, totalBefore + headroom + 1
            )
        );
        deployed.core.supply(deployed.params, headroom + 1, 0, LENDER, "");
    }

    function testRevert_supplyCap_vaultDepositOneUnitOverCap_maxGuard() public {
        uint256 headroom = _nonRoundAmount();
        _setSupplyCap(deployed, deployed.core.market(deployed.id).totalSupplyAssets + headroom);

        deal(address(deployed.loanToken), LENDER, headroom + 1);
        _approve(address(deployed.loanToken), LENDER, address(deployed.vault), headroom + 1);
        vm.prank(LENDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, LENDER, headroom + 1, headroom
            )
        );
        deployed.vault.deposit(headroom + 1, LENDER);
    }

    function test_supplyCap_resetToZero_liftsCap() public {
        uint256 headroom = _nonRoundAmount();
        _setSupplyCap(deployed, deployed.core.market(deployed.id).totalSupplyAssets + headroom);
        _setSupplyCap(deployed, 0);

        assertEq(deployed.controller.maxDeposit(), type(uint256).max, "zero cap means unlimited");
        deal(address(deployed.loanToken), LENDER, headroom + 1);
        market.vaultDeposit(LENDER, headroom + 1);
    }

    // ---
    // INSTANT ACTIVATION
    // ---

    /// @dev The grant is keyed on the supply CALLER: with it, a supply for the borrower lands active at once;
    ///      after the revoke, the same caller's next supply enters the timer.
    function test_setInstantActivation_viaFacade_grantThenRevoke() public {
        address caller = _freshActor(deployed, "governance.instantCaller");
        deal(address(deployed.collateralToken), caller, 2 * lot);

        _setInstantActivation(deployed, caller, true);
        market.supplyCollateralInstant(caller, BORROWER, lot);
        assertEq(deployed.controller.positionOf(BORROWER).active, lot, "granted caller's supply is active at once");

        _setInstantActivation(deployed, caller, false);
        market.supplyCollateralOnBehalf(caller, BORROWER, lot);
        assertEq(deployed.controller.positionOf(BORROWER).activating, lot, "revoked caller's supply enters the timer");
    }

    // ---
    // SETTLEMENT CONFIG
    // ---

    /// @dev Raising the absolute slice floor to a third of the debt puts it above the other two policy terms (a
    ///      percent of debt, a one-point LTV step), so it becomes THE root cut the controller quotes; restoring
    ///      the config restores the old quote. The quote is the prospective one (`queueRootSliceAssets`), so the
    ///      test does not depend on who heads the queue.
    function test_setSettlementConfig_viaFacade_changesRootQuote_thenRestored() public {
        _seedLenderAndBorrower();
        SettlementConfig memory before = deployed.controller.settlementConfig();
        uint256 quoteBefore = deployed.controller.positionOf(BORROWER).queueRootSliceAssets;

        SettlementConfig memory raised = deployed.controller.settlementConfig(); // a second read, so no aliasing
        raised.sliceFloorAssets = uint96(deployed.controller.positionOf(BORROWER).debtAssets / 3);
        _setSettlementConfig(raised);
        assertEq(
            deployed.controller.positionOf(BORROWER).queueRootSliceAssets,
            raised.sliceFloorAssets,
            "root quote is the raised absolute floor"
        );

        _setSettlementConfig(before);
        assertEq(deployed.controller.positionOf(BORROWER).queueRootSliceAssets, quoteBefore, "old quote restored");
    }

    // ---
    // ACTIVATION CONFIG
    // ---

    /// @dev The facade can LOOSEN activation (the dashboard cannot): one second off the delay floor lowers the
    ///      quoted delay at the live inflow, recomputed from the delay formula.
    function test_setCollateralActivationConfig_viaFacade_canLoosen_thenRestored() public {
        CollateralActivationConfig memory before = deployed.controller.collateralActivationConfig();
        uint256 quotedBefore = deployed.controller.currentActivationDelay(0);

        CollateralActivationConfig memory loosened = deployed.controller.collateralActivationConfig(); // no aliasing
        loosened.minActivationDelay = before.minActivationDelay - 1;
        _setActivationConfig(loosened);
        assertEq(
            deployed.controller.currentActivationDelay(0),
            _expectedDelay(loosened, deployed.controller.currentInflow()),
            "quoted delay follows the loosened floor"
        );

        _setActivationConfig(before);
        assertEq(deployed.controller.currentActivationDelay(0), quotedBefore, "old delay restored");
    }

    // ---
    // FEES
    // ---

    /// @dev With a fee and recipient set through the facade, the next accrual mints fee shares to the recipient;
    ///      restoring the fee proves the reverse direction.
    function test_setFee_viaFacade_feeAccruesToRecipient_thenRestored() public {
        _seedLenderAndBorrower();
        address recipient = _freshActor(deployed, "governance.feeRecipient");
        uint256 feeBefore = deployed.core.market(deployed.id).fee;
        uint256 fee = 0.1e18;
        require(fee != feeBefore, "Governance: pick a fee the market does not already carry");

        vm.startPrank(executor);
        facade.setFeeRecipient(recipient);
        vm.expectEmit(true, true, true, true, address(deployed.core));
        emit EventsLib.SetFee(deployed.id, fee);
        facade.setFee(deployed.params, fee);
        vm.stopPrank();
        assertEq(deployed.core.market(deployed.id).fee, fee, "fee stored on the core");

        vm.warp(block.timestamp + 30 days);
        deployed.core.accrueInterest(deployed.params);
        assertGt(deployed.core.position(deployed.id, recipient).supplyShares, 0, "recipient minted fee shares");

        vm.prank(executor);
        facade.setFee(deployed.params, feeBefore);
        assertEq(deployed.core.market(deployed.id).fee, feeBefore, "old fee restored");
    }

    function test_setFeeRecipient_viaFacade_roundTrip() public {
        address before = deployed.core.feeRecipient();
        address recipient = _freshActor(deployed, "governance.feeRecipient");

        vm.expectEmit(true, true, true, true, address(deployed.core));
        emit EventsLib.SetFeeRecipient(recipient);
        vm.prank(executor);
        facade.setFeeRecipient(recipient);
        assertEq(deployed.core.feeRecipient(), recipient, "recipient stored on the core");

        vm.prank(executor);
        facade.setFeeRecipient(before);
        assertEq(deployed.core.feeRecipient(), before, "old recipient restored");
    }

    // ---
    // REFUSALS: the facade gates on its role, and the facade is the only route to the controller
    // ---

    function testRevert_facade_setMarketSupplyCap_byStranger() public {
        bytes32 role = facade.MARKET_MANAGER_ROLE();
        vm.prank(STRANGER);
        vm.expectRevert(_unauthorized(STRANGER, role));
        facade.setMarketSupplyCap(deployed.id, 1);
    }

    function testRevert_controller_setSupplyCap_byExecutorDirectly() public {
        bytes32 role = deployed.controller.MANAGER_ROLE();
        vm.prank(executor);
        vm.expectRevert(_unauthorized(executor, role));
        LidoLendMarketController(address(deployed.controller)).setSupplyCap(1);
    }

    // ---
    // HELPERS
    // ---

    function _setSettlementConfig(SettlementConfig memory config) internal {
        vm.prank(executor);
        facade.setMarketSettlementConfig(deployed.id, config);
    }

    function _setActivationConfig(CollateralActivationConfig memory config) internal {
        vm.prank(executor);
        facade.setMarketCollateralActivationConfig(deployed.id, config);
    }

    /// @dev Three whole loan tokens and a non-round tail, so no rounding cancels against a round fixture.
    function _nonRoundAmount() internal view returns (uint256) {
        return 3 * _loanUnit(deployed) + 4_321;
    }

    /// @dev The activation delay formula: the floor, plus the span scaled by inflow over its reference.
    function _expectedDelay(CollateralActivationConfig memory cfg, uint256 inflow) internal pure returns (uint256) {
        if (inflow >= cfg.maxDelayInflow) return cfg.maxActivationDelay;
        return cfg.minActivationDelay
            + Math.mulDiv(cfg.maxActivationDelay - cfg.minActivationDelay, inflow, cfg.maxDelayInflow);
    }
}

contract GovernanceWethWstethForkTest is GovernanceForkBase("weth-wsteth") {}

contract GovernanceUsdyUsdtForkTest is GovernanceForkBase("usdy-usdt") {}
