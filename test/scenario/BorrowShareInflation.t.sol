// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice L2 guard against the first-borrower borrow-share inflation DoS. On a market with zero borrow assets,
///         a repay that drains borrow assets to zero while leaving shares outstanding would let the next 1-wei
///         borrow mint `toSharesUp(1, 0, shares) ≈ shares` — doubling total borrow shares each cheap cycle until
///         they overflow `uint128` and every borrow reverts. The controller's repay hook vetoes exactly the
///         re-zeroing repay, so the loop never starts; legitimate repays (partial, or a full unwind to zero
///         shares) are untouched.
contract BorrowShareInflationTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev Morpho virtual-shares constant: a fresh borrow of `a` assets mints exactly `a * VIRTUAL_SHARES`.
    uint256 internal constant VIRTUAL_SHARES = 1e6;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Seed liquidity and a matured collateral position for `borrower`, then approve the core to pull repays.
    function _fundedBorrower(address borrower, uint256 collat) internal {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();

        _fund(m.loanToken, borrower, 1 ether); // enough to cover any wei-sized repay
        vm.prank(borrower);
        m.loanToken.approve(address(m.core), type(uint256).max);
    }

    /// @dev The attack's re-zeroing step: after a 1-wei borrow (TBA=1, TBS=1e6), repaying a single share drains
    ///      TBA to zero (`toAssetsUp(1,1,1e6)=1`) while 1e6-1 shares linger. The hook must veto it.
    function test_repay_reZeroingBorrowAssets_reverts() public {
        Market storage m = _m();
        address attacker = _actor("attacker");
        _fundedBorrower(attacker, 100 ether);

        vm.prank(attacker);
        (, uint256 shares) = m.core.borrow(m.params, 1, 0, attacker, attacker);
        assertEq(shares, VIRTUAL_SHARES, "fresh 1-wei borrow mints exactly VIRTUAL_SHARES");
        assertEq(m.core.market(m.id).totalBorrowAssets, 1, "TBA seeded at 1");

        // Repay a single share: assets = toAssetsUp(1,1,1e6) = 1 => TBA -> 0, TBS -> 1e6-1 > 0.
        vm.prank(attacker);
        vm.expectRevert(ILidoLendMarketController.RepayWouldStrandBorrowShares.selector);
        m.core.repay(m.params, 0, 1, attacker, "");
    }

    /// @dev The assets path cannot strand: draining TBA to zero by repaying `assets` removes `toSharesDown`
    ///      shares proportional to those assets, which clears every share too (a full unwind), so it is allowed.
    function test_repay_drainByAssets_isFullUnwind_allowed() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);

        vm.prank(borrower);
        m.core.borrow(m.params, 1, 0, borrower, borrower); // TBA=1, TBS=1e6

        // Repay the 1 wei by assets: toSharesDown(1,1,1e6) = 1e6 => TBA -> 0 AND TBS -> 0. Permitted.
        vm.prank(borrower);
        m.core.repay(m.params, 1, 0, borrower, "");
        assertEq(m.core.market(m.id).totalBorrowShares, 0, "no shares stranded");
        assertEq(m.core.market(m.id).totalBorrowAssets, 0, "borrow assets cleared");
    }

    /// @dev A full unwind that clears every share is allowed even though it drains TBA to zero — this is how an
    ///      honest sole borrower closes out.
    function test_repay_fullUnwind_toZeroShares_allowed() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);

        vm.prank(borrower);
        (, uint256 shares) = m.core.borrow(m.params, 1, 0, borrower, borrower); // TBA=1, TBS=1e6

        // Repay ALL shares: assets = toAssetsUp(1e6,1,1e6) = 1 => TBA -> 0 AND TBS -> 0. Permitted.
        vm.prank(borrower);
        m.core.repay(m.params, 0, shares, borrower, "");
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "borrower debt cleared");
        assertEq(m.core.market(m.id).totalBorrowShares, 0, "no shares stranded");
        assertEq(m.core.market(m.id).totalBorrowAssets, 0, "borrow assets cleared");
    }

    /// @dev A partial repay that leaves borrow assets positive is untouched by the guard.
    function test_repay_partial_leavesAssets_allowed() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fundedBorrower(borrower, 100 ether);

        vm.prank(borrower);
        (, uint256 shares) = m.core.borrow(m.params, 10 ether, 0, borrower, borrower);

        // Repay half the shares: TBA stays well above zero, so the guard does not fire.
        vm.prank(borrower);
        m.core.repay(m.params, 0, shares / 2, borrower, "");
        assertGt(m.core.market(m.id).totalBorrowAssets, 0, "borrow assets remain");
        assertGt(m.core.market(m.id).totalBorrowShares, 0, "borrow shares remain");
    }

    /// @dev With the re-zeroing blocked, the market never enters the inflated-price state, so an honest borrower
    ///      can still borrow after an attacker's attempt — no lingering DoS.
    function test_marketRemainsBorrowable_afterBlockedAttempt() public {
        Market storage m = _m();
        address attacker = _actor("attacker");
        _fundedBorrower(attacker, 100 ether);

        vm.prank(attacker);
        m.core.borrow(m.params, 1, 0, attacker, attacker);
        vm.prank(attacker);
        vm.expectRevert(ILidoLendMarketController.RepayWouldStrandBorrowShares.selector);
        m.core.repay(m.params, 0, 1, attacker, "");

        // Honest borrower posts collateral and borrows a normal amount, unhindered.
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, 10 ether);
        assertEq(m.loanToken.balanceOf(borrower), 10 ether, "honest borrow succeeds");
    }
}
