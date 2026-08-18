// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../../src/libs/CollateralActivationLib.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice L2 scenarios for the suspect surcharge on collateral activation, end-to-end through a real guardian
///         registry and controller. The controller reads a cached snapshot of the suspect set — a count plus one
///         expiry taken from the newest report in it — and the registry rebuilds that snapshot only on a report,
///         a retraction that removes a live report, or a prune that removes a former guardian's report. Between
///         rebuilds the cached count can therefore exceed the reports actually live. These tests pin where that
///         stale count reaches a borrower's activation delay and where it cannot.
contract SuspectDelayTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev Local mirror of `IGuardianSignals.SuspectPruned` for `vm.expectEmit`.
    event SuspectPruned(Id indexed marketId, address indexed account, address indexed guardian);

    uint40 internal constant SUSPECT_WINDOW = 7 days;
    uint32 internal constant DELAY_PER_SUSPECT = 1 hours;
    uint256 internal constant COLLATERAL = 100 ether;

    address internal guardian1;
    address internal guardian2;
    address internal guardian3; // never reports; stands in for an uninvolved committee member
    address internal borrower;

    /// @dev The shared default config zeroes both suspect parameters, which multiplies the whole surcharge away.
    ///      This suite turns them on at representative non-zero values.
    function setUp() public {
        vm.roll(1000);
        guardian1 = _actor("guardian1");
        guardian2 = _actor("guardian2");
        guardian3 = _actor("guardian3");
        borrower = _actor("borrower");

        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.suspectWindow = SUSPECT_WINDOW;
        cfg.activation.delayPerSuspect = DELAY_PER_SUSPECT;
        cfg.guardians = new address[](3);
        cfg.guardians[0] = guardian1;
        cfg.guardians[1] = guardian2;
        cfg.guardians[2] = guardian3;
        cfg.quorum = 2;
        _deployProtocol(cfg);
    }

    // ── helpers ──

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Guardian `guardian` reports the borrower as suspect on its own behalf.
    function _suspect(address guardian) internal {
        Market storage m = _m();
        address[] memory accounts = new address[](1);
        accounts[0] = borrower;
        vm.prank(guardian);
        m.guardianSignals.suspect(m.id, guardian, accounts);
    }

    /// @dev Guardian `guardian` retracts its own suspect report on the borrower.
    function _unsuspect(address guardian) internal {
        Market storage m = _m();
        address[] memory accounts = new address[](1);
        accounts[0] = borrower;
        vm.prank(guardian);
        m.guardianSignals.unsuspect(m.id, guardian, accounts);
    }

    /// @dev Suspect reports on the borrower that are live right now, recomputed from the raw reporter set rather
    ///      than read from the cached snapshot. This is the count a rebuild at this instant would produce.
    function _liveSuspectCount() internal view returns (uint256 live) {
        Market storage m = _m();
        (address[] memory reporters, uint40[] memory reportedAt) = m.guardianSignals.getSuspectedBy(m.id, borrower);
        uint256 window = m.guardianSignals.getSuspectWindow();
        for (uint256 i; i < reporters.length; ++i) {
            if (uint256(reportedAt[i]) + window >= block.timestamp) ++live;
        }
    }

    function _cachedSuspectCount() internal view returns (uint256) {
        return _m().guardianSignals.getOpinion(_m().id, borrower).suspectCount;
    }

    /// @dev Both guardians report, then the window lapses on both with nothing rebuilding the snapshot. Leaves the
    ///      reports stored but lapsed, and the cached count at 2.
    function _lapseBothReports() internal {
        _suspect(guardian1);
        vm.warp(block.timestamp + 1 days);
        _suspect(guardian2); // rebuild: count 2, expiry anchored to this report
        vm.warp(block.timestamp + SUSPECT_WINDOW + 1);
    }

    /// @dev Supply the borrower's collateral into the activation timer. Returns its unlock time and the unlock
    ///      time the base delay alone gives (`activatingStart + activatingDelay`), i.e. the surcharge-free floor.
    ///      The base delay is previewed independently through `currentActivationDelay` before the deposit.
    function _supplyCollateral() internal returns (uint256 unlockTime, uint256 baseUnlock) {
        Market storage m = _m();
        _fund(m.collateralToken, borrower, COLLATERAL);
        baseUnlock = block.timestamp + m.controller.currentActivationDelay(COLLATERAL);
        m.supplyCollateral(borrower, COLLATERAL);
        unlockTime = m.controller.positionOf(borrower).unlockTime;
    }

    /// @dev The timer the controller last booked, decoded from its `CollateralActivating` log. Used where the
    ///      `currentActivationDelay` preview cannot be trusted: the preview reads the persistent inflow, while a
    ///      second deposit inside one transaction also sees the first deposit's transient contribution, which in
    ///      production would have been cleared with the earlier transaction.
    function _lastBookedTimer() internal returns (uint256 activatingStart, uint256 activatingDelay) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] == CollateralActivationLib.CollateralActivating.selector) {
                (, CollateralActivationLib.Position memory position) =
                    abi.decode(logs[i - 1].data, (uint256, CollateralActivationLib.Position));
                return (position.activatingStart, position.activatingDelay);
            }
        }
        revert("no CollateralActivating log");
    }

    function _seedLender() internal {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
    }

    function _safeBorrow() internal view returns (uint256) {
        return COLLATERAL * oraclePrice / 1e36 * 80 / 100 / 2; // half of LLTV-max, seed-safe
    }

    // ── a stale count that cannot reach a lot ──

    /// @dev Every report lapses with no rebuild, so the cached count keeps reading 2. It cannot delay a lot
    ///      started now: the cached expiry is anchored to the newest report, so once that report lapses the
    ///      expiry is necessarily in the past and the controller's `activatingStart < expiry` gate is closed.
    function test_staleCount_allReportsLapsed_addsNoDelay() public {
        _lapseBothReports();

        assertEq(_cachedSuspectCount(), 2, "the cached count is stale");
        assertEq(_liveSuspectCount(), 0, "no live report backs it");

        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        assertEq(unlockTime, baseUnlock, "a lapsed snapshot adds no delay");
    }

    /// @dev The whole exposure as one fuzzed property, over the gap between the two reports and how long after
    ///      them the lot starts. Nothing rebuilds the snapshot after the second report, so: the cached count stays
    ///      frozen however far time moves (reads never clean up), it is an upper bound on the live reports and
    ///      never a lower one, and the surcharge is the cached count for a lot starting before the cached expiry
    ///      and nothing from the expiry onwards — including the boundary instant, where the newer report is still
    ///      live but the lot escapes anyway.
    function testFuzz_staleCount_neverUndercountsAndEndsAtTheCachedExpiry(uint40 reportGap, uint40 lotOffset) public {
        reportGap = uint40(bound(reportGap, 1, SUSPECT_WINDOW - 1)); // guardian1 still live when guardian2 reports
        lotOffset = uint40(bound(lotOffset, 0, 3 * uint256(SUSPECT_WINDOW)));

        uint256 t0 = block.timestamp;
        _suspect(guardian1);
        vm.warp(t0 + reportGap);
        _suspect(guardian2); // the last rebuild: count 2, expiry anchored here
        uint256 cachedExpiry = t0 + reportGap + SUSPECT_WINDOW;

        vm.warp(t0 + reportGap + lotOffset);
        assertEq(_cachedSuspectCount(), 2, "no rebuild happened, so the count is frozen at 2");
        assertLe(_liveSuspectCount(), _cachedSuspectCount(), "the cache never undercounts the live reports");

        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        uint256 expectedSurcharge = block.timestamp < cachedExpiry ? 2 * uint256(DELAY_PER_SUSPECT) : 0;
        assertEq(unlockTime - baseUnlock, expectedSurcharge, "surcharge = cached count until the cached expiry");
    }

    // ── a stale count that does reach a lot ──

    /// @dev The snapshot shares one expiry, taken from its newest report. A report that lapses while a newer one
    ///      is still live therefore keeps counting, and the borrower is charged for two reports with one live.
    ///      The overcharge is not cosmetic: the lot is still locked at the unlock time one report justifies.
    function test_staleCount_lapsedReportUnderALiveOne_delaysTheLot() public {
        _suspect(guardian1);
        vm.warp(block.timestamp + SUSPECT_WINDOW - 1 days);
        _suspect(guardian2); // rebuild while both are live: count 2, expiry = now + SUSPECT_WINDOW
        vm.warp(block.timestamp + 2 days); // guardian1's report lapsed, guardian2's still live

        assertEq(_cachedSuspectCount(), 2, "the cached count still counts both");
        assertEq(_liveSuspectCount(), 1, "only one report is live");

        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        assertEq(unlockTime, baseUnlock + 2 * DELAY_PER_SUSPECT, "charged for the cached count, not the live one");

        Market storage m = _m();
        _seedLender();
        vm.warp(baseUnlock + DELAY_PER_SUSPECT); // the unlock the one live report justifies
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, _safeBorrow(), 0, borrower, borrower);

        vm.warp(unlockTime); // ...and it matures only once the stale count's surcharge has elapsed
        m.borrow(borrower, _safeBorrow());
    }

    // ── paths that heal the stale count ──

    /// @dev A fresh report is itself a rebuild, so it heals the stale count instead of stacking onto it: the
    ///      lapsed report is pruned and the survivors recounted. The live reporter refreshing its own report
    ///      therefore *lowers* the charged count from 2 to 1 while pushing the expiry out, and the surcharge on
    ///      the already-activating lot follows it down — the surcharge is recomputed on every read, not frozen
    ///      into the lot at deposit.
    function test_staleCount_healedByAFreshReport_shortensTheLot() public {
        _suspect(guardian1);
        vm.warp(block.timestamp + SUSPECT_WINDOW - 1 days);
        _suspect(guardian2); // rebuild while both are live
        vm.warp(block.timestamp + 2 days); // guardian1's report lapsed, guardian2's still live

        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        assertEq(unlockTime, baseUnlock + 2 * DELAY_PER_SUSPECT, "the lot starts out charged for the stale count");

        _suspect(guardian2); // refresh: prunes the lapsed report, recounts the survivors

        Market storage m = _m();
        (address[] memory reporters,) = m.guardianSignals.getSuspectedBy(m.id, borrower);
        assertEq(reporters.length, 1, "the lapsed report is pruned out of the set");
        assertEq(_cachedSuspectCount(), 1, "the count is rebuilt from the survivor");
        assertEq(_liveSuspectCount(), 1, "cache and stored reports agree again");
        assertEq(
            m.controller.positionOf(borrower).unlockTime,
            baseUnlock + DELAY_PER_SUSPECT,
            "the lot's surcharge follows the rebuilt count down"
        );
    }

    /// @dev Pruning a departed guardian's report rebuilds from the survivors, so it drops more than that one
    ///      report: a current guardian's lapsed report is left in the set but excluded from the rebuilt count.
    ///      One departed report is therefore enough to give anyone a permissionless way to clear the whole stale
    ///      count, and the borrower's lot drops back to its base delay.
    function test_staleCount_healedByPruningADepartedGuardian_shortensTheLot() public {
        _suspect(guardian1);
        vm.warp(block.timestamp + SUSPECT_WINDOW - 1 days);
        _suspect(guardian2); // rebuild while both are live
        vm.warp(block.timestamp + 2 days); // guardian1's report lapsed, guardian2's still live

        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        assertEq(unlockTime, baseUnlock + 2 * DELAY_PER_SUSPECT, "the lot starts out charged for the stale count");

        Market storage m = _m();
        m.guardianSignals.removeGuardian(guardian2); // the live reporter leaves the committee
        vm.prank(_actor("cleaner")); // permissionless
        m.guardianSignals.prune(m.id, borrower);

        (address[] memory reporters,) = m.guardianSignals.getSuspectedBy(m.id, borrower);
        assertEq(reporters.length, 1, "only the departed guardian's report leaves the set");
        assertEq(reporters[0], guardian1, "the lapsed report of a current guardian stays stored");
        assertEq(_cachedSuspectCount(), 0, "the rebuild drops the departed report and the lapsed one");
        assertEq(m.controller.positionOf(borrower).unlockTime, baseUnlock, "the lot falls back to its base delay");
    }

    /// @dev A top-up onto an un-matured lot restarts the shared timer, and the restart is what sheds a stale
    ///      surcharge: the gate reads the lot's start, so moving that start to the cached expiry closes it even
    ///      though the cached count still says 2. The lot is deliberately still un-matured here — a top-up after
    ///      maturity would simply open a fresh lot, since the supply hook syncs before it credits.
    ///      Note the direction: the top-up pulls the effective unlock *in*, because shedding the surcharge saves
    ///      more than the new base delay costs. The base delay alone can only ever move the unlock out.
    function test_staleCount_topUpOntoAnUnmaturedLot_shedsTheSurcharge() public {
        _suspect(guardian1);
        vm.warp(block.timestamp + 1 days);
        _suspect(guardian2); // rebuild: count 2, expiry = now + SUSPECT_WINDOW
        uint256 cachedExpiry = block.timestamp + SUSPECT_WINDOW;

        vm.warp(cachedExpiry - 1); // the lot starts one second inside the snapshot's reach
        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        assertEq(unlockTime, baseUnlock + 2 * DELAY_PER_SUSPECT, "the lot starts out carrying the surcharge");

        vm.warp(cachedExpiry);
        assertLt(block.timestamp, unlockTime, "the first lot has not matured, so the top-up restarts its timer");

        vm.recordLogs();
        (uint256 toppedUpUnlock,) = _supplyCollateral();
        (uint256 restartedStart, uint256 restartedDelay) = _lastBookedTimer();

        assertEq(restartedStart, cachedExpiry, "the restart moved the lot's start onto the cached expiry");
        assertEq(_cachedSuspectCount(), 2, "the cached count is untouched by the deposit");
        assertEq(toppedUpUnlock, restartedStart + restartedDelay, "the restarted lot carries no suspect surcharge");
        assertLt(toppedUpUnlock, unlockTime, "shedding the surcharge pulls the effective unlock in");
    }

    /// @dev The gate is strict (`activatingStart < suspectExpiryTimestamp`), so a lot starting exactly on the
    ///      cached expiry escapes the surcharge even though the report anchoring that expiry is still live at
    ///      that instant — a report counts through `reportedAt + suspectWindow` inclusive. Pinned as an example
    ///      because the fuzz run above cannot be expected to land on the single boundary second.
    function test_lotStartingExactlyOnTheCachedExpiry_addsNoDelay() public {
        _suspect(guardian1);
        vm.warp(block.timestamp + 1 days);
        _suspect(guardian2);
        uint256 cachedExpiry = block.timestamp + SUSPECT_WINDOW;

        vm.warp(cachedExpiry);
        assertEq(_liveSuspectCount(), 1, "the anchoring report is still live on its last second");

        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        assertEq(unlockTime, baseUnlock, "a lot starting on the expiry takes no surcharge");
    }

    // ── a stale count that does reach a lot, via the window ──

    /// @dev Widening the suspect window is retroactive: the expiry is recomputed from the cached
    ///      `suspectReportedAt`, and lapsed reports still sitting in the set count as live again under the wider
    ///      window. The cached count of 2 becomes correct rather than phantom, which is what separates this from
    ///      the orphaned case below.
    function test_widenedWindow_revivesStoredLapsedReports_delaysTheLot() public {
        _lapseBothReports();

        Market storage m = _m();
        m.guardianSignals.setSuspectWindow(m.guardianSignals.MAX_SUSPECT_WINDOW());

        assertEq(_cachedSuspectCount(), 2, "the window change does not recount the cache");
        assertEq(_liveSuspectCount(), 2, "both stored reports are live again under the wider window");

        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        assertEq(unlockTime, baseUnlock + 2 * DELAY_PER_SUSPECT, "the revived reports delay the lot");
    }

    /// @dev The boundary of the harmless case above. A retraction with nothing live to remove drops every lapsed
    ///      report from the set but returns before rebuilding, so the count is left with no report behind it — and
    ///      the caller need not be one of the reporters, so no committee member can bring the count back in line
    ///      this way. Widening the suspect window then recomputes the expiry from the cached `suspectReportedAt`
    ///      and drags it back into the future, delaying a fresh lot on an orphaned count. Reaching this needs both
    ///      steps: without the orphaning the wider window revives the stored reports legitimately, as above.
    function test_staleCount_orphanedThenWidenedWindow_delaysALotWithNoLiveReport() public {
        _lapseBothReports();

        // Each dropped report is logged, so an indexer following events sees the set empty out. Nothing announces
        // that the count behind it stayed at 2 — the divergence is silent off-chain.
        Market storage m = _m();
        vm.expectEmit(true, true, true, false, address(m.guardianSignals));
        emit SuspectPruned(m.id, borrower, guardian1);
        vm.expectEmit(true, true, true, false, address(m.guardianSignals));
        emit SuspectPruned(m.id, borrower, guardian2);
        _unsuspect(guardian3); // an uninvolved guardian: prunes the lapsed reports, leaves the count standing

        (address[] memory reporters,) = m.guardianSignals.getSuspectedBy(m.id, borrower);
        assertEq(reporters.length, 0, "every report is gone from the stored set");
        assertEq(_cachedSuspectCount(), 2, "the count outlives the reports behind it");

        m.guardianSignals.setSuspectWindow(m.guardianSignals.MAX_SUSPECT_WINDOW());

        assertEq(_cachedSuspectCount(), 2, "the orphaned count survives the window change");
        assertEq(_liveSuspectCount(), 0, "and the wider window has no stored report left to revive");

        (uint256 unlockTime, uint256 baseUnlock) = _supplyCollateral();
        assertEq(unlockTime, baseUnlock + 2 * DELAY_PER_SUSPECT, "the orphaned count delays the lot");
    }
}
