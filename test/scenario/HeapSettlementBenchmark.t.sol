// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Test, console2} from "forge-std/Test.sol";

import {ILidoLendMarketController} from "../utils/ILidoLendMarketController.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

interface IWETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function deposit() external payable;
}

interface IWstETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
}

interface IOracle {
    function price() external view returns (uint256);
}

contract ControllableWstEthOracle is IOracle {
    IWstETH public immutable WSTETH;
    uint256 private _override;

    constructor(address wstETH_) {
        WSTETH = IWstETH(wstETH_);
    }

    function price() external view override returns (uint256) {
        if (_override != 0) return _override;
        return WSTETH.stEthPerToken() * 1e18;
    }

    function setOverridePrice(uint256 p) external {
        _override = p;
    }

    function clearOverride() external {
        _override = 0;
    }
}

contract HeapSettlementBenchmark is Test, LidoLendDeployer {
    using MarketParamsLib for MarketParams;

    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IWETH internal constant WETH = IWETH(WETH_ADDRESS);
    IWstETH internal constant WSTETH = IWstETH(WSTETH_ADDRESS);

    uint256 internal constant LLTV = 0.8e18;
    address internal constant LENDER = address(0x9000);

    uint256 internal constant MAX_ITERATIONS = 150;
    uint96 internal constant SLICE_FLOOR = 1 ether;
    uint128 internal constant DUST_THRESHOLD = 0.005 ether;
    uint256 internal constant MIN_COLLATERAL_ACTIVATION = 10e18;
    uint256 internal _wstEthRate;

    struct Ctx {
        ILidoLend market;
        ILidoLendMarketController controller;
        ControllableWstEthOracle oracle;
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

    // ── Uniform-LTV scenarios
    // ──────────────────────────────────────

    function test_AllSmallEqual() public {
        _skip();
        _runUniform("AllSmallEqual(20x0.5)", 20, 0.5 ether, 0.7e18, 4);
    }

    function test_AllLargeEqual() public {
        _skip();
        _runUniform("AllLargeEqual(5x10)", 5, 10 ether, 0.7e18, 4);
    }

    function test_SmallExitLargePool() public {
        _skip();
        _runUniform("SmallExit1%(10x5)", 10, 5 ether, 0.7e18, 100);
    }

    function test_LargeExit50Pct() public {
        _skip();
        _runUniform("LargeExit50%(10x5)", 10, 5 ether, 0.7e18, 2);
    }

    // ── Mixed-debt scenarios
    // ───────────────────────────────────────

    function test_MixedSmallAndLarge() public {
        _skip();
        uint256[] memory debts = _buildDebts(10, 0.5 ether, 3, 10 ether);
        _runScenario(_deployCtx(), "Mixed(10x0.5+3x10)", debts, 0.7e18, _sum(debts) / 4);
    }

    function test_DustTailThenWhale() public {
        _skip();
        uint256[] memory debts = _buildDebts(10, 0.1 ether, 1, 40 ether);
        _runScenario(_deployCtx(), "DustTailThenWhale(10x0.1+1x40)", debts, 0.7e18, _sum(debts) / 4);
    }

    function test_WhaleThenDustTail() public {
        _skip();
        uint256[] memory debts = _buildDebts(1, 40 ether, 10, 0.1 ether);
        _runScenario(_deployCtx(), "WhaleThenDustTail(1x40+10x0.1)", debts, 0.7e18, _sum(debts) / 4);
    }

    function test_TwoEqualWhalesAtTop() public {
        _skip();
        uint256[] memory debts = _buildDebts(2, 15 ether, 3, 3 ether);
        _runScenario(_deployCtx(), "TwoEqualWhales(2x15+3x3)", debts, 0.7e18, _sum(debts) / 4);
    }

    // ── Variable-LTV scenarios
    // ─────────────────────────────────────

    function test_GradientLTV() public {
        _skip();
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

    function test_ClusterNearTop() public {
        _skip();
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
        _skip();
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

    function test_SerialSmallExits() public {
        _skip();
        Ctx memory ctx = _deployCtx();
        uint256[] memory debts = _uniformDebts(10, 5 ether);
        uint256 total = _sum(debts);
        _seedBorrowers(ctx, debts, 0.7e18, total);

        console2.log("=== SerialSmallExits(10x5%x10rounds) ===");
        for (uint256 round; round < 10; ++round) {
            (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
            if (lenderShares == 0) break;
            uint256 roundShares = _assetsToSupplyShares(ctx, total / 10);
            if (roundShares > lenderShares) roundShares = lenderShares;
            if (roundShares == 0) break;
            SettlementResult memory res = _settleLoop(ctx, roundShares);
            console2.log("  round", round, "iter", res.iterations);
            console2.log("    debt_canceled", res.totalDebtCanceled, "gas", res.gasUsed);
        }
        _logPositions(ctx, debts.length);
    }

    // ── Dust scenarios (withdraw to high LTV) ──────────────────────

    function test_100DustPositions() public {
        _skip();
        Ctx memory ctx = _deployCtx();
        _seedDustBorrowers(ctx, 100, 0.3 ether, 0.78e18);
        _runDustScenario(ctx, "100DustPositions(100x0.3@~78%LTV)", 100, 0.3 ether, 4);
    }

    function test_1000DustPositions() public {
        _skip();
        Ctx memory ctx = _deployCtx();
        _seedDustBorrowers(ctx, 1000, 0.3 ether, 0.78e18);
        _runDustScenario(ctx, "1000DustPositions(1000x0.3@~78%LTV)", 1000, 0.3 ether, 4);
    }

    function test_1000MixedPositions() public {
        _skip();
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
        console2.log("  heap_size_before:", ctx.controller.settlementQueueSize());
        console2.log("  total_debt:", total);

        SettlementResult memory res = _settleLoop(ctx, _assetsToSupplyShares(ctx, total / 4));
        _logSettlementResult(res);
        console2.log("  heap_size:", ctx.controller.settlementQueueSize());
    }

    // ── Whale + dust
    // ───────────────────────────────────────────────

    function test_DustAndOneWhale100() public {
        _skip();
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

        console2.log("=== DustAndOneWhale100(99x0.3lowLTV+1x100whale) ===");
        console2.log("  heap_size_before:", ctx.controller.settlementQueueSize());

        SettlementResult memory res = _settleLoop(ctx, _assetsToSupplyShares(ctx, 75 ether));
        _logSettlementResult(res);

        (, uint128 whaleBorrowAfter, uint128 whaleColAfter) = ctx.market.position(ctx.id, _borrowerAddr(0));
        console2.log("  whale_debt_remaining:", uint256(whaleBorrowAfter));
        console2.log("  whale_col_remaining:", uint256(whaleColAfter));
        console2.log("  heap_size:", ctx.controller.settlementQueueSize());
        console2.log("  dust_positions_touched:", _countClosed(ctx, 1, n));
    }

    // ── Full drain
    // ─────────────────────────────────────────────────

    function test_2000DustFullDrain() public {
        _skip();
        Ctx memory ctx = _deployCtx();
        uint256 n = 2000;
        uint256 debtPer = 0.3 ether;
        _seedDustBorrowers(ctx, n, debtPer, 0.78e18);

        console2.log("=== 2000DustFullDrain ===");
        console2.log("  total_positions:", n);
        console2.log("  total_debt:", debtPer * n);
        console2.log("  heap_size_before:", ctx.controller.settlementQueueSize());

        uint256 totalTx;
        uint256 totalGas;
        uint256 totalIter;
        uint256 totalDebtDrained;

        while (true) {
            (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
            if (lenderShares == 0 || ctx.controller.settlementQueueSize() == 0) break;
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
        console2.log("  positions_remaining:", ctx.controller.settlementQueueSize());
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
        _logResult(ctx, label, debts.length, res);
    }

    function _runDustScenario(Ctx memory ctx, string memory label, uint256 n, uint256 debtPer, uint256 exitDivisor)
        internal
    {
        console2.log("===", label, "===");
        console2.log("  heap_size_before:", ctx.controller.settlementQueueSize());
        SettlementResult memory res = _settleLoop(ctx, _assetsToSupplyShares(ctx, debtPer * n / exitDivisor));
        console2.log("  borrowers:", n);
        _logSettlementResult(res);
        console2.log("  positions_closed:", _countClosed(ctx, 0, n));
        console2.log("  heap_size:", ctx.controller.settlementQueueSize());
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
            (,, uint128 col) = ctx.market.position(ctx.id, b);
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
        uint256 ethForCol = (requiredCol * _wstEthRate / 1e18) * 13 / 10;
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
        uint256 gasBefore = gasleft();

        for (uint256 i; i < MAX_ITERATIONS; ++i) {
            if (remaining == 0 || ctx.controller.settlementQueueSize() == 0) break;

            (address top, uint256 sliceAssets) = ctx.controller.nextSettlementCut();
            if (top == address(0)) break;
            (, uint128 topBorrowShares, uint128 topCol) = ctx.market.position(ctx.id, top);
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = ctx.market.market(ctx.id);

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

            vm.prank(LENDER);
            try ctx.market.settle(ctx.marketParams, 0, cutShares, LENDER, top, LENDER) returns (
                uint256 colSeized, uint256 debtCanceled
            ) {
                remaining -= cutShares;
                res.totalCollateralSeized += colSeized;
                res.totalDebtCanceled += debtCanceled;
                res.iterations++;
            } catch {
                if (cutShares > remaining / 2) cutShares = remaining / 2;
                if (cutShares == 0) break;
                vm.prank(LENDER);
                try ctx.market.settle(ctx.marketParams, 0, cutShares, LENDER, top, LENDER) returns (
                    uint256 colSeized, uint256 debtCanceled
                ) {
                    remaining -= cutShares;
                    res.totalCollateralSeized += colSeized;
                    res.totalDebtCanceled += debtCanceled;
                    res.iterations++;
                } catch {
                    break;
                }
            }
        }

        res.gasUsed = gasBefore - gasleft();
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
        console2.log("  heap_size:", ctx.controller.settlementQueueSize());
    }

    // ── Deployment
    // ─────────────────────────────────────────────────

    function _deployCtx() internal returns (Ctx memory ctx) {
        if (_wstEthRate == 0) _wstEthRate = WSTETH.stEthPerToken();

        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: WETH_ADDRESS,
                collateralToken: WSTETH_ADDRESS,
                oracleSource: WSTETH_ADDRESS,
                lltv: LLTV,
                enableSettlement: true,
                activation: ActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    delayPerStrike: 2 hours,
                    activatingHold: 0,
                    inflowDecayWindow: 4 hours,
                    maxDelayInflow: 10_000 ether,
                    minActivationAmount: uint128(MIN_COLLATERAL_ACTIVATION),
                    minDecayInflow: 1_000 ether
                }),
                slicePolicy: SlicePolicyConfig({sliceFloorBps: 100, sliceFloorAssets: 0, fallbackMinRequest: 0}),
                guardians: guardians,
                quorum: 1,
                vaultName: "Lido wstETH/WETH Vault",
                vaultSymbol: "lidoWSTETH-WETH"
            })
        );

        ctx.market = ILidoLend(d.core);
        ctx.oracle = ControllableWstEthOracle(d.oracle);
        ctx.controller = ILidoLendMarketController(d.controllerProxy);
        ctx.marketParams = d.params;
        ctx.id = d.marketId;
        ctx.price = ctx.oracle.price();

        ctx.controller.grantRole(ctx.controller.CONFIGURATOR_ROLE(), address(this));
        ctx.controller
            .setSlicePolicy(
                ILidoLendMarketController.SlicePolicy({
                    sliceFloorBps: 100, sliceFloorAssets: SLICE_FLOOR, fallbackMinRequest: 0
                })
            );
    }

    /// @dev Override the default `WstEthRateOracle` with a per-test controllable oracle so
    ///      benchmark scenarios can pin a known price (off the live wstETH rate).
    function _deployOracle(address oracleSource) internal override returns (address) {
        return address(new ControllableWstEthOracle(oracleSource));
    }

    // ── Helpers
    // ─────────────────────────────────────────────────────

    function _skip() internal {
        vm.skip(!_hasMainnet(), "mainnet fork required");
    }

    function _hasMainnet() internal view returns (bool) {
        return block.chainid == 1 && WETH_ADDRESS.code.length != 0 && WSTETH_ADDRESS.code.length != 0;
    }

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
            (, uint128 bs,) = ctx.market.position(ctx.id, _borrowerAddr(i));
            if (bs == 0) count++;
        }
    }

    function _countDust(Ctx memory ctx, uint256 from, uint256 to) internal view returns (uint256 count) {
        for (uint256 i = from; i < to; ++i) {
            (, uint128 bs, uint128 col) = ctx.market.position(ctx.id, _borrowerAddr(i));
            if (bs > 0 && col < uint128(DUST_THRESHOLD)) count++;
        }
    }

    function _collateralForDebt(uint256 debt, uint256 targetLTV, uint256 oraclePrice) internal pure returns (uint256) {
        return (debt * ORACLE_PRICE_SCALE) / (oraclePrice * targetLTV / 1e18);
    }

    function _assetsToSupplyShares(Ctx memory ctx, uint256 assets) internal view returns (uint256) {
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = ctx.market.market(ctx.id);
        return SharesMathLib.toSharesDown(assets, uint256(totalSupplyAssets), uint256(totalSupplyShares));
    }

    function _mintWETH(ILidoLend market, address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        WETH.deposit{value: amount}();
        vm.prank(user);
        WETH.approve(address(market), type(uint256).max);
    }

    function _mintWstETH(ILidoLend market, address user, uint256 ethAmount) internal returns (uint256) {
        uint256 wstETHAmount = (ethAmount * 1e18) / _wstEthRate;
        bytes32 balSlot = keccak256(abi.encode(user, uint256(0)));
        vm.store(WSTETH_ADDRESS, balSlot, bytes32(wstETHAmount));
        bytes32 allowSlot = keccak256(abi.encode(address(market), keccak256(abi.encode(user, uint256(1)))));
        vm.store(WSTETH_ADDRESS, allowSlot, bytes32(type(uint256).max));
        return wstETHAmount;
    }
}
