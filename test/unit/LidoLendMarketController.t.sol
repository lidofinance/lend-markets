// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test, stdError} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";

import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";
import {BlockInfoWithHash} from "../../src/types/GuardianSignalsTypes.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice Unit/integration suite for `LidoLendMarketController`, modelled from the market-controller spec's
///         "Policy boundary" and "Freeze and pause" sections. The controller's `on` hook is driven by the
///         core, so the policy is exercised through real market actions on a fresh `setup/` stack. The
///         libraries it composes (activation/settlement/guardian) are covered in §3–5; here the focus is
///         the controller-specific policy: pause (every hook), freeze gate, banned-borrow, active-only
///         health, instant activation, settlement config, and setter role-gating.
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
        // Grant the remaining governance roles to the test contract (admin holds DEFAULT_ADMIN, and the setup
        // already granted MANAGER_ROLE).
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

    // ── mutations ──

    // ── on() access ──

    function testRevert_on_nonCoreCaller_unauthorized() public {
        vm.expectRevert(ILidoLendMarketController.Unauthorized.selector);
        c.on(_m().id, ILidoLendBaseMarketController.HookEvent.Supply, "");
    }

    function testRevert_on_wrongMarketId_invalidMarketId() public {
        Id wrongId = Id.wrap(bytes32(uint256(0xDEAD)));
        vm.prank(address(_m().core)); // authorized caller, wrong market
        vm.expectRevert(ILidoLendMarketController.InvalidMarketId.selector);
        c.on(wrongId, ILidoLendBaseMarketController.HookEvent.Supply, "");
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
        uint256 before = _m().collateralToken.balanceOf(borrower);
        vm.prank(borrower);
        _m().core.withdrawCollateral(_m().params, 1 ether, borrower, borrower); // succeeds while frozen
        assertEq(_m().collateralToken.balanceOf(borrower) - before, 1 ether, "collateral returned while frozen");
    }

    function test_freeze_allowsRepay() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether);
        c.freeze();
        _fund(_m().loanToken, borrower, 20 ether);
        vm.prank(borrower);
        _m().loanToken.approve(address(_m().core), type(uint256).max);
        uint256 before = _m().loanToken.balanceOf(borrower);
        vm.prank(borrower);
        _m().core.repay(_m().params, 5 ether, 0, borrower, ""); // repay allowed while frozen
        assertEq(before - _m().loanToken.balanceOf(borrower), 5 ether, "repay debited the borrower while frozen");
    }

    function test_unfreeze_restoresBorrow() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 0);
        c.freeze();
        c.unfreeze();
        assertFalse(c.isFrozen(), "unfrozen");
        vm.prank(borrower);
        _m().core.borrow(_m().params, 10 ether, 0, borrower, borrower); // borrow works again
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
        address nobody = _actor("nobody");
        bytes32 role = c.FREEZER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, role));
        c.freeze();
    }

    function testRevert_pauseFor_wrongRole() public {
        address nobody = _actor("nobody");
        bytes32 role = c.PAUSER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, role));
        c.pauseFor(1 hours);
    }

    function testRevert_grantInstantActivation_wrongRole() public {
        address nobody = _actor("nobody");
        address borrower = _actor("borrower");
        bytes32 role = c.MANAGER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, role));
        c.grantInstantActivation(borrower);
    }

    // ── ban 3-way: receiver and caller (distinct from onBehalf) ──

    function testRevert_borrow_bannedReceiver() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 0);
        address receiver = _actor("receiver");
        _ban(receiver);
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        _m().core.borrow(_m().params, 10 ether, 0, borrower, receiver);
    }

    function testRevert_borrow_bannedCaller() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 0);
        address operator = _actor("operator");
        _ban(operator);
        vm.prank(borrower);
        _m().core.setAuthorization(operator, true); // borrower authorizes the (banned) operator
        vm.prank(operator);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        _m().core.borrow(_m().params, 10 ether, 0, borrower, borrower);
    }

    // ── collateral-activation config (MANAGER_ROLE) ──

    /// @dev `setCollateralActivationConfig` writes the full activation config in one shot (the test contract
    ///      holds MANAGER_ROLE from deploy). We write a non-default config and read it back through the view.
    function test_setCollateralActivationConfig_storesFullConfig() public {
        CollateralActivationConfig memory cfg = CollateralActivationConfig({
            minActivationDelay: 300,
            maxActivationDelay: 3 hours,
            maxDelayInflow: 20_000 ether,
            delayPerStrike: 1 hours,
            activatingLockAmount: 5 ether,
            activatingLockDuration: 1 hours,
            minActivationAmount: 7 ether,
            // must be 0 or strictly above maxActivationDelay (the liveness fallback sits past the delay cap)
            maxGuardiansQuorumDelay: 4 hours
        });
        c.setCollateralActivationConfig(cfg);

        CollateralActivationConfig memory stored = c.collateralActivationConfig();
        assertEq(stored.minActivationDelay, 300, "minActivationDelay");
        assertEq(stored.maxActivationDelay, 3 hours, "maxActivationDelay");
        assertEq(stored.maxDelayInflow, 20_000 ether, "maxDelayInflow");
        assertEq(stored.delayPerStrike, 1 hours, "delayPerStrike");
        assertEq(stored.activatingLockAmount, 5 ether, "activatingLockAmount");
        assertEq(stored.activatingLockDuration, 1 hours, "activatingLockDuration");
        assertEq(stored.minActivationAmount, 7 ether, "minActivationAmount");
        assertEq(stored.maxGuardiansQuorumDelay, 4 hours, "maxGuardiansQuorumDelay");
    }

    function testRevert_setCollateralActivationConfig_wrongRole() public {
        CollateralActivationConfig memory cfg = c.collateralActivationConfig();
        address nobody = _actor("nobody");
        bytes32 role = c.MANAGER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, role));
        c.setCollateralActivationConfig(cfg);
    }

    /// @dev `revokeInstantActivation` (MANAGER_ROLE) clears a previously-granted instant flag.
    function test_revokeInstantActivation_clearsFlag() public {
        address borrower = _actor("borrower");
        c.grantInstantActivation(borrower);
        assertTrue(c.hasInstantActivation(borrower), "granted");
        c.revokeInstantActivation(borrower);
        assertFalse(c.hasInstantActivation(borrower), "revoked");
    }

    function testRevert_revokeInstantActivation_wrongRole() public {
        address nobody = _actor("nobody");
        address borrower = _actor("borrower");
        bytes32 role = c.MANAGER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, role));
        c.revokeInstantActivation(borrower);
    }

    // ── on() unknown hook event (defensive, see note) and onBehalf-banned borrow ──

    /// @dev The borrow ban gate is three-way (caller, receiver, onBehalf). The earlier suite covers caller and
    ///      receiver; this hits the distinct onBehalf branch: a clean operator borrows on behalf of a BANNED
    ///      borrower to a clean receiver, so caller and receiver pass and only the onBehalf check trips.
    function testRevert_borrow_bannedOnBehalf() public {
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 0);
        address operator = _actor("operator"); // clean caller
        address receiver = _actor("receiver"); // clean receiver
        _ban(borrower); // only the onBehalf borrower is banned
        vm.prank(borrower);
        _m().core.setAuthorization(operator, true);
        vm.prank(operator);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        _m().core.borrow(_m().params, 10 ether, 0, borrower, receiver);
    }

    // ── settle hook defensive re-checks via a direct core-impersonated on() call ──
    //
    // The controller re-checks payload consistency the core already enforces (shares <= debt, 0 < seize <=
    // collateral). The real core never emits an inconsistent payload, so these branches are reachable only by
    // a forged payload. We impersonate the core and call `on(Settle, ...)` directly with a crafted payload, so
    // the bad-debt and eligibility gates pass but the consistency re-check trips.

    /// @dev `SettlementExceedsDebt` (line 519) is a defensive re-check: after the controller has already bounded
    ///      `debtCanceled <= allowedSlice <= debtAssets` (lines 165 + 514), the recomputed share-burn
    ///      `toSharesUp(debtCanceled)` can only exceed `position.borrowShares` via a double-round-up, and the
    ///      virtual-shares offsets make `toSharesUp(toAssetsUp(borrowShares)) == borrowShares` in the standard
    ///      accounting, so the guard never fires through `on()`. We document that here: a FULL-debt forged cut
    ///      (debtCanceled == the strand-dust full slice, the largest value line 514 admits) passes the share
    ///      check, i.e. the guard does not falsely fire. The branch is reachable only by a payload that bypasses
    ///      the asset-side cap line 514 already enforces, hence unreachable in practice.
    function test_settle_fullDebtCut_doesNotTripExceedsDebt() public {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(1.3e36); // fixed, seed-independent

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100_000 ether);
        m.vaultDeposit(lender, 100_000 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 11 ether); // at the floor -> strand-dust lifts the slice to full debt
        m.supplyCollateral(borrower, 11 ether);
        m.activateCollateral();
        uint256 maxBorrow = 11 ether * 1.3e36 / 1e36 * 80 / 100;
        m.borrow(borrower, maxBorrow * 90 / 100);

        // Forge a cut at exactly the allowed slice (the largest value line 514 admits) with a valid 1-unit seize.
        // The recomputed share-burn stays within borrowShares, so SettlementExceedsDebt does NOT fire — the
        // guard is not a false positive at the cap, and cannot fire through `on()` at all.
        (, uint256 allowedAssets,) = c.nextSettlementBorrower();
        assertGt(allowedAssets, 0, "borrower is the eligible queue root");

        bytes memory data = abi.encode(
            ILidoLendBaseMarketController.SettleHookData({
                caller: lender,
                onBehalf: lender,
                borrower: borrower,
                receiver: lender,
                supplySharesBurned: 0,
                borrowAssetsCanceled: allowedAssets,
                borrowSharesCanceled: 0,
                seizedAssets: 1
            })
        );
        vm.prank(address(m.core));
        c.on(m.id, ILidoLendBaseMarketController.HookEvent.Settle, data); // no revert: no SettlementExceedsDebt
    }

    /// @dev Forge a Settle payload with seizedAssets == 0 -> SettlementInvalidSeize.
    function testRevert_settle_zeroSeize_forgedPayload() public {
        Market storage m = _m();
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether);
        (, uint256 allowedAssets,) = c.nextSettlementBorrower();

        bytes memory data = abi.encode(
            ILidoLendBaseMarketController.SettleHookData({
                caller: address(this),
                onBehalf: address(this),
                borrower: borrower,
                receiver: address(this),
                supplySharesBurned: 0,
                borrowAssetsCanceled: allowedAssets, // within slice, within debt
                borrowSharesCanceled: 0,
                seizedAssets: 0 // invalid: zero seize
            })
        );
        vm.prank(address(m.core));
        vm.expectRevert(ILidoLendMarketController.SettlementInvalidSeize.selector);
        c.on(m.id, ILidoLendBaseMarketController.HookEvent.Settle, data);
    }

    /// @dev Forge a Settle payload with seizedAssets > the borrower's collateral -> SettlementInvalidSeize.
    function testRevert_settle_overSeize_forgedPayload() public {
        Market storage m = _m();
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether);
        (, uint256 allowedAssets,) = c.nextSettlementBorrower();
        uint256 borrowerCollateral = m.core.position(m.id, borrower).collateral;

        bytes memory data = abi.encode(
            ILidoLendBaseMarketController.SettleHookData({
                caller: address(this),
                onBehalf: address(this),
                borrower: borrower,
                receiver: address(this),
                supplySharesBurned: 0,
                borrowAssetsCanceled: allowedAssets,
                borrowSharesCanceled: 0,
                seizedAssets: borrowerCollateral + 1 // invalid: over the borrower's collateral
            })
        );
        vm.prank(address(m.core));
        vm.expectRevert(ILidoLendMarketController.SettlementInvalidSeize.selector);
        c.on(m.id, ILidoLendBaseMarketController.HookEvent.Settle, data);
    }

    /// @dev Forge a Settle payload whose borrowAssetsCanceled exceeds the allowed slice -> SettlementExceedsAllowed.
    function testRevert_settle_exceedsAllowed_forgedPayload() public {
        Market storage m = _m();
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether);
        (, uint256 allowedAssets,) = c.nextSettlementBorrower();

        bytes memory data = abi.encode(
            ILidoLendBaseMarketController.SettleHookData({
                caller: address(this),
                onBehalf: address(this),
                borrower: borrower,
                receiver: address(this),
                supplySharesBurned: 0,
                borrowAssetsCanceled: allowedAssets + 1, // one over the allowed slice
                borrowSharesCanceled: 0,
                seizedAssets: 1
            })
        );
        vm.prank(address(m.core));
        vm.expectRevert(ILidoLendMarketController.SettlementExceedsAllowed.selector);
        c.on(m.id, ILidoLendBaseMarketController.HookEvent.Settle, data);
    }

    /// @dev Forge a Settle payload against an ineligible (non-root, no personal LTV) borrower -> SettlementIneligible.
    function testRevert_settle_ineligible_forgedPayload() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        address a = _actor("a");
        _fund(m.collateralToken, a, 400 ether);
        m.supplyCollateral(a, 400 ether);
        address b = _actor("b");
        _fund(m.collateralToken, b, 800 ether);
        m.supplyCollateral(b, 800 ether);
        m.activateCollateral();
        m.borrow(a, 80 ether);
        m.borrow(b, 80 ether);

        (address root,,) = c.nextSettlementBorrower();
        address nonRoot = root == a ? b : a; // non-root, no personal LTV -> allowedSlice == 0

        bytes memory data = abi.encode(
            ILidoLendBaseMarketController.SettleHookData({
                caller: address(this),
                onBehalf: address(this),
                borrower: nonRoot,
                receiver: address(this),
                supplySharesBurned: 0,
                borrowAssetsCanceled: 1,
                borrowSharesCanceled: 0,
                seizedAssets: 1
            })
        );
        vm.prank(address(m.core));
        vm.expectRevert(ILidoLendMarketController.SettlementIneligible.selector);
        c.on(m.id, ILidoLendBaseMarketController.HookEvent.Settle, data);
    }

    // ── PausableUntil: indefinite pause, getResumeSinceTimestamp, infinite-pause emit branch ──

    /// @dev An indefinite pause (`PAUSE_INFINITELY`) never auto-resumes and parks the resume timestamp at the
    ///      sentinel. Exercises `_setPausedState`'s PAUSE_INFINITELY emit branch and `getResumeSinceTimestamp`.
    function test_pauseFor_indefinite() public {
        uint256 inf = c.PAUSE_INFINITELY();
        c.pauseFor(inf);
        assertTrue(c.isPaused(), "paused");
        assertEq(c.getResumeSinceTimestamp(), inf, "resume timestamp parked at the sentinel");
        vm.warp(block.timestamp + 3650 days); // far future
        assertTrue(c.isPaused(), "indefinite pause never auto-resumes");
        c.resume();
        assertFalse(c.isPaused(), "resumed explicitly");
        assertEq(c.getResumeSinceTimestamp(), block.timestamp, "resume timestamp moved to now");
    }

    /// @dev A finite pause parks the resume timestamp at now + duration (the non-infinite emit branch).
    function test_pauseFor_finite_resumeTimestamp() public {
        c.pauseFor(1 hours);
        assertEq(c.getResumeSinceTimestamp(), block.timestamp + 1 hours, "resume timestamp == now + duration");
    }

    /// @dev `pauseFor` while already paused reverts (ResumedExpected via _checkResumed in _pauseFor).
    function testRevert_pauseFor_whenAlreadyPaused() public {
        c.pauseFor(1 hours);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        c.pauseFor(1 hours);
    }

    function testRevert_resume_wrongRole() public {
        c.pauseFor(1 hours);
        address nobody = _actor("nobody");
        bytes32 role = c.RESUMER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, role));
        c.resume();
    }

    function testRevert_unfreeze_wrongRole() public {
        c.freeze();
        address nobody = _actor("nobody");
        bytes32 role = c.UNFREEZER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, role));
        c.unfreeze();
    }

    // ── supply cap (MANAGER_ROLE) ──

    /// @dev Local mirror of `ILidoLendMarketController.SupplyCapSet` for `vm.expectEmit`.
    event SupplyCapSet(uint256 cap, address indexed account);

    /// @dev `setSupplyCap` stores the value, exposes it through `supplyCap()`, and emits `SupplyCapSet`.
    function test_setSupplyCap_storesAndEmits() public {
        assertEq(c.supplyCap(), 0, "default cap is 0 (no cap)");
        vm.expectEmit(true, false, false, true, address(c));
        emit SupplyCapSet(500 ether, address(this));
        c.setSupplyCap(500 ether);
        assertEq(c.supplyCap(), 500 ether, "cap stored");
    }

    function testRevert_setSupplyCap_wrongRole() public {
        address nobody = _actor("nobody");
        bytes32 role = c.MANAGER_ROLE();
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nobody, role));
        c.setSupplyCap(1 ether);
    }

    /// @dev With the default cap of 0 the market is uncapped: a large supply goes through unimpeded.
    function test_supplyCap_zeroMeansNoCap() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1_000_000 ether);
        m.vaultDeposit(lender, 1_000_000 ether); // helper asserts the deposit succeeded
    }

    /// @dev A deposit landing exactly on the cap is allowed; the next wei is not. Total starts at 0 (fresh
    ///      market, no borrow → no interest), so the attempted total the gate sees is exactly the cumulative
    ///      assets supplied.
    function test_supplyCap_allowsUpToCapBlocksAbove() public {
        Market storage m = _m();
        c.setSupplyCap(100 ether);
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether); // total == cap exactly: allowed

        // One more wei would push the total to cap + 1.
        address lender2 = _actor("lender2");
        _fund(m.loanToken, lender2, 1);
        vm.prank(lender2);
        m.loanToken.approve(address(m.vault), 1);
        vm.prank(lender2);
        vm.expectRevert(
            abi.encodeWithSelector(ILidoLendMarketController.SupplyCapExceeded.selector, 100 ether, 100 ether + 1)
        );
        m.vault.deposit(1, lender2);
    }

    /// @dev The cap gates the core supply path, not just the vault: a direct `core.supply` over the cap reverts
    ///      with the same error. This is why the cap lives on the controller hook, not in the vault's maxDeposit.
    function testRevert_supplyCap_blocksDirectCoreSupply() public {
        Market storage m = _m();
        c.setSupplyCap(50 ether);
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 60 ether);
        vm.prank(lender);
        m.loanToken.approve(address(m.core), 60 ether);
        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(ILidoLendMarketController.SupplyCapExceeded.selector, 50 ether, 60 ether)
        );
        m.core.supply(m.params, 60 ether, 0, lender, "");
    }

    /// @dev The cap gates entry only: lowering it below the current total never blocks a withdrawal of existing
    ///      liquidity (the non-custody exit must always work).
    function test_supplyCap_doesNotGateWithdraw() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);
        c.setSupplyCap(10 ether); // below the 100 ether already supplied
        m.vaultWithdraw(lender, 40 ether); // helper asserts the withdrawal succeeded despite the cap
    }

    /// @dev The gate fires iff the post-supply market total would exceed the cap, over any seed/incoming
    ///      split. The expectation is built from observed state, not the inputs: `attempted` uses the core's
    ///      live `totalSupplyAssets` (no borrow here → no pending interest, so the stored total matches what
    ///      the hook reads post-accrue), and the success path re-reads the total to confirm the deposit
    ///      supplied exactly `incoming`. This keeps the assertion from echoing the contract's own
    ///      `total + assets` arithmetic.
    function testFuzz_supplyCap_enforcedAtBoundary(uint256 cap, uint256 existing, uint256 incoming) public {
        cap = bound(cap, 1, 1e30);
        existing = bound(existing, 0, cap); // seed must itself fit under the cap
        incoming = bound(incoming, 1, 1e30);
        c.setSupplyCap(cap);

        Market storage m = _m();
        address lender = _actor("lender");
        if (existing > 0) {
            _fund(m.loanToken, lender, existing);
            m.vaultDeposit(lender, existing);
        }

        _fund(m.loanToken, lender, incoming);
        vm.prank(lender);
        m.loanToken.approve(address(m.vault), incoming);

        uint256 totalBefore = m.core.market(m.id).totalSupplyAssets; // observed, not assumed from `existing`
        uint256 attempted = totalBefore + incoming;

        if (attempted > cap) {
            vm.prank(lender);
            vm.expectRevert(
                abi.encodeWithSelector(ILidoLendMarketController.SupplyCapExceeded.selector, cap, attempted)
            );
            m.vault.deposit(incoming, lender);
        } else {
            vm.prank(lender);
            m.vault.deposit(incoming, lender); // within cap: succeeds
            // Independently confirm the supplied amount: the market total grew by exactly `incoming`.
            assertEq(m.core.market(m.id).totalSupplyAssets, totalBefore + incoming, "supplied != incoming");
        }
    }

    /// @dev Supply denominated in shares (vault `mint`) is gated on the loan assets it resolves to, not the
    ///      share count: the hook reads `SupplyHookData.assets`, which the core sets to `toAssetsUp(shares)`.
    ///      `previewMint` is the independent oracle for the assets the mint will supply, and the cap rejects
    ///      when those exceed it — reporting that resolved asset figure as `attempted`.
    function testRevert_supplyCap_blocksMintByResolvedAssets() public {
        Market storage m = _m();
        c.setSupplyCap(50 ether);
        address lender = _actor("lender");

        uint256 shares = m.vault.previewDeposit(60 ether); // shares worth ~60 ether of assets
        uint256 assetsForMint = m.vault.previewMint(shares); // assets the mint supplies (independent of cap code)
        assertGt(assetsForMint, 50 ether, "mint must resolve above the cap for this case");

        _fund(m.loanToken, lender, assetsForMint);
        vm.prank(lender);
        m.loanToken.approve(address(m.vault), assetsForMint);
        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(ILidoLendMarketController.SupplyCapExceeded.selector, 50 ether, assetsForMint)
        );
        m.vault.mint(shares, lender);
    }

    // ── supply cap scenarios ──

    /// @dev Scenario 1: filling the cap over several deposits never breaches it. Each iteration stays within
    ///      the cap, the last lands exactly on it, and one further wei reverts. No borrow → no interest, so
    ///      the total moves only through these supplies.
    function test_supplyCap_multiStepFillNeverBreaches() public {
        Market storage m = _m();
        uint256 cap = 100 ether;
        c.setSupplyCap(cap);
        address lender = _actor("lender");

        uint256[4] memory steps = [uint256(30 ether), 30 ether, 30 ether, 10 ether]; // sums to the cap
        for (uint256 i; i < steps.length; ++i) {
            _fund(m.loanToken, lender, steps[i]);
            m.vaultDeposit(lender, steps[i]); // helper asserts the deposit succeeded
            assertLe(m.core.market(m.id).totalSupplyAssets, cap, "never breach the cap while filling");
        }
        assertEq(m.core.market(m.id).totalSupplyAssets, cap, "filled exactly to the cap");

        _fund(m.loanToken, lender, 1);
        vm.prank(lender);
        m.loanToken.approve(address(m.vault), 1);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ILidoLendMarketController.SupplyCapExceeded.selector, cap, cap + 1));
        m.vault.deposit(1, lender);
    }

    /// @dev Scenario 2: supply just under the cap, then accrued interest consumes the headroom — a further
    ///      deposit is rejected because the gate measures the grown total, not the supplied principal.
    function test_supplyCap_interestEatsHeadroom_blocksDeposit() public {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(1e36); // deterministic borrow capacity
        uint256 cap = 100 ether;

        // Supply 99 (1 ether under the cap); borrow drives utilization so interest accrues.
        (address lender,) = _seedBorrower(99 ether, 200 ether, 90 ether);
        c.setSupplyCap(cap);

        vm.warp(block.timestamp + 365 days);
        m.core.accrueInterest(m.params);
        uint256 total = m.core.market(m.id).totalSupplyAssets;
        assertGt(total, cap, "interest must have consumed the headroom and passed the cap");

        _fund(m.loanToken, lender, 1);
        vm.prank(lender);
        m.loanToken.approve(address(m.vault), 1);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ILidoLendMarketController.SupplyCapExceeded.selector, cap, total + 1));
        m.vault.deposit(1, lender);
    }

    /// @dev Scenario 3: fill to the cap, let interest carry the total above it (deposits blocked), then a
    ///      withdrawal reopens headroom and a fresh deposit within it succeeds.
    function test_supplyCap_withdrawReopensHeadroom() public {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(1e36);
        uint256 cap = 100 ether;

        // Supply exactly to the cap; a modest borrow leaves ample idle liquidity for the later withdraw.
        (address lender,) = _seedBorrower(100 ether, 200 ether, 60 ether);
        c.setSupplyCap(cap);

        vm.warp(block.timestamp + 30 days);
        m.core.accrueInterest(m.params);
        uint256 grown = m.core.market(m.id).totalSupplyAssets;
        assertGt(grown, cap, "interest carried the total above the cap");

        // Over the cap: even one wei reverts.
        _fund(m.loanToken, lender, 1);
        vm.prank(lender);
        m.loanToken.approve(address(m.vault), 1);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ILidoLendMarketController.SupplyCapExceeded.selector, cap, grown + 1));
        m.vault.deposit(1, lender);

        // Withdraw frees room (idle liquidity covers it: only 60 of ~100 is borrowed).
        m.vaultWithdraw(lender, 20 ether); // helper asserts the withdrawal succeeded
        uint256 afterWithdraw = m.core.market(m.id).totalSupplyAssets;
        assertLt(afterWithdraw, cap, "withdraw reopened headroom below the cap");

        // A deposit within the reopened headroom goes through, landing back on the cap.
        uint256 room = cap - afterWithdraw;
        _fund(m.loanToken, lender, room);
        m.vaultDeposit(lender, room); // helper asserts the deposit succeeded
        assertLe(m.core.market(m.id).totalSupplyAssets, cap, "still within the cap after re-deposit");
    }

    // ── views ──

    function test_views_defaults() public view {
        assertFalse(c.isFrozen(), "not frozen initially");
        assertFalse(c.isPaused(), "not paused initially");
    }

    /// @dev `currentInflow` reads the decayed activation inflow accumulator. A fresh market has zero inflow;
    ///      after a maturing deposit of 100 ether the accumulator equals that deposit (no decay in-block).
    function test_currentInflow_tracksDeposit() public {
        assertEq(c.currentInflow(), 0, "no inflow before any deposit");
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        assertEq(c.currentInflow(), 100 ether, "inflow == the activating deposit (no decay in-block)");
    }

    /// @dev `settlementConfig()` returns the policy set at deploy (`_defaultConfig`: 100/0/10e18/100).
    function test_settlementConfig_returnsDeployedPolicy() public view {
        SettlementConfig memory cfg = c.settlementConfig();
        assertEq(cfg.sliceFloorBps, 100, "sliceFloorBps");
        assertEq(cfg.sliceFloorAssets, 0, "sliceFloorAssets");
        assertEq(cfg.fullCutBelowCollateral, 10 ether, "fullCutBelowCollateral");
        assertEq(cfg.ltvStepBps, 100, "ltvStepBps");
    }

    /// @dev `settlementBorrowersCount()` is the queue size: 0 with no borrowers, 1 after one borrow enters.
    function test_settlementBorrowersCount_tracksQueue() public {
        assertEq(c.settlementBorrowersCount(), 0, "empty queue");
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether);
        assertEq(c.settlementBorrowersCount(), 1, "one borrower queued after a borrow");
        // Repay to zero drops the borrower out of the queue.
        _fund(_m().loanToken, borrower, 100 ether);
        uint256 shares = _m().core.position(_m().id, borrower).borrowShares;
        _m().repay(borrower, shares);
        assertEq(c.settlementBorrowersCount(), 0, "queue empties when debt clears");
    }

    /// @dev `positionOf` dashboard: every field recomputed independently from the seeded position. A borrower
    ///      with 100 ether active collateral and a 10 ether borrow, not banned, not yet settle-eligible until a
    ///      personal LTV is set.
    function test_positionOf_recomputesDashboard() public {
        Market storage m = _m();
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether);

        ILidoLendMarketController.BorrowerPosition memory d = c.positionOf(borrower);

        // Collateral is fully matured (we warped past the delay before borrowing): active = 100, no activating/dust.
        assertEq(d.active, 100 ether, "active == matured collateral");
        assertEq(d.activating, 0, "no activating left after maturation");
        assertEq(d.dust, 0, "no dust");
        assertEq(d.unlockTime, 0, "no timer once matured");
        assertEq(d.strikes, 0, "no guardian strikes");
        assertEq(d.flagCount, 0, "no flags");
        assertFalse(d.banned, "not banned");
        // Fresh borrow with no interest accrued: debt assets == borrowed amount.
        assertEq(d.debtAssets, 10 ether, "debt == borrow (no interest yet)");
        assertEq(d.settlementLtv, 0, "no personal settle LTV");
        // Sole borrower -> it is the queue root -> next to settle, and its allowed slice is non-empty.
        assertTrue(d.isNextToSettle, "sole borrower is the queue root");
        (, uint256 expectedSlice,) = c.nextSettlementBorrower();
        assertEq(d.slice, expectedSlice, "dashboard slice == nextSettlementBorrower slice");
    }

    /// @dev `positionOf` reflects a banned borrower and a personal settlement LTV opt-in.
    function test_positionOf_reflectsBanAndSettleLtv() public {
        Market storage m = _m();
        (, address borrower) = _seedBorrower(1000 ether, 100 ether, 10 ether);
        _ban(borrower); // quorum 1 -> Banned, 1 flag
        vm.prank(borrower);
        c.setSettlementLtv(0.5e18);

        ILidoLendMarketController.BorrowerPosition memory d = c.positionOf(borrower);
        assertTrue(d.banned, "banned reflected");
        assertEq(d.flagCount, 1, "one flag recorded");
        assertEq(d.settlementLtv, 0.5e18, "personal settle LTV reflected");
        // A banned position never unlocks: getUnlockTime returns max. But active is already 100 (matured pre-ban),
        // and the activating bucket is empty, so there is no live timer -> unlockTime is 0 (no activating lot).
        assertEq(d.unlockTime, 0, "no activating lot -> no unlock time");
    }
}

