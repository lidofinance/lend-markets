// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {BlockInfoWithHash} from "../../src/types/GuardianSignalsTypes.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice L2 collateral-activation scenarios end-to-end through the controller hooks: fresh collateral is
///         locked in a maturation timer before it can back a loan; maturing it unlocks borrowing; a guardian
///         ban keeps it locked regardless; and instant activation bypasses the timer. The activation/guardian
///         math is unit-tested in isolation (§4/§5) — here the focus is the integrated supply->hook->borrow path.
contract ActivationTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev Local mirror of `CollateralActivationLib.CollateralActivating` for `vm.expectEmit`.
    event CollateralActivating(address indexed borrower, uint256 amount, CollateralActivationLib.Position position);

    function setUp() public {
        vm.roll(1000);
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _safeBorrow(uint256 collat) internal view returns (uint256) {
        return collat * oraclePrice / 1e36 * 80 / 100 / 2; // half of LLTV-max, seed-safe
    }

    function _seedLenderAndCollateral(uint256 collat) internal returns (address borrower) {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
    }

    function _ban(address account) internal {
        uint40 n = uint40(block.number - 1);
        address[] memory a = new address[](1);
        a[0] = account;
        protocol.guardianSignals
            .flag(_m().id, a, BlockInfoWithHash({hash: blockhash(n), number: n, timestamp: uint40(block.timestamp)}));
    }

    /// @dev Fresh collateral cannot back a loan while activating: borrow reverts InsufficientActiveCollateral
    ///      before maturation and succeeds with exact deltas once the timer matures it.
    function test_freshCollateral_isLockedUntilMatured() public {
        Market storage m = _m();
        address borrower = _seedLenderAndCollateral(100 ether);
        uint256 borrowAmt = _safeBorrow(100 ether);

        // Before maturation the collateral is still `activating`, so it backs no borrow.
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, borrowAmt, 0, borrower, borrower);

        // Maturing it through the timer unlocks borrowing.
        m.activateCollateral();
        m.borrow(borrower, borrowAmt); // helper asserts the borrow succeeds with exact deltas
        assertEq(m.loanToken.balanceOf(borrower), borrowAmt, "borrow unlocked after maturation");
    }

    /// @dev A banned borrower's collateral never matures: even after warping past the delay, borrow reverts
    ///      AddressBanned.
    function test_bannedBorrower_staysLocked_evenPastTheTimer() public {
        Market storage m = _m();
        address borrower = _seedLenderAndCollateral(100 ether);
        _ban(borrower); // quorum 1 in the default registry -> Banned

        m.activateCollateral(); // warp past the delay; a banned lot never matures, and borrowing is blocked

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        m.core.borrow(m.params, _safeBorrow(100 ether), 0, borrower, borrower);
    }

    /// @dev A borrower granted instant activation routes collateral straight to active, so borrowing succeeds
    ///      with no warp past the timer.
    function test_instantActivation_bypassesTheTimer() public {
        Market storage m = _m();
        m.controller.grantInstantActivation(_actor("borrower"));
        address borrower = _seedLenderAndCollateral(100 ether);

        // No warp: instant activation routes the lot straight to active, so the borrow works immediately.
        uint256 borrowAmt = _safeBorrow(100 ether);
        m.borrow(borrower, borrowAmt);
        assertEq(m.loanToken.balanceOf(borrower), borrowAmt, "instant activation skips the timer");
    }

    /// @dev A fresh activating deposit emits `CollateralActivating` with the resulting position: `activating`
    ///      equals the deposit, `activatingStart` is now, and `activatingDelay` is previewed independently via
    ///      `currentActivationDelay(amount)`.
    function test_supplyCollateral_emitsActivatingPosition() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        address borrower = _actor("borrower");
        uint256 amount = 100 ether; // >= minActivationAmount -> enters the timer, not dust
        _fund(m.collateralToken, borrower, amount);

        uint256 expectedDelay = m.controller.currentActivationDelay(amount); // independent delay preview
        CollateralActivationLib.Position memory expected = CollateralActivationLib.Position({
            dust: 0,
            activating: uint128(amount),
            activatingStart: uint40(block.timestamp),
            activatingDelay: uint32(expectedDelay)
        });

        vm.prank(borrower);
        m.collateralToken.approve(address(m.core), amount);
        vm.expectEmit(true, false, false, true, address(m.controller));
        emit CollateralActivating(borrower, amount, expected);
        vm.prank(borrower);
        m.core.supplyCollateral(m.params, amount, borrower, "");
    }
}
