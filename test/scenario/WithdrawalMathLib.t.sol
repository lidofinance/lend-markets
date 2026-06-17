// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {WithdrawalMathLib} from "../../src/libs/WithdrawalMathLib.sol";

/// @notice Unit + fuzz coverage for the pure withdrawal-queue settlement split.
contract WithdrawalMathLibTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice At-par price, fee ramped to the deadline, no protocol cut: the whole cap is charged.
    function test_atParFullRamp_feeFromOwed() public pure {
        // 10 shares × 1.0 = 10 owed == assetsOut; full ramp + full fill → whole cap (3) to keeper.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            WithdrawalMathLib.splitFill(10 ether, 10 ether, 10 ether, WAD, 3 ether, BPS, 0);
        assertEq(lender, 7 ether, "owed minus fee");
        assertEq(keeper, 3 ether, "fee to keeper");
        assertEq(protocol, 0);
    }

    /// @notice Dutch ramp: at half the time-to-deadline only half the cap is charged; the unramped
    ///         remainder stays with the lender.
    function test_halfRamp_chargesHalfTheCap() public pure {
        (uint256 lender, uint256 keeper,) =
            WithdrawalMathLib.splitFill(10 ether, 10 ether, 10 ether, WAD, 4 ether, BPS / 2, 0);
        assertEq(keeper, 2 ether, "half the 4 cap at half ramp");
        assertEq(lender, 8 ether, "lender keeps the unramped half");
    }

    /// @notice A fill at request creation (ramp 0) earns no priority fee — the auction starts at zero.
    function test_zeroRamp_noFee() public pure {
        (uint256 lender, uint256 keeper,) =
            WithdrawalMathLib.splitFill(10 ether, 10 ether, 10 ether, WAD, 4 ether, 0, 0);
        assertEq(keeper, 0, "no fee at ramp start");
        assertEq(lender, 10 ether, "lender keeps the full owed");
    }

    /// @notice Accrued yield (price rose above the fixed request price) is the keeper's reward.
    function test_accruedYieldGoesToKeeper() public pure {
        // 10 shares fixed at 1.0; redeemed now at 1.2 → assetsOut 12, owed 10, yield 2 → keeper.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            WithdrawalMathLib.splitFill(12 ether, 10 ether, 10 ether, WAD, 0, BPS, 0);
        assertEq(lender, 10 ether, "lender gets fixed-price owed");
        assertEq(keeper, 2 ether, "keeper gets the accrued yield");
        assertEq(protocol, 0);
    }

    /// @notice Yield + priority fee both go to the keeper; protocol takes its bps of the gross.
    function test_yieldPlusFee_withProtocolCut() public pure {
        // owed 10, yield 2, fee 4 (full ramp) → keeperGross 6; protocol 25% = 1.5; keeper 4.5; lender 6.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            WithdrawalMathLib.splitFill(12 ether, 10 ether, 10 ether, WAD, 4 ether, BPS, 2500);
        assertEq(lender, 6 ether, "owed minus fee, unaffected by protocol cut");
        assertEq(keeper, 4.5 ether, "(yield + fee) net of protocol cut");
        assertEq(protocol, 1.5 ether, "25% of the 6 gross");
    }

    /// @notice Partial fill scales the fee by the share fraction (`filledShares / sizeTotal`).
    function test_partialFillProRatesFee() public pure {
        // half the original shares filled at full ramp → half the cap; at par, no yield.
        (uint256 lender, uint256 keeper,) =
            WithdrawalMathLib.splitFill(5 ether, 5 ether, 10 ether, WAD, 4 ether, BPS, 0);
        assertEq(keeper, 2 ether, "half the 4 cap for half the size");
        assertEq(lender, 3 ether, "owed (5) minus fee (2)");
    }

    /// @notice A loss (redeem yields less than the fixed price) caps the owed at `assetsOut` and leaves
    ///         no yield; the lender eats the loss.
    function test_lossTrimsOwedNoYield() public pure {
        (uint256 lender, uint256 keeper,) = WithdrawalMathLib.splitFill(8 ether, 10 ether, 10 ether, WAD, 0, BPS, 0);
        assertEq(lender, 8 ether, "owed capped at assetsOut");
        assertEq(keeper, 0, "no yield on a loss");
    }

    /// @notice Conservation: lender + keeper + protocol always equals assetsOut.
    function testFuzz_conservation(
        uint256 assetsOut,
        uint256 filled,
        uint256 sizeTotal,
        uint256 price,
        uint256 maxFee,
        uint256 feeRampBps,
        uint256 protocolFeeBps
    ) public pure {
        assetsOut = bound(assetsOut, 0, 1e30);
        sizeTotal = bound(sizeTotal, 1, 1e27);
        filled = bound(filled, 0, sizeTotal);
        price = bound(price, 1, 1e21);
        maxFee = bound(maxFee, 0, 1e30);
        feeRampBps = bound(feeRampBps, 0, BPS);
        protocolFeeBps = bound(protocolFeeBps, 0, BPS);

        (uint256 lender, uint256 keeper, uint256 protocol) =
            WithdrawalMathLib.splitFill(assetsOut, filled, sizeTotal, price, maxFee, feeRampBps, protocolFeeBps);
        assertEq(lender + keeper + protocol, assetsOut, "split conserves assetsOut");
    }

    /// @notice The fee is monotonic in the ramp: a later fill never earns the lender more / the
    ///         keeper less for the same fill.
    function testFuzz_feeMonotonicInRamp(uint256 maxFee, uint256 rampLow, uint256 rampHigh) public pure {
        maxFee = bound(maxFee, 0, 100 ether); // ≤ owed (100 at par) so the cap never trims the fee
        rampLow = bound(rampLow, 0, BPS);
        rampHigh = bound(rampHigh, rampLow, BPS);

        (uint256 lenderLow, uint256 keeperLow,) =
            WithdrawalMathLib.splitFill(100 ether, 100 ether, 100 ether, WAD, maxFee, rampLow, 0);
        (uint256 lenderHigh, uint256 keeperHigh,) =
            WithdrawalMathLib.splitFill(100 ether, 100 ether, 100 ether, WAD, maxFee, rampHigh, 0);
        assertGe(keeperHigh, keeperLow, "later fill earns at least as much fee");
        assertLe(lenderHigh, lenderLow, "lender keeps at most as much later");
    }

    /// @notice At full ramp, a full drain across sequential partial fills pays exactly the cap (the
    ///         per-fill share fractions sum to one). At par isolates the fee from yield.
    function testFuzz_fullRampFullDrainPaysCap(uint256 sizeTotal, uint256 maxFee, uint256 step) public pure {
        sizeTotal = bound(sizeTotal, 1, 1e21);
        maxFee = bound(maxFee, 0, sizeTotal); // ≤ owed at par, so the per-fill cap never trims
        step = bound(step, sizeTotal / 128 + 1, sizeTotal);

        uint256 remaining = sizeTotal;
        uint256 paid;
        while (remaining > 0) {
            uint256 filled = step < remaining ? step : remaining;
            // at par, assetsOut == filled; lender gets owed minus fee, so fee == filled-owed-to-lender.
            (uint256 lender, uint256 keeper,) =
                WithdrawalMathLib.splitFill(filled, filled, sizeTotal, WAD, maxFee, BPS, 0);
            paid += keeper; // no yield, no protocol cut → keeper == fee
            assertEq(lender + keeper, filled, "fill conserves at par");
            remaining -= filled;
        }
        // mulDiv floors each fill's fraction, so a tiny dust shortfall is allowed.
        assertApproxEqAbs(paid, maxFee, 128, "full drain at full ramp pays the cap (modulo rounding dust)");
    }
}
