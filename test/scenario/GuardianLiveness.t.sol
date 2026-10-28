// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice The guardian-liveness gate on collateral maturation, driven through a real committee. Maturation
///         needs three things at once: the clock past the lot's unlock time, the quorum scan frontier having
///         reached that unlock time, and an unfrozen market. The frontier condition is the one no scenario
///         reached before — the default fixture sets `maxGuardiansQuorumDelay` to zero, which short-circuits
///         it, so every other suite matures on the clock alone.
///
///         Committee here is three guardians at quorum two, so the frontier is the second-highest reported
///         scan time: one heartbeat is provably not enough, two are.
contract GuardianLivenessTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev Must exceed `maxActivationDelay` (2 hours) per the config bounds, and is the liveness escape:
    ///      once this much time has passed since the lot started, maturation no longer needs scan evidence.
    uint256 internal constant QUORUM_FALLBACK = 6 hours;

    address internal guardian1;
    address internal guardian2;
    address internal guardian3;
    address internal borrower;

    function setUp() public {
        // Heartbeats name a real past block, so the chain needs history and a sane clock.
        vm.roll(1000);
        vm.warp(1_000_000);

        guardian1 = _actor("guardian1");
        guardian2 = _actor("guardian2");
        guardian3 = _actor("guardian3");

        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);

        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        cfg.guardians = new address[](3);
        cfg.guardians[0] = guardian1;
        cfg.guardians[1] = guardian2;
        cfg.guardians[2] = guardian3;
        cfg.quorum = 2;
        cfg.activation.maxGuardiansQuorumDelay = uint40(QUORUM_FALLBACK);
        _deployProtocol(cfg);

        Market storage m = _m();
        assertEq(m.guardianSignals.getQuorum(), 2, "setup: quorum must be 2 of 3");
        assertEq(
            m.controller.collateralActivationConfig().maxGuardiansQuorumDelay,
            QUORUM_FALLBACK,
            "setup: frontier gate must be enabled"
        );
        assertEq(m.guardianSignals.getQuorumFrontier(), 0, "setup: frontier starts unset");

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Books a lot and moves the clock past its unlock time but short of the fallback, so maturation
    ///      depends purely on the frontier. Returns that unlock time.
    function _bookLotAndPassUnlockTime() internal returns (uint256 unlockTime) {
        Market storage m = _m();
        uint256 lotStart = block.timestamp;
        m.supplyCollateral(borrower, 100 ether);

        unlockTime = m.controller.positionOf(borrower).unlockTime;
        assertGt(unlockTime, lotStart, "setup: lot must have a future unlock time");
        assertLt(unlockTime, lotStart + QUORUM_FALLBACK, "setup: unlock must precede the fallback");

        // Past the clock condition, still inside the fallback window.
        vm.warp(lotStart + 3 hours);
        assertGt(block.timestamp, unlockTime, "setup: clock condition must be satisfied");
        assertLt(block.timestamp, lotStart + QUORUM_FALLBACK, "setup: fallback must not have fired");
    }

    function _maxBorrow() internal view returns (uint256) {
        return ((100 ether * oraclePrice) / 1e36) * 80 / 100;
    }

    // ── The frontier gate holds maturation ──

    function testRevert_TimerElapsedButFrontierBehind_BorrowBlocked() public {
        Market storage m = _m();
        _bookLotAndPassUnlockTime();

        assertEq(m.guardianSignals.getQuorumFrontier(), 0, "no scan evidence has been reported");
        assertEq(m.controller.positionOf(borrower).activating, 100 ether, "lot is still activating");

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, _maxBorrow() / 2, 0, borrower, borrower);
    }

    /// @dev With three guardians at quorum two the frontier is the second-highest reported scan time, so a
    ///      single heartbeat leaves it at zero however recent that scan was.
    function testRevert_SingleHeartbeatPastUnlock_StillBlocked() public {
        Market storage m = _m();
        uint256 unlockTime = _bookLotAndPassUnlockTime();

        m.heartbeatAt(guardian1, unlockTime);
        assertEq(m.guardianSignals.getQuorumFrontier(), 0, "one of three cannot carry a quorum of two");

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, _maxBorrow() / 2, 0, borrower, borrower);
    }

    function test_QuorumOfHeartbeatsPastUnlock_MaturesLot() public {
        Market storage m = _m();
        uint256 unlockTime = _bookLotAndPassUnlockTime();

        m.heartbeatAt(guardian1, unlockTime);
        m.heartbeatAt(guardian2, unlockTime);
        assertGe(m.guardianSignals.getQuorumFrontier(), unlockTime, "second heartbeat carries the frontier");

        m.borrow(borrower, _maxBorrow() / 2);
        assertEq(m.controller.positionOf(borrower).activating, 0, "lot matured once the frontier covered it");
    }

    /// @dev A frontier that stops short of the unlock time is not enough, even with a full quorum reporting.
    ///      Pins that the comparison is against the lot's unlock time rather than merely "some scan happened".
    function testRevert_QuorumHeartbeatsBeforeUnlock_StillBlocked() public {
        Market storage m = _m();
        uint256 unlockTime = _bookLotAndPassUnlockTime();

        m.heartbeatAt(guardian1, unlockTime - 1);
        m.heartbeatAt(guardian2, unlockTime - 1);
        assertEq(m.guardianSignals.getQuorumFrontier(), unlockTime - 1, "frontier one second short of unlock");

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, _maxBorrow() / 2, 0, borrower, borrower);
    }

    // ── The liveness escape ──

    /// @dev A silent committee must not freeze collateral forever. Once `maxGuardiansQuorumDelay` has elapsed
    ///      since the lot started, maturation proceeds with no scan evidence at all.
    function test_SilentCommittee_FallbackDelayMaturesLot() public {
        Market storage m = _m();
        uint256 lotStart = block.timestamp;
        m.supplyCollateral(borrower, 100 ether);

        vm.warp(lotStart + QUORUM_FALLBACK + 1);
        assertEq(m.guardianSignals.getQuorumFrontier(), 0, "no guardian ever reported a scan");

        m.borrow(borrower, _maxBorrow() / 2);
        assertEq(m.controller.positionOf(borrower).activating, 0, "fallback matured the lot without scan evidence");
    }

    /// @dev The frontier is a monotonic ratchet: a permissionless sync never lowers it, even when the live
    ///      candidate would be lower because the quorum was raised afterwards.
    function test_SyncFrontier_NeverMovesBackwards() public {
        Market storage m = _m();
        uint256 unlockTime = _bookLotAndPassUnlockTime();

        m.heartbeatAt(guardian1, unlockTime);
        m.heartbeatAt(guardian2, unlockTime);
        uint256 reached = m.guardianSignals.getQuorumFrontier();
        assertGe(reached, unlockTime, "setup: frontier must have advanced");

        vm.startPrank(m.config.admin);
        m.guardianSignals.grantRole(m.guardianSignals.MANAGER_ROLE(), m.config.admin);
        m.guardianSignals.setQuorum(3); // the live candidate is now the lowest heartbeat, i.e. zero
        vm.stopPrank();

        assertEq(m.syncFrontier(), reached, "raising quorum must not lower the stored frontier");
    }

    // ── Bans have no finite unlock time ──

    function test_BannedBorrower_HasNoFiniteUnlockTime() public {
        Market storage m = _m();
        m.supplyCollateral(borrower, 100 ether);

        address[] memory quorumGuardians = new address[](2);
        quorumGuardians[0] = guardian1;
        quorumGuardians[1] = guardian2;
        m.banVia(quorumGuardians, borrower);

        assertEq(m.controller.positionOf(borrower).unlockTime, type(uint256).max, "banned lot never unlocks");
    }

    /// @dev Unbanning restores a finite unlock time, and the lot then matures on the ordinary conditions.
    function test_UnbanRestoresFiniteUnlock_ThenLotMatures() public {
        Market storage m = _m();
        uint256 lotStart = block.timestamp;
        m.supplyCollateral(borrower, 100 ether);

        address[] memory quorumGuardians = new address[](2);
        quorumGuardians[0] = guardian1;
        quorumGuardians[1] = guardian2;
        m.banVia(quorumGuardians, borrower);
        assertEq(m.controller.positionOf(borrower).unlockTime, type(uint256).max, "setup: banned");

        m.unban(borrower);
        uint256 unlockTime = m.controller.positionOf(borrower).unlockTime;
        assertLt(unlockTime, type(uint256).max, "unlock time is finite again");

        // Take the fallback route so this test does not depend on the frontier as well.
        vm.warp(lotStart + QUORUM_FALLBACK + 1);
        m.borrow(borrower, _maxBorrow() / 2);
        assertEq(m.controller.positionOf(borrower).activating, 0, "lot matures after the ban is cleared");
    }

    // ── A ban on matured collateral gates new borrowing only ──

    /// @dev Matures the lot on a quorum of heartbeats, borrows half the capacity, then bans the borrower. Returns the
    ///      borrow shares.
    function _borrowThenBan() internal returns (uint256 borrowShares) {
        Market storage m = _m();
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        borrowShares = m.borrow(borrower, _maxBorrow() / 2);

        address[] memory quorumGuardians = new address[](2);
        quorumGuardians[0] = guardian1;
        quorumGuardians[1] = guardian2;
        m.banVia(quorumGuardians, borrower);
        assertEq(m.controller.positionOf(borrower).active, 100 ether, "setup: lot matured before the ban");
    }

    function test_BannedBorrower_RepaysThenWithdrawsAllCollateral() public {
        Market storage m = _m();
        uint256 borrowShares = _borrowThenBan();

        _fund(m.loanToken, borrower, m.repayAssets(borrowShares));
        m.repay(borrower, borrowShares);
        m.withdrawCollateral(borrower, 100 ether, borrower);

        assertEq(m.core.position(m.id, borrower).collateral, 0, "banned borrower withdrew all collateral");
    }

    function test_BannedBorrower_CanBeLiquidated() public {
        Market storage m = _m();
        uint256 borrowShares = _borrowThenBan();
        m.distress(borrower, 0.9e18);

        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, m.repayAssets(borrowShares));
        (uint256 seized,) = m.liquidate(keeper, borrower, 0, borrowShares / 2);
        assertGt(seized, 0, "keeper seized collateral from the banned borrower");
    }

    /// @dev A ban is keyed to the borrower, so the supply side is untouched: a lender still withdraws free liquidity.
    function test_BannedBorrower_LenderExitStaysOpen() public {
        _borrowThenBan();
        _m().vaultWithdraw(_actor("lender"), 333 ether);
    }

    function testRevert_BannedBorrower_BorrowBlocked() public {
        Market storage m = _m();
        _borrowThenBan();

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        m.core.borrow(m.params, 1 ether, 0, borrower, borrower);
    }

    // ── Pinned: the stored frontier stalls after a quorum decrease ──

    /// @dev All three guardians report one shared scan. Then guardians 2 and 3 go silent, and guardian 1 reports once
    ///      more. From then on, each report of guardian 1 starts above the stored frontier, so none recomputes it.
    ///      Returns the shared scan time, where the frontier stays.
    function _silenceGuardians2And3() internal returns (uint256 sharedScan) {
        Market storage m = _m();
        sharedScan = block.timestamp;
        m.heartbeatAt(guardian1, sharedScan);
        m.heartbeatAt(guardian2, sharedScan);
        m.heartbeatAt(guardian3, sharedScan);
        assertEq(m.guardianSignals.getQuorumFrontier(), sharedScan, "setup: frontier at the shared scan");

        vm.warp(block.timestamp + 1 minutes);
        m.heartbeatAt(guardian1, block.timestamp);
        assertEq(m.guardianSignals.getQuorumFrontier(), sharedScan, "setup: one guardian cannot carry quorum two");
    }

    /// @dev Pins open finding ll-aud-17: after a quorum decrease, the stored frontier stays behind guardian 1's scan,
    ///      so the lot waits for a `syncQuorumFrontier` call.
    ///      A fix changes this outcome; update this test with the fix.
    function test_LLAUD17_quorumLowered_frontierStallsUntilSync() public {
        Market storage m = _m();
        uint256 sharedScan = _silenceGuardians2And3();
        vm.prank(m.config.admin);
        m.guardianSignals.setQuorum(1);
        uint256 unlockTime = _bookLotAndPassUnlockTime();

        // With quorum one the live candidate is the highest report: this scan of guardian 1.
        uint256 liveCandidate = block.timestamp;
        m.heartbeatAt(guardian1, liveCandidate);
        assertGe(liveCandidate, unlockTime, "setup: guardian 1 scanned past the unlock");
        assertEq(m.guardianSignals.getQuorumFrontier(), sharedScan, "stored frontier stalls at the shared scan");

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, _maxBorrow() / 2, 0, borrower, borrower);

        assertEq(m.syncFrontier(), liveCandidate, "sync moves the frontier to the live candidate");
        m.borrow(borrower, _maxBorrow() / 2);
        assertEq(m.controller.positionOf(borrower).activating, 0, "lot matures once the frontier is synced");
    }

    /// @dev Pins open finding ll-aud-17: after the remove-guardian motion, the lot waits for the fallback deadline
    ///      although guardian 1 scanned past its unlock. A fix changes this outcome; update this test with the fix.
    function test_LLAUD17_removeGuardianMotion_lotWaitsForFallback() public {
        Market storage m = _m();
        uint256 sharedScan = _silenceGuardians2And3();
        // The motion lowers quorum, then removes a silent guardian.
        vm.startPrank(m.config.admin);
        m.guardianSignals.setQuorum(1);
        m.guardianSignals.removeGuardian(guardian3);
        vm.stopPrank();
        uint256 lotStart = block.timestamp;
        uint256 unlockTime = _bookLotAndPassUnlockTime();

        vm.warp(lotStart + QUORUM_FALLBACK - 1);
        m.heartbeatAt(guardian1, block.timestamp);
        assertGt(block.timestamp, unlockTime, "setup: guardian 1 scanned past the unlock");
        assertEq(m.guardianSignals.getQuorumFrontier(), sharedScan, "stored frontier stalls at the shared scan");

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        m.core.borrow(m.params, _maxBorrow() / 2, 0, borrower, borrower);

        vm.warp(lotStart + QUORUM_FALLBACK);
        m.borrow(borrower, _maxBorrow() / 2);
        assertEq(m.controller.positionOf(borrower).activating, 0, "fallback deadline matures the lot");
        assertEq(m.guardianSignals.getQuorumFrontier(), sharedScan, "frontier still stalled at the fallback");
    }
}
