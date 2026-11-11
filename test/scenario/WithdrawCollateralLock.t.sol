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

    /// @dev Fixed issue: a debt-free withdrawal under the activating lock reverted with an arithmetic panic.
    ///      Root cause: `_handleWithdrawCollateral` computed `position.collateral - inactive` for every position, and
    ///      the locked buckets could exceed the collateral left after the withdrawal. Now: `debit` reverts with
    ///      `ActivatingCollateralLocked` when the request exceeds active collateral inside the lock. The controller
    ///      subtracts `inactive` only for a position with debt.
    ///      Same cause: the fix covers a full withdrawal and any partial withdrawal above the active balance, with or
    ///      without debt. It also covers dust that sits next to a locked lot.
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
        // Syncing action, raw call: the withdraw hook matures the lot mid-call, which the helper's
        // assertions assume never happens. Active is 99 ether afterwards.
        vm.prank(borrower);
        market.core.withdrawCollateral(market.params, 1 ether, borrower, borrower);

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

    /// @dev Known issue: a third party tops up a borrower's dust to the activation threshold, so the whole amount
    ///      enters the timer. The activating lock then blocks the borrower's withdrawal of its old dust until the lock
    ///      ends.
    ///      Root cause: `LidoLend.supplyCollateral` accepts any `onBehalf` with no consent from that borrower.
    ///      `credit` moves existing dust into `activating` when dust plus the deposit reach `minActivationAmount`.
    ///      `debit` then allows only draws from active collateral until `activatingStart + activatingLockDuration`.
    ///      Same cause: any address, router or bundler can send the top-up. It needs only `minDepositAmount` when the
    ///      dust is close to the threshold. A top-up that extends the deadline of an existing activating lot restarts
    ///      the lock for the whole lot. Dust next to a locked activating lot is locked too. All committed market
    ///      configs set the lock to zero.
    ///      A fix changes this outcome; update this test with the fix.
    function testRevert_thirdPartyTopUp_locksVictimDust() public {
        uint40 lockDuration = 1 hours;
        Market storage market = _deployLockMarket(lockDuration);
        uint256 minActivation = market.controller.collateralActivationConfig().minActivationAmount;
        uint256 victimDust = minActivation - 1 ether;
        uint256 topUp = 1 ether; // == minDepositAmount in the default config

        address victim = _actor("victim");
        _fund(market.collateralToken, victim, victimDust);
        market.supplyCollateral(victim, victimDust);
        assertEq(market.controller.positionOf(victim).dust, victimDust, "setup: victim holds dust");

        address attacker = _actor("attacker");
        _fund(market.collateralToken, attacker, topUp);
        market.supplyCollateralOnBehalf(attacker, victim, topUp); // helper asserts dust + topUp enters the timer
        uint256 lockDeadline = block.timestamp + lockDuration;

        ILidoLendMarketController.BorrowerPosition memory position = market.controller.positionOf(victim);
        assertEq(position.dust, 0, "the victim's dust left the dust bucket");
        assertEq(position.activating, minActivation, "dust plus top-up is activating");

        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralActivationLib.ActivatingCollateralLocked.selector, minActivation, lockDeadline
            )
        );
        market.core.withdrawCollateral(market.params, victimDust, victim, victim);

        // The lock outlasts the short activation delay, so at the deadline the lot has matured and the old dust is
        // free again.
        vm.warp(lockDeadline);
        market.withdrawCollateral(victim, victimDust, victim);
    }

    /// @dev Known issue: each third-party top-up before the deadline restarts the shared timer. The lock deadline
    ///      moves past the first deadline plus one lock duration, and the victim still cannot withdraw.
    ///      Root cause: `credit` restarts `activatingStart` for the whole activating lot when a deposit extends the
    ///      unlock deadline, and any caller can deposit for any borrower. `debit` measures the lock from that
    ///      restarted `activatingStart`.
    ///      Same cause: the attacker repeats the top-up before each maturity, so the lot can stay locked and
    ///      unmatured. Each restart also delays the maturity of the whole lot, so it holds back borrow capacity even
    ///      with a zero lock. Onto an empty dust bucket, each top-up must reach `minActivationAmount`, and it becomes
    ///      the victim's collateral.
    ///      A fix changes this outcome; update this test with the fix.
    function testRevert_repeatedTopUps_renewLock() public {
        uint40 lockDuration = 2 hours;
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        // A fixed delay equal to the lock: every later top-up gives a later deadline, so it restarts the timer.
        cfg.activation.minActivationDelay = lockDuration;
        cfg.activation.maxActivationDelay = lockDuration;
        cfg.activation.activatingLockDuration = lockDuration;
        _deployProtocol(cfg);
        Market storage market = protocol.markets[0];
        uint256 topUp = cfg.activation.minActivationAmount;

        address victim = _actor("victim");
        _fund(market.collateralToken, victim, 100 ether);
        market.supplyCollateral(victim, 100 ether);
        uint256 firstDeadline = block.timestamp + lockDuration;

        address attacker = _actor("attacker");
        _fund(market.collateralToken, attacker, 2 * topUp);
        vm.warp(firstDeadline - 1 hours);
        market.supplyCollateralOnBehalf(attacker, victim, topUp);
        vm.warp(firstDeadline + 30 minutes);
        market.supplyCollateralOnBehalf(attacker, victim, topUp);
        uint256 renewedDeadline = block.timestamp + lockDuration;

        vm.warp(firstDeadline + lockDuration);
        assertEq(
            market.controller.positionOf(victim).unlockTime, renewedDeadline, "the second top-up restarts the timer"
        );

        uint256 total = 100 ether + 2 * topUp;
        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralActivationLib.ActivatingCollateralLocked.selector, total, renewedDeadline)
        );
        market.core.withdrawCollateral(market.params, total, victim, victim);
    }
}
