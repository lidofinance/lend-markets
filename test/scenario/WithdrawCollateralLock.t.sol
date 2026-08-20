// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice Audit #32: a debt-free full `withdrawCollateral` under an active activating-lock drives raw collateral
///         to zero while the lock keeps a positive amount in the un-matured buckets. The library rejects it
///         directly with a descriptive `ActivatingCollateralLocked` instead of an opaque `Panic(0x11)` underflow.
///         A sibling test covers the all-or-nothing rule once the lock itself has expired: a withdrawal that
///         does not cover the whole remaining inactive balance still reverts, via `InactiveCollateralNotCleared`.
contract WithdrawCollateralLockTest is LidoLendSetup {
    using MarketActions for Market;

    function testRevert_debtFreeWithdrawUnderLock_activatingCollateralLocked() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.activation.activatingLockDuration = 1 hours;
        _deployProtocol(cfg);
        Market storage market = protocol.markets[0];

        address borrower = _actor("borrower");
        _fund(market.collateralToken, borrower, 100 ether);
        market.supplyCollateral(borrower, 100 ether); // enters the activating bucket; lock in force, no debt

        // Debt-free full withdrawal while the lock is still in force: the lib rejects it outright, regardless
        // of the requested amount, rather than letting raw collateral drop below the locked bucket.
        vm.prank(borrower);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralActivationLib.ActivatingCollateralLocked.selector, 100 ether, block.timestamp + 1 hours
            )
        );
        market.core.withdrawCollateral(market.params, 100 ether, borrower, borrower);
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
