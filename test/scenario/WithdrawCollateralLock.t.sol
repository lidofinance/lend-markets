// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice The activating lock binds only the inactive buckets (dust + activating): a voluntary withdrawal
///         within the matured active balance passes even while the lock is in force, one that dips into the
///         locked lot reverts `ActivatingCollateralLocked` (Audit #32: descriptively, never as an opaque
///         `Panic(0x11)` underflow), and once the lock has expired the all-or-nothing rule still governs the
///         inactive balance via `InactiveCollateralNotCleared`. With open debt, the post-withdraw health check
///         counts active collateral only — a still-activating top-up cannot be used as debt cover for an exit.
contract WithdrawCollateralLockTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev Deploys a market whose `activatingLockDuration` is `lockDuration` and returns its handle.
    function _deployLockMarket(uint40 lockDuration) internal returns (Market storage) {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.activation.activatingLockDuration = lockDuration;
        _deployProtocol(cfg);
        return protocol.markets[0];
    }

    function testRevert_debtFreeWithdrawUnderLock_activatingCollateralLocked() public {
        Market storage market = _deployLockMarket(1 hours);

        address borrower = _actor("borrower");
        _fund(market.collateralToken, borrower, 100 ether);
        market.supplyCollateral(borrower, 100 ether); // enters the activating bucket; lock in force, no debt

        // Debt-free full withdrawal while the lock is still in force: with no matured active collateral, any
        // requested amount dips into the locked lot, so the lib rejects it rather than letting raw collateral
        // drop below the locked bucket.
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralActivationLib.ActivatingCollateralLocked.selector, 100 ether, block.timestamp + 1 hours
            )
        );
        market.core.withdrawCollateral(market.params, 100 ether, borrower, borrower);
    }

    /// @notice The lock binds only the inactive buckets: a debt-free borrower with matured active collateral and
    ///         a freshly locked top-up can draw down active while the lock is in force — the locked lot and its
    ///         timer stay untouched — but one wei beyond the active balance reverts.
    function test_debtFreeActiveWithdraw_passesUnderLock() public {
        Market storage market = _deployLockMarket(1 hours);

        address borrower = _actor("borrower");
        _fund(market.collateralToken, borrower, 150 ether);
        market.supplyCollateral(borrower, 100 ether);
        market.activateCollateral(); // warp past the max activation delay (and the first lot's lock)
        market.withdrawCollateral(borrower, 1 ether, borrower); // syncing action: matures the lot, active = 99

        market.supplyCollateral(borrower, 50 ether); // fresh lot, locked for 1 hour from now

        // Active-only draw during the lock: passes, and the helper asserts the buckets stay untouched.
        market.withdrawCollateral(borrower, 40 ether, borrower); // active 99 -> 59

        ILidoLendMarketController.BorrowerPosition memory position = market.controller.positionOf(borrower);
        assertEq(position.active, 59 ether, "active drawn down under the lock");
        assertEq(position.activating, 50 ether, "locked lot untouched");
        assertGt(position.unlockTime, 0, "the lot's timer keeps running");

        // One wei beyond the active balance dips into the locked lot: reverts.
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralActivationLib.ActivatingCollateralLocked.selector, 50 ether, block.timestamp + 1 hours
            )
        );
        market.core.withdrawCollateral(market.params, 59 ether + 1, borrower, borrower);
    }

    /// @notice With open debt, the post-withdraw health check counts active collateral only: a withdrawal that
    ///         leaves enough ACTIVE cover passes even during the top-up's lock, while one that would need the
    ///         still-activating top-up as cover reverts `InsufficientActiveCollateral` — even though the raw
    ///         total (active + activating) would cover the debt at LLTV.
    function test_debtBearingWithdraw_healthCheckExcludesInactive() public {
        Market storage market = _deployLockMarket(1 hours);

        address lender = _actor("lender");
        _fund(market.loanToken, lender, 1000 ether);
        market.vaultDeposit(lender, 1000 ether);

        address borrower = _actor("borrower");
        _fund(market.collateralToken, borrower, 150 ether);
        market.supplyCollateral(borrower, 100 ether);
        market.activateCollateral(); // warp past the max activation delay
        // Debt at 40% of the 100 ether collateral value — half of the 0.8e18 LLTV capacity, seed-safe. The
        // borrow hook's sync matures the lot into active.
        uint256 borrowAmt = 100 ether * oraclePrice / 1e36 * 80 / 100 / 2;
        market.borrow(borrower, borrowAmt);

        market.supplyCollateral(borrower, 50 ether); // fresh lot, locked; active stays 100

        // Remaining active 70 still covers the debt at LLTV (0.56 > 0.40 of the original collateral value):
        // passes during the lock, buckets untouched (helper asserts).
        market.withdrawCollateral(borrower, 30 ether, borrower);

        // Remaining active would be 35 (0.28 < 0.40): reverts, even though active + activating = 85 would
        // cover the debt at LLTV (0.68 > 0.40) — the still-locked top-up is no debt cover.
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        market.core.withdrawCollateral(market.params, 35 ether, borrower, borrower);
    }

    /// @notice Once the lock itself has expired, the ordinary all-or-nothing rule still governs: a withdrawal
    ///         short of the whole inactive balance reverts even though nothing is locked anymore. The lock
    ///         duration here (1 minute) is deliberately shorter than the base activation delay (floor 10
    ///         minutes), so the lot is demonstrably still un-matured — not locked, but not active either.
    function testRevert_partialWithdraw_inactiveNotCleared() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.activation.activatingLockDuration = 1 minutes;
        _deployProtocol(cfg);
        Market storage market = protocol.markets[0];

        address borrower = _actor("borrower");
        _fund(market.collateralToken, borrower, 100 ether);
        market.supplyCollateral(borrower, 100 ether); // enters the activating bucket

        vm.warp(block.timestamp + 1 minutes + 1); // lock window over; well short of the 10-minute delay floor

        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralActivationLib.InactiveCollateralNotCleared.selector, 50 ether, 100 ether)
        );
        market.core.withdrawCollateral(market.params, 50 ether, borrower, borrower);
    }
}
