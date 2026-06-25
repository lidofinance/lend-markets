// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLendMarketController} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";

import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";
import {BlockInfoWithHash} from "../../src/interfaces/GuardianSignalsTypes.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice Unit/integration suite for `LidoLendMarketController`, modelled from the market-controller spec's
///         "Policy boundary" and "Freeze and pause" sections. The controller's `on` hook is driven by the
///         core, so the policy is exercised through real market actions on a fresh `setup/` stack. The
///         libraries it composes (activation/settlement/guardian) are covered in §3–5; here the focus is
///         the controller-specific policy: pause (every hook), freeze gate, borrow-utilization gap (WAD),
///         banned-borrow, active-only health, instant activation, and setter role-gating / monotonicity.
contract LidoLendMarketControllerTest is LidoLendSetup {
    using MarketActions for Market;

    MockERC20 internal loan;
    MockERC20 internal collateral;
    LidoLendMarketController internal c;

    function setUp() public {
        vm.roll(1000);
        loan = new MockERC20("Loan", "LOAN", 18);
        collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        c = LidoLendMarketController(address(protocol.markets[0].controller));
        // Grant every governance role to the test contract (admin holds DEFAULT_ADMIN).
        c.grantRole(c.RISK_STEWARD_ROLE(), address(this));
        c.grantRole(c.FREEZER_ROLE(), address(this));
        c.grantRole(c.UNFREEZER_ROLE(), address(this));
        c.grantRole(c.PAUSER_ROLE(), address(this));
        c.grantRole(c.RESUMER_ROLE(), address(this));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender liquidity + a borrower with matured collateral and an open borrow.
    function _seedBorrower(uint256 liquidity, uint256 collat, uint256 borrow)
        internal
        returns (address lender, address borrower)
    {
        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, liquidity);
        m.vaultDeposit(lender, liquidity);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, collat);
        m.supplyCollateral(borrower, collat);
        m.activateCollateral();
        if (borrow > 0) m.borrow(borrower, borrow);
    }

    function _validBlock() internal view returns (BlockInfoWithHash memory) {
        uint40 n = uint40(block.number - 1);
        return BlockInfoWithHash({hash: blockhash(n), number: n, timestamp: n});
    }

    /// @dev Flag `account` to quorum (the default registry has the test as the sole guardian, quorum 1).
    function _ban(address account) internal {
        address[] memory a = new address[](1);
        a[0] = account;
        protocol.guardianSignals.flag(_m().id, a, _validBlock());
    }

    // ── on() access ──

    function testRevert_on_nonCoreCaller_unauthorized() public {
        vm.expectRevert(ILidoLendMarketController.Unauthorized.selector);
        c.on(_m().id, ILidoLendMarketController.HookEvent.Supply, "");
    }

    function testRevert_on_wrongMarketId_invalidMarketId() public {
        Id wrongId = Id.wrap(bytes32(uint256(0xDEAD)));
        vm.prank(address(_m().core)); // authorized caller, wrong market
        vm.expectRevert(ILidoLendMarketController.InvalidMarketId.selector);
        c.on(wrongId, ILidoLendMarketController.HookEvent.Supply, "");
    }

    // ── pause: every hook reverts ──

    function test_pause_haltsActions() public {
        c.pauseFor(1 hours);
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 10 ether);
        vm.prank(lender);
        m.loanToken.approve(address(m.vault), 10 ether);
        vm.prank(lender);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        m.vault.deposit(10 ether, lender); // core.supply -> on(Supply) -> _checkResumed
    }

    function test_pause_autoResumesAfterDuration() public {
        c.pauseFor(1 hours);
        vm.warp(block.timestamp + 1 hours); // resumeSince reached -> resumed
        assertFalse(c.isPaused(), "auto-resumed after the duration");
    }

    function testRevert_pauseFor_zeroDuration() public {
        vm.expectRevert(PausableUntil.ZeroPauseDuration.selector);
        c.pauseFor(0);
    }

    function testRevert_resume_whenNotPaused() public {
        vm.expectRevert(PausableUntil.PausedExpected.selector);
        c.resume();
    }

    function test_resume_early() public {
        c.pauseFor(1 hours);
        assertTrue(c.isPaused(), "paused");
        c.resume();
        assertFalse(c.isPaused(), "resumed early");
    }

    // ── freeze gate ──

    function testRevert_freeze_blocksBorrow() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 0);
        c.freeze();
        assertTrue(c.isFrozen(), "frozen");
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.MarketIsFrozen.selector);
        _m().core.borrow(_m().params, 10 ether, 0, borrower, borrower);
    }

    function testRevert_freeze_blocksWithdrawCollateral_withDebt() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether); // open debt
        c.freeze();
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.MarketIsFrozen.selector);
        _m().core.withdrawCollateral(_m().params, 1 ether, borrower, borrower);
    }

    function test_freeze_allowsDebtFreeWithdraw() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 0); // no debt
        c.freeze();
        vm.prank(borrower);
        _m().core.withdrawCollateral(_m().params, 1 ether, borrower, borrower); // succeeds while frozen
    }

    function test_freeze_allowsRepay() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether);
        c.freeze();
        _fund(_m().loanToken, borrower, 20 ether);
        vm.prank(borrower);
        _m().loanToken.approve(address(_m().core), type(uint256).max);
        vm.prank(borrower);
        _m().core.repay(_m().params, 5 ether, 0, borrower, ""); // repay allowed while frozen
    }

    // ── borrow-utilization gap (WAD) ──

    function testRevert_borrowUtilizationGap_blocksOverMax() public {
        // gap = 50% (WAD/2) -> at most half the supply borrowable.
        c.setBorrowUtilizationGap(0.5e18);
        (, address borrower) = _seedBorrower(100 ether, 1000 ether, 0); // ample collateral
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.MaxBorrowUtilizationExceeded.selector);
        _m().core.borrow(_m().params, 60 ether, 0, borrower, borrower); // 60 > 50% of 100 supply
    }

    function test_borrowUtilizationGap_allowsUpToMax() public {
        c.setBorrowUtilizationGap(0.5e18);
        (, address borrower) = _seedBorrower(100 ether, 1000 ether, 0);
        vm.prank(borrower);
        _m().core.borrow(_m().params, 50 ether, 0, borrower, borrower); // exactly at the 50% ceiling
        assertEq(c.maxBorrowUtilization(), 0.5e18, "max = WAD - gap");
    }

    // ── banned borrow ──

    function testRevert_borrow_bannedBorrower() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 0);
        _ban(borrower); // quorum 1 -> Banned
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        _m().core.borrow(_m().params, 10 ether, 0, borrower, borrower);
    }

    // ── active-only health ──

    function testRevert_borrow_againstUnmaturedCollateral() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether); // NOT activated -> still `activating`, not `active`
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, 10 ether, 0, borrower, borrower);
    }

    // ── instant activation ──

    function test_instantActivation_borrowsWithoutWaiting() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
        address borrower = _actor("borrower");
        c.grantInstantActivation(borrower);
        assertTrue(c.hasInstantActivation(borrower), "granted");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether); // instant -> straight to active, no warp
        vm.prank(borrower);
        m.core.borrow(m.params, 10 ether, 0, borrower, borrower); // succeeds immediately
    }

    // ── setter role-gating ──

    function testRevert_freeze_wrongRole() public {
        vm.prank(_actor("nobody"));
        vm.expectRevert();
        c.freeze();
    }

    function testRevert_pauseFor_wrongRole() public {
        vm.prank(_actor("nobody"));
        vm.expectRevert();
        c.pauseFor(1 hours);
    }

    function testRevert_setBorrowUtilizationGap_wrongRole() public {
        vm.prank(_actor("nobody"));
        vm.expectRevert();
        c.setBorrowUtilizationGap(0.5e18);
    }

    function testRevert_grantInstantActivation_wrongRole() public {
        vm.prank(_actor("nobody"));
        vm.expectRevert();
        c.grantInstantActivation(_actor("borrower"));
    }

    // ── setter monotonicity ──

    function testRevert_increaseBorrowUtilizationGap_notTightened() public {
        c.setBorrowUtilizationGap(0.5e18);
        vm.expectRevert(ILidoLendMarketController.ConfigNotTightened.selector);
        c.increaseBorrowUtilizationGap(0.4e18); // lower -> not tightened
    }

    function testRevert_increaseBorrowUtilizationGap_aboveWad() public {
        vm.expectRevert(ILidoLendMarketController.BorrowUtilizationGapTooHigh.selector);
        c.increaseBorrowUtilizationGap(1e18); // >= WAD
    }

    function testRevert_increaseMinActivationDelay_notTightened() public {
        // The default min is 10 minutes; a lower value is not a tightening.
        vm.expectRevert(ILidoLendMarketController.ConfigNotTightened.selector);
        c.increaseMinActivationDelay(60);
    }

    // ── views ──

    function test_views_defaults() public view {
        assertFalse(c.isFrozen(), "not frozen initially");
        assertFalse(c.isPaused(), "not paused initially");
        assertEq(c.maxBorrowUtilization(), 1e18, "no gap -> full utilization allowed");
    }
}
