// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice Audit #32: a debt-free full `withdrawCollateral` under an active activating-lock drives raw collateral
///         to zero while the lock keeps a positive amount in the un-matured buckets. The controller rejects it
///         with a descriptive `ActivationLockActive` instead of an opaque `Panic(0x11)` underflow.
contract WithdrawCollateralLockTest is LidoLendSetup {
    using MarketActions for Market;

    function test_debtFreeWithdrawUnderLock_revertsActivationLockActive() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.activation.activatingLockAmount = 50 ether;
        cfg.activation.activatingLockDuration = 1 hours;
        _deployProtocol(cfg);
        Market storage market = protocol.markets[0];

        address borrower = _actor("borrower");
        _fund(market.collateralToken, borrower, 100 ether);
        market.supplyCollateral(borrower, 100 ether); // enters the activating bucket; lock in force, no debt

        // Debt-free full withdrawal while the lock still holds 50e18 in the activating bucket.
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.ActivationLockActive.selector);
        market.core.withdrawCollateral(market.params, 100 ether, borrower, borrower);
    }
}
