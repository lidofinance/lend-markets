// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLendMarketController as IBase} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice Controller hook branches reached only with forged core payloads (the core never sends these) or with
///         the specific position shapes the end-to-end flows don't hit: `PositionAccountingMismatch` on the repay,
///         withdraw-collateral, and liquidate hooks, the liquidate zero-seize path, a zero-debt collateral withdraw
///         that skips the health gate, and the `hasBadDebt` empty-queue / solvent-root branches.
contract LidoLendMarketControllerHooksTest is LidoLendSetup {
    using MarketActions for Market;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender liquidity + a matured borrower; `borrow` optionally opens debt.
    function _seedBorrower(uint256 borrow) internal returns (address borrower) {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        if (borrow > 0) m.borrow(borrower, borrow);
    }

    function _onAsCore(IBase.HookEvent ev, bytes memory data) internal {
        vm.prank(address(_m().core));
        _m().controller.on(_m().id, ev, data);
    }

    // ── PositionAccountingMismatch: the controller's mirror of the core position diverges ──

    /// @dev A repay hook payload claiming more shares than the borrower's position reverts PositionAccountingMismatch.
    function test_repayHook_forgedSharesAbovePosition_reverts() public {
        address borrower = _seedBorrower(10 ether);
        uint256 shares = _m().core.position(_m().id, borrower).borrowShares;

        bytes memory data =
            abi.encode(IBase.RepayHookData({caller: address(this), onBehalf: borrower, assets: 0, shares: shares + 1}));
        vm.prank(address(_m().core));
        vm.expectRevert(ILidoLendMarketController.PositionAccountingMismatch.selector);
        _m().controller.on(_m().id, IBase.HookEvent.Repay, data);
    }

    /// @dev A forged withdraw-collateral payload above the position's collateral reverts PositionAccountingMismatch.
    function test_withdrawCollateralHook_forgedAssetsAbovePosition_reverts() public {
        address borrower = _seedBorrower(0);
        uint256 collat = _m().core.position(_m().id, borrower).collateral;

        bytes memory data = abi.encode(
            IBase.WithdrawCollateralHookData({
                caller: address(this), onBehalf: borrower, receiver: borrower, assets: collat + 1
            })
        );
        vm.prank(address(_m().core));
        vm.expectRevert(ILidoLendMarketController.PositionAccountingMismatch.selector);
        _m().controller.on(_m().id, IBase.HookEvent.WithdrawCollateral, data);
    }

    /// @dev A liquidate hook payload seizing more than the borrower's collateral reverts PositionAccountingMismatch.
    function test_liquidateHook_seizeAboveCollateral_reverts() public {
        address borrower = _seedBorrower(10 ether);
        uint256 collat = _m().core.position(_m().id, borrower).collateral;

        bytes memory data = abi.encode(
            IBase.LiquidateHookData({
                caller: address(this), borrower: borrower, seizedAssets: collat + 1, repaidAssets: 0, repaidShares: 0
            })
        );
        vm.prank(address(_m().core));
        vm.expectRevert(ILidoLendMarketController.PositionAccountingMismatch.selector);
        _m().controller.on(_m().id, IBase.HookEvent.Liquidate, data);
    }

    // ── liquidate zero-seize path (the `seizedAssets != 0` guard's false branch) ──

    /// @dev A zero-seize liquidate that repays the whole debt must re-key the borrower to zero debt — i.e. drop it
    ///      from the settlement queue — without touching collateral. Asserting the queue transition (not just
    ///      "no revert") checks the re-key is correct, not merely reached.
    function test_liquidateHook_zeroSeize_reKeysToZeroDebt() public {
        address borrower = _seedBorrower(10 ether);
        uint256 shares = _m().core.position(_m().id, borrower).borrowShares;
        uint256 collateral = _m().core.position(_m().id, borrower).collateral;
        assertEq(_m().controller.settlementBorrowersCount(), 1, "borrower is queued while it has debt");

        _onAsCore(
            IBase.HookEvent.Liquidate,
            abi.encode(
                IBase.LiquidateHookData({
                    caller: address(this), borrower: borrower, seizedAssets: 0, repaidAssets: 0, repaidShares: shares
                })
            )
        );

        assertEq(_m().controller.settlementBorrowersCount(), 0, "zero-debt borrower is dropped from the queue");
        assertEq(_m().core.position(_m().id, borrower).collateral, collateral, "zero-seize leaves collateral intact");
    }

    // ── hasBadDebt view: empty queue vs solvent root ──

    /// @dev A market with no queued borrowers has an empty settlement queue, so `hasBadDebt` short-circuits to
    ///      false without evaluating any position.
    function test_hasBadDebt_emptyQueue_false() public {
        assertEq(_m().controller.settlementBorrowersCount(), 0, "no borrowers queued");
        assertFalse(_m().controller.hasBadDebt(), "empty queue has no bad debt");
    }

    /// @dev A queued but solvent borrower makes the root non-zero, so the check falls through to the position
    ///      evaluation and still reports no bad debt.
    function test_hasBadDebt_solventRoot_false() public {
        _seedBorrower(10 ether); // healthy borrower: collateral well above debt
        assertEq(_m().controller.settlementBorrowersCount(), 1, "borrower queued");
        assertFalse(_m().controller.hasBadDebt(), "solvent root is not bad debt");
    }

    // ── zero-debt collateral withdraw skips the active-collateral health gate ──

    /// @dev A debt-free borrower withdraws its entire collateral: the hook skips the active-collateral health gate.
    function test_withdrawCollateral_zeroDebt_skipsHealthGate() public {
        address borrower = _seedBorrower(0); // collateral, no debt
        Market storage m = _m();

        uint256 before = m.core.position(m.id, borrower).collateral;
        vm.prank(borrower);
        m.core.withdrawCollateral(m.params, before, borrower, borrower); // whole position out, no health check
        assertEq(m.core.position(m.id, borrower).collateral, 0, "zero-debt withdraw needs no active-collateral check");
    }

    // ── borrow-share-rate ceiling — recovery/exemption branches ──

    /// @dev Force the core market into an over-cap state (`totalBorrowShares` huge vs `totalBorrowAssets`), which
    ///      the guarded paths cannot create post-fix but a pre-existing/forced state can be. `market` is the 4th
    ///      `LidoLend` state variable (slot 3); its second sub-slot packs `totalBorrowAssets` (low 128) |
    ///      `totalBorrowShares` (high 128). `lastUpdate` is set to now so the accrued `_marketView` equals raw.
    function _forceOverCapMarket(uint256 tba, uint256 tbs) internal {
        Market storage m = _m();
        bytes32 base = keccak256(abi.encode(Id.unwrap(m.id), uint256(3)));
        vm.store(address(m.core), bytes32(uint256(base) + 1), bytes32((tbs << 128) | tba));
        uint256 fee = m.core.market(m.id).fee;
        vm.store(address(m.core), bytes32(uint256(base) + 2), bytes32((fee << 128) | block.timestamp));

        // Self-validate the slot: the raw getter must read back exactly what we injected.
        assertEq(m.core.market(m.id).totalBorrowAssets, tba, "slot check: TBA");
        assertEq(m.core.market(m.id).totalBorrowShares, tbs, "slot check: TBS");
    }

    /// @dev A borrow is rejected when the market is already over the cap: the direct (non-transition) check
    ///      blocks growing debt on a broken market — only repay/settle cleanup can bring it back under.
    function test_borrowHook_overCapMarket_reverts() public {
        Market storage m = _m();
        _forceOverCapMarket(1, 1e9);

        bytes memory data = abi.encode(
            IBase.BorrowHookData({
                caller: address(this), onBehalf: address(0xB0B), receiver: address(0xB0B), assets: 1e5, shares: 1e15
            })
        );
        vm.prank(address(m.core));
        vm.expectRevert(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        m.controller.on(m.id, IBase.HookEvent.Borrow, data);
    }

    /// @dev req9 — permissionless cleanup: when the market is ALREADY over the cap, a repay is NOT blocked by the
    ///      ceiling (the transition check short-circuits on `exceeded(pre)`), so a stranded state can be unwound.
    function test_repayHook_overCapMarket_cleanupAllowed() public {
        Market storage m = _m();
        _forceOverCapMarket(1, 1e9); // rate ~5e8 >> MAX_BORROW_SHARE_RATE (1e7)

        // A repay in this state must not revert with the rate error (it is allowed, to enable cleanup). Zero
        // shares keeps it consistent with the (empty) position; the point is the rate branch, not the accounting.
        bytes memory data =
            abi.encode(IBase.RepayHookData({caller: address(this), onBehalf: address(0xB0B), assets: 1, shares: 0}));
        _onAsCore(IBase.HookEvent.Repay, data); // no BorrowShareRateExceeded revert
    }

    /// @dev Settlement uses the same transition guard as repayment. An already over-cap market must reach the
    ///      policy checks instead of being blocked by the rate ceiling, so a legacy stranded state remains
    ///      recoverable through settlement too.
    function test_settleHook_overCapMarket_cleanupAllowed() public {
        Market storage m = _m();
        _forceOverCapMarket(1, 1e9);

        bytes memory data = abi.encode(
            IBase.SettleHookData({
                caller: address(this),
                onBehalf: address(this),
                borrower: address(0xB0B),
                receiver: address(this),
                supplySharesBurned: 0,
                borrowAssetsCanceled: 0,
                borrowSharesCanceled: 0,
                seizedAssets: 0
            })
        );
        _onAsCore(IBase.HookEvent.Settle, data); // no BorrowShareRateExceeded revert
    }

    /// @dev req8 — liquidation is exempt: even with the market over the cap, the liquidate hook carries no
    ///      rate check, so it never reverts with the rate error (stays live for recovery).
    function test_liquidateHook_overCapMarket_notBlocked() public {
        Market storage m = _m();
        _forceOverCapMarket(1, 1e9);

        bytes memory data = abi.encode(
            IBase.LiquidateHookData({
                caller: address(this), borrower: address(0xB0B), repaidShares: 0, repaidAssets: 0, seizedAssets: 0
            })
        );
        _onAsCore(IBase.HookEvent.Liquidate, data); // exempt: no BorrowShareRateExceeded revert
    }
}
