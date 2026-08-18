// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice L2 collateral-activation scenarios end-to-end through the controller hooks: fresh collateral is
///         locked in a maturation timer before it can back a loan; maturing it unlocks borrowing; a guardian
///         ban keeps it locked regardless; and instant activation bypasses the timer. The activation/guardian
///         math is unit-tested in isolation — here the focus is the integrated supply->hook->borrow path.
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
        _flagAs(address(this), account);
    }

    /// @dev Guardian `guardian` flags `account` on its own behalf.
    function _flagAs(address guardian, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(guardian);
        protocol.guardianSignals.flag(_m().id, guardian, accounts);
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

    /// @dev End-to-end delegate path: a guardian appoints a delegate, the delegate raises the flag on the
    ///      guardian's behalf, and the resulting ban blocks borrowing through the controller just like a direct
    ///      flag — proving the `onBehalf`/delegate wiring works across the full stack.
    function test_delegateBan_blocksBorrow() public {
        Market storage m = _m();
        address borrower = _seedLenderAndCollateral(100 ether);

        // The test contract is the sole guardian; it appoints a delegate to act for it.
        address delegate = _actor("delegate");
        protocol.guardianSignals.setDelegate(delegate);

        // The delegate flags the borrower on the guardian's behalf, latching the ban.
        address[] memory accounts = new address[](1);
        accounts[0] = borrower;
        vm.prank(delegate);
        protocol.guardianSignals.flag(_m().id, address(this), accounts);

        m.activateCollateral(); // warp past the delay; a banned lot never matures

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        m.core.borrow(m.params, _safeBorrow(100 ether), 0, borrower, borrower);
    }

    /// @dev End-to-end: pruning a departed guardian's stale flag cannot un-ban a borrower whose ban is latched —
    ///      the controller keeps blocking its borrow. (Only `unban` clears a latched ban.)
    function test_prune_cannotUnbanLatchedBanThroughController() public {
        Market storage m = _m();
        address borrower = _seedLenderAndCollateral(100 ether);

        // Three guardians at quorum 2; two flag the borrower, latching the ban.
        address guardian2 = _actor("guardian2");
        address guardian3 = _actor("guardian3");
        protocol.guardianSignals.addGuardian(guardian2);
        protocol.guardianSignals.addGuardian(guardian3);
        protocol.guardianSignals.setQuorum(2);
        _flagAs(address(this), borrower);
        _flagAs(guardian2, borrower);
        assertTrue(protocol.guardianSignals.isBanned(m.id, borrower), "latched at quorum");

        protocol.guardianSignals.removeGuardian(guardian2);
        protocol.guardianSignals.prune(m.id, borrower); // stale flag pruned, but the latched ban stays

        m.activateCollateral();
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        m.core.borrow(m.params, _safeBorrow(100 ether), 0, borrower, borrower);
    }

    /// @dev A borrower granted instant activation routes collateral straight to active, so borrowing succeeds
    ///      with no warp past the timer.
    function test_instantActivation_bypassesTheTimer() public {
        Market storage m = _m();
        m.controller.setInstantActivation(_actor("borrower"), true);
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

    function test_minDeposit_boundsDustFundersBeforeActivation() public {
        Market storage m = _m();
        address borrower = _actor("borrower");

        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 2 ether;
        m.controller.setCollateralActivationConfig(cfg);

        for (uint256 i; i < 8; ++i) {
            address spammer = address(uint160(0xBAD0 + i));
            uint256 spamAmount = uint256(cfg.minDepositAmount) - 1;
            _fund(m.collateralToken, spammer, spamAmount);

            vm.prank(spammer);
            m.collateralToken.approve(address(m.core), spamAmount);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CollateralActivationLib.DepositTooSmall.selector, spamAmount, cfg.minDepositAmount
                )
            );
            vm.prank(spammer);
            m.core.supplyCollateral(m.params, spamAmount, borrower, "");
        }

        ILidoLendMarketController.BorrowerPosition memory position = m.controller.positionOf(borrower);
        assertEq(position.dust, 0, "rejected spam cannot add dust");
        assertEq(position.activating, 0, "rejected spam cannot start activation");
        assertEq(m.core.position(m.id, borrower).collateral, 0, "rejected spam cannot add collateral");

        for (uint256 i; i < 5; ++i) {
            address funder = address(uint160(0xCAFE + i));
            _fund(m.collateralToken, funder, cfg.minDepositAmount);

            vm.prank(funder);
            m.collateralToken.approve(address(m.core), cfg.minDepositAmount);
            vm.prank(funder);
            m.core.supplyCollateral(m.params, cfg.minDepositAmount, borrower, "");
        }

        position = m.controller.positionOf(borrower);
        assertEq(position.dust, 0, "threshold consumes all dust");
        assertEq(position.activating, cfg.minActivationAmount, "fifth accepted funder starts activation");
        assertEq(m.core.position(m.id, borrower).collateral, cfg.minActivationAmount, "only accepted deposits land");
    }

    function test_maxLock_preventsRecyclingActivationCapital() public {
        Market storage m = _m();
        address borrower = _actor("borrower");

        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 2 ether;
        cfg.activatingLockAmount = type(uint128).max;
        cfg.activatingLockDuration = cfg.maxActivationDelay;
        m.controller.setCollateralActivationConfig(cfg);

        uint256 fundersPerActivation = cfg.minActivationAmount / cfg.minDepositAmount;
        for (uint256 batch; batch < 2; ++batch) {
            for (uint256 i; i < fundersPerActivation; ++i) {
                address funder = address(uint160(0xD000 + batch * fundersPerActivation + i));
                _fund(m.collateralToken, funder, cfg.minDepositAmount);

                vm.prank(funder);
                m.collateralToken.approve(address(m.core), cfg.minDepositAmount);
                vm.prank(funder);
                m.core.supplyCollateral(m.params, cfg.minDepositAmount, borrower, "");
            }

            uint256 expectedLocked = (batch + 1) * uint256(cfg.minActivationAmount);
            ILidoLendMarketController.BorrowerPosition memory position = m.controller.positionOf(borrower);
            assertEq(position.dust, 0, "threshold crossing consumes the dust batch");
            assertEq(position.activating, expectedLocked, "each trigger adds another locked threshold");
            assertEq(m.core.position(m.id, borrower).collateral, expectedLocked, "trigger capital remains posted");

            vm.expectRevert(ILidoLendMarketController.ActivationLockActive.selector);
            vm.prank(borrower);
            m.core.withdrawCollateral(m.params, cfg.minActivationAmount, borrower, address(0xBEEF));
        }
    }
}
