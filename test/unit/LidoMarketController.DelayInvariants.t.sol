// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev Properties of the single leaky-bucket delay formula: bounded, monotonic in load, decaying
///      over time. These guard against regressions in the simplified formula.
contract LidoMarketControllerDelayInvariantsTest is LidoMarketControllerTestBase {
    address internal user = address(0xCAFE);

    function testFuzz_DelayWithinBounds(uint128 load) public {
        _enableLeakyBucket();
        uint64 d = harness.exposed_computeMaturationDelay(MARKET, load);
        assertGe(d, MIN_DELAY, "delay >= minDelay");
        assertLe(d, MAX_DELAY, "delay <= maxDelay");
    }

    function testFuzz_DelayMonotonicInLoad(uint128 a, uint128 b) public {
        _enableLeakyBucket();
        if (a > b) (a, b) = (b, a);
        assertLe(
            harness.exposed_computeMaturationDelay(MARKET, a),
            harness.exposed_computeMaturationDelay(MARKET, b),
            "delay non-decreasing in load"
        );
    }

    function test_DelayDecaysMonotonicallyOverTime() public {
        _enableLeakyBucket();
        _supplyCollateral(user, REF); // saturate the accumulator to maxDelay

        uint64 d0 = harness.exposed_computeMaturationDelay(MARKET, 0);
        skip(MAX_DELAY / 2);
        uint64 d1 = harness.exposed_computeMaturationDelay(MARKET, 0);
        skip(MAX_DELAY / 2);
        uint64 d2 = harness.exposed_computeMaturationDelay(MARKET, 0);

        assertEq(d0, MAX_DELAY, "starts saturated");
        assertGt(d0, d1, "decays after half window");
        assertGt(d1, d2, "keeps decaying");
        assertEq(d2, MIN_DELAY, "fully drained at end of window");
    }

    function test_DepositSizeContributesToOwnDelay() public {
        _enableLeakyBucket();
        // With an empty accumulator, a deposit equal to the max-delay load already saturates delay.
        assertEq(harness.exposed_computeMaturationDelay(MARKET, REF), MAX_DELAY, "deposit size alone can saturate");
        // A small deposit gets a small delay above the minimum.
        uint64 d = harness.exposed_computeMaturationDelay(MARKET, REF / 100);
        assertGt(d, MIN_DELAY, "small deposit > minDelay");
        assertLt(d, MAX_DELAY, "small deposit < maxDelay");
    }
}
