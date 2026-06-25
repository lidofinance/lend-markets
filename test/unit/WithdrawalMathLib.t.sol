// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WithdrawalMathLib} from "../../src/libs/WithdrawalMathLib.sol";

contract WMHarness {
    function splitFill(
        uint256 assetsOut,
        uint256 filledShares,
        uint256 sizeTotal,
        uint256 pricePerShare,
        uint256 maxPriorityFee,
        uint256 feeRampBps,
        uint256 protocolFeeBps
    ) external pure returns (uint256, uint256, uint256) {
        return WithdrawalMathLib.splitFill(
            assetsOut, filledShares, sizeTotal, pricePerShare, maxPriorityFee, feeRampBps, protocolFeeBps
        );
    }
}

/// @notice Unit/fuzz for `WithdrawalMathLib.splitFill`: the per-fill split of
///         `assetsOut` into the lender's fixed-price owed (net of a Dutch-auction priority fee), the
///         keeper's reward (accrued yield + fee, net of the protocol cut), and the protocol cut. Example
///         outputs are hand-computed; the headline property — exact value conservation across the three
///         payouts — is fuzzed.
contract WithdrawalMathLibTest is Test {
    WMHarness internal h;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    function setUp() public {
        h = new WMHarness();
    }

    function test_split_normalYield_handComputed() public view {
        // owed=100, yield=10; fee=10*0.5=5; keeperGross=15; protocol=1.5; keeper=13.5; lender=95.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            h.splitFill(110 ether, 100 ether, 100 ether, 1e18, 10 ether, 5000, 1000);
        assertEq(lender, 95 ether, "lender = owed - fee");
        assertEq(keeper, 13.5 ether, "keeper = (yield + fee) - protocol cut");
        assertEq(protocol, 1.5 ether, "protocol = 10% of keeperGross 15");
        assertEq(lender + keeper + protocol, 110 ether, "conservation");
    }

    function test_split_priceDrop_noYield() public view {
        // assetsOut 80 < raw owed 100 -> owed=80, yield=0; fee=5; keeper=5; lender=75; protocol=0.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            h.splitFill(80 ether, 100 ether, 100 ether, 1e18, 10 ether, 5000, 0);
        assertEq(lender, 75 ether, "lender = capped owed - fee");
        assertEq(keeper, 5 ether, "keeper = fee only (no yield)");
        assertEq(protocol, 0, "no protocol cut at 0 bps");
        assertEq(lender + keeper + protocol, 80 ether, "conservation");
    }

    function test_split_feeRampZero_lenderKeepsAllOwed() public view {
        // feeRampBps 0 -> fee 0 -> lender = owed = 100; keeper = yield 10; protocol 0.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            h.splitFill(110 ether, 100 ether, 100 ether, 1e18, 10 ether, 0, 0);
        assertEq(lender, 100 ether, "no fee at ramp 0 -> lender keeps full owed");
        assertEq(keeper, 10 ether, "keeper = accrued yield");
        assertEq(protocol, 0, "no protocol cut");
    }

    function test_split_feeRampFull_maxFee() public view {
        // feeRampBps BPS -> fee = maxPriorityFee*filled/total = 10; lender = 90; keeper = yield10 + fee10 = 20.
        (uint256 lender, uint256 keeper,) = h.splitFill(110 ether, 100 ether, 100 ether, 1e18, 10 ether, BPS, 0);
        assertEq(lender, 90 ether, "full ramp -> fee = cap");
        assertEq(keeper, 20 ether, "keeper = yield + full fee");
    }

    function test_split_protocolTakesAll() public view {
        // protocolFeeBps BPS -> protocol = keeperGross, keeper = 0.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            h.splitFill(110 ether, 100 ether, 100 ether, 1e18, 10 ether, 5000, BPS);
        assertEq(lender, 95 ether, "lender owed unaffected by protocol cut");
        assertEq(keeper, 0, "protocol takes the whole keeper gross");
        assertEq(protocol, 15 ether, "protocol = keeperGross 15");
    }

    function test_split_feeExceedsOwed_cappedToOwed() public view {
        // Tiny owed (price 0.01), huge fee cap -> fee clamps to owed -> lender 0, keeper = owed + yield.
        // filled 100, price 0.01e18 -> raw owed 1; assetsOut 5 -> owed=min(1,5)=1, yield=4.
        // fee = 100*1/1 ... maxFee 50, ramp BPS -> 50 > owed 1 -> fee=1. lender=0; keeperGross=4+1=5.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            h.splitFill(5 ether, 100 ether, 100 ether, 0.01e18, 50 ether, BPS, 0);
        assertEq(lender, 0, "fee clamped to owed -> lender 0");
        assertEq(keeper, 5 ether, "keeper = yield + clamped fee");
        assertEq(protocol, 0, "no protocol cut");
        assertEq(lender + keeper + protocol, 5 ether, "conservation");
    }

    function testRevert_split_zeroSizeTotal() public {
        // fee = mulDiv(maxFee, filled, 0) -> division by zero.
        vm.expectRevert();
        h.splitFill(110 ether, 100 ether, 0, 1e18, 10 ether, 5000, 1000);
    }

    function testFuzz_conservation(
        uint256 assetsOut,
        uint256 filledShares,
        uint256 sizeTotal,
        uint256 pricePerShare,
        uint256 maxPriorityFee,
        uint256 feeRampBps,
        uint256 protocolFeeBps
    ) public view {
        assetsOut = bound(assetsOut, 0, 1e30);
        sizeTotal = bound(sizeTotal, 1, 1e30);
        filledShares = bound(filledShares, 0, sizeTotal); // a fill never exceeds the request
        pricePerShare = bound(pricePerShare, 0, 1e21);
        maxPriorityFee = bound(maxPriorityFee, 0, 1e30);
        feeRampBps = bound(feeRampBps, 0, BPS);
        protocolFeeBps = bound(protocolFeeBps, 0, BPS); // function does not guard >BPS (would underflow)

        (uint256 lender, uint256 keeper, uint256 protocol) =
            h.splitFill(assetsOut, filledShares, sizeTotal, pricePerShare, maxPriorityFee, feeRampBps, protocolFeeBps);

        assertEq(lender + keeper + protocol, assetsOut, "exact value conservation");
    }

    function testFuzz_matchesRecomputeAndBounds(
        uint256 assetsOut,
        uint256 filledShares,
        uint256 sizeTotal,
        uint256 pricePerShare,
        uint256 maxPriorityFee,
        uint256 feeRampBps,
        uint256 protocolFeeBps
    ) public view {
        assetsOut = bound(assetsOut, 0, 1e30);
        sizeTotal = bound(sizeTotal, 1, 1e30);
        filledShares = bound(filledShares, 0, sizeTotal);
        pricePerShare = bound(pricePerShare, 0, 1e21);
        maxPriorityFee = bound(maxPriorityFee, 0, 1e30);
        feeRampBps = bound(feeRampBps, 0, BPS);
        protocolFeeBps = bound(protocolFeeBps, 0, BPS);

        // Independent recompute of each payout from the spec formula.
        uint256 owed = Math.min(Math.mulDiv(filledShares, pricePerShare, WAD), assetsOut);
        uint256 fee = Math.mulDiv(maxPriorityFee, filledShares, sizeTotal) * feeRampBps / BPS;
        if (fee > owed) fee = owed;
        uint256 keeperGross = (assetsOut - owed) + fee;
        uint256 expProtocol = keeperGross * protocolFeeBps / BPS;

        (uint256 lender, uint256 keeper, uint256 protocol) =
            h.splitFill(assetsOut, filledShares, sizeTotal, pricePerShare, maxPriorityFee, feeRampBps, protocolFeeBps);

        assertEq(lender, owed - fee, "lenderAssets == owed - fee");
        assertEq(protocol, expProtocol, "protocolFee == keeperGross * protocolFeeBps / BPS");
        assertEq(keeper, keeperGross - expProtocol, "keeperFee == keeperGross - protocolFee");
        // Bounds (property): the lender never gets more than its capped owed, which never exceeds the fill.
        assertLe(lender, owed, "lender <= owed");
        assertLe(owed, assetsOut, "owed <= assetsOut");
    }

    /// @dev FINDING: the pure lib does NOT guard `protocolFeeBps <= BPS` (the NatSpec
    ///      only documents the expectation). Above BPS, `protocolFee > keeperGross` so `keeperFee =
    ///      keeperGross - protocolFee` underflows and reverts. The controller config must validate it.
    function testRevert_FINDING_protocolFeeBpsAboveBps_underflows() public {
        vm.expectRevert();
        h.splitFill(110 ether, 100 ether, 100 ether, 1e18, 10 ether, 5000, BPS + 1);
    }

    /// @dev `feeRampBps > BPS` is also unguarded but BENIGN: it inflates the raw fee past the linear cap,
    ///      yet the `fee <= owed` clamp bounds it, so no revert — the lender simply pays at most its owed.
    function test_feeRampAboveBps_clampsToOwed() public view {
        // raw fee = 60 * (2*BPS/BPS) = 120 > owed 100 -> clamped to 100 -> lender 0, keeper = yield 10 + 100.
        (uint256 lender, uint256 keeper, uint256 protocol) =
            h.splitFill(110 ether, 100 ether, 100 ether, 1e18, 60 ether, 2 * BPS, 0);
        assertEq(lender, 0, "ramp>BPS overshoots but fee clamps to owed -> lender 0");
        assertEq(keeper, 110 ether, "keeper = yield 10 + clamped fee 100");
        assertEq(lender + keeper + protocol, 110 ether, "conservation");
    }
}
