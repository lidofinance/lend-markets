// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Market as CoreMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementConfig, SettlementQuote, SettlementSlice} from "../../src/types/SettlementTypes.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice Settlement cuts are sized in borrow/supply shares alone; nothing checks that the collateral the core
///         then seizes for them rounds to a nonzero amount. The core prices the seizure off the down-rounded
///         debt, so above `ORACLE_PRICE_SCALE` — wstETH/WETH is ~1.19e36 — a cut worth one loan asset seizes
///         zero and is rejected: the smallest executable cut is `ceil(price / ORACLE_PRICE_SCALE)` loan assets.
///         `settlementSlice` therefore checks the seizure the core will derive and reports a cut that buys no whole
///         collateral unit as unavailable — an all-zero slice — so a supply budget landing on that boundary is
///         handled as budget exhaustion (`settle` reverts `NothingSettled`, `fallbackExit` partial-fills) instead
///         of reverting the whole call inside the core.
contract SettleSeizeFloorTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev wstETH/WETH-like: strictly above `ORACLE_PRICE_SCALE`, so one loan asset buys zero collateral units.
    uint256 internal constant PRICE = 1.193e36;

    uint256 internal constant VAULT_SUPPLY = 100 ether;
    uint256 internal constant DIRECT_SUPPLY = 100 ether;
    uint256 internal constant COLLATERAL = 200 ether;
    uint256 internal constant BORROW = 150 ether; // 75% utilization: a liquid leg to lose, a settle leg for the rest

    address internal lender;
    address internal directLender;
    address internal borrower;
    address internal receiver;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        Market storage m = protocol.markets[0];
        // Fixed and seed-independent: the price sitting above parity is the whole case.
        MockPriceOracle(address(m.oracle)).setPrice(PRICE);

        lender = _actor("lender");
        directLender = _actor("directLender");
        borrower = _actor("borrower");
        receiver = _actor("receiver");

        _fund(m.loanToken, lender, VAULT_SUPPLY);
        m.vaultDeposit(lender, VAULT_SUPPLY);

        _fund(m.loanToken, directLender, DIRECT_SUPPLY);
        vm.startPrank(directLender);
        m.loanToken.approve(address(m.core), DIRECT_SUPPLY);
        m.core.supply(m.params, DIRECT_SUPPLY, 0, directLender, "");
        vm.stopPrank();

        _fund(m.collateralToken, borrower, COLLATERAL);
        m.supplyCollateral(borrower, COLLATERAL);
        m.activateCollateral();
        m.borrow(borrower, BORROW);

        // A personal settlement target well below the current LTV, so the personal slice is large and the supply
        // budget — not policy — is what sizes every cut below.
        m.setSettlementLtv(borrower, 0.05e18);

        // Drift the share ratios off mint parity so the share<->asset conversions actually round.
        m.warpAndAccrue(30 days);
    }

    // ---
    // THE BOUNDARY IN THE CORE
    // ---

    /// @dev A cut worth exactly one loan asset seizes zero collateral and is rejected. Two loan assets is the
    ///      smallest cut the core executes at this price, so the effective minimum is `ceil(price / 1e36)`, not 1.
    function testRevert_oneLoanAssetCut_seizesZeroCollateral() public {
        Market storage m = protocol.markets[0];
        CoreMarket memory cm = m.core.market(m.id);

        uint256 oneAssetShares = SharesMathLib.toSharesUp(1, cm.totalBorrowAssets, cm.totalBorrowShares);
        assertEq(
            SharesMathLib.toAssetsDown(oneAssetShares, cm.totalBorrowAssets, cm.totalBorrowShares),
            1,
            "handle is worth exactly one loan asset going down"
        );
        assertEq(Math.mulDiv(1, ORACLE_PRICE_SCALE, PRICE), 0, "one loan asset buys zero collateral above parity");

        vm.prank(directLender);
        vm.expectRevert(bytes("settlement slice too small"));
        m.core.settle(m.params, oneAssetShares, directLender, borrower, receiver);

        uint256 twoAssetShares = SharesMathLib.toSharesUp(2, cm.totalBorrowAssets, cm.totalBorrowShares);
        vm.prank(directLender);
        (uint256 seized,,,) = m.core.settle(m.params, twoAssetShares, directLender, borrower, receiver);
        assertEq(seized, 1, "the smallest executable cut seizes one collateral unit");
    }

    // ---
    // THE QUEUE LIBRARY REPORTS THAT CUT AS UNAVAILABLE
    // ---

    /// @dev A budget worth two loan assets funds a one-loan-asset cut (budget -> supply assets -> borrow shares
    ///      floors twice), which seizes nothing at this price. The library reports it as unavailable rather
    ///      than a nonzero cut the core would reject.
    /// @dev Same issue as `test_fallbackExit_dustRootPartialFillsUntilDustIsRepaid` in
    ///      `test/scenario/SettleVaultBorrowAnchor.t.sol`; this test shows that a budget-shrunk cut below the seizure
    ///      floor reads as unavailable.
    function test_settlementSlice_budgetShrunkCutBelowSeizureFloor_isUnavailable() public view {
        Market storage m = protocol.markets[0];
        CoreMarket memory cm = m.core.market(m.id);

        uint256 budget = _budgetWorthAssets(2);

        // The cut that budget funds, sized the way the library sizes it before the seizure check.
        uint256 fundedShares = SharesMathLib.toSharesDown(
            SharesMathLib.toAssetsDown(budget, cm.totalSupplyAssets, cm.totalSupplyShares),
            cm.totalBorrowAssets,
            cm.totalBorrowShares
        );
        assertGt(fundedShares, 0, "the budget does fund borrow shares");
        uint256 cutAssets = SharesMathLib.toAssetsDown(fundedShares, cm.totalBorrowAssets, cm.totalBorrowShares);
        assertEq(cutAssets, 1, "and that cut is worth one loan asset");
        assertEq(Math.mulDiv(cutAssets, ORACLE_PRICE_SCALE, PRICE), 0, "which seizes no collateral at this price");

        SettlementQuote memory quote = m.controller.settlementFor(borrower, budget);
        assertEq(quote.personal.borrowShares, 0, "so the personal candidate is unavailable");
        assertEq(quote.personal.supplyShares, 0, "with no supply charged");
        assertEq(
            quote.personal.remainingBorrowShares,
            m.core.position(m.id, borrower).borrowShares,
            "with the untouched debt reported"
        );
        assertEq(quote.queueRoot.borrowShares, 0, "the root candidate is unavailable on the same budget");

        (, SettlementSlice memory next) = m.controller.nextSettlementBorrower(budget);
        assertEq(next.borrowShares, 0, "and so is the queue-root cut the fallback path would take");
    }

    /// @dev The guard is scoped to the seizure floor: the same borrower and price still quote a normal cut once the
    ///      budget clears it, and an unbudgeted policy quote is untouched.
    function test_settlementSlice_aboveSeizureFloor_stillQuotes() public view {
        Market storage m = protocol.markets[0];

        SettlementQuote memory quote = m.controller.settlementFor(borrower, _budgetWorthAssets(3));
        assertGt(quote.personal.borrowShares, 0, "a three-asset budget quotes a cut");
        assertGt(quote.personal.supplyShares, 0, "and charges supply for it");
        assertGt(quote.personal.remainingBorrowShares, 0, "as a partial, not a close");

        SettlementQuote memory unbudgeted = m.controller.settlementFor(borrower, 0);
        assertGt(unbudgeted.personal.borrowShares, 0, "the unbudgeted policy quote is unaffected");
    }

    // ---
    // THE VAULT SEES BUDGET EXHAUSTION, NOT A CORE REVERT
    // ---

    /// @dev `settle` has nothing to settle on the boundary budget, so it reverts with its own `NothingSettled`
    ///      rather than the core's rejection. Three loan assets is the smallest budget that settles.
    function testRevert_vaultSettle_boundaryBudgetSettlesNothing() public {
        Market storage m = protocol.markets[0];
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;

        uint256 boundaryShares = _vaultSharesForBudget(_budgetWorthAssets(2));
        uint256 settleableShares = _vaultSharesForBudget(_budgetWorthAssets(3));

        vm.prank(lender);
        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        m.vault.settle(boundaryShares, borrowers, receiver, lender);

        (, uint256 collateralSeized,) = m.settle(lender, settleableShares, borrowers, receiver);
        assertEq(collateralSeized, 1, "the smallest settleable budget seizes one collateral unit");
    }

    /// @dev Control: the same two-loan-asset budget settles when the price sits at parity, so the revert above is
    ///      the seizure floor at `price > ORACLE_PRICE_SCALE`, not the budget being too small in share terms.
    function test_vaultSettle_sameBudgetSettlesAtParityPrice() public {
        Market storage m = protocol.markets[0];
        MockPriceOracle(address(m.oracle)).setPrice(ORACLE_PRICE_SCALE);

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;

        uint256 boundaryShares = _vaultSharesForBudget(_budgetWorthAssets(2));
        (, uint256 collateralSeized,) = m.settle(lender, boundaryShares, borrowers, receiver);
        assertEq(collateralSeized, 1, "at parity a one-loan-asset cut seizes one collateral unit");
    }

    /// @dev `fallbackExit` documents budget exhaustion as a partial fill. With the boundary tail reported as an
    ///      unavailable cut the settle loop breaks on it, so the liquid leg that already paid out survives.
    /// @dev Same issue as `test_fallbackExit_dustRootPartialFillsUntilDustIsRepaid` in
    ///      `test/scenario/SettleVaultBorrowAnchor.t.sol`; this test reaches the zero-collateral cut by the budget
    ///      instead of a dust root.
    function test_fallbackExit_boundaryTail_partialFillsLiquidLeg() public {
        Market storage m = protocol.markets[0];

        // Shares the liquid leg covers on its own. Requesting exactly these exits cleanly — the settle leg is
        // never reached — and it fixes the state the settle leg would start from.
        uint256 liquidShares = m.vault.previewWithdraw(m.controller.maxWithdrawableAssets(address(m.vault)));

        uint256 snapshot = vm.snapshotState();
        vm.prank(lender);
        (uint256 liquidBurned, uint256 liquidAssets,,) = m.vault.fallbackExit(liquidShares, receiver, lender, 0);
        assertEq(liquidBurned, liquidShares, "liquid leg alone burns the whole request");
        assertGt(liquidAssets, 0, "liquid leg alone pays out");
        uint256 tailShares = _vaultSharesForBudget(_budgetWorthAssets(2));
        vm.revertToState(snapshot);

        // The same liquid leg plus a tail whose budget lands on the boundary cut: the settle leg finds no
        // executable cut, breaks, and the call partial-fills on the liquid leg alone.
        uint256 requestShares = liquidShares + tailShares;
        (uint256 sharesBurned, uint256 loanPaid, uint256 collateralSeized,) =
            m.fallbackExit(lender, requestShares, receiver, 0);

        assertEq(sharesBurned, liquidShares, "only the liquid leg's shares are burned");
        assertEq(loanPaid, liquidAssets, "the liquid payout is the same as the liquid leg alone");
        assertEq(collateralSeized, 0, "the settle leg cut nothing");
        assertEq(m.loanToken.balanceOf(receiver), liquidAssets, "and the receiver keeps the liquid payout");
        assertEq(m.vault.balanceOf(lender), m.vault.totalSupply(), "the unsettled tail stays with the lender");
    }

    // ---
    // AN UNAVAILABLE QUEUE ROOT STOPS THE FALLBACK SETTLE LEG
    // ---

    /// @dev Known issue: when the queue root has no executable cut, `fallbackExit` stops at it and reverts
    ///      `NothingSettled` in a fully borrowed market. This occurs although a borrower behind the root has an
    ///      executable cut.
    ///      Root cause: `nextSettlementBorrower` quotes only `peekRoot()`, and `settlementSlice` returns zero borrow
    ///      shares when the cut seizes no whole collateral unit. `fallbackExit` reads a zero cut as the end of its
    ///      settle loop and never tries another borrower.
    ///      Same cause: any root whose cut rounds to zero collateral. Examples are a small `sliceFloorAssets` at a
    ///      price above `ORACLE_PRICE_SCALE` and a dust-debt root. A zero oracle price and a
    ///      root with no policy or personal slice also stop the loop. The root holds the block for every lender and
    ///      every repeated exit while its cut stays unavailable. With free liquidity the call partial-fills on its
    ///      liquid leg instead of a revert.
    function testRevert_unavailableRoot_blocksFallbackExitPastExecutableBorrower() public {
        Market storage m = protocol.markets[0];
        _seedUnavailableRootInFullyBorrowedMarket();
        uint256 shares = m.vault.balanceOf(lender);

        SettlementQuote memory quote = m.controller.settlementFor(borrower, 0);
        assertGt(quote.personal.borrowShares, 0, "setup: the borrower behind the root has an executable cut");

        vm.prank(lender);
        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        m.vault.fallbackExit(shares, receiver, lender, 0);
    }

    /// @dev Same issue as `testRevert_unavailableRoot_blocksFallbackExitPastExecutableBorrower`; this control shows
    ///      that a targeted `settle` in the same state still reaches the borrower behind the root.
    function test_unavailableRoot_targetedSettleStillCuts() public {
        Market storage m = protocol.markets[0];
        _seedUnavailableRootInFullyBorrowedMarket();
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        uint128 borrowSharesBefore = m.core.position(m.id, borrower).borrowShares;

        (uint256 sharesBurned, uint256 collateralSeized,) =
            m.settle(lender, m.vault.balanceOf(lender) / 10, borrowers, receiver);

        assertGt(sharesBurned, 0, "the targeted settle burns lender shares");
        assertGt(collateralSeized, 0, "and seizes collateral");
        assertLt(m.core.position(m.id, borrower).borrowShares, borrowSharesBefore, "and cuts the borrower");
    }

    /// @dev Specified behaviour: anyone can make a repay of the root's exact borrow shares revert by first repaying
    ///      one of them for one raw unit. A repay that reads the root's shares when it runs still lifts it, and
    ///      `fallbackExit` then settles past it. `lender-settlement.md` describes it.
    function test_unavailableRootLift_frontRunByOneShare_liveShareRepayStillLifts() public {
        Market storage m = protocol.markets[0];
        _seedUnavailableRootInFullyBorrowedMarket();
        address root = _actor("unavailableRoot");
        uint256 rootShares = m.core.position(m.id, root).borrowShares;

        address griefer = _actor("griefer");
        _fund(m.loanToken, griefer, 1);
        vm.startPrank(griefer);
        m.loanToken.approve(address(m.core), 1);
        (uint256 griefPaid,) = m.core.repay(m.params, 0, 1, root, "");
        vm.stopPrank();
        assertEq(griefPaid, 1, "one borrow share costs one raw unit");

        address lifter = _actor("lifter");
        _fund(m.loanToken, lifter, 100 ether);
        vm.startPrank(lifter);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.expectRevert(ILidoLendMarketController.PositionAccountingMismatch.selector);
        m.core.repay(m.params, 0, rootShares, root, "");
        m.core.repay(m.params, 0, m.core.position(m.id, root).borrowShares, root, "");
        vm.stopPrank();

        (address queueRoot,) = m.controller.nextSettlementBorrower(0);
        assertEq(queueRoot, borrower, "the executable borrower is the root again");
        (,, uint256 collateralSeized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), receiver, 0);
        assertGt(collateralSeized, 0, "the exit settles against the borrower behind the old root");
    }

    /// @dev The settlement policy under test: a one-loan-asset root slice and nothing else. At this price that slice
    ///      buys no collateral unit. A new root with no personal LTV then borrows all free liquidity.
    ///      No market config in `script/config/markets` uses this policy. The test uses it to give the root an
    ///      unavailable cut.
    function _seedUnavailableRootInFullyBorrowedMarket() internal {
        Market storage m = protocol.markets[0];
        m.setSettlementConfig(
            SettlementConfig({sliceFloorBps: 0, sliceFloorAssets: 1, fullCutBelowCollateral: 0, ltvStepBps: 0})
        );

        address root = _actor("unavailableRoot");
        _fund(m.collateralToken, root, 60 ether);
        m.supplyCollateral(root, 60 ether);
        m.activateCollateral();
        m.accrueInterest();
        CoreMarket memory cm = m.core.market(m.id);
        // About 50 loan assets against 60 collateral units: 70% LTV, and a higher key than the first borrower.
        m.borrow(root, cm.totalSupplyAssets - cm.totalBorrowAssets);

        (address queueRoot, SettlementSlice memory rootSlice) = m.controller.nextSettlementBorrower(0);
        assertEq(queueRoot, root, "setup: the new borrower is the queue root");
        assertEq(rootSlice.borrowShares, 0, "setup: the root cut buys no collateral unit");
        assertEq(m.controller.maxWithdrawableAssets(address(m.vault)), 0, "setup: no liquid leg");
    }

    // ---
    // HELPERS
    // ---

    /// @dev Core supply shares whose down-rounded value is exactly `assets` loan assets.
    function _budgetWorthAssets(uint256 assets) internal view returns (uint256) {
        Market storage m = protocol.markets[0];
        CoreMarket memory cm = m.core.market(m.id);
        return SharesMathLib.toSharesUp(assets, cm.totalSupplyAssets, cm.totalSupplyShares);
    }

    /// @dev Invert both downward budget conversions to find the smallest request that funds these core shares.
    function _vaultSharesForBudget(uint256 budgetSupplyShares) internal view returns (uint256) {
        Market storage m = protocol.markets[0];
        CoreMarket memory cm = m.core.market(m.id);
        uint256 assets = SharesMathLib.toAssetsUp(budgetSupplyShares, cm.totalSupplyAssets, cm.totalSupplyShares);
        return m.vault.previewWithdraw(assets);
    }
}
