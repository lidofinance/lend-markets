// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Id, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

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
    ///         Best-effort and liquidity-neutral: asserts `sharesBurned <= shares`, `loanAssets == 0`, the
    ///         owner's share burn, the collateral received by `receiver`, and — when `owner != receiver` —
    ///         that the owner's own collateral is untouched (all of it routed to `receiver`).
    function settle(Market storage self, address owner, uint256 shares, address[] memory borrowers, address receiver)
        internal
        returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
    {
        uint256 ownerSharesBefore = self.vault.balanceOf(owner);
        uint256 recvColBefore = self.collateralToken.balanceOf(receiver);
        uint256 ownerColBefore = self.collateralToken.balanceOf(owner);

        vm.prank(owner);
        (sharesBurned, loanAssets, collateralSeized, debtCanceled) =
            self.vault.settle(shares, borrowers, receiver, owner);

        vm.assertLe(sharesBurned, shares, "settle: burned > requested");
        vm.assertEq(loanAssets, 0, "settle: not liquidity-neutral");
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

    /// @notice Borrower posts `amount` collateral. Approves it, then asserts the `SupplyCollateral` event,
    ///         the position's collateral delta, and the token moving to the core.
    function supplyCollateral(Market storage self, address borrower, uint256 amount) internal {
        vm.prank(borrower);
        self.collateralToken.approve(address(self.core), amount);

        uint128 colBefore = self.core.position(self.id, borrower).collateral;
        uint256 coreBefore = self.collateralToken.balanceOf(address(self.core));

        vm.expectEmit(true, true, true, true, address(self.core));
        emit SupplyCollateral(self.id, borrower, borrower, amount);
        vm.prank(borrower);
        self.core.supplyCollateral(self.params, amount, borrower, "");

        vm.assertEq(self.core.position(self.id, borrower).collateral, colBefore + amount, "supplyCollateral: position");
        vm.assertEq(
            self.collateralToken.balanceOf(address(self.core)), coreBefore + amount, "supplyCollateral: to core"
        );
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
    ///         event, the position's collateral delta, and the collateral received.
    function withdrawCollateral(Market storage self, address borrower, uint256 amount, address receiver) internal {
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
}
