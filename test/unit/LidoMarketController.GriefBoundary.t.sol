// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev Accepted limitation: withdrawing still-immature collateral does NOT
///      refund the load accumulator. An attacker can deposit a large lot to spike the load,
///      immediately withdraw it (free, since immature withdrawal is unpenalised), and keep later
///      deposits' delays inflated for the decay window — at near-zero capital cost. We accept this
///      rather than add refund accounting or lock immature collateral; these tests pin its boundary:
///        - the damage is bounded above by maxDelay (no funds at risk, only throughput), and
///        - it is self-limiting: the accumulator drains to zero over the known decay window, and a
///          single oversized deposit cannot leave a long residual delay.
contract LidoMarketControllerGriefBoundaryTest is LidoMarketControllerTestBase {
    address internal attacker = address(0xBAD);
    address internal depositor = address(0xD0);

    function test_ImmatureWithdrawalDoesNotRefundLoad() public {
        _enableLeakyBucket();

        // Attacker spikes the load with a large lot...
        _supplyCollateral(attacker, REF);
        // ...then immediately withdraws the still-immature collateral (no open debt).
        harness.exposed_handleWithdrawCollateral(MARKET, attacker, attacker, attacker, REF, 0);

        // Position is gone, but the load was not refunded: probing with a zero-size deposit isolates
        // the accumulator's contribution, which still saturates the delay to maxDelay.
        assertEq(_maturingOf(attacker), 0, "attacker collateral fully withdrawn");
        assertEq(harness.exposed_computeMaturationDelay(MARKET, 0), MAX_DELAY, "load not refunded");
    }

    function test_GriefIsBoundedByMaxDelay() public {
        _enableLeakyBucket();
        _supplyCollateral(attacker, REF);
        harness.exposed_handleWithdrawCollateral(MARKET, attacker, attacker, attacker, REF, 0);

        // Even an enormous follow-up deposit cannot push the delay past maxDelay.
        assertEq(harness.exposed_computeMaturationDelay(MARKET, 1_000_000e18), MAX_DELAY, "never exceeds maxDelay");
    }

    function test_GriefDecaysOverKnownWindow() public {
        _enableLeakyBucket();
        _supplyCollateral(attacker, REF);
        harness.exposed_handleWithdrawCollateral(MARKET, attacker, attacker, attacker, REF, 0);

        assertEq(harness.exposed_computeMaturationDelay(MARKET, 0), MAX_DELAY, "starts saturated");

        // The load drains fully over the maxDelay window; afterwards the baseline returns to the
        // size-only minimum.
        skip(MAX_DELAY);
        assertEq(harness.exposed_computeMaturationDelay(MARKET, 0), MIN_DELAY, "decays back to minimum");
    }

    /// @dev Requirement: a single oversized deposit must not pin every later deposit at maxDelay
    ///      for many hours. The accumulator is capped at maxDelayMaturationLoad, so a 10x deposit
    ///      spikes the load no higher than a 1x one and decays back to the minimum over the window.
    function test_LargeDepositLeavesNoLongResidualDelay() public {
        _enableLeakyBucket();
        _supplyCollateral(depositor, 10 * REF);

        skip(5 hours); // well past the depositor's 2h maxDelay maturation

        assertEq(harness.exposed_computeMaturationDelay(MARKET, 0), MIN_DELAY, "residual delay must decay to minimum");
    }
}
