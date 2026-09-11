// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IPausableUntil} from "../../src/interfaces/IPausableUntil.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";

import {BlockInfoWithHash} from "../../src/types/GuardianSignalsTypes.sol";

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
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event SupplyCollateral(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assets);
    event WithdrawCollateral(
        Id indexed id, address caller, address indexed onBehalf, address indexed receiver, uint256 assets
    );

    // ── Lender ──

    /// @notice Lender deposits `assets` into the vault. Asserts shares vs preview, the `Deposit` event,
    ///         the loan pulled, and the share-balance / `totalSupply` / `totalAssets` deltas.
    function vaultDeposit(Market storage self, address lender, uint256 assets) internal returns (uint256 shares) {
        vm.prank(lender);
        self.loanToken.approve(address(self.vault), assets);

        uint256 expectedShares = self.vault.previewDeposit(assets);
        uint256 loanBefore = self.loanToken.balanceOf(lender);
        uint256 sharesBefore = self.vault.balanceOf(lender);
        uint256 supplyBefore = self.vault.totalSupply();
        uint256 assetsBefore = self.vault.totalAssets();

        vm.expectEmit(true, true, false, true, address(self.vault));
        emit Deposit(lender, lender, assets, expectedShares);
        vm.prank(lender);
        shares = self.vault.deposit(assets, lender);

        vm.assertEq(shares, expectedShares, "deposit: shares != preview");
        vm.assertEq(self.loanToken.balanceOf(lender), loanBefore - assets, "deposit: loan not pulled");
        vm.assertEq(self.vault.balanceOf(lender), sharesBefore + shares, "deposit: shares not credited");
        vm.assertEq(self.vault.totalSupply(), supplyBefore + shares, "deposit: totalSupply delta");
        vm.assertEq(self.vault.totalAssets(), assetsBefore + assets, "deposit: totalAssets delta");
    }

    /// @notice Lender withdraws `assets` of ordinary liquidity. Asserts shares vs preview, the `Withdraw`
    ///         event, the loan received, and the share burn.
    function vaultWithdraw(Market storage self, address lender, uint256 assets) internal returns (uint256 shares) {
        uint256 expectedShares = self.vault.previewWithdraw(assets);
        uint256 loanBefore = self.loanToken.balanceOf(lender);
        uint256 sharesBefore = self.vault.balanceOf(lender);

        vm.expectEmit(true, true, true, true, address(self.vault));
        emit Withdraw(lender, lender, lender, assets, expectedShares);
        vm.prank(lender);
        shares = self.vault.withdraw(assets, lender, lender);

        vm.assertEq(shares, expectedShares, "withdraw: shares != preview");
        vm.assertEq(self.loanToken.balanceOf(lender), loanBefore + assets, "withdraw: loan not received");
        vm.assertEq(self.vault.balanceOf(lender), sharesBefore - shares, "withdraw: shares not burned");
    }

    /// @notice Lender mints `shares` from the vault. Asserts assets vs preview, the `Deposit` event, the
    ///         loan pulled, and the share / `totalSupply` deltas.
    function vaultMint(Market storage self, address lender, uint256 shares) internal returns (uint256 assets) {
        uint256 expectedAssets = self.vault.previewMint(shares);
        vm.prank(lender);
        self.loanToken.approve(address(self.vault), expectedAssets);

        uint256 loanBefore = self.loanToken.balanceOf(lender);
        uint256 sharesBefore = self.vault.balanceOf(lender);
        uint256 supplyBefore = self.vault.totalSupply();

        vm.expectEmit(true, true, false, true, address(self.vault));
        emit Deposit(lender, lender, expectedAssets, shares);
        vm.prank(lender);
        assets = self.vault.mint(shares, lender);

        vm.assertEq(assets, expectedAssets, "mint: assets != preview");
        vm.assertEq(self.loanToken.balanceOf(lender), loanBefore - assets, "mint: loan not pulled");
        vm.assertEq(self.vault.balanceOf(lender), sharesBefore + shares, "mint: shares not credited");
        vm.assertEq(self.vault.totalSupply(), supplyBefore + shares, "mint: totalSupply delta");
    }

    /// @notice Lender redeems `shares` of ordinary liquidity. Asserts assets vs preview, the `Withdraw`
    ///         event, the loan received, and the share burn.
    function vaultRedeem(Market storage self, address lender, uint256 shares) internal returns (uint256 assets) {
        uint256 expectedAssets = self.vault.previewRedeem(shares);
        uint256 loanBefore = self.loanToken.balanceOf(lender);
        uint256 sharesBefore = self.vault.balanceOf(lender);

        vm.expectEmit(true, true, true, true, address(self.vault));
        emit Withdraw(lender, lender, lender, expectedAssets, shares);
        vm.prank(lender);
        assets = self.vault.redeem(shares, lender, lender);

        vm.assertEq(assets, expectedAssets, "redeem: assets != preview");
        vm.assertEq(self.loanToken.balanceOf(lender), loanBefore + assets, "redeem: loan not received");
        vm.assertEq(self.vault.balanceOf(lender), sharesBefore - shares, "redeem: shares not burned");
    }

    /// @notice Lender (`owner`) targeted-settles `shares` against `borrowers`, collateral to `receiver`.
    ///         Best-effort within the batch but reverts when no borrower is settled. On success, asserts
    ///         `sharesBurned <= shares`, that no loan assets reached `receiver`, the owner's share burn, the
    ///         collateral received by `receiver`, and — when `owner != receiver` — that the owner's own collateral
    ///         is untouched (all of it routed to `receiver`).
    function settle(Market storage self, address owner, uint256 shares, address[] memory borrowers, address receiver)
        internal
        returns (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled)
    {
        uint256 ownerSharesBefore = self.vault.balanceOf(owner);
        uint256 recvColBefore = self.collateralToken.balanceOf(receiver);
        uint256 ownerColBefore = self.collateralToken.balanceOf(owner);
        uint256 recvLoanBefore = self.loanToken.balanceOf(receiver);

        vm.prank(owner);
        (sharesBurned, collateralSeized, debtCanceled) = self.vault.settle(shares, borrowers, receiver, owner);

        vm.assertLe(sharesBurned, shares, "settle: burned > requested");
        vm.assertEq(self.loanToken.balanceOf(receiver), recvLoanBefore, "settle: not liquidity-neutral");
        vm.assertEq(self.vault.balanceOf(owner), ownerSharesBefore - sharesBurned, "settle: owner shares burned");
        vm.assertEq(
            self.collateralToken.balanceOf(receiver), recvColBefore + collateralSeized, "settle: receiver collateral"
        );
        if (owner != receiver) {
            vm.assertEq(self.collateralToken.balanceOf(owner), ownerColBefore, "settle: owner collateral routed away");
        }
    }

    /// @notice Lender (`owner`) fallback-exits `shares`: the redeem leg pays loan and the settle leg pays
    ///         collateral, both to `receiver`. Asserts `sharesBurned <= shares`, the owner's share burn, the
    ///         loan + collateral received by `receiver`, and — when `owner != receiver` — that the owner's own
    ///         loan and collateral are untouched (both legs routed to `receiver`).
    function fallbackExit(Market storage self, address owner, uint256 shares, address receiver, uint256 maxIterations)
        internal
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        uint256 ownerSharesBefore = self.vault.balanceOf(owner);
        uint256 recvLoanBefore = self.loanToken.balanceOf(receiver);
        uint256 recvColBefore = self.collateralToken.balanceOf(receiver);
        // Single stack slot (memory pointer) for the owner's loan+collateral snapshot, to stay within the
        // legacy pipeline's stack depth.
        uint256[2] memory ownerBefore = [self.loanToken.balanceOf(owner), self.collateralToken.balanceOf(owner)];

        vm.prank(owner);
        (sharesBurned, loanAssets, collateralSeized, debtCanceled) =
            self.vault.fallbackExit(shares, receiver, owner, maxIterations);

        vm.assertLe(sharesBurned, shares, "fallbackExit: burned > requested");
        vm.assertEq(self.vault.balanceOf(owner), ownerSharesBefore - sharesBurned, "fallbackExit: owner shares burned");
        vm.assertEq(self.loanToken.balanceOf(receiver), recvLoanBefore + loanAssets, "fallbackExit: receiver loan");
        vm.assertEq(
            self.collateralToken.balanceOf(receiver),
            recvColBefore + collateralSeized,
            "fallbackExit: receiver collateral"
        );
        if (owner != receiver) {
            vm.assertEq(self.loanToken.balanceOf(owner), ownerBefore[0], "fallbackExit: owner loan routed away");
            vm.assertEq(
                self.collateralToken.balanceOf(owner), ownerBefore[1], "fallbackExit: owner collateral routed away"
            );
        }
    }

    // ── Borrower ──

    /// @notice Borrower supplies `amount` collateral (normal, non-instant path). Asserts the core event and
    ///         balances, then recomputes the activation classification from the pre-state: a sub-threshold
    ///         amount over empty dust stays dust; otherwise the whole dust+amount lot enters activating.
    /// @dev Assumes no lot matures inside this call — mature explicitly (warp + a syncing action) before
    ///      supplying when a test needs that.
    function supplyCollateral(Market storage self, address borrower, uint256 amount) internal {
        vm.prank(borrower);
        self.collateralToken.approve(address(self.core), amount);

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

        if (pre.dust + amount < minActivation) {
            vm.assertEq(pre.dust, 0, "supplyCollateral: sub-threshold over dust should have reverted");
            vm.assertEq(post.dust, amount, "supplyCollateral: dust lot");
            vm.assertEq(post.activating, pre.activating, "supplyCollateral: activating unchanged");
        } else {
            vm.assertEq(post.dust, 0, "supplyCollateral: dust promoted");
            vm.assertEq(post.activating, pre.activating + pre.dust + amount, "supplyCollateral: activating lot");
        }
    }

    /// @notice Warps past the market's max activation delay so freshly supplied collateral matures and can
    ///         back a borrow (the activation gate resolves lazily on the next borrow).
    function activateCollateral(Market storage self) internal {
        vm.warp(block.timestamp + self.config.activation.maxActivationDelay + 1);
    }

    /// @notice Borrower borrows `amount` loan assets to itself. Asserts the returned assets/shares, the
    ///         borrow-share delta, and the loan received.
    function borrow(Market storage self, address borrower, uint256 amount) internal returns (uint256 sharesBorrowed) {
        uint128 sharesBefore = self.core.position(self.id, borrower).borrowShares;
        uint256 loanBefore = self.loanToken.balanceOf(borrower);

        vm.prank(borrower);
        (uint256 assetsBorrowed, uint256 s) = self.core.borrow(self.params, amount, 0, borrower, borrower);
        sharesBorrowed = s;

        vm.assertEq(assetsBorrowed, amount, "borrow: assets");
        vm.assertGt(sharesBorrowed, 0, "borrow: shares minted");
        vm.assertEq(
            self.core.position(self.id, borrower).borrowShares,
            sharesBefore + uint128(sharesBorrowed),
            "borrow: borrowShares delta"
        );
        vm.assertEq(self.loanToken.balanceOf(borrower), loanBefore + amount, "borrow: loan not received");
    }

    /// @notice Borrower repays `shares` of debt (must already hold enough loan tokens). Approves and
    ///         repays, then asserts the borrow-share delta.
    function repay(Market storage self, address borrower, uint256 shares) internal {
        vm.prank(borrower);
        self.loanToken.approve(address(self.core), type(uint256).max);

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
    /// @dev Assumes no lot matures inside this call — mature explicitly (warp + a syncing action) before
    ///      withdrawing when a test needs that.
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
        uint256 preInactive = pre.dust + pre.activating;
        if (post.dust + post.activating == 0) {
            vm.assertTrue(
                preInactive == 0 || amount >= preInactive, "withdrawCollateral: cleared without covering inactive"
            );
        } else {
            vm.assertEq(post.dust, pre.dust, "withdrawCollateral: dust partially drained");
            vm.assertEq(post.activating, pre.activating, "withdrawCollateral: lot partially drained");
            vm.assertLe(amount, colBefore - preInactive, "withdrawCollateral: active-only draw exceeds active");
        }
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
    ///         expecting NO bad debt. Keeper must hold loan tokens to repay. Asserts the seized collateral
    ///         to the keeper, the borrower's collateral debit, and that no loss was socialized.
    function liquidate(
        Market storage self,
        address keeper,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) internal returns (uint256 seized, uint256 repaid) {
        accrueInterest(self); // settle pending interest so the supply-asset delta isolates bad debt
        vm.prank(keeper);
        self.loanToken.approve(address(self.core), type(uint256).max);

        uint256 keeperColBefore = self.collateralToken.balanceOf(keeper);
        uint128 borrowerColBefore = self.core.position(self.id, borrower).collateral;
        uint128 supplyBefore = self.core.market(self.id).totalSupplyAssets;

        vm.prank(keeper);
        (seized, repaid) = self.core.liquidate(self.params, borrower, seizedAssets, repaidShares, "");

        vm.assertEq(self.collateralToken.balanceOf(keeper), keeperColBefore + seized, "liquidate: keeper collateral");
        vm.assertEq(
            self.core.position(self.id, borrower).collateral,
            borrowerColBefore - uint128(seized),
            "liquidate: borrower debit"
        );
        vm.assertGe(
            self.core.market(self.id).totalSupplyAssets, supplyBefore, "liquidate: unexpected bad debt socialized"
        );
    }

    /// @notice Keeper liquidates `borrower` expecting bad debt to be realized: the position is fully wiped
    ///         (collateral and debt both to zero) and the residual loss is socialized
    ///         (`totalSupplyAssets` drops). Reverts the test if no bad debt occurs.
    function liquidateBadDebt(
        Market storage self,
        address keeper,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) internal returns (uint256 seized, uint256 repaid) {
        accrueInterest(self);
        vm.prank(keeper);
        self.loanToken.approve(address(self.core), type(uint256).max);

        uint256 keeperColBefore = self.collateralToken.balanceOf(keeper);
        uint128 supplyBefore = self.core.market(self.id).totalSupplyAssets;

        vm.prank(keeper);
        (seized, repaid) = self.core.liquidate(self.params, borrower, seizedAssets, repaidShares, "");

        Position memory p = self.core.position(self.id, borrower);
        vm.assertEq(
            self.collateralToken.balanceOf(keeper), keeperColBefore + seized, "liquidateBadDebt: keeper collateral"
        );
        vm.assertEq(p.collateral, 0, "liquidateBadDebt: collateral not fully seized");
        vm.assertEq(p.borrowShares, 0, "liquidateBadDebt: debt not cleared");
        vm.assertLt(
            self.core.market(self.id).totalSupplyAssets, supplyBefore, "liquidateBadDebt: no bad debt socialized"
        );
    }

    // ── Interest / sizing utilities ──

    /// @notice Accrue interest on the market (no actor).
    function accrueInterest(Market storage self) internal {
        self.core.accrueInterest(self.params);
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
        vm.prank(lender);
        self.loanToken.approve(address(self.core), type(uint256).max);

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

    /// @notice Lender withdraws `assets` straight from the core. Asserts the burned shares against the market
    ///         totals and the loan tokens received.
    function coreWithdraw(Market storage self, address lender, uint256 assets) internal returns (uint256 shares) {
        MorphoMarket memory pre = self.core.market(self.id);
        uint256 expectedShares = SharesMathLib.toSharesUp(assets, pre.totalSupplyAssets, pre.totalSupplyShares);
        uint256 lenderBefore = self.loanToken.balanceOf(lender);
        uint256 posBefore = self.core.position(self.id, lender).supplyShares;

        vm.prank(lender);
        (uint256 assetsWithdrawn, uint256 sharesBurned) = self.core.withdraw(self.params, assets, 0, lender, lender);
        shares = sharesBurned;

        vm.assertEq(assetsWithdrawn, assets, "coreWithdraw: assets");
        vm.assertEq(shares, expectedShares, "coreWithdraw: shares vs recomputed");
        vm.assertEq(self.core.position(self.id, lender).supplyShares, posBefore - shares, "coreWithdraw: position");
        vm.assertEq(self.loanToken.balanceOf(lender), lenderBefore + assets, "coreWithdraw: loan received");
    }

    // ── Borrower variants the plain helpers do not model ──

    /// @notice `caller` (an instant-activation-enabled address) supplies collateral for `borrower`. Asserts the
    ///         whole amount lands active immediately: the inactive buckets are untouched by this supply.
    function supplyCollateralInstant(Market storage self, address caller, address borrower, uint256 amount) internal {
        vm.prank(caller);
        self.collateralToken.approve(address(self.core), amount);

        ILidoLendMarketController.BorrowerPosition memory pre = self.controller.positionOf(borrower);
        uint128 colBefore = self.core.position(self.id, borrower).collateral;

        vm.prank(caller);
        self.core.supplyCollateral(self.params, amount, borrower, "");

        ILidoLendMarketController.BorrowerPosition memory post = self.controller.positionOf(borrower);
        vm.assertEq(self.core.position(self.id, borrower).collateral, colBefore + amount, "instant: position");
        vm.assertEq(post.dust, pre.dust, "instant: dust must be untouched");
        vm.assertEq(post.activating, pre.activating, "instant: nothing may enter the timer");
    }

    /// @notice Borrower repays `assets` of debt by asset amount (the share-anchored helper is `repay`).
    ///         Asserts the returned assets and that borrow shares strictly decreased.
    function repayByAssets(Market storage self, address borrower, uint256 assets) internal returns (uint256 shares) {
        vm.prank(borrower);
        self.loanToken.approve(address(self.core), type(uint256).max);

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
