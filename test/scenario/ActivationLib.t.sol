// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ActivationLib} from "../../src/libs/ActivationLib.sol";

/// @dev Storage harness so the internal library can operate on a real storage struct.
contract ActivationHarness {
    using ActivationLib for ActivationLib.State;

    ActivationLib.State internal $;

    function setConfig(ActivationLib.Config memory cfg) external {
        $.setConfig(cfg);
    }

    function deposit(address borrower, uint256 assets, uint256 raw) external {
        $.deposit(borrower, assets, raw);
    }

    function currentLoad() external view returns (uint256) {
        return $.currentLoad();
    }

    function bucketsOf(address borrower, uint256 raw)
        external
        view
        returns (uint256 active, uint256 activating, uint256 dust)
    {
        return $.bucketsOf(borrower, raw);
    }
}

contract ActivationLibTest is Test {
    ActivationHarness internal h;

    function setUp() public {
        h = new ActivationHarness();
        h.setConfig(
            ActivationLib.Config({
                minActivationDelay: 1 minutes,
                maxActivationDelay: 1 hours,
                maxSuspicionDelay: 1 hours,
                maxDecayDuration: 1 days,
                maxDelayLoad: type(uint128).max,
                minActivationAmount: 1,
                minDecayAmount: 1 ether
            })
        );
    }

    /// @notice F01 — characterization test for silent uint128 truncation in `_increaseLoad`.
    /// @dev    With a pathological `maxDelayLoad = type(uint128).max` config, two consecutive
    ///         deposits whose sum exceeds `type(uint128).max` silently wrap the load accumulator.
    ///         Under realistic governance bounds (`maxDelayLoad ≈ 10000 ether`) this is unreachable;
    ///         this test pins down the misbehaviour so we can decide whether to cap in `setConfig`
    ///         or switch `_increaseLoad` to a saturating add.
    function test_loadAccumulator_silentlyWrapsAtUint128Max() public {
        uint256 firstAssets = uint256(type(uint128).max) - 1 ether;

        h.deposit(address(0xB1), firstAssets, 0);
        uint256 loadAfterFirst = h.currentLoad();
        assertEq(loadAfterFirst, firstAssets, "first deposit accumulates linearly");

        h.deposit(address(0xB2), 2 ether, 0);
        uint256 loadAfterSecond = h.currentLoad();

        assertTrue(loadAfterSecond < loadAfterFirst, "BUG: load wrapped after adding 2 ether (smaller than before)");
        // The truncation drops the high uint128 bit. Pinning the exact post-wrap value documents the
        // characterization; this assertion will break (intentionally) if the lib is changed to
        // saturate or revert instead.
        assertEq(loadAfterSecond, 1 ether - 1, "post-wrap load is `(firstAssets + 2 ether) mod 2^128`");
    }
}
