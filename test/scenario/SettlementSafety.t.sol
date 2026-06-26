// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementQueueLib} from "../../src/libs/SettlementQueueLib.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice L2 controller-safety scenarios that the per-method suites left to the integration layer: the
///         settle bad-debt gate (the controller's O(1) root health-check discharging the duty the core skips
///         on settle), the collateral floor on a debt-bearing withdrawal, and the per-borrower settlement
///         LTV opt-in.
contract SettlementSafetyTest is LidoLendSetup {
    using MarketActions for Market;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _seed(uint256 collat, uint256 borrowBps)
        internal
        returns (address lender, address borrower, uint256 shares)
    {
        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        shares = m.vaultDeposit(lender, 1000 ether);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();
        uint256 maxBorrow = collat * oraclePrice / 1e36 * 80 / 100;
        m.borrow(borrower, maxBorrow * borrowBps / 10_000);
    }

    /// @dev The settle hook reverts if the queue ROOT (riskiest position) carries bad debt — the controller
    ///      doing the health check the core omits on settle. A hard crash makes the sole borrower's root
    ///      position underwater, so any settle against the market is rejected.
    function testRevert_settle_whenRootIsBadDebt() public {
        Market storage m = _m();
        (address lender, address borrower, uint256 shares) = _seed(100 ether, 9900); // ~99% of LLTV-max

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 2); // collateral value now below the debt
        m.accrueInterest();

        address[] memory bs = new address[](1);
        bs[0] = borrower;
        vm.prank(lender);
        vm.expectRevert(ILidoLendMarketController.SettlementBadDebt.selector);
        m.vault.settle(shares, bs, lender, lender);
    }

    /// @dev Withdrawing collateral under open debt may not leave a raw balance below `minActivationAmount`
    ///      (10 ether) — it would strand un-reactivatable dust backing a loan.
    function testRevert_withdrawCollateral_belowFloorWithOpenDebt() public {
        Market storage m = _m();
        (, address borrower,) = _seed(100 ether, 100); // tiny debt -> lots of health headroom

        // Leaving 5 ether (< the 10 ether floor) while debt is open trips the floor, not the health gate.
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.CollateralFloorBreached.selector);
        m.core.withdrawCollateral(m.params, 95 ether, borrower, borrower);
    }

    /// @dev Pinned from the solvency fuzz: seizing the FULL collateral of a SOLVENT (unhealthy-but-not-
    ///      underwater) position implies repaying more debt than the borrower owes. The controller's liquidate
    ///      hook rejects the over-repay with `PositionAccountingMismatch` before the core underflows.
    function testRevert_liquidate_seizeAllOnSolventPosition_overRepays() public {
        Market storage m = _m();
        (, address borrower,) = _seed(100 ether, 8000); // ~80% of LLTV-max

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 75 / 100); // unhealthy, still solvent (coll > debt)
        m.accrueInterest();

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000_000 ether);
        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.expectRevert(ILidoLendMarketController.PositionAccountingMismatch.selector);
        m.core.liquidate(m.params, borrower, 100 ether, 0, ""); // seize ALL -> over-repay on a solvent position
        vm.stopPrank();
    }

    /// @dev The over-seize revert above is NOT a stuck-position bug: the SAME solvent position liquidates fine
    ///      when the keeper specifies the debt to repay (`repaidShares`) instead of over-seizing. The core
    ///      seizes only the incentivized collateral for that debt and leaves the surplus with the borrower.
    function test_liquidate_solventPosition_byRepaidShares_succeeds() public {
        Market storage m = _m();
        (, address borrower,) = _seed(100 ether, 8000);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 75 / 100); // unhealthy, still solvent
        m.accrueInterest();

        uint256 shares = m.core.position(m.id, borrower).borrowShares;
        uint256 colBefore = m.core.position(m.id, borrower).collateral;

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000_000 ether);
        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        (uint256 seized,) = m.core.liquidate(m.params, borrower, 0, shares, ""); // repay the WHOLE debt
        vm.stopPrank();

        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "debt fully cleared");
        assertEq(colBefore - m.core.position(m.id, borrower).collateral, seized, "collateral delta == seized");
        assertLt(seized, colBefore, "solvent: only the incentivized slice is seized, not all collateral");
        assertGt(m.core.position(m.id, borrower).collateral, 0, "borrower keeps the surplus collateral");
    }

    /// @dev A borrower opts into a personal settlement LTV; it is stored and read back, and a value at/above
    ///      WAD is rejected.
    function test_setSettlementLtv_storesAndRejectsOutOfRange() public {
        Market storage m = _m();
        address borrower = _actor("borrower");

        vm.prank(borrower);
        m.controller.setSettlementLtv(0.5e18);
        (uint256 ltv,) = m.controller.settlementLtv(borrower);
        assertEq(ltv, 0.5e18, "personal settlement LTV stored");

        vm.prank(borrower);
        vm.expectRevert(SettlementQueueLib.SettlementLtvOutOfRange.selector);
        m.controller.setSettlementLtv(1e18); // >= WAD
    }

    /// @dev Eligibility is queue-root OR a personal settlement LTV (no global watermark): a NON-root borrower
    ///      is ineligible. The lender-facing `vault.settle` is best-effort, so it SKIPS an ineligible target
    ///      (cancels nothing, no revert); after the target opts into a personal LTV it becomes eligible and
    ///      the same call cancels exactly the predicted slice. (The direct `core.settle` instead reverts
    ///      `SettlementIneligible` on a non-zero cut — the best-effort skip lives in the vault.)
    function test_settle_nonRootSkipped_thenEligibleViaPersonalLtv() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        uint256 shares = m.vaultDeposit(lender, 1000 ether);

        // Two borrowers at different risk keys (80/400 vs 80/800); 400/800 keep an 80 borrow within LLTV-max
        // at any seeded price. The queue root is read from the contract, not assumed.
        address a = _actor("a");
        _fund(m.collateralToken, a, 400 ether);
        m.supplyCollateral(a, 400 ether);
        address b = _actor("b");
        _fund(m.collateralToken, b, 800 ether);
        m.supplyCollateral(b, 800 ether);
        m.activateCollateral();
        m.borrow(a, 80 ether);
        m.borrow(b, 80 ether);

        (address root,,) = m.controller.nextSettlementBorrower();
        address nonRoot = root == a ? b : a;
        address[] memory bs = new address[](1);
        bs[0] = nonRoot;

        // Ineligible non-root -> the best-effort vault settle cancels nothing.
        vm.prank(lender);
        (,,, uint256 cancelledBefore) = m.vault.settle(shares, bs, lender, lender);
        assertEq(cancelledBefore, 0, "ineligible non-root: best-effort settle skips it");

        // It opts into a settlement LTV below its current LTV -> eligible -> cancels exactly the slice.
        vm.prank(nonRoot);
        m.controller.setSettlementLtv(0.05e18);
        (uint256 sliceAssets,) = m.controller.settlementFor(nonRoot);
        vm.prank(lender);
        (,,, uint256 cancelledAfter) = m.vault.settle(shares, bs, lender, lender);
        assertEq(cancelledAfter, sliceAssets, "after opt-in: eligible, cancels the personal-LTV slice exactly");
    }

    /// @dev Setting LTV to 0 clears the opt-in.
    function test_setSettlementLtv_zeroClears() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        vm.prank(borrower);
        m.controller.setSettlementLtv(0.6e18);
        vm.prank(borrower);
        m.controller.setSettlementLtv(0);
        (uint256 ltv,) = m.controller.settlementLtv(borrower);
        assertEq(ltv, 0, "zero clears the personal LTV");
    }
}
