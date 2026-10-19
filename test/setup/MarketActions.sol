// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, IMorpho, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {MathLib, WAD} from "@lido-lend/src/libraries/MathLib.sol";
import {LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IPausableUntil} from "../../src/interfaces/IPausableUntil.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";

import {BPS} from "../../src/libs/Constants.sol";
import {BlockInfoWithHash, GuardiansOpinion} from "../../src/types/GuardianSignalsTypes.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {Approvals} from "./Approvals.sol";
import {Erc4626Math} from "./Erc4626Math.sol";
import {MockPriceOracle} from "./Mocks.sol";
import {Market} from "./Types.sol";

/// @notice DG-style action helpers over a deployed `Market` (`using MarketActions for Market` →
///         `market.borrow(bob, 10 ether)`). Each does the action AND asserts the balances, state deltas
///         and events around it, so call sites never repeat assertion blocks (AGENTS "Helper Pattern").
///
///         Actors must be funded first: token `deal` is StdCheats (a contract), not a `vm` cheatcode, so
///         it cannot live in a library — funding helpers stay on the test base. This is also more
///         realistic: an actor holds a budget and the actions spend it.
library MarketActions {
    using SharesMathLib for uint256;
    using MathLib for uint256;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;

    /// @dev Pre-call snapshot for the liquidation helpers, one memory slot on the stack (via_ir = false).
    struct LiquidationSnapshot {
        uint256 keeperCollateral;
        uint128 borrowerCollateral;
        uint128 borrowerShares;
        uint256 borrowerActive;
        uint128 totalSupplyAssets;
        uint128 totalBorrowShares;
        uint256 expectedSeized;
        uint256 expectedRepaidAssets;
        uint256 expectedRepaidShares;
    }

    /// @notice What one vault `settle` must do, recomputed from the spec over its whole borrower list (see
    ///         `expectedPersonalSettlements`).
    struct SettlementExpectation {
        bool applies;
        uint256 cutBorrowShares;
        uint256 cutSupplyShares;
        uint256 debtCanceled;
        uint256 collateralSeized;
        uint256 sharesBurned;
    }

    /// @dev Pre-call state the `settle` assertions compare against. The borrower fields are set only for a
    ///      single-borrower batch.
    struct SettleSnapshot {
        address caller;
        address owner;
        address receiver;
        uint256 ownerShares;
        uint256 allowance;
        uint256 receiverCollateral;
        uint256 receiverLoan;
        uint256 ownerCollateral;
        uint256 ownerLoan;
        uint256 vaultTotalSupply;
        uint256 managedSupplyShares;
        MorphoMarket market;
        address borrower;
        uint128 borrowerShares;
        uint128 borrowerCollateral;
    }

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event SupplyCollateral(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets);
    event WithdrawCollateral(
        Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets
    );
    event Settle(
        Id indexed id,
        address caller,
        address indexed onBehalf,
        address indexed borrower,
        address receiver,
        uint256 supplySharesBurned,
        uint256 borrowAssetsCanceled,
        uint256 borrowSharesCanceled,
        uint256 seizedAssets
    );

    // ── Lender ──

    /// @notice Lender deposits `assets` into the vault. Asserts the minted shares against the ERC-4626
    ///         conversion recomputed from the live totals (and that the preview agrees), the `Deposit` event,
    ///         the loan pulled, and the share-balance / `totalSupply` / `totalAssets` deltas.
    function vaultDeposit(Market storage self, address lender, uint256 assets) internal returns (uint256 shares) {
        Approvals.approve(address(self.loanToken), lender, address(self.vault), assets);

        uint256 expectedShares = Erc4626Math.toShares(self.vault, assets, Math.Rounding.Floor);
        uint256 loanBefore = self.loanToken.balanceOf(lender);
        uint256 sharesBefore = self.vault.balanceOf(lender);
        uint256 supplyBefore = self.vault.totalSupply();
        uint256 assetsBefore = self.vault.totalAssets();
        vm.assertEq(self.vault.previewDeposit(assets), expectedShares, "deposit: preview != ERC-4626 recompute");

        vm.expectEmit(true, true, false, true, address(self.vault));
        emit Deposit(lender, lender, assets, expectedShares);
        vm.prank(lender);
        shares = self.vault.deposit(assets, lender);

        vm.assertEq(shares, expectedShares, "deposit: shares != ERC-4626 recompute");
        vm.assertEq(self.loanToken.balanceOf(lender), loanBefore - assets, "deposit: loan not pulled");
        vm.assertEq(self.vault.balanceOf(lender), sharesBefore + shares, "deposit: shares not credited");
        vm.assertEq(self.vault.totalSupply(), supplyBefore + shares, "deposit: totalSupply delta");
        // The core rounds the minted supply shares down, so total assets grow by the deposit or one unit less.
        vm.assertLe(self.vault.totalAssets(), assetsBefore + assets, "deposit: totalAssets rose above the deposit");
        vm.assertGe(self.vault.totalAssets() + 1, assetsBefore + assets, "deposit: totalAssets delta");
    }

    /// @notice Lender withdraws `assets` of ordinary liquidity. Asserts shares vs preview, the `Withdraw`
    ///         event, the loan received, and the share burn.
    function vaultWithdraw(Market storage self, address lender, uint256 assets) internal returns (uint256 shares) {
        uint256 expectedShares = Erc4626Math.toShares(self.vault, assets, Math.Rounding.Ceil);
        uint256 loanBefore = self.loanToken.balanceOf(lender);
        uint256 sharesBefore = self.vault.balanceOf(lender);
        vm.assertEq(self.vault.previewWithdraw(assets), expectedShares, "withdraw: preview != ERC-4626 recompute");

        vm.expectEmit(true, true, true, true, address(self.vault));
        emit Withdraw(lender, lender, lender, assets, expectedShares);
        vm.prank(lender);
        shares = self.vault.withdraw(assets, lender, lender);

        vm.assertEq(shares, expectedShares, "withdraw: shares != ERC-4626 recompute");
        vm.assertEq(self.loanToken.balanceOf(lender), loanBefore + assets, "withdraw: loan not received");
        vm.assertEq(self.vault.balanceOf(lender), sharesBefore - shares, "withdraw: shares not burned");
    }

    /// @notice Lender mints `shares` from the vault. Asserts assets vs preview, the `Deposit` event, the
    ///         loan pulled, and the share / `totalSupply` deltas.
    function vaultMint(Market storage self, address lender, uint256 shares) internal returns (uint256 assets) {
        uint256 expectedAssets = Erc4626Math.toAssets(self.vault, shares, Math.Rounding.Ceil);
        Approvals.approve(address(self.loanToken), lender, address(self.vault), expectedAssets);

        uint256 loanBefore = self.loanToken.balanceOf(lender);
        uint256 sharesBefore = self.vault.balanceOf(lender);
        uint256 supplyBefore = self.vault.totalSupply();
        vm.assertEq(self.vault.previewMint(shares), expectedAssets, "mint: preview != ERC-4626 recompute");

        vm.expectEmit(true, true, false, true, address(self.vault));
        emit Deposit(lender, lender, expectedAssets, shares);
        vm.prank(lender);
        assets = self.vault.mint(shares, lender);

        vm.assertEq(assets, expectedAssets, "mint: assets != ERC-4626 recompute");
        vm.assertEq(self.loanToken.balanceOf(lender), loanBefore - assets, "mint: loan not pulled");
        vm.assertEq(self.vault.balanceOf(lender), sharesBefore + shares, "mint: shares not credited");
        vm.assertEq(self.vault.totalSupply(), supplyBefore + shares, "mint: totalSupply delta");
    }

    /// @notice Lender redeems `shares` of ordinary liquidity. Asserts assets vs preview, the `Withdraw`
    ///         event, the loan received, and the share burn.
    function vaultRedeem(Market storage self, address lender, uint256 shares) internal returns (uint256 assets) {
        uint256 expectedAssets = Erc4626Math.toAssets(self.vault, shares, Math.Rounding.Floor);
        uint256 loanBefore = self.loanToken.balanceOf(lender);
        uint256 sharesBefore = self.vault.balanceOf(lender);
        vm.assertEq(self.vault.previewRedeem(shares), expectedAssets, "redeem: preview != ERC-4626 recompute");

        vm.expectEmit(true, true, true, true, address(self.vault));
        emit Withdraw(lender, lender, lender, expectedAssets, shares);
        vm.prank(lender);
        assets = self.vault.redeem(shares, lender, lender);

        vm.assertEq(assets, expectedAssets, "redeem: assets != ERC-4626 recompute");
        vm.assertEq(self.loanToken.balanceOf(lender), loanBefore + assets, "redeem: loan not received");
        vm.assertEq(self.vault.balanceOf(lender), sharesBefore - shares, "redeem: shares not burned");
    }

    /// @notice Lender (`owner`) targeted-settles `shares` against `borrowers`, collateral to `receiver`.
    ///         Best-effort within the batch but reverts when no borrower is settled. Asserts the `Settled` event,
    ///         the shares burned, the collateral seized and the debt canceled against `expectedPersonalSettlements`
    ///         over the whole list, the market totals and the vault's `totalSupply` and managed supply shares, the
    ///         owner's share burn, and that `receiver` got the collateral and no loan tokens, with the owner's own
    ///         balances untouched when it is not the receiver. A single-borrower batch also holds the core `Settle`
    ///         event and the borrower's position to the recompute.
    function settle(Market storage self, address owner, uint256 shares, address[] memory borrowers, address receiver)
        internal
        returns (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled)
    {
        return settleBy(self, owner, owner, shares, borrowers, receiver);
    }

    /// @notice `settle` with `caller` acting on `owner`'s shares. An operator (`caller != owner`) must also have
    ///         spent allowance for exactly the shares burned.
    function settleBy(
        Market storage self,
        address caller,
        address owner,
        uint256 shares,
        address[] memory borrowers,
        address receiver
    ) internal returns (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled) {
        accrueInterest(self); // the vault quotes off simulated totals; same-block accrual makes them the stored ones
        SettlementExpectation memory expected = _personalExpectation(self, shares, borrowers);
        SettleSnapshot memory pre = _snapshotSettle(self, caller, owner, receiver, borrowers);
        _expectSettled(self, pre, expected);

        vm.prank(caller);
        (sharesBurned, collateralSeized, debtCanceled) = self.vault.settle(shares, borrowers, receiver, owner);

        vm.assertLe(sharesBurned, shares, "settle: burned > requested");
        vm.assertEq(debtCanceled, expected.debtCanceled, "settle: debtCanceled != personal recompute");
        _assertSettle(self, pre, expected, sharesBurned, collateralSeized);
    }

    /// @dev The core settles on the vault's own supply position and pays `receiver` directly, so its `Settle`
    ///      carries the vault as caller and onBehalf. It fires inside the vault call, before the vault's `Settled`,
    ///      once per cut, so only a single-borrower batch pins it.
    function _expectSettled(Market storage self, SettleSnapshot memory pre, SettlementExpectation memory expected)
        private
    {
        if (!expected.applies) return;
        if (pre.borrower != address(0)) {
            vm.expectEmit(true, true, true, true, address(self.core));
            emit Settle(
                self.id,
                address(self.vault),
                address(self.vault),
                pre.borrower,
                pre.receiver,
                expected.cutSupplyShares,
                expected.debtCanceled,
                expected.cutBorrowShares,
                expected.collateralSeized
            );
        }
        vm.expectEmit(true, true, true, true, address(self.vault));
        emit ILidoLendERC4626.Settled(
            pre.caller, pre.owner, pre.receiver, expected.sharesBurned, expected.collateralSeized, expected.debtCanceled
        );
    }

    /// @dev The vault cuts personal slices only, so the recompute over the list determines every targeted settlement.
    function _personalExpectation(Market storage self, uint256 shares, address[] memory borrowers)
        private
        view
        returns (SettlementExpectation memory expected)
    {
        (expected,) = expectedPersonalSettlements(self, shares, borrowers);
        expected.applies = true;
    }

    function _snapshotSettle(
        Market storage self,
        address caller,
        address owner,
        address receiver,
        address[] memory borrowers
    ) private view returns (SettleSnapshot memory pre) {
        pre.caller = caller;
        pre.owner = owner;
        pre.receiver = receiver;
        pre.ownerShares = self.vault.balanceOf(owner);
        pre.allowance = self.vault.allowance(owner, caller);
        pre.receiverCollateral = self.collateralToken.balanceOf(receiver);
        pre.receiverLoan = self.loanToken.balanceOf(receiver);
        pre.ownerCollateral = self.collateralToken.balanceOf(owner);
        pre.ownerLoan = self.loanToken.balanceOf(owner);
        pre.vaultTotalSupply = self.vault.totalSupply();
        pre.managedSupplyShares = self.vault.managedSupplyShares();
        pre.market = self.core.market(self.id);
        if (borrowers.length == 1) {
            Position memory position = self.core.position(self.id, borrowers[0]);
            pre.borrower = borrowers[0];
            pre.borrowerShares = position.borrowShares;
            pre.borrowerCollateral = position.collateral;
        }
    }

    /// @dev A targeted settlement pays no loan assets, so the exit balance check runs with a zero loan leg.
    function _assertSettle(
        Market storage self,
        SettleSnapshot memory pre,
        SettlementExpectation memory expected,
        uint256 sharesBurned,
        uint256 collateralSeized
    ) private view {
        if (expected.applies) {
            vm.assertEq(sharesBurned, expected.sharesBurned, "settle: sharesBurned != personal recompute");
            vm.assertEq(collateralSeized, expected.collateralSeized, "settle: collateralSeized != personal recompute");
            _assertPersonalSettleDeltas(self, pre, expected);
        }
        vm.assertEq(self.vault.totalSupply(), pre.vaultTotalSupply - sharesBurned, "settle: vault totalSupply burned");
        _assertExitBalances(self, pre, sharesBurned, 0, collateralSeized);
    }

    /// @dev The cancelled debt rounds up, so it can exceed `totalBorrowAssets` by one unit; that total floors at zero.
    ///      The totals aggregate over the batch; the position deltas need its one borrower.
    function _assertPersonalSettleDeltas(
        Market storage self,
        SettleSnapshot memory pre,
        SettlementExpectation memory expected
    ) private view {
        if (pre.borrower != address(0)) {
            Position memory post = self.core.position(self.id, pre.borrower);
            vm.assertEq(
                post.borrowShares, pre.borrowerShares - expected.cutBorrowShares, "settle: borrower debt shares cut"
            );
            vm.assertEq(
                post.collateral,
                pre.borrowerCollateral - expected.collateralSeized,
                "settle: borrower collateral debited"
            );
        }

        MorphoMarket memory mkt = self.core.market(self.id);
        vm.assertEq(
            mkt.totalSupplyShares,
            pre.market.totalSupplyShares - expected.cutSupplyShares,
            "settle: market supply shares burned"
        );
        vm.assertEq(
            mkt.totalSupplyAssets,
            pre.market.totalSupplyAssets - expected.debtCanceled,
            "settle: market supply assets cancelled"
        );
        vm.assertEq(
            mkt.totalBorrowShares,
            pre.market.totalBorrowShares - expected.cutBorrowShares,
            "settle: market borrow shares cancelled"
        );
        vm.assertEq(
            mkt.totalBorrowAssets,
            Math.saturatingSub(pre.market.totalBorrowAssets, expected.debtCanceled),
            "settle: market borrow assets cancelled"
        );
        vm.assertEq(
            self.vault.managedSupplyShares(),
            pre.managedSupplyShares - expected.cutSupplyShares,
            "settle: vault managed supply shares burned"
        );
    }

    /// @notice Lender (`owner`) fallback-exits `shares`: the redeem leg pays loan and the settle leg pays
    ///         collateral, both to `receiver`. Asserts `sharesBurned <= shares`, the owner's share burn, the
    ///         loan + collateral received by `receiver`, and — when `owner != receiver` — that the owner's own
    ///         loan and collateral are untouched (both legs routed to `receiver`).
    function fallbackExit(Market storage self, address owner, uint256 shares, address receiver, uint256 maxIterations)
        internal
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        return fallbackExitBy(self, owner, owner, shares, receiver, maxIterations);
    }

    /// @notice `fallbackExit` with `caller` acting on `owner`'s shares. An operator (`caller != owner`) must also
    ///         have spent allowance for exactly the shares burned.
    function fallbackExitBy(
        Market storage self,
        address caller,
        address owner,
        uint256 shares,
        address receiver,
        uint256 maxIterations
    ) internal returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) {
        SettleSnapshot memory pre = _snapshotSettle(self, caller, owner, receiver, new address[](0));

        vm.prank(caller);
        (sharesBurned, loanAssets, collateralSeized, debtCanceled) =
            self.vault.fallbackExit(shares, receiver, owner, maxIterations);

        vm.assertLe(sharesBurned, shares, "fallbackExit: burned > requested");
        _assertExitBalances(self, pre, sharesBurned, loanAssets, collateralSeized);
    }

    /// @dev The balance checks shared by every vault exit.
    function _assertExitBalances(
        Market storage self,
        SettleSnapshot memory pre,
        uint256 sharesBurned,
        uint256 loanAssets,
        uint256 collateralSeized
    ) private view {
        vm.assertEq(self.vault.balanceOf(pre.owner), pre.ownerShares - sharesBurned, "exit: owner shares burned");
        if (pre.caller != pre.owner) {
            vm.assertEq(
                self.vault.allowance(pre.owner, pre.caller), pre.allowance - sharesBurned, "exit: allowance spent"
            );
        }
        vm.assertEq(self.loanToken.balanceOf(pre.receiver), pre.receiverLoan + loanAssets, "exit: receiver loan");
        vm.assertEq(
            self.collateralToken.balanceOf(pre.receiver),
            pre.receiverCollateral + collateralSeized,
            "exit: receiver collateral"
        );
        if (pre.owner != pre.receiver) {
            vm.assertEq(self.loanToken.balanceOf(pre.owner), pre.ownerLoan, "exit: owner loan routed away");
            vm.assertEq(
                self.collateralToken.balanceOf(pre.owner), pre.ownerCollateral, "exit: owner collateral routed away"
            );
        }
    }

    /// @notice Lender (`owner`) fallback-exits `shares` that free liquidity fully covers, so only the redeem leg
    ///         runs: exactly `shares` burn, the ERC-4626 conversion of them is paid in loan tokens to `receiver`,
    ///         and no collateral moves and no debt is canceled. Asserts the liquidity precondition first, so a
    ///         resized fixture cannot turn this into a settling exit unnoticed.
    function fallbackExitLiquid(Market storage self, address owner, uint256 shares, address receiver)
        internal
        returns (uint256 loanAssets)
    {
        uint256 expectedAssets = Erc4626Math.toAssets(self.vault, shares, Math.Rounding.Floor);
        vm.assertLe(
            expectedAssets, self.controller.maxWithdrawableAssets(address(self.vault)), "fallbackExitLiquid: illiquid"
        );
        uint256 ownerSharesBefore = self.vault.balanceOf(owner);
        uint256 recvLoanBefore = self.loanToken.balanceOf(receiver);
        uint256 recvColBefore = self.collateralToken.balanceOf(receiver);

        vm.expectEmit(true, true, true, true, address(self.vault));
        emit ILidoLendERC4626.FallbackExit(owner, owner, receiver, shares, 0, expectedAssets, 0, 0);
        vm.prank(owner);
        (uint256 sharesBurned, uint256 paid, uint256 collateralSeized, uint256 debtCanceled) =
            self.vault.fallbackExit(shares, receiver, owner, 0);
        loanAssets = paid;

        vm.assertEq(sharesBurned, shares, "fallbackExitLiquid: not all shares burned");
        vm.assertEq(loanAssets, expectedAssets, "fallbackExitLiquid: loan != ERC-4626 recompute");
        vm.assertEq(collateralSeized, 0, "fallbackExitLiquid: settle leg seized collateral");
        vm.assertEq(debtCanceled, 0, "fallbackExitLiquid: settle leg canceled debt");
        vm.assertEq(self.vault.balanceOf(owner), ownerSharesBefore - shares, "fallbackExitLiquid: owner shares");
        vm.assertEq(
            self.loanToken.balanceOf(receiver), recvLoanBefore + loanAssets, "fallbackExitLiquid: receiver loan"
        );
        vm.assertEq(self.collateralToken.balanceOf(receiver), recvColBefore, "fallbackExitLiquid: receiver collateral");
    }

    /// @notice What a vault `settle(shares, [borrower], ...)` must do when `borrower` carries a personal
    ///         settlement LTV: `expectedPersonalSettlements` over the one borrower, which must yield a cut.
    function expectedPersonalSettlement(Market storage self, uint256 shares, address borrower)
        internal
        view
        returns (SettlementExpectation memory e)
    {
        address[] memory one = new address[](1);
        one[0] = borrower;
        (e,) = expectedPersonalSettlements(self, shares, one);
        vm.assertGt(e.cutBorrowShares, 0, "expectedPersonalSettlement: no cut (budget, slice or seizure is zero)");
    }

    /// @notice What a vault `settle(shares, borrowers, ...)` must do, recomputed from the spec. The budget is the
    ///         redemption value of `shares` in core supply shares, rounded down. Borrowers take personal cuts in list
    ///         order while budget remains, each applied to the totals before the next. The vault burns all `shares`
    ///         once the budget is exhausted, else the settled fraction rounded up. `cuts[i]` is the borrow shares
    ///         cut from `borrowers[i]`; `e` aggregates the whole list.
    /// @dev Sized on `accruedMarket`, so it holds whether or not the core has accrued this block.
    function expectedPersonalSettlements(Market storage self, uint256 shares, address[] memory borrowers)
        internal
        view
        returns (SettlementExpectation memory e, uint256[] memory cuts)
    {
        MorphoMarket memory mkt = accruedMarket(self);
        uint256 price = self.oracle.price();
        uint256 budget = Erc4626Math.toAssets(self.vault, shares, Math.Rounding.Floor)
            .toSharesDown(mkt.totalSupplyAssets, mkt.totalSupplyShares);
        uint256 remaining = budget;
        cuts = new uint256[](borrowers.length);
        for (uint256 i; i < borrowers.length && remaining != 0; ++i) {
            cuts[i] = _applyPersonalCut(self, mkt, price, borrowers[i], remaining, e);
            remaining = budget - e.cutSupplyShares;
        }
        if (budget == 0) return (e, cuts);
        e.sharesBurned = remaining == 0 ? shares : Math.mulDiv(shares, budget - remaining, budget, Math.Rounding.Ceil);
    }

    /// @dev One personal cut of `borrower` within `remaining` core supply shares, added to `e` and applied to `mkt`
    ///      as the core applies it. Returns 0 when the borrower has no slice or the cut seizes nothing.
    function _applyPersonalCut(
        Market storage self,
        MorphoMarket memory mkt,
        uint256 price,
        address borrower,
        uint256 remaining,
        SettlementExpectation memory e
    ) private view returns (uint256 cut) {
        Position memory p = self.core.position(self.id, borrower);
        uint256 slice = _personalSlice(self, mkt, p, price, borrower);
        if (slice == 0) return 0;
        cut = _budgetedCut(mkt, p, slice, remaining);
        uint256 seized = _seizure(mkt, cut, price);
        if (seized == 0) return 0;
        uint256 canceled = cut.toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        uint256 burn = canceled.toSharesUp(mkt.totalSupplyAssets, mkt.totalSupplyShares);
        e.cutBorrowShares += cut;
        e.debtCanceled += canceled;
        e.cutSupplyShares += burn;
        e.collateralSeized += seized;
        mkt.totalSupplyAssets -= uint128(canceled);
        mkt.totalSupplyShares -= uint128(burn);
        mkt.totalBorrowShares -= uint128(cut);
        mkt.totalBorrowAssets = uint128(Math.saturatingSub(mkt.totalBorrowAssets, canceled));
    }

    /// @notice The cut the controller must quote for the queue root `borrower` within `budget` core supply shares
    ///         (0 for no budget), recomputed from the spec: the larger of the personal and the root-policy slice,
    ///         sized in borrow shares and shrunk to the budget as a personal cut is. Zero when the cut seizes nothing
    ///         or the position has no debt or no collateral value.
    /// @dev Sized on `accruedMarket`, like `expectedPersonalSettlements`.
    function expectedRootSettlement(Market storage self, address borrower, uint256 budget)
        internal
        view
        returns (uint256)
    {
        MorphoMarket memory mkt = accruedMarket(self);
        Position memory p = self.core.position(self.id, borrower);
        if (p.borrowShares == 0 || p.collateral == 0) return 0;
        uint256 price = self.oracle.price();
        uint256 debt = uint256(p.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        uint256 collateralValue = Math.mulDiv(p.collateral, price, ORACLE_PRICE_SCALE);
        if (collateralValue == 0) return 0;
        uint256 allowed = Math.max(
            _personalSlice(self, mkt, p, price, borrower), _rootPolicySlice(self, p, debt, collateralValue, price)
        );
        if (allowed == 0) return 0;
        uint256 cut = _budgetedCut(mkt, p, allowed, budget);
        return _seizure(mkt, cut, price) == 0 ? 0 : cut;
    }

    /// @dev The personal slice: loan assets that bring `borrower` to its personal settlement LTV, capped at its
    ///      debt; 0 without that LTV, debt or collateral value.
    function _personalSlice(
        Market storage self,
        MorphoMarket memory mkt,
        Position memory p,
        uint256 price,
        address borrower
    ) private view returns (uint256) {
        (uint256 ltv,) = self.controller.settlementLtv(borrower);
        if (ltv == 0) return 0;
        uint256 debt = uint256(p.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        uint256 collateralValue = Math.mulDiv(p.collateral, price, ORACLE_PRICE_SCALE);
        if (debt == 0 || collateralValue == 0) return 0;
        return Math.min(_sliceToLtv(debt, collateralValue, ltv), debt);
    }

    /// @dev The root-policy slice: the largest of `sliceFloorBps` of the debt, `sliceFloorAssets`, and the slice
    ///      that lowers the LTV by `ltvStepBps`, capped at the debt. It becomes the whole debt when the collateral
    ///      left after its estimated seizure is under `fullCutBelowCollateral`.
    function _rootPolicySlice(
        Market storage self,
        Position memory p,
        uint256 debt,
        uint256 collateralValue,
        uint256 price
    ) private view returns (uint256 slice) {
        SettlementConfig memory cfg = self.controller.settlementConfig();
        uint256 byFraction = Math.mulDiv(debt, cfg.sliceFloorBps, BPS);
        uint256 byStep;
        if (cfg.ltvStepBps != 0) {
            uint256 currentLtv = Math.mulDiv(debt, WAD, collateralValue);
            byStep = _sliceToLtv(
                debt, collateralValue, Math.saturatingSub(currentLtv, Math.mulDiv(cfg.ltvStepBps, WAD, BPS))
            );
        }
        slice = Math.min(Math.max(cfg.sliceFloorAssets, Math.max(byFraction, byStep)), debt);
        if (slice == 0) return 0;
        uint256 remaining = Math.saturatingSub(p.collateral, Math.mulDiv(slice, ORACLE_PRICE_SCALE, price));
        if (remaining < cfg.fullCutBelowCollateral) slice = debt;
    }

    /// @dev `sliceAssets` in borrow shares (up), closing the position when it spans the debt or rounds up to it, and
    ///      shrunk to what `budget` core supply shares afford (both conversions down); a zero budget means no limit.
    function _budgetedCut(MorphoMarket memory mkt, Position memory p, uint256 sliceAssets, uint256 budget)
        private
        pure
        returns (uint256 cut)
    {
        uint256 debt = uint256(p.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        cut = sliceAssets.toSharesUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        if (sliceAssets == debt || cut >= p.borrowShares) cut = p.borrowShares;
        if (budget == 0) return cut;
        uint256 affordable = budget.toAssetsDown(mkt.totalSupplyAssets, mkt.totalSupplyShares)
            .toSharesDown(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        if (affordable < cut) cut = affordable;
    }

    /// @dev Collateral the core seizes for `cut` borrow shares: the cut's debt rounded down, priced down.
    function _seizure(MorphoMarket memory mkt, uint256 cut, uint256 price) private pure returns (uint256) {
        return Math.mulDiv(cut.toAssetsDown(mkt.totalBorrowAssets, mkt.totalBorrowShares), ORACLE_PRICE_SCALE, price);
    }

    /// @dev Loan assets to cancel so a position at (`debt`, `collateralValue`) lands on `targetLtv`; 0 when it
    ///      is already there or below, or when the target is not below 100%.
    function _sliceToLtv(uint256 debt, uint256 collateralValue, uint256 targetLtv) private pure returns (uint256) {
        if (targetLtv >= WAD) return 0;
        uint256 debtScaled = debt * WAD;
        uint256 targetTerm = targetLtv * collateralValue;
        if (debtScaled <= targetTerm) return 0;
        return (debtScaled - targetTerm) / (WAD - targetLtv);
    }

    // ── Borrower ──

    /// @notice Borrower supplies `amount` collateral (normal, non-instant path). Asserts the core event and
    ///         balances, then recomputes the activation classification from the pre-state: a sub-threshold
    ///         amount over empty dust stays dust; otherwise the whole dust+amount lot enters activating.
    /// @dev The hook syncs first, so a lot already due matures inside this call; the expectation allows for that.
    function supplyCollateral(Market storage self, address borrower, uint256 amount) internal {
        Approvals.approve(address(self.collateralToken), borrower, address(self.core), amount);

        ILidoLendMarketController.BorrowerPosition memory pre = self.controller.positionOf(borrower);
        uint128 colBefore = self.core.position(self.id, borrower).collateral;
        uint256 coreBefore = self.collateralToken.balanceOf(address(self.core));
        uint256 minActivation = self.controller.collateralActivationConfig().minActivationAmount;

        vm.expectEmit(true, true, true, true, address(self.core));
        emit SupplyCollateral(self.id, borrower, borrower, amount);
        vm.prank(borrower);
        self.core.supplyCollateral(self.params, amount, borrower, "");

        ILidoLendMarketController.BorrowerPosition memory post = self.controller.positionOf(borrower);
        vm.assertEq(self.core.position(self.id, borrower).collateral, colBefore + amount, "supplyCollateral: position");
        vm.assertEq(
            self.collateralToken.balanceOf(address(self.core)), coreBefore + amount, "supplyCollateral: to core"
        );

        uint256 added;
        if (pre.dust + amount < minActivation) {
            vm.assertEq(pre.dust, 0, "supplyCollateral: sub-threshold over dust should have reverted");
            vm.assertEq(post.dust, amount, "supplyCollateral: dust lot");
        } else {
            vm.assertEq(post.dust, 0, "supplyCollateral: dust promoted");
            added = pre.dust + amount;
        }
        (bool matures, bool certain) = _maturation(self, borrower, pre);
        if (certain) {
            vm.assertEq(post.activating, (matures ? 0 : pre.activating) + added, "supplyCollateral: activating lot");
        } else {
            vm.assertTrue(
                post.activating == added || post.activating == pre.activating + added,
                "supplyCollateral: activating lot matches neither maturation outcome"
            );
        }
    }

    /// @notice Warps past the market's LIVE max activation delay so freshly supplied collateral matures and can
    ///         back a borrow (the activation gate resolves lazily on the next borrow). Read from the controller,
    ///         not the deploy config, so a delay governance raised after deployment is honoured. A market that
    ///         also gates on the guardian quorum gets a quorum of heartbeats at the warped time, so the frontier
    ///         covers the unlock the way a live committee would.
    function activateCollateral(Market storage self) internal {
        CollateralActivationConfig memory config = self.controller.collateralActivationConfig();
        vm.warp(block.timestamp + config.maxActivationDelay + 1);
        if (config.maxGuardiansQuorumDelay == 0) return;

        vm.roll(block.number + 1);
        (address[] memory guardians,) = self.guardianSignals.getGuardians();
        uint256 quorum = self.guardianSignals.getQuorum();
        vm.assertGe(guardians.length, quorum, "activateCollateral: guardian set smaller than its quorum");
        for (uint256 i; i < quorum; ++i) {
            heartbeatAt(self, guardians[i], block.timestamp);
        }
        vm.assertGe(
            uint256(self.guardianSignals.getQuorumFrontier()),
            block.timestamp,
            "activateCollateral: quorum frontier short of the unlock"
        );
    }

    /// @notice Borrower borrows `amount` loan assets to itself. Asserts the returned assets/shares, the
    ///         borrow-share delta, and the loan received.
    function borrow(Market storage self, address borrower, uint256 amount) internal returns (uint256 sharesBorrowed) {
        return borrowTo(self, borrower, amount, borrower);
    }

    /// @notice Borrower borrows `amount` loan assets to `receiver`. Asserts the returned assets, the shares minted
    ///         against the `toSharesUp` recompute, the borrow-share delta, and the loan received by `receiver`.
    function borrowTo(Market storage self, address borrower, uint256 amount, address receiver)
        internal
        returns (uint256 sharesBorrowed)
    {
        accrueInterest(self);
        MorphoMarket memory pre = self.core.market(self.id);
        uint256 expectedShares = SharesMathLib.toSharesUp(amount, pre.totalBorrowAssets, pre.totalBorrowShares);
        uint128 sharesBefore = self.core.position(self.id, borrower).borrowShares;
        uint256 loanBefore = self.loanToken.balanceOf(receiver);

        vm.prank(borrower);
        (uint256 assetsBorrowed, uint256 s) = self.core.borrow(self.params, amount, 0, borrower, receiver);
        sharesBorrowed = s;

        vm.assertEq(assetsBorrowed, amount, "borrow: assets");
        vm.assertEq(sharesBorrowed, expectedShares, "borrow: shares vs recomputed");
        vm.assertEq(
            self.core.position(self.id, borrower).borrowShares,
            sharesBefore + uint128(sharesBorrowed),
            "borrow: borrowShares delta"
        );
        vm.assertEq(self.loanToken.balanceOf(receiver), loanBefore + amount, "borrow: loan not received");
    }

    /// @notice Borrower borrows exactly `shares` of debt to itself. Asserts the assets against the `toAssetsDown`
    ///         recompute, the borrow-share delta, and the loan received.
    function borrowByShares(Market storage self, address borrower, uint256 shares) internal returns (uint256 assets) {
        accrueInterest(self);
        MorphoMarket memory pre = self.core.market(self.id);
        uint256 expectedAssets = SharesMathLib.toAssetsDown(shares, pre.totalBorrowAssets, pre.totalBorrowShares);
        uint128 sharesBefore = self.core.position(self.id, borrower).borrowShares;
        uint256 loanBefore = self.loanToken.balanceOf(borrower);

        vm.prank(borrower);
        (uint256 assetsBorrowed, uint256 sharesMinted) = self.core.borrow(self.params, 0, shares, borrower, borrower);
        assets = assetsBorrowed;

        vm.assertEq(sharesMinted, shares, "borrowByShares: shares");
        vm.assertEq(assets, expectedAssets, "borrowByShares: assets vs recomputed");
        vm.assertEq(
            self.core.position(self.id, borrower).borrowShares,
            sharesBefore + uint128(shares),
            "borrowByShares: borrowShares delta"
        );
        vm.assertEq(self.loanToken.balanceOf(borrower), loanBefore + assets, "borrowByShares: loan not received");
    }

    /// @notice Borrower repays `shares` of debt (must already hold enough loan tokens). Approves and
    ///         repays, then asserts the borrow-share delta.
    function repay(Market storage self, address borrower, uint256 shares) internal {
        Approvals.approve(address(self.loanToken), borrower, address(self.core), type(uint256).max);

        uint128 sharesBefore = self.core.position(self.id, borrower).borrowShares;
        vm.prank(borrower);
        (, uint256 sharesRepaid) = self.core.repay(self.params, 0, shares, borrower, "");

        vm.assertEq(sharesRepaid, shares, "repay: shares");
        vm.assertEq(
            self.core.position(self.id, borrower).borrowShares,
            sharesBefore - uint128(shares),
            "repay: borrowShares delta"
        );
    }

    /// @notice Borrower withdraws `amount` collateral to `receiver`. Asserts the `WithdrawCollateral`
    ///         event, the position's collateral delta, the collateral received, and the bucket outcome
    ///         against the rule: the inactive buckets (dust + activating) either clear all-or-nothing
    ///         (the request must have covered them) or stay untouched (a locked active-only draw, which
    ///         must have fit within the active balance).
    /// @dev The hook syncs first, so a lot already due matures inside this call; the expectation allows for that.
    function withdrawCollateral(Market storage self, address borrower, uint256 amount, address receiver) internal {
        ILidoLendMarketController.BorrowerPosition memory pre = self.controller.positionOf(borrower);
        uint128 colBefore = self.core.position(self.id, borrower).collateral;
        uint256 recvBefore = self.collateralToken.balanceOf(receiver);

        vm.expectEmit(true, true, true, true, address(self.core));
        emit WithdrawCollateral(self.id, borrower, borrower, receiver, amount);
        vm.prank(borrower);
        self.core.withdrawCollateral(self.params, amount, borrower, receiver);

        vm.assertEq(
            self.core.position(self.id, borrower).collateral, colBefore - amount, "withdrawCollateral: position"
        );
        vm.assertEq(self.collateralToken.balanceOf(receiver), recvBefore + amount, "withdrawCollateral: received");

        ILidoLendMarketController.BorrowerPosition memory post = self.controller.positionOf(borrower);
        (bool matures, bool certain) = _maturation(self, borrower, pre);
        if (post.dust + post.activating == 0) {
            // The request covered what the sync left inactive: dust, plus the lot unless it matured. When the
            // maturation is uncertain, dust alone is the bound.
            uint256 preInactive = pre.dust + (certain && !matures ? pre.activating : 0);
            vm.assertTrue(
                preInactive == 0 || amount >= preInactive, "withdrawCollateral: cleared without covering inactive"
            );
        } else {
            // A locked draw from active only: the lot stayed, so it did not mature in this call.
            vm.assertFalse(certain && matures, "withdrawCollateral: matured lot still inside");
            vm.assertEq(post.dust, pre.dust, "withdrawCollateral: dust partially drained");
            vm.assertEq(post.activating, pre.activating, "withdrawCollateral: lot partially drained");
            vm.assertLe(
                amount, colBefore - pre.dust - pre.activating, "withdrawCollateral: active-only draw exceeds active"
            );
        }
    }

    /// @dev Whether the hook's sync matures `borrower`'s lot. The controller does not expose the lot's start, so its
    ///      quorum fallback deadline is bracketed from the unlock time by the delay bounds and the guardian surcharges;
    ///      `certain` is false when `block.timestamp` falls inside the bracket.
    function _maturation(Market storage self, address borrower, ILidoLendMarketController.BorrowerPosition memory pre)
        private
        view
        returns (bool matures, bool certain)
    {
        if (pre.activating == 0 || self.controller.isFrozen() || block.timestamp < pre.unlockTime) {
            return (false, true);
        }
        CollateralActivationConfig memory cfg = self.controller.collateralActivationConfig();
        if (cfg.maxGuardiansQuorumDelay == 0 || self.guardianSignals.getQuorumFrontier() >= pre.unlockTime) {
            return (true, true);
        }
        GuardiansOpinion memory opinion = self.guardianSignals.getOpinion(self.id, borrower);
        uint256 minSurcharge = opinion.strikeCount * cfg.delayPerStrike;
        uint256 maxSurcharge = minSurcharge + opinion.suspectCount * cfg.delayPerSuspect;
        uint256 latestStart = Math.saturatingSub(pre.unlockTime, minSurcharge + cfg.minActivationDelay);
        uint256 earliestStart = Math.saturatingSub(pre.unlockTime, maxSurcharge + cfg.maxActivationDelay);
        if (block.timestamp >= latestStart + cfg.maxGuardiansQuorumDelay) return (true, true);
        if (block.timestamp < earliestStart + cfg.maxGuardiansQuorumDelay) return (false, true);
        return (false, false);
    }

    /// @notice Borrower opts into a personal settlement LTV. Asserts the stored value.
    function setSettlementLtv(Market storage self, address borrower, uint256 ltv) internal {
        vm.prank(borrower);
        self.controller.setSettlementLtv(ltv);
        (uint256 stored,) = self.controller.settlementLtv(borrower);
        vm.assertEq(stored, ltv, "setSettlementLtv: not stored");
    }

    // ── Keeper ──

    /// @notice Keeper liquidates `borrower` (specify `seizedAssets` XOR `repaidShares`; the other is `0`)
    ///         expecting NO bad debt. Keeper must hold loan tokens to repay. Asserts the seized collateral and
    ///         repaid shares against the liquidation-incentive recompute, the collateral to the keeper, the
    ///         borrower's collateral and debt-share debits, the active-bucket debit, and that no loss was
    ///         socialized.
    function liquidate(
        Market storage self,
        address keeper,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) internal returns (uint256 seized, uint256 repaid) {
        LiquidationSnapshot memory pre = _snapshotLiquidation(self, keeper, borrower, seizedAssets, repaidShares);

        vm.prank(keeper);
        (seized, repaid) = self.core.liquidate(self.params, borrower, seizedAssets, repaidShares, "");

        _assertLiquidation(self, pre, keeper, borrower, seized, repaid);
        vm.assertGe(
            self.core.market(self.id).totalSupplyAssets,
            pre.totalSupplyAssets,
            "liquidate: unexpected bad debt socialized"
        );
    }

    /// @notice Keeper liquidates `borrower` expecting bad debt to be realized: the position is fully wiped
    ///         (collateral and debt both to zero), every remaining debt share leaves the market, and the
    ///         residual loss is socialized (`totalSupplyAssets` drops by exactly the unbacked debt). Reverts the
    ///         test if no bad debt occurs.
    function liquidateBadDebt(
        Market storage self,
        address keeper,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) internal returns (uint256 seized, uint256 repaid) {
        LiquidationSnapshot memory pre = _snapshotLiquidation(self, keeper, borrower, seizedAssets, repaidShares);
        uint256 expectedBadDebt = _expectedBadDebt(self, pre);

        vm.prank(keeper);
        (seized, repaid) = self.core.liquidate(self.params, borrower, seizedAssets, repaidShares, "");

        vm.assertEq(seized, pre.expectedSeized, "liquidateBadDebt: seized != incentive recompute");
        vm.assertEq(repaid, pre.expectedRepaidAssets, "liquidateBadDebt: repaid assets != incentive recompute");
        vm.assertEq(
            self.collateralToken.balanceOf(keeper), pre.keeperCollateral + seized, "liquidateBadDebt: keeper collateral"
        );
        Position memory p = self.core.position(self.id, borrower);
        vm.assertEq(p.collateral, 0, "liquidateBadDebt: collateral not fully seized");
        vm.assertEq(p.borrowShares, 0, "liquidateBadDebt: debt not cleared");
        MorphoMarket memory post = self.core.market(self.id);
        vm.assertEq(
            post.totalBorrowShares, pre.totalBorrowShares - pre.borrowerShares, "liquidateBadDebt: borrow shares left"
        );
        vm.assertGt(expectedBadDebt, 0, "liquidateBadDebt: no bad debt to socialize");
        vm.assertEq(
            pre.totalSupplyAssets - post.totalSupplyAssets, expectedBadDebt, "liquidateBadDebt: socialized != recompute"
        );
    }

    /// @dev Accrue, approve the keeper, and snapshot everything the liquidation assertions compare against,
    ///      including the (seized, repaid) pair recomputed from the incentive formula.
    function _snapshotLiquidation(
        Market storage self,
        address keeper,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) private returns (LiquidationSnapshot memory pre) {
        accrueInterest(self); // settle pending interest so the supply-asset delta isolates bad debt
        Approvals.approve(address(self.loanToken), keeper, address(self.core), type(uint256).max);

        Position memory p = self.core.position(self.id, borrower);
        MorphoMarket memory mkt = self.core.market(self.id);
        pre.keeperCollateral = self.collateralToken.balanceOf(keeper);
        pre.borrowerCollateral = p.collateral;
        pre.borrowerShares = p.borrowShares;
        pre.borrowerActive = self.controller.positionOf(borrower).active;
        pre.totalSupplyAssets = mkt.totalSupplyAssets;
        pre.totalBorrowShares = mkt.totalBorrowShares;
        (pre.expectedSeized, pre.expectedRepaidAssets, pre.expectedRepaidShares) =
            expectedLiquidation(self, seizedAssets, repaidShares);
    }

    function _assertLiquidation(
        Market storage self,
        LiquidationSnapshot memory pre,
        address keeper,
        address borrower,
        uint256 seized,
        uint256 repaid
    ) private view {
        vm.assertEq(seized, pre.expectedSeized, "liquidate: seized != incentive recompute");
        vm.assertEq(repaid, pre.expectedRepaidAssets, "liquidate: repaid assets != incentive recompute");
        vm.assertEq(
            self.collateralToken.balanceOf(keeper), pre.keeperCollateral + seized, "liquidate: keeper collateral"
        );
        Position memory p = self.core.position(self.id, borrower);
        vm.assertEq(p.collateral, pre.borrowerCollateral - uint128(seized), "liquidate: borrower collateral debit");
        vm.assertEq(
            p.borrowShares,
            pre.borrowerShares - uint128(pre.expectedRepaidShares),
            "liquidate: borrower debt-share debit"
        );
        // A seizure takes active collateral first, so active drops by the seizure up to what was active.
        vm.assertEq(
            self.controller.positionOf(borrower).active,
            pre.borrowerActive - Math.min(seized, pre.borrowerActive),
            "liquidate: active bucket debit"
        );
    }

    /// @notice What a core `liquidate` must produce for the given input — the seized collateral, the repaid debt
    ///         in assets (what the call returns) and in shares (what leaves the position) — recomputed from the
    ///         market's accrued totals, the oracle price and the LLTV-dependent liquidation incentive factor
    ///         `min(1.15, 1 / (1 - 0.3 * (1 - lltv)))`. Exactly one input is non-zero.
    function expectedLiquidation(Market storage self, uint256 seizedAssets, uint256 repaidShares)
        internal
        view
        returns (uint256 seized, uint256 repaidAssets, uint256 repaid)
    {
        MorphoMarket memory mkt = self.core.market(self.id);
        uint256 price = self.oracle.price();
        uint256 incentive = Math.min(
            MAX_LIQUIDATION_INCENTIVE_FACTOR, WAD.wDivDown(WAD - LIQUIDATION_CURSOR.wMulDown(WAD - self.params.lltv))
        );
        if (seizedAssets != 0) {
            seized = seizedAssets;
            repaid = seizedAssets.mulDivUp(price, ORACLE_PRICE_SCALE).wDivUp(incentive)
                .toSharesUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        } else {
            repaid = repaidShares;
            seized = repaidShares.toAssetsDown(mkt.totalBorrowAssets, mkt.totalBorrowShares).wMulDown(incentive)
                .mulDivDown(ORACLE_PRICE_SCALE, price);
        }
        repaidAssets = repaid.toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
    }

    /// @dev The loss a full-seizure liquidation socializes: the borrower's debt shares left after the repay,
    ///      valued at the post-repay totals and capped at the remaining borrow assets.
    function _expectedBadDebt(Market storage self, LiquidationSnapshot memory pre) private view returns (uint256) {
        MorphoMarket memory mkt = self.core.market(self.id);
        uint256 borrowAssetsAfterRepay = Math.saturatingSub(mkt.totalBorrowAssets, pre.expectedRepaidAssets);
        uint256 remainingShares = pre.borrowerShares - pre.expectedRepaidShares;
        return Math.min(
            borrowAssetsAfterRepay,
            remainingShares.toAssetsUp(borrowAssetsAfterRepay, mkt.totalBorrowShares - pre.expectedRepaidShares)
        );
    }

    // ── Interest / sizing utilities ──

    /// @notice Accrue interest on the market (no actor).
    function accrueInterest(Market storage self) internal {
        self.core.accrueInterest(self.params);
    }

    /// @notice The market totals with pending interest simulated, as the core would store them after accruing now.
    function accruedMarket(Market storage self) internal view returns (MorphoMarket memory mkt) {
        (uint256 supplyAssets, uint256 supplyShares, uint256 borrowAssets, uint256 borrowShares) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(address(self.core)), self.params);
        mkt.totalSupplyAssets = uint128(supplyAssets);
        mkt.totalSupplyShares = uint128(supplyShares);
        mkt.totalBorrowAssets = uint128(borrowAssets);
        mkt.totalBorrowShares = uint128(borrowShares);
    }

    /// @notice Advance time by `dt` and accrue — for interest-dependent scenarios.
    function warpAndAccrue(Market storage self, uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        self.core.accrueInterest(self.params);
    }

    /// @notice Loan assets that repaying `shares` currently consumes (round up). Used by tests to fund a
    ///         borrower before `repay`.
    function repayAssets(Market storage self, uint256 shares) internal view returns (uint256) {
        MorphoMarket memory m = self.core.market(self.id);
        return SharesMathLib.toAssetsUp(shares, m.totalBorrowAssets, m.totalBorrowShares);
    }

    // ── Direct core lender (no vault) ──

    /// @notice Lender supplies `assets` straight to the core, bypassing the vault. Asserts the supply-share
    ///         delta against the market totals and the loan tokens pulled.
    function coreSupply(Market storage self, address lender, uint256 assets) internal returns (uint256 shares) {
        Approvals.approve(address(self.loanToken), lender, address(self.core), type(uint256).max);

        accrueInterest(self); // the core accrues before pricing; same-block accrual makes the stored totals its own
        MorphoMarket memory pre = self.core.market(self.id);
        uint256 expectedShares = SharesMathLib.toSharesDown(assets, pre.totalSupplyAssets, pre.totalSupplyShares);
        uint256 lenderBefore = self.loanToken.balanceOf(lender);
        uint256 posBefore = self.core.position(self.id, lender).supplyShares;

        vm.prank(lender);
        (uint256 assetsSupplied, uint256 sharesMinted) = self.core.supply(self.params, assets, 0, lender, "");
        shares = sharesMinted;

        vm.assertEq(assetsSupplied, assets, "coreSupply: assets");
        vm.assertEq(shares, expectedShares, "coreSupply: shares vs recomputed");
        vm.assertEq(self.core.position(self.id, lender).supplyShares, posBefore + shares, "coreSupply: position");
        vm.assertEq(self.loanToken.balanceOf(lender), lenderBefore - assets, "coreSupply: loan pulled");
    }

    /// @notice Lender withdraws `shares` straight from the core. Asserts the paid assets against the market totals
    ///         and the loan tokens received. By shares, so a supply's minted shares round-trip at any share rate.
    function coreWithdraw(Market storage self, address lender, uint256 shares) internal returns (uint256 assets) {
        accrueInterest(self); // the core accrues before pricing; same-block accrual makes the stored totals its own
        MorphoMarket memory pre = self.core.market(self.id);
        uint256 expectedAssets = SharesMathLib.toAssetsDown(shares, pre.totalSupplyAssets, pre.totalSupplyShares);
        uint256 lenderBefore = self.loanToken.balanceOf(lender);
        uint256 posBefore = self.core.position(self.id, lender).supplyShares;

        vm.prank(lender);
        (uint256 assetsWithdrawn, uint256 sharesBurned) = self.core.withdraw(self.params, 0, shares, lender, lender);
        assets = assetsWithdrawn;

        vm.assertEq(sharesBurned, shares, "coreWithdraw: shares");
        vm.assertEq(assets, expectedAssets, "coreWithdraw: assets vs recomputed");
        vm.assertEq(self.core.position(self.id, lender).supplyShares, posBefore - shares, "coreWithdraw: position");
        vm.assertEq(self.loanToken.balanceOf(lender), lenderBefore + assets, "coreWithdraw: loan received");
    }

    /// @notice Lender withdraws exactly `assets` straight from the core. Asserts the burned shares against the
    ///         market totals and the loan tokens received. By assets, so a withdraw can drain the free liquidity.
    function coreWithdrawAssets(Market storage self, address lender, uint256 assets) internal returns (uint256 shares) {
        accrueInterest(self); // the core accrues before pricing; same-block accrual makes the stored totals its own
        MorphoMarket memory pre = self.core.market(self.id);
        uint256 expectedShares = SharesMathLib.toSharesUp(assets, pre.totalSupplyAssets, pre.totalSupplyShares);
        uint256 lenderBefore = self.loanToken.balanceOf(lender);
        uint256 posBefore = self.core.position(self.id, lender).supplyShares;

        vm.prank(lender);
        (uint256 assetsWithdrawn, uint256 sharesBurned) = self.core.withdraw(self.params, assets, 0, lender, lender);
        shares = sharesBurned;

        vm.assertEq(assetsWithdrawn, assets, "coreWithdrawAssets: assets");
        vm.assertEq(shares, expectedShares, "coreWithdrawAssets: shares vs recomputed");
        vm.assertEq(
            self.core.position(self.id, lender).supplyShares, posBefore - shares, "coreWithdrawAssets: position"
        );
        vm.assertEq(self.loanToken.balanceOf(lender), lenderBefore + assets, "coreWithdrawAssets: loan received");
    }

    /// @dev Snapshot and results of `coreSettle`, one memory slot on the stack (via_ir = false).
    struct CoreSettleSnapshot {
        uint256 borrowShares;
        uint256 expectedSeized;
        uint256 expectedCanceled;
        uint256 expectedBurn;
        uint256 supplierShares;
        uint128 borrowerShares;
        uint128 borrowerCollateral;
        uint256 receiverCollateral;
        uint256 receiverLoan;
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowShares;
        uint256 seized;
        uint256 canceled;
        uint256 sharesCanceled;
        uint256 burned;
    }

    /// @notice Direct supplier `supplier` settles `borrowShares` of `borrower`'s debt with its own core supply
    ///         shares, collateral to `receiver`. Asserts the settle amounts and their rounding (debt canceled and
    ///         supply burn up, seizure down), the position debits, the market totals, and that `receiver` got the
    ///         collateral and no loan tokens.
    function coreSettle(Market storage self, address supplier, address borrower, uint256 borrowShares, address receiver)
        internal
        returns (uint256 seized, uint256 canceled)
    {
        accrueInterest(self);
        CoreSettleSnapshot memory r = _snapshotCoreSettle(self, supplier, borrower, borrowShares, receiver);

        vm.prank(supplier);
        (r.seized, r.canceled, r.sharesCanceled, r.burned) =
            self.core.settle(self.params, borrowShares, supplier, borrower, receiver);

        _assertCoreSettle(self, r, supplier, borrower, receiver);
        return (r.seized, r.canceled);
    }

    function _snapshotCoreSettle(
        Market storage self,
        address supplier,
        address borrower,
        uint256 borrowShares,
        address receiver
    ) private view returns (CoreSettleSnapshot memory r) {
        MorphoMarket memory mk = self.core.market(self.id);
        r.borrowShares = borrowShares;
        r.expectedCanceled = borrowShares.toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
        r.expectedBurn = r.expectedCanceled.toSharesUp(mk.totalSupplyAssets, mk.totalSupplyShares);
        r.expectedSeized = borrowShares.toAssetsDown(mk.totalBorrowAssets, mk.totalBorrowShares)
            .mulDivDown(ORACLE_PRICE_SCALE, self.oracle.price());
        r.supplierShares = self.core.position(self.id, supplier).supplyShares;
        Position memory p = self.core.position(self.id, borrower);
        r.borrowerShares = p.borrowShares;
        r.borrowerCollateral = p.collateral;
        r.receiverCollateral = self.collateralToken.balanceOf(receiver);
        r.receiverLoan = self.loanToken.balanceOf(receiver);
        r.totalSupplyAssets = mk.totalSupplyAssets;
        r.totalSupplyShares = mk.totalSupplyShares;
        r.totalBorrowShares = mk.totalBorrowShares;
    }

    function _assertCoreSettle(
        Market storage self,
        CoreSettleSnapshot memory r,
        address supplier,
        address borrower,
        address receiver
    ) private view {
        vm.assertEq(r.canceled, r.expectedCanceled, "coreSettle: debt canceled != up-rounded recompute");
        vm.assertEq(r.burned, r.expectedBurn, "coreSettle: supply burn != up-rounded recompute");
        vm.assertEq(r.seized, r.expectedSeized, "coreSettle: seized != down-rounded recompute");
        vm.assertEq(r.sharesCanceled, r.borrowShares, "coreSettle: borrow shares canceled");
        vm.assertEq(
            self.core.position(self.id, supplier).supplyShares,
            r.supplierShares - r.burned,
            "coreSettle: supplier shares"
        );
        Position memory p = self.core.position(self.id, borrower);
        vm.assertEq(p.borrowShares, r.borrowerShares - uint128(r.borrowShares), "coreSettle: borrower debt shares");
        vm.assertEq(p.collateral, r.borrowerCollateral - uint128(r.seized), "coreSettle: borrower collateral");
        vm.assertEq(
            self.collateralToken.balanceOf(receiver), r.receiverCollateral + r.seized, "coreSettle: receiver collateral"
        );
        vm.assertEq(self.loanToken.balanceOf(receiver), r.receiverLoan, "coreSettle: not liquidity-neutral");
        MorphoMarket memory post = self.core.market(self.id);
        vm.assertEq(post.totalSupplyAssets, r.totalSupplyAssets - r.canceled, "coreSettle: supply assets");
        vm.assertEq(post.totalSupplyShares, r.totalSupplyShares - r.burned, "coreSettle: supply shares");
        vm.assertEq(post.totalBorrowShares, r.totalBorrowShares - r.borrowShares, "coreSettle: borrow shares");
    }

    // ── Borrower variants the plain helpers do not model ──

    /// @notice `caller` (an instant-activation-enabled address) supplies collateral for `borrower`. Asserts the
    ///         whole amount lands active immediately: the inactive buckets are untouched by this supply.
    function supplyCollateralInstant(Market storage self, address caller, address borrower, uint256 amount) internal {
        Approvals.approve(address(self.collateralToken), caller, address(self.core), amount);

        ILidoLendMarketController.BorrowerPosition memory pre = self.controller.positionOf(borrower);
        uint128 colBefore = self.core.position(self.id, borrower).collateral;

        vm.prank(caller);
        self.core.supplyCollateral(self.params, amount, borrower, "");

        ILidoLendMarketController.BorrowerPosition memory post = self.controller.positionOf(borrower);
        vm.assertEq(self.core.position(self.id, borrower).collateral, colBefore + amount, "instant: position");
        vm.assertEq(post.dust, pre.dust, "instant: dust must be untouched");
        vm.assertEq(post.activating, pre.activating, "instant: nothing may enter the timer");
    }

    /// @notice `caller` (with NO instant activation) supplies collateral for `borrower`. Asserts the whole lot
    ///         enters the activation timer: the caller's lack of a grant, not the borrower's, decides the bucket.
    ///         `amount` must clear the activation threshold on its own.
    function supplyCollateralOnBehalf(Market storage self, address caller, address borrower, uint256 amount) internal {
        Approvals.approve(address(self.collateralToken), caller, address(self.core), amount);

        ILidoLendMarketController.BorrowerPosition memory pre = self.controller.positionOf(borrower);
        uint128 colBefore = self.core.position(self.id, borrower).collateral;

        vm.prank(caller);
        self.core.supplyCollateral(self.params, amount, borrower, "");

        ILidoLendMarketController.BorrowerPosition memory post = self.controller.positionOf(borrower);
        vm.assertEq(self.core.position(self.id, borrower).collateral, colBefore + amount, "onBehalf: position");
        vm.assertEq(post.active, pre.active, "onBehalf: nothing may land active");
        vm.assertEq(post.activating, pre.activating + pre.dust + amount, "onBehalf: lot must enter the timer");
    }

    /// @notice Borrower repays `assets` of debt by asset amount (the share-anchored helper is `repay`).
    ///         Asserts the returned assets and that borrow shares strictly decreased.
    function repayByAssets(Market storage self, address borrower, uint256 assets) internal returns (uint256 shares) {
        Approvals.approve(address(self.loanToken), borrower, address(self.core), type(uint256).max);

        uint128 sharesBefore = self.core.position(self.id, borrower).borrowShares;
        vm.prank(borrower);
        (uint256 assetsRepaid, uint256 sharesRepaid) = self.core.repay(self.params, assets, 0, borrower, "");
        shares = sharesRepaid;

        vm.assertEq(assetsRepaid, assets, "repayByAssets: assets");
        vm.assertEq(
            self.core.position(self.id, borrower).borrowShares,
            sharesBefore - uint128(shares),
            "repayByAssets: borrowShares delta"
        );
    }

    // ── Market conditions ──

    /// @notice Moves the oracle so `borrower` lands at `targetLtv` (WAD). Asserts the borrower actually has a
    ///         position to distress and that the realized LTV matches the target, so a test never silently
    ///         proceeds against a healthy position.
    function distress(Market storage self, address borrower, uint256 targetLtv) internal returns (uint256 newPrice) {
        accrueInterest(self);
        Position memory pos = self.core.position(self.id, borrower);
        vm.assertGt(pos.borrowShares, 0, "distress: borrower has no debt");
        vm.assertGt(pos.collateral, 0, "distress: borrower has no collateral");

        MorphoMarket memory m = self.core.market(self.id);
        uint256 debtAssets = SharesMathLib.toAssetsUp(pos.borrowShares, m.totalBorrowAssets, m.totalBorrowShares);

        // LTV = debtAssets * WAD / (collateral * price / ORACLE_PRICE_SCALE)  ⇒  solve for price.
        newPrice = (debtAssets * 1e18 * ORACLE_PRICE_SCALE) / (uint256(pos.collateral) * targetLtv);
        MockPriceOracle(address(self.oracle)).setPrice(newPrice);

        uint256 collateralValue = (uint256(pos.collateral) * newPrice) / ORACLE_PRICE_SCALE;
        uint256 realizedLtv = (debtAssets * 1e18) / collateralValue;
        vm.assertApproxEqRel(realizedLtv, targetLtv, 1e15, "distress: realized LTV missed target");
    }

    // ── Control plane (drives state; access control is asserted by the tests that own it) ──

    /// @notice Pauses the controller for `duration` as the market admin. Asserts the market reports paused.
    function pause(Market storage self, uint256 duration) internal {
        vm.startPrank(self.config.admin);
        self.controller.grantRole(self.controller.PAUSER_ROLE(), self.config.admin);
        self.controller.pauseFor(duration);
        vm.stopPrank();
        vm.assertTrue(IPausableUntil(address(self.controller)).isPaused(), "pause: not paused");
    }

    /// @notice Resumes a paused controller as the market admin. Asserts the market reports resumed.
    function resume(Market storage self) internal {
        vm.startPrank(self.config.admin);
        self.controller.grantRole(self.controller.RESUMER_ROLE(), self.config.admin);
        self.controller.resume();
        vm.stopPrank();
        vm.assertFalse(IPausableUntil(address(self.controller)).isPaused(), "resume: still paused");
    }

    /// @notice Freezes the market as the market admin. Asserts the market reports frozen.
    function freeze(Market storage self) internal {
        vm.startPrank(self.config.admin);
        self.controller.grantRole(self.controller.FREEZER_ROLE(), self.config.admin);
        self.controller.freeze();
        vm.stopPrank();
        vm.assertTrue(self.controller.isFrozen(), "freeze: not frozen");
    }

    /// @notice Unfreezes the market as the market admin. Asserts the market reports unfrozen.
    function unfreeze(Market storage self) internal {
        vm.startPrank(self.config.admin);
        self.controller.grantRole(self.controller.UNFREEZER_ROLE(), self.config.admin);
        self.controller.unfreeze();
        vm.stopPrank();
        vm.assertFalse(self.controller.isFrozen(), "unfreeze: still frozen");
    }

    /// @notice Sets the collateral-activation config as the market admin. Asserts the stored config.
    function setActivationConfig(Market storage self, CollateralActivationConfig memory cfg) internal {
        LidoLendMarketController ctrl = LidoLendMarketController(address(self.controller));
        vm.startPrank(self.config.admin);
        self.controller.grantRole(self.controller.MANAGER_ROLE(), self.config.admin);
        ctrl.setCollateralActivationConfig(cfg);
        vm.stopPrank();
        vm.assertEq(
            keccak256(abi.encode(self.controller.collateralActivationConfig())),
            keccak256(abi.encode(cfg)),
            "setActivationConfig: not stored"
        );
    }

    /// @notice Sets the settlement config as the market admin. Asserts the stored config.
    function setSettlementConfig(Market storage self, SettlementConfig memory cfg) internal {
        vm.startPrank(self.config.admin);
        self.controller.grantRole(self.controller.MANAGER_ROLE(), self.config.admin);
        self.controller.setSettlementConfig(cfg);
        vm.stopPrank();
        vm.assertEq(
            keccak256(abi.encode(self.controller.settlementConfig())),
            keccak256(abi.encode(cfg)),
            "setSettlementConfig: not stored"
        );
    }

    /// @notice Sets the market supply cap as the market admin. Asserts the stored cap.
    function setSupplyCap(Market storage self, uint256 cap) internal {
        LidoLendMarketController ctrl = LidoLendMarketController(address(self.controller));
        vm.startPrank(self.config.admin);
        self.controller.grantRole(self.controller.MANAGER_ROLE(), self.config.admin);
        ctrl.setSupplyCap(cap);
        vm.stopPrank();
        vm.assertEq(ctrl.supplyCap(), cap, "setSupplyCap: not stored");
    }

    /// @notice Grants or revokes instant activation for `caller` as the market admin. Asserts the stored flag.
    function setInstantActivation(Market storage self, address caller, bool enabled) internal {
        LidoLendMarketController ctrl = LidoLendMarketController(address(self.controller));
        vm.startPrank(self.config.admin);
        self.controller.grantRole(self.controller.MANAGER_ROLE(), self.config.admin);
        ctrl.setInstantActivation(caller, enabled);
        vm.stopPrank();
        vm.assertEq(self.controller.hasInstantActivation(caller), enabled, "setInstantActivation: not stored");
    }

    // ── Guardian committee ──

    /// @notice Guardian `guardian` flags `account` on its own behalf. Asserts the strike landed.
    function flagAs(Market storage self, address guardian, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        uint256 before = self.guardianSignals.getOpinion(self.id, account).strikeCount;

        vm.prank(guardian);
        self.guardianSignals.flag(self.id, guardian, accounts);

        vm.assertEq(
            self.guardianSignals.getOpinion(self.id, account).strikeCount, before + 1, "flagAs: strike not recorded"
        );
    }

    /// @notice Guardian `guardian` files a suspect report on `account` on its own behalf. Asserts a `SuspectPruned`
    ///         for each lapsed report, then `Suspected`, and the rebuilt snapshot: it counts every live report once
    ///         and, since the new report is the newest, expires one suspect window from now. Strikes and the ban do
    ///         not move.
    function suspectAs(Market storage self, address guardian, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        GuardiansOpinion memory pre = self.guardianSignals.getOpinion(self.id, account);
        uint256 window = self.guardianSignals.getSuspectWindow();
        (address[] memory reporters, uint40[] memory reportedAt) = self.guardianSignals.getSuspectedBy(self.id, account);
        uint256 live = 1;
        for (uint256 i; i < reporters.length; ++i) {
            if (reportedAt[i] + window < block.timestamp) {
                vm.expectEmit(true, true, true, true, address(self.guardianSignals));
                emit IGuardianSignals.SuspectPruned(self.id, account, reporters[i]);
            } else if (reporters[i] != guardian) {
                ++live;
            }
        }
        vm.expectEmit(true, true, true, true, address(self.guardianSignals));
        emit IGuardianSignals.Suspected(self.id, account, guardian, guardian, block.timestamp);

        vm.prank(guardian);
        self.guardianSignals.suspect(self.id, guardian, accounts);

        GuardiansOpinion memory post = self.guardianSignals.getOpinion(self.id, account);
        vm.assertEq(post.suspectCount, live, "suspectAs: count != live reports");
        vm.assertEq(post.suspectExpiryTimestamp, block.timestamp + window, "suspectAs: expiry != now + window");
        vm.assertEq(post.strikeCount, pre.strikeCount, "suspectAs: strikes moved");
        vm.assertEq(post.banned, pre.banned, "suspectAs: ban moved");
    }

    /// @notice Guardian `guardian` retracts its flag on `account`. Asserts the strike was dropped — note this
    ///         never lifts a ban that is already in effect.
    function unflagAs(Market storage self, address guardian, address account) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        uint256 before = self.guardianSignals.getOpinion(self.id, account).strikeCount;
        vm.assertGt(before, 0, "unflagAs: nothing to retract");

        vm.prank(guardian);
        self.guardianSignals.unflag(self.id, guardian, accounts);

        vm.assertEq(
            self.guardianSignals.getOpinion(self.id, account).strikeCount, before - 1, "unflagAs: strike not dropped"
        );
    }

    /// @notice Enough distinct guardians flag `account` to reach quorum. Asserts the account ends up banned.
    function banVia(Market storage self, address[] memory guardians, address account) internal {
        for (uint256 i = 0; i < guardians.length; ++i) {
            flagAs(self, guardians[i], account);
        }
        vm.assertTrue(self.guardianSignals.isBanned(self.id, account), "banVia: account is not banned");
    }

    /// @notice Clears `account`'s ban as the registry admin. Asserts the ban is gone.
    function unban(Market storage self, address account) internal {
        vm.startPrank(self.config.admin);
        self.guardianSignals.grantRole(self.guardianSignals.ACCESS_RESTORER_ROLE(), self.config.admin);
        self.guardianSignals.unban(self.id, account);
        vm.stopPrank();

        vm.assertFalse(self.guardianSignals.isBanned(self.id, account), "unban: still banned");
    }

    /// @notice Guardian `guardian` reports having scanned up to `scanTimestamp`. The block number and hash must
    ///         name a real past block, while the reported scan time is independent of it — that is what moves
    ///         the quorum frontier. Asserts the stored heartbeat.
    /// @dev Requires at least one block to have elapsed (`vm.roll`), since `blockhash` of the current block is
    ///      zero and the registry rejects a zero hash.
    function heartbeatAt(Market storage self, address guardian, uint256 scanTimestamp) internal {
        vm.assertGt(block.number, 0, "heartbeatAt: needs a past block; vm.roll first");
        vm.assertLe(scanTimestamp, block.timestamp, "heartbeatAt: cannot report a future scan");

        uint40 pastBlock = uint40(block.number - 1);
        BlockInfoWithHash memory scanned =
            BlockInfoWithHash({hash: blockhash(pastBlock), number: pastBlock, timestamp: uint40(scanTimestamp)});
        vm.assertNotEq(scanned.hash, bytes32(0), "heartbeatAt: no blockhash available; vm.roll further");

        vm.prank(guardian);
        self.guardianSignals.heartbeat(guardian, scanned, "");

        vm.assertEq(uint256(self.guardianSignals.getHeartbeat(guardian)), scanTimestamp, "heartbeatAt: not recorded");
    }

    /// @notice Permissionlessly recomputes the quorum frontier. Asserts it never moved backwards.
    function syncFrontier(Market storage self) internal returns (uint256 frontier) {
        uint256 before = self.guardianSignals.getQuorumFrontier();
        self.guardianSignals.syncQuorumFrontier();
        frontier = self.guardianSignals.getQuorumFrontier();
        vm.assertGe(frontier, before, "syncFrontier: frontier moved backwards");
    }
}
