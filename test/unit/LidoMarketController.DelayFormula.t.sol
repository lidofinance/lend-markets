// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev The legacy size-ratio delay scaled a deposit's delay against the live
///      `totalMaturedCollateral`. That denominator moves with every maturation/withdrawal, so the
///      same deposit got wildly different delays, and an unconfigured market with a non-trivial
///      matured base produced near-minimum delays for small deposits — unsafe by default.
///      Target: an unconfigured market (leaky-bucket disabled) is conservative and deterministic —
///      it always returns maxDelay, with no dependence on live market state.
contract LidoMarketControllerDelayFormulaTest is LidoMarketControllerTestBase {
    address internal alice = address(0xA11CE);

    function test_UnconfiguredMarketAlwaysReturnsMaxDelay() public {
        // No setMarketConfig: defaults apply (maxDelayMaturationLoad == 0, leaky-bucket disabled).
        // Build a non-zero matured base so the legacy ratio path has a denominator to scale by.
        _supplyCollateral(alice, 100e18);
        skip(MAX_DELAY + 1);
        harness.exposed_syncMaturation(MARKET, alice);
        assertEq(_maturedOf(alice), 100e18, "precondition: non-zero matured base");

        // Regardless of deposit size relative to the matured base, the delay must be maxDelay.
        assertEq(harness.exposed_computeMaturationDelay(MARKET, 1e18), MAX_DELAY, "tiny deposit");
        assertEq(harness.exposed_computeMaturationDelay(MARKET, 10e18), MAX_DELAY, "small deposit");
        assertEq(harness.exposed_computeMaturationDelay(MARKET, 100e18), MAX_DELAY, "equal deposit");
    }
}
