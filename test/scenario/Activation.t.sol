// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

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
        address borrower = _actor("borrower");
        m.controller.setInstantActivation(borrower, true);

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        // `supplyCollateral` helper models the non-instant path only (a sub-threshold amount stays dust,
        // otherwise the lot enters activating); an instant supply lands straight in active, so bypass the
        // helper and call core directly.
        uint256 collat = 100 ether;
        _fund(m.collateralToken, borrower, collat);
        vm.prank(borrower);
        m.collateralToken.approve(address(m.core), collat);
        vm.prank(borrower);
        m.core.supplyCollateral(m.params, collat, borrower, "");

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

    /// @notice One CollateralActivating transition admits at most two normal supplies: one dust supply
    ///         (allowed only over an empty dust bucket) and one resolving supply that promotes the lot.
    function test_twoSupplyBound_perActivationTransition() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        address funder = _actor("funder");

        uint256 minActivation = m.controller.collateralActivationConfig().minActivationAmount;
        uint256 dustAmount = 1 ether; // sub-threshold under the default 10 ether minActivationAmount

        _fund(m.collateralToken, borrower, minActivation); // covers both of the borrower's own supplies below
        _fund(m.collateralToken, funder, dustAmount);

        m.supplyCollateral(borrower, dustAmount); // dust supply #1

        // A second sub-threshold supply onto existing dust reverts instead of stacking a second dust lot —
        // the rule tracks the borrower's position, not the caller, so a distinct funder trips it too.
        vm.prank(funder);
        m.collateralToken.approve(address(m.core), dustAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralActivationLib.DustNotResolved.selector, dustAmount, dustAmount, minActivation
            )
        );
        vm.prank(funder);
        m.core.supplyCollateral(m.params, dustAmount, borrower, "");

        // the resolving supply promotes the whole lot in one CollateralActivating transition
        m.supplyCollateral(borrower, minActivation - dustAmount);

        ILidoLendMarketController.BorrowerPosition memory position = m.controller.positionOf(borrower);
        assertEq(position.dust, 0, "dust cleared by the resolving supply");
        assertEq(position.activating, minActivation, "resolving supply promotes the whole lot");
    }

    /// @notice Documents the dust-donation front-run: a stranger's sub-threshold supply on the victim's behalf
    ///         forces the victim's next supply to resolve the donated dust — by resizing to the threshold or
    ///         ejecting the dust in full. Funds are never stuck.
    function test_dustDonation_victimResolvesByResizeOrEject() public {
        Market storage m = _m();
        address attacker = _actor("attacker");
        address victim = _actor("victim");
        uint256 minActivation = m.controller.collateralActivationConfig().minActivationAmount;

        _fund(m.collateralToken, attacker, 1 ether);
        _fund(m.collateralToken, victim, 2 ether);

        // attacker donates dust to victim (onBehalf supply, so the helper is bypassed on purpose)
        vm.prank(attacker);
        m.collateralToken.approve(address(m.core), 1 ether);
        vm.prank(attacker);
        m.core.supplyCollateral(m.params, 1 ether, victim, "");

        // victim's planned sub-threshold supply now reverts
        vm.prank(victim);
        m.collateralToken.approve(address(m.core), 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralActivationLib.DustNotResolved.selector, 1 ether, 2 ether, minActivation)
        );
        vm.prank(victim);
        m.core.supplyCollateral(m.params, 2 ether, victim, "");

        // resolution 1: eject the donated dust in full
        m.withdrawCollateral(victim, 1 ether, victim);
        assertEq(m.controller.positionOf(victim).dust, 0, "donated dust ejected in full");
    }

    /// @notice Forced seizure consumes matured collateral first and leaves the fresh lot on its timer.
    function test_liquidation_activeFirst_freshLotSurvivesOnTimer() public {
        Market storage m = _m();

        // arrange: borrower has matured active collateral backing debt, plus a fresh activating top-up.
        address borrower = _seedLenderAndCollateral(100 ether); // 100 ether enters activating
        m.activateCollateral(); // warp past the max activation delay
        uint256 borrowAmt = _safeBorrow(100 ether); // half of LLTV-max on the original 100 ether, seed-safe
        m.borrow(borrower, borrowAmt); // matures the 100 ether into active (sync fires inside the borrow hook)

        uint256 freshTopUp = 20 ether; // >= minActivationAmount (10 ether default) -> activating, not dust
        _fund(m.collateralToken, borrower, freshTopUp);
        m.supplyCollateral(borrower, freshTopUp); // fresh lot, own new timer; the matured 100 ether stays active

        ILidoLendMarketController.BorrowerPosition memory pre = m.controller.positionOf(borrower);
        assertEq(pre.active, 100 ether, "matured lot is active before the crash");
        assertEq(pre.activating, freshTopUp, "fresh top-up is activating before the crash");

        // drop the oracle price to make him liquidatable: the core's own health check sums ALL raw collateral
        // (active + activating), so at 38% of the seed price the full 120 ether no longer covers the debt at
        // LLTV (unhealthy) while still exceeding the debt outright (solvent, not bad debt).
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 38 / 100);

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        uint256 seizeAmt = 10 ether; // well under the 100 ether active balance
        m.liquidate(keeper, borrower, seizeAmt, 0); // helper asserts no bad debt

        // assert the bucket split before/after: activating and unlockTime unchanged, active reduced by
        // exactly the seized amount — the forced seizure consumed matured collateral first.
        ILidoLendMarketController.BorrowerPosition memory post = m.controller.positionOf(borrower);
        assertEq(post.activating, pre.activating, "fresh lot untouched by the seizure");
        assertEq(post.unlockTime, pre.unlockTime, "fresh lot keeps its original timer");
        assertEq(post.active, pre.active - seizeAmt, "active reduced by exactly the seized amount");
    }

    function test_maxLock_preventsRecyclingActivationCapital() public {
        Market storage m = _m();
        address borrower = _actor("borrower");

        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        cfg.minActivationAmount = 10 ether;
        cfg.minDepositAmount = 2 ether;
        cfg.activatingLockDuration = cfg.maxActivationDelay;
        m.controller.setCollateralActivationConfig(cfg);

        // At most one unresolved dust lot is allowed per borrower: a single dust supply, then a resolving
        // supply that lifts the combined amount to the threshold.
        uint256[2] memory supplies =
            [uint256(cfg.minDepositAmount), uint256(cfg.minActivationAmount) - cfg.minDepositAmount];
        for (uint256 batch; batch < 2; ++batch) {
            for (uint256 i; i < supplies.length; ++i) {
                address funder = address(uint160(0xD000 + batch * supplies.length + i));
                uint256 supplyAmount = supplies[i];
                _fund(m.collateralToken, funder, supplyAmount);

                vm.prank(funder);
                m.collateralToken.approve(address(m.core), supplyAmount);
                vm.prank(funder);
                m.core.supplyCollateral(m.params, supplyAmount, borrower, "");
            }

            uint256 expectedLocked = (batch + 1) * uint256(cfg.minActivationAmount);
            ILidoLendMarketController.BorrowerPosition memory position = m.controller.positionOf(borrower);
            assertEq(position.dust, 0, "threshold crossing consumes the dust batch");
            assertEq(position.activating, expectedLocked, "each trigger adds another locked threshold");
            assertEq(m.core.position(m.id, borrower).collateral, expectedLocked, "trigger capital remains posted");

            // The lib reverts directly whenever the request dips into a lot still inside activatingLockDuration —
            // and with no matured active collateral here, that is any requested amount.
            vm.expectRevert(
                abi.encodeWithSelector(
                    CollateralActivationLib.ActivatingCollateralLocked.selector,
                    expectedLocked,
                    block.timestamp + cfg.activatingLockDuration
                )
            );
            vm.prank(borrower);
            m.core.withdrawCollateral(m.params, cfg.minActivationAmount, borrower, address(0xBEEF));
        }
    }

    /// @notice A non-instant supply below the configured `minDepositAmount` floor reverts `DepositTooSmall`.
    function test_supplyCollateral_revertsBelowMinDepositAmount() public {
        Market storage m = _m();
        address borrower = _actor("borrower");

        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        cfg.minDepositAmount = 2 ether;
        m.controller.setCollateralActivationConfig(cfg);

        uint256 amount = 1 ether; // below minDepositAmount
        _fund(m.collateralToken, borrower, amount);
        vm.prank(borrower);
        m.collateralToken.approve(address(m.core), amount);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralActivationLib.DepositTooSmall.selector, amount, cfg.minDepositAmount)
        );
        vm.prank(borrower);
        m.core.supplyCollateral(m.params, amount, borrower, "");
    }
}
