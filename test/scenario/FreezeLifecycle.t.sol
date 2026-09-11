// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice What a frozen market still allows. Freeze is the risk-reducing lever a steward can pull alone, and
///         it is deliberately narrow: it blocks new borrowing and stops collateral maturing, but leaves every
///         exit and every loss-realising path open. The existing freeze coverage only pins the two things it
///         blocks, so this suite pins what it must NOT block — a lender settling, a keeper liquidating, and a
///         borrower topping up collateral to defend a position that can still be liquidated under freeze.
contract FreezeLifecycleTest is LidoLendSetup {
    using MarketActions for Market;

    address internal lender;
    address internal borrower;
    address internal keeper;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 300 ether);
        keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender in, borrower at `borrowBps` of its LLTV capacity, collateral matured.
    function _seed(uint256 collat, uint256 borrowBps) internal returns (uint256 lenderShares) {
        Market storage m = _m();
        lenderShares = m.vaultDeposit(lender, 1000 ether);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();
        uint256 maxBorrow = ((collat * oraclePrice) / 1e36) * 80 / 100;
        m.borrow(borrower, (maxBorrow * borrowBps) / 10_000);
    }

    // ── Freeze does not block loss-realising or exit paths ──

    function test_FrozenMarket_SettleStillProceeds() public {
        Market storage m = _m();
        uint256 shares = _seed(100 ether, 9900);
        m.setSettlementLtv(borrower, 0.5e18);
        m.freeze();

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        (uint256 burned, uint256 seized,) = m.settle(lender, shares / 4, borrowers, lender);

        assertGt(burned, 0, "settle must proceed while frozen");
        assertGt(seized, 0, "settle must pay collateral while frozen");
    }

    function test_FrozenMarket_FallbackExitStillProceeds() public {
        Market storage m = _m();
        uint256 shares = _seed(100 ether, 9900);
        m.setSettlementLtv(borrower, 0.5e18);

        uint256 liquid = m.controller.maxWithdrawableAssets(address(m.vault));
        assertLt(liquid, m.vault.previewRedeem(shares), "setup: request must reach the settle leg");

        m.freeze();
        (uint256 burned,, uint256 seized,) = m.fallbackExit(lender, shares, lender, 0);

        assertGt(burned, 0, "fallback exit must proceed while frozen");
        assertGt(seized, 0, "settle leg must run while frozen");
    }

    function test_FrozenMarket_LiquidationStillProceeds() public {
        Market storage m = _m();
        _seed(100 ether, 9900);
        m.freeze();
        m.distress(borrower, 0.95e18); // above the 0.8 LLTV, still solvent

        uint256 seize = m.core.position(m.id, borrower).collateral / 10;
        (uint256 seized,) = m.liquidate(keeper, borrower, seize, 0);
        assertEq(seized, seize, "liquidation must proceed while frozen");
    }

    function test_FrozenMarket_RepayAndDebtFreeWithdrawStillProceed() public {
        Market storage m = _m();
        _seed(100 ether, 5000);
        m.freeze();

        _fund(m.loanToken, borrower, 1000 ether);
        m.repay(borrower, m.core.position(m.id, borrower).borrowShares);
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "debt cleared while frozen");

        m.withdrawCollateral(borrower, 100 ether, borrower);
    }

    // ── Freeze does block borrowing ──

    function testRevert_FrozenMarket_BorrowBlocked() public {
        Market storage m = _m();
        _seed(100 ether, 5000);
        m.freeze();

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.MarketIsFrozen.selector);
        m.core.borrow(m.params, 1 ether, 0, borrower, borrower);
    }

    function testRevert_FrozenMarket_DebtBearingCollateralWithdrawBlocked() public {
        Market storage m = _m();
        _seed(100 ether, 5000);
        m.freeze();
        assertGt(m.core.position(m.id, borrower).borrowShares, 0, "setup: borrower must carry debt");

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.MarketIsFrozen.selector);
        m.core.withdrawCollateral(m.params, 1 ether, borrower, borrower);
    }

    // ── Freeze defers maturation ──

    /// @dev Isolates the deferral rather than inferring it from a blocked borrow. A debt-free withdrawal is
    ///      allowed under freeze, and the all-or-nothing rule applies only to collateral that is still
    ///      inactive. So a partial withdrawal after the delay has elapsed succeeds if and only if the lot
    ///      matured — it reverts while frozen, and the identical call passes once unfrozen.
    function test_FrozenMarket_LotDoesNotMatureUntilUnfreeze() public {
        Market storage m = _m();
        m.supplyCollateral(borrower, 100 ether);

        m.freeze();
        vm.warp(block.timestamp + m.config.activation.maxActivationDelay + 1);

        ILidoLendMarketController.BorrowerPosition memory frozenPos = m.controller.positionOf(borrower);
        assertEq(frozenPos.activating, 100 ether, "setup: lot is still recorded as activating");

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralActivationLib.InactiveCollateralNotCleared.selector, 50 ether, 100 ether)
        );
        m.core.withdrawCollateral(m.params, 50 ether, borrower, borrower);

        m.unfreeze();

        // The same partial draw now succeeds. Called on the core directly rather than through the action
        // helper, whose bucket assertions assume no lot matures inside the call — here one does, which is
        // exactly the behaviour under test.
        uint256 receivedBefore = m.collateralToken.balanceOf(borrower);
        vm.prank(borrower);
        m.core.withdrawCollateral(m.params, 50 ether, borrower, borrower);

        assertEq(m.collateralToken.balanceOf(borrower), receivedBefore + 50 ether, "partial draw paid out");
        assertEq(m.controller.positionOf(borrower).activating, 0, "lot matured once unfrozen");
        assertEq(m.core.position(m.id, borrower).collateral, 50 ether, "remaining collateral is now active");
    }

    // ── Freeze leaves collateral supply open, so a borrower can defend ──

    /// @dev Liquidation stays live under freeze, so a borrower must still be able to add collateral. The
    ///      supply is booked as a new activating lot and nothing matures while frozen.
    function test_FrozenMarket_CollateralSupplyBooksLotWithoutMaturing() public {
        Market storage m = _m();
        _seed(100 ether, 5000);
        m.freeze();

        m.supplyCollateral(borrower, 100 ether);
        assertEq(m.controller.positionOf(borrower).activating, 100 ether, "top-up booked as activating");

        vm.warp(block.timestamp + m.config.activation.maxActivationDelay + 1);
        m.supplyCollateral(borrower, 100 ether);
        assertEq(m.controller.positionOf(borrower).activating, 200 ether, "still nothing matures while frozen");
    }

    function test_FrozenMarket_InstantActivationStillLandsActive() public {
        Market storage m = _m();
        _seed(100 ether, 5000);

        address helper = _actor("instantHelper");
        _fund(m.collateralToken, helper, 100 ether);
        m.setInstantActivation(helper, true);
        m.freeze();

        uint256 activatingBefore = m.controller.positionOf(borrower).activating;
        m.supplyCollateralInstant(helper, borrower, 100 ether);
        assertEq(
            m.controller.positionOf(borrower).activating,
            activatingBefore,
            "instant supply must not enter the timer, frozen or not"
        );
    }
}
