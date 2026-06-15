// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";

/// @dev Storage harness so the internal library can operate on a real storage struct.
contract ActivationHarness {
    using CollateralActivationLib for CollateralActivationLib.State;

    CollateralActivationLib.State internal $;

    function setConfig(CollateralActivationLib.Config memory cfg) external {
        $.setConfig(cfg);
    }

    function deposit(address borrower, uint256 assets) external {
        $.deposit(borrower, assets);
    }

    function currentInflow() external view returns (uint256) {
        return $.getInflow();
    }

    function bucketsOf(address borrower) external view returns (uint256 active, uint256 activating, uint256 dust) {
        return $.getBuckets(borrower);
    }
}

contract CollateralActivationLibTest is Test {
    ActivationHarness internal h;

    function setUp() public {
        h = new ActivationHarness();
        h.setConfig(
            CollateralActivationLib.Config({
                minActivationDelay: 1 minutes,
                maxActivationDelay: 1 hours,
                maxSuspicionDelay: 1 hours,
                activatingHold: 0,
                inflowDecayWindow: 1 days,
                maxDelayInflow: type(uint128).max,
                minActivationAmount: 1,
                minDecayInflow: 1 ether
            })
        );
    }

    /// @notice F01 — characterization test for silent uint128 truncation in `deposit`'s inflow addition.
    /// @dev    With a pathological `maxDelayInflow = type(uint128).max` config, two consecutive
    ///         deposits whose sum exceeds `type(uint128).max` silently wrap the inflow accumulator.
    ///         Under realistic governance bounds (`maxDelayInflow ≈ 10000 ether`) this is unreachable;
    ///         this test pins down the misbehaviour so we can decide whether to cap in `setConfig`
    ///         or switch the inflow addition to a saturating add.
    function test_inflowAccumulator_silentlyWrapsAtUint128Max() public {
        uint256 firstAssets = uint256(type(uint128).max) - 1 ether;

        h.deposit(address(0xB1), firstAssets);
        uint256 inflowAfterFirst = h.currentInflow();
        assertEq(inflowAfterFirst, firstAssets, "first deposit accumulates linearly");

        h.deposit(address(0xB2), 2 ether);
        uint256 inflowAfterSecond = h.currentInflow();

        assertTrue(
            inflowAfterSecond < inflowAfterFirst, "BUG: inflow wrapped after adding 2 ether (smaller than before)"
        );
        // The truncation drops the high uint128 bit. Pinning the exact post-wrap value documents the
        // characterization; this assertion will break (intentionally) if the lib is changed to
        // saturate or revert instead.
        assertEq(inflowAfterSecond, 1 ether - 1, "post-wrap inflow is `(firstAssets + 2 ether) mod 2^128`");
    }
}