/// @notice Thin harness exposing `PausableUntil`'s internal helpers. The controller only routes through
///         `_pauseFor`/`_resume`, so the absolute-deadline path `_pauseUntil` (and its `PauseUntilMustBeInFuture`
///         revert) has no controller entrypoint and is otherwise unreachable. This harness drives it directly so
///         the base contract reaches full coverage.
contract PausableUntilHarness is PausableUntil {
    function pauseUntil(uint256 pauseUntilInclusive) external {
        _pauseUntil(pauseUntilInclusive);
    }

    function pauseForExternal(uint256 duration) external {
        _pauseFor(duration);
    }

    function resumeExternal() external {
        _resume();
    }

    function checkPaused() external view {
        _checkPaused();
    }
}

/// @notice Direct coverage of `PausableUntil`'s `_pauseUntil` path, which `LidoLendMarketController` never
///         routes through (it only exposes `pauseFor`).
contract PausableUntilTest is Test {
    PausableUntilHarness internal p;

    function setUp() public {
        vm.warp(1_000_000); // a non-zero base time so "in the past" is well-defined
        p = new PausableUntilHarness();
    }

    // ── mutations ──

    /// @dev Pause until an absolute future timestamp: stays paused through it, resumes the second after.
    function test_pauseUntil_futureTimestamp() public {
        uint256 deadline = block.timestamp + 1 hours;
        p.pauseUntil(deadline);
        assertTrue(p.isPaused(), "paused until the deadline");
        // Resume timestamp is deadline + 1 (paused through `deadline`, resumes the second after).
        assertEq(p.getResumeSinceTimestamp(), deadline + 1, "resume == deadline + 1");

        vm.warp(deadline); // still within the inclusive window
        assertTrue(p.isPaused(), "paused at the inclusive deadline");
        vm.warp(deadline + 1); // the second after -> resumed
        assertFalse(p.isPaused(), "resumed the second after the deadline");
    }

    /// @dev `_pauseUntil(PAUSE_INFINITELY)` parks the resume timestamp at the sentinel (the infinite branch).
    function test_pauseUntil_infinite() public {
        p.pauseUntil(p.PAUSE_INFINITELY());
        assertEq(p.getResumeSinceTimestamp(), p.PAUSE_INFINITELY(), "infinite pause parks at the sentinel");
        assertTrue(p.isPaused(), "paused");
    }

    /// @dev A target timestamp in the past reverts `PauseUntilMustBeInFuture`. Equal to now is allowed (the
    ///      window is inclusive), so `now - 1` is the boundary that reverts.
    function testRevert_pauseUntil_past() public {
        vm.expectRevert(PausableUntil.PauseUntilMustBeInFuture.selector);
        p.pauseUntil(block.timestamp - 1);
    }

    /// @dev `_pauseUntil` while already paused reverts `ResumedExpected` (via `_checkResumed`).
    function testRevert_pauseUntil_whenAlreadyPaused() public {
        p.pauseUntil(block.timestamp + 1 hours);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        p.pauseUntil(block.timestamp + 2 hours);
    }

    // ── views ──

    /// @dev `_checkPaused` reverts `PausedExpected` when the contract is resumed (the default state).
    function testRevert_checkPaused_whenResumed() public {
        vm.expectRevert(PausableUntil.PausedExpected.selector);
        p.checkPaused();
    }

    /// @dev `_checkPaused` succeeds while paused — the success leg of the branch.
    function test_checkPaused_whenPaused() public {
        p.pauseForExternal(1 hours);
        p.checkPaused(); // no revert
    }
}
