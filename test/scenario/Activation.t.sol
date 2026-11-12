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

    /// @dev 100 ether matured collateral backs a half-capacity loan, then a fresh 20 ether lot starts its timer. At
    ///      38% of the seed price a keeper seizes exactly the 100 ether active balance. The borrower keeps debt, no
    ///      active collateral and the whole maturing lot.
    function _seizeAllActive() internal returns (address borrower) {
        Market storage m = _m();
        borrower = _seedLenderAndCollateral(100 ether);
        m.activateCollateral();
        m.borrow(borrower, _safeBorrow(100 ether));
        _fund(m.collateralToken, borrower, 20 ether);
        m.supplyCollateral(borrower, 20 ether);

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 38 / 100);
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        m.liquidate(keeper, borrower, 100 ether, 0);

        ILidoLendMarketController.BorrowerPosition memory position = m.controller.positionOf(borrower);
        assertEq(position.active, 0, "setup: all active collateral seized");
        assertEq(position.dust, 0, "setup: no dust");
        assertEq(position.activating, 20 ether, "setup: the lot is untouched");
        assertLt(block.timestamp, position.unlockTime, "setup: the lot is still maturing");
        assertGt(position.debtAssets, 0, "setup: debt remains");
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

    /// @dev Without a guardian quorum a lot matures only once `maxGuardiansQuorumDelay` has also elapsed, which a
    ///      non-zero config sets above `maxActivationDelay`. `activateCollateral` must wait for both.
    function test_activateCollateral_waitsOutGuardiansQuorumDelay() public {
        Market storage m = _m();
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        cfg.maxGuardiansQuorumDelay = cfg.maxActivationDelay + 1 hours;
        m.controller.setCollateralActivationConfig(cfg);
        address borrower = _seedLenderAndCollateral(100 ether);
        uint256 borrowAmt = _safeBorrow(100 ether);

        m.activateCollateral();
        m.borrow(borrower, borrowAmt);
        assertEq(m.loanToken.balanceOf(borrower), borrowAmt, "borrow unlocked after the quorum delay");
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

    /// @dev The liquidate and settle hooks do not call `sync`, so `seize` reads the stored buckets. A lot that is
    ///      past its unlock time but has no `sync` yet still counts as activating. `seize` then takes the uncovered
    ///      part from dust first and from that lot second. After a `sync`, the same seizure takes only active
    ///      collateral and keeps the dust.
    function test_liquidation_maturedLotWithoutSync_seizesDustBeforeTheLot() public {
        Market storage m = _m();
        address borrower = _seedLenderAndCollateral(100 ether);
        m.activateCollateral();
        m.borrow(borrower, _safeBorrow(100 ether));

        // A 20 ether lot starts its timer, then a 5 ether deposit below the activation threshold lands as dust.
        _fund(m.collateralToken, borrower, 25 ether);
        m.supplyCollateral(borrower, 20 ether);
        m.supplyCollateral(borrower, 5 ether);
        m.activateCollateral();

        ILidoLendMarketController.BorrowerPosition memory pre = m.controller.positionOf(borrower);
        assertEq(pre.active, 100 ether, "setup: active collateral");
        assertEq(pre.activating, 20 ether, "setup: the lot has no sync yet");
        assertEq(pre.dust, 5 ether, "setup: dust");
        assertGe(block.timestamp, pre.unlockTime, "setup: the lot is past its unlock time");

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        uint256 seizeAmt = 110 ether; // 10 ether more than the stored active balance
        uint256 snapshot = vm.snapshotState();

        // No sync: the 10 ether above the stored active balance comes from 5 ether dust, then 5 ether of the lot.
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 38 / 100);
        m.liquidate(keeper, borrower, seizeAmt, 0);
        ILidoLendMarketController.BorrowerPosition memory stored = m.controller.positionOf(borrower);
        assertEq(stored.dust, 0, "no sync: the seizure takes all dust");
        assertEq(stored.activating, 15 ether, "no sync: the seizure takes the rest from the lot");
        assertEq(stored.active, 0, "no sync: no active collateral remains");

        // Sync first: a one-unit borrow matures the lot, so the 120 ether active balance covers the seizure.
        vm.revertToState(snapshot);
        vm.prank(borrower);
        m.core.borrow(m.params, 1, 0, borrower, borrower);
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 38 / 100);
        m.liquidate(keeper, borrower, seizeAmt, 0);
        ILidoLendMarketController.BorrowerPosition memory synced = m.controller.positionOf(borrower);
        assertEq(synced.dust, 5 ether, "sync first: the dust stays");
        assertEq(synced.activating, 0, "sync first: the lot is active");
        assertEq(synced.active, 10 ether, "sync first: the seizure takes only active collateral");
    }

    /// @dev A maturing lot gives no borrow capacity, so a borrower whose active collateral was all seized cannot
    ///      borrow even one asset unit while it still owes debt.
    function testRevert_borrow_activeSeizedToZero_maturingLotGivesNoCapacity() public {
        Market storage m = _m();
        address borrower = _seizeAllActive();

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, 1, 0, borrower, borrower);
    }

    /// @dev Core health counts the maturing lot, so a further price drop makes the position liquidatable. With
    ///      active and dust empty, the seizure comes from the activating lot, ignores its timer and keeps its unlock
    ///      time.
    function test_liquidation_activeZero_seizesFromMaturingLot() public {
        Market storage m = _m();
        address borrower = _seizeAllActive();
        ILidoLendMarketController.BorrowerPosition memory pre = m.controller.positionOf(borrower);

        // At 25% of the seed price the 20 ether lot no longer covers the debt at LLTV, but it still exceeds it.
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 25 / 100);
        uint256 seizeAmt = 10 ether;
        m.liquidate(_actor("keeper"), borrower, seizeAmt, 0); // helper asserts no bad debt

        ILidoLendMarketController.BorrowerPosition memory post = m.controller.positionOf(borrower);
        assertEq(post.activating, pre.activating - seizeAmt, "seizure taken from the activating lot");
        assertEq(post.active, 0, "active stays empty");
        assertEq(post.unlockTime, pre.unlockTime, "the remaining lot keeps its timer");
        assertLt(block.timestamp, post.unlockTime, "the lot is still maturing");
        assertGt(post.debtAssets, 0, "debt remains after the partial seizure");
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

    // ---
    // KNOWN ISSUES AND SPECIFIED EDGE BEHAVIOUR
    // ---

    /// @dev A guardian ban on an instant-activation caller does not remove its grant. Only `MANAGER_ROLE` can enable
    ///      such a caller, and no caller is enabled at launch.
    function test_bannedRouter_landsFreshBorrowerCollateralActive() public {
        Market storage m = _m();
        address router = _actor("router");
        m.setInstantActivation(router, true);
        _ban(router);
        assertTrue(protocol.guardianSignals.isBanned(m.id, router), "setup: router is banned");
        assertTrue(m.controller.hasInstantActivation(router), "the ban keeps the instant grant");

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        address fresh = _actor("fresh");
        uint256 collat = 100 ether;
        _fund(m.collateralToken, router, collat);
        m.supplyCollateralInstant(router, fresh, collat); // helper asserts nothing enters the timer

        ILidoLendMarketController.BorrowerPosition memory position = m.controller.positionOf(fresh);
        assertEq(position.active, collat, "the banned router's supply lands active");
        assertEq(position.activating, 0, "no lot on the timer");

        m.borrow(fresh, _safeBorrow(collat));

        vm.prank(router);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        m.core.borrow(m.params, 1 ether, 0, router, router);
    }

    /// @dev A freeze does not stop an instant supply. Only a caller that `MANAGER_ROLE` enables can make this supply.
    function test_instantSupplyDuringFreeze_isActiveOnUnfreeze() public {
        Market storage m = _m();
        address router = _actor("router");
        m.setInstantActivation(router, true);

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        m.freeze();
        address fresh = _actor("fresh");
        uint256 collat = 100 ether;
        _fund(m.collateralToken, router, collat);
        m.supplyCollateralInstant(router, fresh, collat);
        m.unfreeze();

        assertEq(m.controller.positionOf(fresh).active, collat, "the frozen-time supply is active on unfreeze");
        m.borrow(fresh, _safeBorrow(collat));
    }

    /// @dev With no activating lock, an instant supply and an equal withdrawal make a throttled lot active in the same
    ///      block. Only a caller that `MANAGER_ROLE` enables can make the instant supply.
    function test_instantSupplyThenWithdraw_laundersThrottledLot() public {
        Market storage m = _m();
        uint256 lot = 100 ether;
        address router = _actor("router");
        m.setInstantActivation(router, true);
        address bob = _seedLenderAndCollateral(lot); // lot enters the timer
        assertEq(m.controller.positionOf(bob).activating, lot, "setup: the lot is throttled");
        assertEq(m.controller.positionOf(bob).active, 0, "setup: no active collateral");

        _fund(m.collateralToken, router, lot);
        m.supplyCollateralInstant(router, bob, lot);
        m.withdrawCollateral(bob, lot, bob); // drains the activating bucket, not the instant amount

        ILidoLendMarketController.BorrowerPosition memory position = m.controller.positionOf(bob);
        assertEq(position.activating, 0, "throttled bucket drained");
        assertEq(position.active, lot, "the throttled lot is now active");
        assertEq(position.unlockTime, 0, "the timer is cleared");

        m.borrow(bob, _safeBorrow(lot));
    }

    /// @dev Inside a nonzero activating lock, the same round trip draws from active collateral, so the lot stays
    ///      throttled.
    function test_launderInsideLock_drawsFromActive() public {
        Market storage m = _m();
        uint256 lot = 100 ether;
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        cfg.activatingLockDuration = 1 hours;
        m.setActivationConfig(cfg);
        address router = _actor("router");
        m.setInstantActivation(router, true);
        address bob = _seedLenderAndCollateral(lot);

        _fund(m.collateralToken, router, lot);
        m.supplyCollateralInstant(router, bob, lot);
        m.withdrawCollateral(bob, lot, bob);

        ILidoLendMarketController.BorrowerPosition memory position = m.controller.positionOf(bob);
        assertEq(position.activating, lot, "the throttled lot stays on its timer");
        assertEq(position.active, 0, "the withdrawal took the instant amount");

        vm.prank(bob);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, 1, 0, bob, bob);
    }

    /// @dev Specified behaviour: one caller can split 50 lots of 200 ether over fresh addresses. Then the first
    ///      lot gets the delay of a 200 ether inflow, and the last lot gets the max delay. After one hour the first
    ///      address borrows and the last cannot.
    ///      Mechanism: `credit` freezes each lot's `activatingDelay` from the market inflow at that lot's own deposit.
    ///      A later deposit raises the inflow but never the frozen delay of another position. `market-controller.md`
    ///      states that a lot keeps the base delay quoted at its start.
    ///      Same cause: the split works with any lot at or above `minActivationAmount` and any number of addresses. It
    ///      works in one transaction or across several transactions and blocks. Splits within one address gain
    ///      nothing, because its lots share one timer. A guardian ban still blocks the borrow. This test covers one
    ///      caller that splits in one transaction.
    function test_splitAcrossAddresses_underThrottlesEarlyLots() public {
        Market storage m = _m();
        uint256 lots = 50;
        uint256 lot = 200 ether; // lots * lot == maxDelayInflow
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        assertEq(lots * lot, cfg.maxDelayInflow, "setup: the split sums to the inflow cap");

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        address funder = _actor("funder");
        _fund(m.collateralToken, funder, lots * lot);
        uint256 startTime = block.timestamp;
        for (uint256 i = 1; i <= lots; ++i) {
            m.supplyCollateralOnBehalf(funder, _splitAddress(i), lot);
        }

        address first = _splitAddress(1);
        address last = _splitAddress(lots);
        uint256 firstDelay = m.controller.positionOf(first).unlockTime - startTime;
        uint256 lastDelay = m.controller.positionOf(last).unlockTime - startTime;

        uint256 expectedFirstDelay = uint256(cfg.minActivationDelay)
            + (uint256(cfg.maxActivationDelay) - cfg.minActivationDelay) * lot / cfg.maxDelayInflow;
        assertEq(firstDelay, expectedFirstDelay, "the first lot gets the delay of one lot of inflow");
        assertEq(lastDelay, cfg.maxActivationDelay, "the last lot freezes the max delay");

        vm.warp(startTime + 1 hours);
        m.borrow(first, _safeBorrow(lot));

        vm.prank(last);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, 1, 0, last, last);
    }

    function _splitAddress(uint256 i) internal pure returns (address) {
        return address(uint160(0xA0000 + i));
    }
}
