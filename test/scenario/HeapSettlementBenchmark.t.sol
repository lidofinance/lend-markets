// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Test, console2} from "forge-std/Test.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice Gas benchmark of the settlement heap walk: seed a queue of borrower positions in a chosen
///         shape, drive a lender exit through repeated `settle` cuts, and log iterations and gas.
/// @dev Local-EVM only: mock tokens and a constant-price oracle, deployed fresh per test through
///      `LidoLendDeployer`, so the numbers are deterministic and no RPC is involved.
contract HeapSettlementBenchmark is Test, LidoLendDeployer {
    MockERC20 internal WETH;
    MockERC20 internal WSTETH;

    uint256 internal constant LLTV = 0.8e18;
    address internal constant LENDER = address(0x9000);

    uint256 internal constant MAX_ITERATIONS = 150;
    uint96 internal constant SLICE_FLOOR = 1 ether;
    uint128 internal constant DUST_THRESHOLD = 0.005 ether;
    uint256 internal constant MIN_COLLATERAL_ACTIVATION = 10e18;
    // Fixed collateral rate for the mock oracle: one wstETH is worth 1.2 WETH. A constant (rather than
    // a seeded price) keeps the benchmark's gas numbers comparable across runs.
    uint256 internal constant WSTETH_RATE = 1.2e18;

    struct Ctx {
        ILidoLend market;
        ILidoLendMarketController controller;
        MockPriceOracle oracle;
        MarketParams marketParams;
        Id id;
        uint256 price;
    }

    struct SettlementResult {
        uint256 totalCollateralSeized;
        uint256 totalDebtCanceled;
        uint256 iterations;
        uint256 gasUsed;
    }

    function setUp() public {
        WETH = new MockERC20("Wrapped Ether", "WETH", 18);
        WSTETH = new MockERC20("Wrapped stETH", "wstETH", 18);
    }

    // ── Uniform-LTV scenarios
    // ──────────────────────────────────────

    /// @dev Benchmarks the settlement heap walk over 20 equal small (0.5) uniform-LTV positions on a quarter-pool exit.
    function test_AllSmallEqual() public {
        _runUniform("AllSmallEqual(20x0.5)", 20, 0.5 ether, 0.7e18, 4);
    }

    /// @dev Benchmarks the settlement heap walk over 5 equal large (10) uniform-LTV positions on a quarter-pool exit.
    function test_AllLargeEqual() public {
        _runUniform("AllLargeEqual(5x10)", 5, 10 ether, 0.7e18, 4);
    }

    /// @dev Benchmarks the settlement heap walk for a tiny (~1%) exit against a large uniform pool.
    function test_SmallExitLargePool() public {
        _runUniform("SmallExit1%(10x5)", 10, 5 ether, 0.7e18, 100);
    }

    /// @dev Benchmarks the settlement heap walk for a 50% exit against a uniform pool.
    function test_LargeExit50Pct() public {
        _runUniform("LargeExit50%(10x5)", 10, 5 ether, 0.7e18, 2);
    }

    // ── Mixed-debt scenarios
    // ───────────────────────────────────────

    /// @dev Benchmarks the settlement heap walk over a mixed debt profile (10 small + 3 large) on a quarter-pool exit.
    function test_MixedSmallAndLarge() public {
        uint256[] memory debts = _buildDebts(10, 0.5 ether, 3, 10 ether);
        _runScenario(_deployCtx(), "Mixed(10x0.5+3x10)", debts, 0.7e18, _sum(debts) / 4);
    }

    /// @dev Benchmarks the heap walk when a dust tail is seeded before one whale (insertion order stresses the heap).
    function test_DustTailThenWhale() public {
        uint256[] memory debts = _buildDebts(10, 0.1 ether, 1, 40 ether);
        _runScenario(_deployCtx(), "DustTailThenWhale(10x0.1+1x40)", debts, 0.7e18, _sum(debts) / 4);
    }

    /// @dev Benchmarks the heap walk when the whale is seeded before the dust tail (reverse insertion order).
    function test_WhaleThenDustTail() public {
        uint256[] memory debts = _buildDebts(1, 40 ether, 10, 0.1 ether);
        _runScenario(_deployCtx(), "WhaleThenDustTail(1x40+10x0.1)", debts, 0.7e18, _sum(debts) / 4);
    }

    /// @dev Benchmarks the heap walk with two tied whales contending for the heap root plus smaller positions.
    function test_TwoEqualWhalesAtTop() public {
        uint256[] memory debts = _buildDebts(2, 15 ether, 3, 3 ether);
        _runScenario(_deployCtx(), "TwoEqualWhales(2x15+3x3)", debts, 0.7e18, _sum(debts) / 4);
    }

    // ── Variable-LTV scenarios
    // ─────────────────────────────────────

    /// @dev Benchmarks the heap walk over positions spread across a gradient of LTVs (30%..72%).
    function test_GradientLTV() public {
        Ctx memory ctx = _deployCtx();
        uint256 n = 10;
        uint256[] memory debts = new uint256[](n);
        uint256[] memory ltvs = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            debts[i] = 3 ether;
            ltvs[i] = 0.3e18 + (i * 0.045e18);
        }
        _runScenarioWithLTVs(ctx, "GradientLTV(10x3,LTV30-72%)", debts, ltvs, _sum(debts) / 4);
    }

    /// @dev Benchmarks the heap walk with positions clustered in a tight high-LTV band (69..71%) plus low-LTV outliers.
    function test_ClusterNearTop() public {
        Ctx memory ctx = _deployCtx();
        uint256[] memory debts = new uint256[](8);
        uint256[] memory ltvs = new uint256[](8);
        for (uint256 i; i < 5; ++i) {
            debts[i] = 5 ether;
            ltvs[i] = 0.69e18 + (i * 0.005e18);
        }
        for (uint256 i = 5; i < 8; ++i) {
            debts[i] = 5 ether;
            ltvs[i] = 0.4e18;
        }
        _runScenarioWithLTVs(ctx, "ClusterNearTop(5@69-71%+3@40%)", debts, ltvs, _sum(debts) / 4);
    }

    /// @notice Worst case for the heap walk: many large positions packed into a 2% LTV band, so
    ///         every cut barely re-orders the queue and the exit has to rotate through all of them.
    function test_ManyLargeCloseLTV() public {
        Ctx memory ctx = _deployCtx();
        uint256 n = 20;
        uint256[] memory debts = new uint256[](n);
        uint256[] memory ltvs = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            debts[i] = 50 ether;
            ltvs[i] = 0.74e18 + (i * 0.001e18); // 74.0% .. 75.9%
        }
        _runScenarioWithLTVs(ctx, "ManyLargeCloseLTV(20x50@74-76%)", debts, ltvs, _sum(debts) / 2);
    }

    // ── Serial exits
    // ───────────────────────────────────────────────

    /// @dev Benchmarks repeated small exits (10 rounds) draining a uniform pool, tracking per-round iterations and gas.
    function test_SerialSmallExits() public {
        Ctx memory ctx = _deployCtx();
        uint256[] memory debts = _uniformDebts(10, 5 ether);
        uint256 total = _sum(debts);
        _seedBorrowers(ctx, debts, 0.7e18, total);

        console2.log("=== SerialSmallExits(10x5%x10rounds) ===");
        uint256 drainedAcrossRounds;
        for (uint256 round; round < 10; ++round) {
            uint256 lenderShares = ctx.market.position(ctx.id, LENDER).supplyShares;
            if (lenderShares == 0) break;
            uint256 roundShares = _assetsToSupplyShares(ctx, total / 10);
            if (roundShares > lenderShares) roundShares = lenderShares;
            if (roundShares == 0) break;
            SettlementResult memory res = _settleLoop(ctx, roundShares);
            drainedAcrossRounds += res.totalDebtCanceled;
            console2.log("  round", round, "iter", res.iterations);
            console2.log("    debt_canceled", res.totalDebtCanceled, "gas", res.gasUsed);
        }
        assertGt(drainedAcrossRounds, 0, "serial exits cancelled debt");
        assertLt(ctx.controller.settlementBorrowersCount(), debts.length, "serial exits shrank the queue");
        _logPositions(ctx, debts.length);
    }

    // ── Dust scenarios (withdraw to high LTV) ──────────────────────

    /// @dev Benchmarks the heap walk over 100 dust positions each withdrawn to a high (~78%) LTV.
    function test_100DustPositions() public {
        Ctx memory ctx = _deployCtx();
        _seedDustBorrowers(ctx, 100, 0.3 ether, 0.78e18);
        _runDustScenario(ctx, "100DustPositions(100x0.3@~78%LTV)", 100, 0.3 ether, 4);
    }

    /// @dev Benchmarks the heap walk over 1000 dust positions each withdrawn to a high (~78%) LTV.
    function test_1000DustPositions() public {
        Ctx memory ctx = _deployCtx();
        _seedDustBorrowers(ctx, 1000, 0.3 ether, 0.78e18);
        _runDustScenario(ctx, "1000DustPositions(1000x0.3@~78%LTV)", 1000, 0.3 ether, 4);
    }

    /// @dev Benchmarks the heap walk over 1000 mixed-size positions (900 small + 90 mid + 10 large) on a quarter exit.
    function test_1000MixedPositions() public {
        Ctx memory ctx = _deployCtx();
        uint256 n = 1000;
        uint256[] memory debts = new uint256[](n);
        for (uint256 i; i < 900; ++i) {
            debts[i] = 0.5 ether;
        }
        for (uint256 i = 900; i < 990; ++i) {
            debts[i] = 5 ether;
        }
        for (uint256 i = 990; i < n; ++i) {
            debts[i] = 20 ether;
        }
        uint256 total = _sum(debts);

        _seedBorrowers(ctx, debts, 0.7e18, total);

        console2.log("=== 1000Mixed(900x0.5+90x5+10x20) ===");
        console2.log("  heap_size_before:", ctx.controller.settlementBorrowersCount());
        console2.log("  total_debt:", total);

        SettlementResult memory res = _settleLoop(ctx, _assetsToSupplyShares(ctx, total / 4));
        // A capped uniform-LTV pass slices debt but need not fully close any position, so don't assert a heap drop.
        assertGt(res.totalDebtCanceled, 0, "the quarter-pool exit cancels debt");
        _logSettlementResult(res);
        console2.log("  heap_size:", ctx.controller.settlementBorrowersCount());
    }

    // ── Whale + dust
    // ───────────────────────────────────────────────

    /// @dev Benchmarks the heap walk over 99 low-LTV dust positions plus one high-value whale that the exit hits first.
    function test_DustAndOneWhale100() public {
        Ctx memory ctx = _deployCtx();
        uint256 n = 100;
        uint256 dustDebt = 0.3 ether;
        uint256 whaleDebt = 100 ether;
        uint256 totalDebt = dustDebt * (n - 1) + whaleDebt;

        _mintWETH(ctx.market, LENDER, totalDebt);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, totalDebt, 0, LENDER, "");

        _seedOneBorrower(ctx, 0, whaleDebt, 0.7e18);
        for (uint256 i = 1; i < n; ++i) {
            _seedOneBorrower(ctx, i, dustDebt, 0.03e18);
        }

        vm.warp(block.timestamp + 2 hours + 1);
        _borrowAll(ctx, 0, 1, whaleDebt);
        _borrowAll(ctx, 1, n, dustDebt);
        uint128 whaleBorrowBefore = ctx.market.position(ctx.id, _borrowerAddr(0)).borrowShares;

        console2.log("=== DustAndOneWhale100(99x0.3lowLTV+1x100whale) ===");
        console2.log("  heap_size_before:", ctx.controller.settlementBorrowersCount());

        SettlementResult memory res = _settleLoop(ctx, _assetsToSupplyShares(ctx, 75 ether));
        _logSettlementResult(res);

        Position memory _whalePos = ctx.market.position(ctx.id, _borrowerAddr(0));
        (uint128 whaleBorrowAfter, uint128 whaleColAfter) = (_whalePos.borrowShares, _whalePos.collateral);
        // The high-LTV whale is the heap root; a 75-WETH exit (< its 100 debt) trims it and never reaches the dust.
        assertGt(res.totalDebtCanceled, 0, "the whale exit cancels something");
        assertLt(whaleBorrowAfter, whaleBorrowBefore, "the whale was trimmed");
        assertGt(whaleBorrowAfter, 0, "a 75-WETH exit cannot fully close a 100-WETH whale");
        assertEq(_countClosed(ctx, 1, n), 0, "the dust tail is never touched");
        console2.log("  whale_debt_remaining:", uint256(whaleBorrowAfter));
        console2.log("  whale_col_remaining:", uint256(whaleColAfter));
        console2.log("  heap_size:", ctx.controller.settlementBorrowersCount());
        console2.log("  dust_positions_touched:", _countClosed(ctx, 1, n));
    }

    // ── Full drain
    // ─────────────────────────────────────────────────

    /// @dev Benchmarks fully draining 2000 dust positions across repeated settle transactions, totaling gas/iterations.
    function test_2000DustFullDrain() public {
        Ctx memory ctx = _deployCtx();
        uint256 n = 2000;
        uint256 debtPer = 0.3 ether;
        _seedDustBorrowers(ctx, n, debtPer, 0.78e18);

        console2.log("=== 2000DustFullDrain ===");
        console2.log("  total_positions:", n);
        console2.log("  total_debt:", debtPer * n);
        console2.log("  heap_size_before:", ctx.controller.settlementBorrowersCount());

        uint256 totalTx;
        uint256 totalGas;
        uint256 totalIter;
        uint256 totalDebtDrained;

        while (true) {
            uint256 lenderShares = ctx.market.position(ctx.id, LENDER).supplyShares;
            if (lenderShares == 0 || ctx.controller.settlementBorrowersCount() == 0) break;
            SettlementResult memory res = _settleLoop(ctx, lenderShares);
            if (res.iterations == 0) break;
            totalTx++;
            totalGas += res.gasUsed;
            totalIter += res.iterations;
            totalDebtDrained += res.totalDebtCanceled;
            console2.log("  tx", totalTx, "iter", res.iterations);
            console2.log("    debt", res.totalDebtCanceled, "gas", res.gasUsed);
        }

        console2.log("  --- TOTALS ---");
        console2.log("  transactions:", totalTx);
        console2.log("  total_iterations:", totalIter);
        console2.log("  total_debt_drained:", totalDebtDrained);
        console2.log("  total_gas:", totalGas);
        console2.log("  positions_remaining:", ctx.controller.settlementBorrowersCount());

        // Real progress, though not to zero: accrued interest leaves a residual tail once the lender's supply runs out.
        assertGt(totalDebtDrained, 0, "the drain cancelled debt");
        assertGt(_countClosed(ctx, 0, n), 0, "the drain closed positions");
        assertLt(ctx.controller.settlementBorrowersCount(), n, "the drain shrank the settlement queue");
    }

    // ── Runners
    // ────────────────────────────────────────────────────

    function _runUniform(string memory label, uint256 n, uint256 debtPer, uint256 ltv, uint256 exitDivisor) internal {
        Ctx memory ctx = _deployCtx();
        uint256[] memory debts = _uniformDebts(n, debtPer);
        _runScenario(ctx, label, debts, ltv, _sum(debts) / exitDivisor);
    }

    function _runScenario(Ctx memory ctx, string memory label, uint256[] memory debts, uint256 ltv, uint256 exitAssets)
        internal
    {
        _seedBorrowers(ctx, debts, ltv, _sum(debts));
        SettlementResult memory res = _settleLoop(ctx, _assetsToSupplyShares(ctx, exitAssets));
        assertGt(res.totalDebtCanceled, 0, "a funded exit against outstanding debt cancels something");
        _logResult(ctx, label, debts.length, res);
    }

    function _runScenarioWithLTVs(
        Ctx memory ctx,
        string memory label,
        uint256[] memory debts,
        uint256[] memory ltvs,
        uint256 exitAssets
    ) internal {
        _seedBorrowersWithLTVs(ctx, debts, ltvs, _sum(debts));
        SettlementResult memory res = _settleLoop(ctx, _assetsToSupplyShares(ctx, exitAssets));
        assertGt(res.totalDebtCanceled, 0, "a funded exit against outstanding debt cancels something");
        _logResult(ctx, label, debts.length, res);
    }

    function _runDustScenario(Ctx memory ctx, string memory label, uint256 n, uint256 debtPer, uint256 exitDivisor)
        internal
    {
        console2.log("===", label, "===");
        console2.log("  heap_size_before:", ctx.controller.settlementBorrowersCount());
        SettlementResult memory res = _settleLoop(ctx, _assetsToSupplyShares(ctx, debtPer * n / exitDivisor));
        assertGt(res.totalDebtCanceled, 0, "the dust exit cancels something");
        console2.log("  borrowers:", n);
        _logSettlementResult(res);
        console2.log("  positions_closed:", _countClosed(ctx, 0, n));
        console2.log("  heap_size:", ctx.controller.settlementBorrowersCount());
    }

    // ── Seeding
    // ────────────────────────────────────────────────────

    function _seedBorrowers(Ctx memory ctx, uint256[] memory debts, uint256 ltv, uint256 totalSupply) internal {
        uint256[] memory ltvs = new uint256[](debts.length);
        for (uint256 i; i < debts.length; ++i) {
            ltvs[i] = ltv;
        }
        _seedBorrowersWithLTVs(ctx, debts, ltvs, totalSupply);
    }

    function _seedBorrowersWithLTVs(Ctx memory ctx, uint256[] memory debts, uint256[] memory ltvs, uint256 totalSupply)
        internal
    {
        _mintWETH(ctx.market, LENDER, totalSupply);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, totalSupply, 0, LENDER, "");

        for (uint256 i; i < debts.length; ++i) {
            _seedOneBorrower(ctx, i, debts[i], ltvs[i]);
        }
        vm.warp(block.timestamp + 2 hours + 1);
        for (uint256 i; i < debts.length; ++i) {
            _borrowOne(ctx, i, debts[i]);
        }
    }

    function _seedDustBorrowers(Ctx memory ctx, uint256 n, uint256 debtPer, uint256 targetLTV) internal {
        uint256 totalDebt = debtPer * n;
        _mintWETH(ctx.market, LENDER, totalDebt);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, totalDebt, 0, LENDER, "");

        for (uint256 i; i < n; ++i) {
            address b = _borrowerAddr(i);
            uint256 col = _mintWstETH(ctx.market, b, 15 ether);
            vm.prank(b);
            ctx.market.supplyCollateral(ctx.marketParams, col, b, "");
        }

        vm.warp(block.timestamp + 2 hours + 1);

        for (uint256 i; i < n; ++i) {
            _borrowOne(ctx, i, debtPer);
        }

        uint256 minCol = _collateralForDebt(debtPer, targetLTV, ctx.price);
        for (uint256 i; i < n; ++i) {
            address b = _borrowerAddr(i);
            uint128 col = ctx.market.position(ctx.id, b).collateral;
            uint256 toWithdraw = uint256(col) - minCol;
            if (toWithdraw > 0) {
                vm.prank(b);
                ctx.market.withdrawCollateral(ctx.marketParams, toWithdraw, b, b);
            }
        }
    }

    function _seedOneBorrower(Ctx memory ctx, uint256 idx, uint256 debt, uint256 ltv) internal {
        address b = _borrowerAddr(idx);
        uint256 requiredCol = _collateralForDebt(debt, ltv, ctx.price);
        uint256 ethForCol = requiredCol * WSTETH_RATE * 13 / (1e18 * 10);
        if (ethForCol < 15 ether) ethForCol = 15 ether;
        uint256 col = _mintWstETH(ctx.market, b, ethForCol);
        vm.prank(b);
        ctx.market.supplyCollateral(ctx.marketParams, col, b, "");
    }

    function _borrowOne(Ctx memory ctx, uint256 idx, uint256 debt) internal {
        address b = _borrowerAddr(idx);
        vm.prank(b);
        ctx.market.borrow(ctx.marketParams, debt, 0, b, b);
    }

    function _borrowAll(Ctx memory ctx, uint256 from, uint256 to, uint256 debt) internal {
        for (uint256 i = from; i < to; ++i) {
            _borrowOne(ctx, i, debt);
        }
    }

    // ── Settle loop
    // ────────────────────────────────────────────

    function _settleLoop(Ctx memory ctx, uint256 exitShares) internal returns (SettlementResult memory res) {
        uint256 remaining = exitShares;
        uint256 heapBefore = ctx.controller.settlementBorrowersCount();
        uint256 gasBefore = gasleft();

        for (uint256 i; i < MAX_ITERATIONS; ++i) {
            if (remaining == 0 || ctx.controller.settlementBorrowersCount() == 0) break;

            (address top,) = ctx.controller.nextSettlementBorrower(0);
            if (top == address(0)) break;
            uint256 sliceAssets = _dashboardSliceAssets(ctx.controller, top);
            uint128 topBorrowShares = ctx.market.position(ctx.id, top).borrowShares;
            uint128 topCol = ctx.market.position(ctx.id, top).collateral;
            uint128 totalBorrowAssets = ctx.market.market(ctx.id).totalBorrowAssets;
            uint128 totalBorrowShares = ctx.market.market(ctx.id).totalBorrowShares;

            // Single-borrower sentinel: size the cut to the whole position.
            if (sliceAssets == type(uint256).max) {
                sliceAssets = (uint256(topBorrowShares) * (uint256(totalBorrowAssets) + 1))
                    / (uint256(totalBorrowShares) + SharesMathLib.VIRTUAL_SHARES);
            }
            uint256 sliceCol = sliceAssets * ORACLE_PRICE_SCALE / ctx.price;

            uint256 cutShares;
            if (uint256(topCol) - _min(sliceCol, uint256(topCol)) < MIN_COLLATERAL_ACTIVATION) {
                cutShares = uint256(topBorrowShares);
            } else {
                cutShares = (sliceAssets * (uint256(totalBorrowShares) + SharesMathLib.VIRTUAL_SHARES))
                    / (uint256(totalBorrowAssets) + 1);
                if (cutShares == 0) cutShares = 1;
            }
            if (cutShares > remaining) cutShares = remaining;

            if (!_settleCutOnce(ctx, res, cutShares, top)) {
                if (cutShares > remaining / 2) cutShares = remaining / 2;
                if (cutShares == 0) break;
                if (!_settleCutOnce(ctx, res, cutShares, top)) break;
            }
            remaining -= cutShares;
        }

        res.gasUsed = gasBefore - gasleft();

        // Correctness rails for every scenario, independent of the gas numbers.
        assertLe(res.iterations, MAX_ITERATIONS, "settle walk stays within the iteration cap");
        assertLe(ctx.controller.settlementBorrowersCount(), heapBefore, "heap never grows during settlement");
        assertEq(res.totalCollateralSeized == 0, res.totalDebtCanceled == 0, "collateral seized iff debt canceled");
    }

    function _dashboardSliceAssets(ILidoLendMarketController controller, address borrower)
        internal
        view
        returns (uint256)
    {
        ILidoLendMarketController.BorrowerPosition memory dashboard = controller.positionOf(borrower);
        return dashboard.personalSliceAssets > dashboard.queueRootSliceAssets
            ? dashboard.personalSliceAssets
            : dashboard.queueRootSliceAssets;
    }

    /// @dev One settle attempt as LENDER, accumulated into `res`; swallows the revert so the caller can
    ///      retry with a smaller cut.
    function _settleCutOnce(Ctx memory ctx, SettlementResult memory res, uint256 cutShares, address top)
        internal
        returns (bool)
    {
        vm.prank(LENDER);
        try ctx.market.settle(ctx.marketParams, cutShares, LENDER, top, LENDER) returns (
            uint256 colSeized, uint256 debtCanceled, uint256, uint256
        ) {
            res.totalCollateralSeized += colSeized;
            res.totalDebtCanceled += debtCanceled;
            res.iterations++;
            return true;
        } catch {
            return false;
        }
    }

    // ── Logging
    // ────────────────────────────────────────────────────

    function _logResult(Ctx memory ctx, string memory label, uint256 n, SettlementResult memory res) internal view {
        console2.log("===", label, "===");
        console2.log("  borrowers:", n);
        _logSettlementResult(res);
        _logPositions(ctx, n);
    }

    function _logSettlementResult(SettlementResult memory res) internal pure {
        console2.log("  iterations:", res.iterations);
        console2.log("  total_debt_canceled:", res.totalDebtCanceled);
        console2.log("  total_col_seized:", res.totalCollateralSeized);
        console2.log("  gas_used:", res.gasUsed);
    }

    function _logPositions(Ctx memory ctx, uint256 n) internal view {
        console2.log("  dust_positions:", _countDust(ctx, 0, n));
        console2.log("  heap_size:", ctx.controller.settlementBorrowersCount());
    }

    // ── Deployment
    // ─────────────────────────────────────────────────

    function _deployCtx() internal returns (Ctx memory ctx) {
        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: address(WETH),
                collateralToken: address(WSTETH),
                oracleSource: address(0), // unused — `_deployOracle` is overridden below
                lltv: LLTV,
                supplyCap: 0,
                enableSettlement: true,
                activation: CollateralActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    activatingLockDuration: 0,
                    maxDelayInflow: 10_000 ether,
                    // The benchmark builds sub-floor dust positions directly (borrow, then withdraw to a
                    // sliver) to stress the heap. The open-debt collateral floor forbids that voluntary path,
                    // so relax the activation minimum here — this benchmark is not exercising that policy.
                    minActivationAmount: 1,
                    minDepositAmount: 0,
                    maxGuardiansQuorumDelay: 0,
                    delayPerStrike: 0,
                    delayPerSuspect: 0
                }),
                settlementConfig: SettlementConfig({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                suspectWindow: 0,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );

        ctx.market = ILidoLend(d.core);
        ctx.oracle = MockPriceOracle(d.oracle);
        ctx.controller = ILidoLendMarketController(d.controllerProxy);
        ctx.marketParams = d.params;
        ctx.id = d.marketId;
        ctx.price = ctx.oracle.price();

        ctx.controller.grantRole(ctx.controller.MANAGER_ROLE(), address(this));
        ctx.controller
            .setSettlementConfig(
                SettlementConfig({
                    sliceFloorBps: 100,
                    sliceFloorAssets: SLICE_FLOOR,
                    fullCutBelowCollateral: uint96(MIN_COLLATERAL_ACTIVATION),
                    ltvStepBps: 100
                })
            );
    }

    /// @dev Overrides the default `WstEthRateOracle` with a constant-price mock at the fixed rate, in the
    ///      Morpho 1e36 convention (both tokens have 18 decimals).
    function _deployOracle(address, address) internal override returns (address) {
        MockPriceOracle oracle = new MockPriceOracle();
        oracle.initialize(WSTETH_RATE * 1e18);
        return address(oracle);
    }

    // ── Helpers
    // ─────────────────────────────────────────────────────

    function _borrowerAddr(uint256 i) internal pure returns (address) {
        return address(uint160(0x2000 + i));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sum(uint256[] memory arr) internal pure returns (uint256 s) {
        for (uint256 i; i < arr.length; ++i) {
            s += arr[i];
        }
    }

    function _uniformDebts(uint256 n, uint256 amount) internal pure returns (uint256[] memory debts) {
        debts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            debts[i] = amount;
        }
    }

    function _buildDebts(uint256 n1, uint256 a1, uint256 n2, uint256 a2)
        internal
        pure
        returns (uint256[] memory debts)
    {
        debts = new uint256[](n1 + n2);
        for (uint256 i; i < n1; ++i) {
            debts[i] = a1;
        }
        for (uint256 i; i < n2; ++i) {
            debts[n1 + i] = a2;
        }
    }

    function _countClosed(Ctx memory ctx, uint256 from, uint256 to) internal view returns (uint256 count) {
        for (uint256 i = from; i < to; ++i) {
            uint128 bs = ctx.market.position(ctx.id, _borrowerAddr(i)).borrowShares;
            if (bs == 0) count++;
        }
    }

    function _countDust(Ctx memory ctx, uint256 from, uint256 to) internal view returns (uint256 count) {
        for (uint256 i = from; i < to; ++i) {
            Position memory _pos = ctx.market.position(ctx.id, _borrowerAddr(i));
            (uint128 bs, uint128 col) = (_pos.borrowShares, _pos.collateral);
            if (bs > 0 && col < uint128(DUST_THRESHOLD)) count++;
        }
    }

    function _collateralForDebt(uint256 debt, uint256 targetLTV, uint256 oraclePrice) internal pure returns (uint256) {
        return (debt * ORACLE_PRICE_SCALE) / (oraclePrice * targetLTV / 1e18);
    }

    function _assetsToSupplyShares(Ctx memory ctx, uint256 assets) internal view returns (uint256) {
        Market memory _mkt = ctx.market.market(ctx.id);
        (uint128 totalSupplyAssets, uint128 totalSupplyShares) = (_mkt.totalSupplyAssets, _mkt.totalSupplyShares);
        return SharesMathLib.toSharesDown(assets, uint256(totalSupplyAssets), uint256(totalSupplyShares));
    }

    function _mintWETH(ILidoLend market, address user, uint256 amount) internal {
        WETH.mint(user, amount);
        vm.prank(user);
        WETH.approve(address(market), type(uint256).max);
    }

    /// @dev `ethAmount` is denominated in loan-token (WETH) terms and converted to wstETH at the fixed rate.
    function _mintWstETH(ILidoLend market, address user, uint256 ethAmount) internal returns (uint256) {
        uint256 wstEthAmount = (ethAmount * 1e18) / WSTETH_RATE;
        WSTETH.mint(user, wstEthAmount);
        vm.prank(user);
        WSTETH.approve(address(market), type(uint256).max);
        return wstEthAmount;
    }
}
