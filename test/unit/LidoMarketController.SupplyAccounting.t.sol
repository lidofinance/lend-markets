// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev Collateral classification on supply: sub-minimum stays dust; dust folds into maturing once
///      the threshold is crossed; repeated deposits move the maturation timer by the maximum of the
///      existing and the freshly computed unlock (a later deposit cannot shorten an existing unlock,
///      and a fresh lot cannot inherit a partially-elapsed delay).
contract LidoMarketControllerSupplyAccountingTest is LidoMarketControllerTestBase {
    address internal user = address(0xABCD);

    function test_SubMinimumStaysDust() public {
        _supplyCollateral(user, 5e18); // < 10e18 min
        (, uint256 maturing, uint256 dust,) = harness.previewMaturation(MARKET, user);
        assertEq(dust, 5e18, "stays dust");
        assertEq(maturing, 0, "does not enter maturation");
    }

    function test_DustPromotedWhenThresholdCrossed() public {
        _supplyCollateral(user, 5e18); // dust = 5e18
        _supplyCollateral(user, 8e18); // 5 + 8 = 13 >= 10 => promote dust, fold into maturing
        (, uint256 maturing, uint256 dust,) = harness.previewMaturation(MARKET, user);
        assertEq(dust, 0, "dust promoted");
        assertEq(maturing, 13e18, "folded into maturing");
    }

    function test_RepeatedDepositExtendsUnlock() public {
        _supplyCollateral(user, 100e18); // unlock at t0 + maxDelay
        skip(1 hours);
        _supplyCollateral(user, 50e18); // new unlock at t0 + 1h + maxDelay > old => extends

        skip(MAX_DELAY - 1 hours + 1); // past the OLD unlock, before the new one
        harness.exposed_syncMaturation(MARKET, user);
        assertEq(_maturedOf(user), 0, "not matured before the extended unlock");

        skip(1 hours); // past the new unlock
        harness.exposed_syncMaturation(MARKET, user);
        assertEq(_maturedOf(user), 150e18, "matures once the extended unlock passes");
    }

    function test_SameBlockDepositKeepsUnlock() public {
        _supplyCollateral(user, 100e18);
        uint64 start1 = harness.collateralState(MARKET, user).pendingMaturationStart;

        _supplyCollateral(user, 50e18); // same block: new unlock == old => kept
        IMarketController.CollateralState memory s = harness.collateralState(MARKET, user);
        assertEq(s.pendingMaturationStart, start1, "unlock unchanged for same-block deposit");
        assertEq(uint256(s.maturingCollateral), 150e18, "both deposits maturing together");
    }
}
