// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

import {MorphoBlueFork} from "../../src/MorphoBlueFork.sol";
import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {IDeleverageHeap} from "../../src/interfaces/IDeleverageHeap.sol";
import {AdaptiveCurveIrm} from "@morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {Id, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {Test, console2} from "forge-std/Test.sol";

interface IWETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function deposit() external payable;
}

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function wrap(uint256 stETHAmount) external returns (uint256);
}

interface IControllerDeleverageHeapAdmin {
    function CONFIGURATOR_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function setDeleverageHeap(address heap) external;
    function setDeleverageHeapConfig(Id id, IMarketController.DeleverageHeapConfig calldata cfg) external;
}

interface IOracle {
    function price() external view returns (uint256);
}

/// @notice Oracle that reads wstETH/stETH rate from the wstETH contract by default.
///         Calling setOverridePrice(p) switches to returning a fixed value instead.
///         Calling clearOverride() reverts to the live rate.
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

/// @title HeapDeleverageBenchmark
/// @notice Scenario test suite for heap-driven deleverage.
///         Each test seeds borrowers with a specific distribution, saturates the market,
///         then runs the deleverage loop and logs gas, iteration count, collateral
///         distribution, and dust positions.
contract HeapDeleverageBenchmark is Test {
    using MarketParamsLib for MarketParams;

    address internal constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    IWETH internal constant WETH = IWETH(WETH_ADDRESS);
    IStETH internal constant STETH = IStETH(STETH_ADDRESS);
    IWstETH internal constant WSTETH = IWstETH(WSTETH_ADDRESS);

    uint256 internal constant LLTV = 0.8e18;
    address internal constant LENDER = address(0x9000);

    uint256 internal constant MAX_ITERATIONS = 150;
    uint128 internal constant SLICE_FLOOR = 1 ether;
    uint128 internal constant DUST_THRESHOLD = 0.005 ether;
    uint256 internal constant MIN_COLLATERAL_ACTIVATION = 10e18;
    uint256 internal _wstEthRate;

    struct Ctx {
        MorphoBlueFork market;
        IMarketController controller;
        IDeleverageHeap heap;
        ControllableWstEthOracle oracle;
        MarketParams marketParams;
        Id id;
        uint256 price;
    }

    struct DeleverageResult {
        uint256 totalCollateralSeized;
        uint256 totalDebtCanceled;
        uint256 iterations;
        uint256 gasUsed;
    }

    // ── Scenarios ──────────────────────────────────────────────────

    function testScenario_AllSmallEqual() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 20;
        uint256[] memory debts = new uint256[](n);
        for (uint256 i; i < n; ++i) debts[i] = 0.5 ether;

        _runScenario(ctx, "AllSmallEqual(20x0.5)", debts, 0.7e18, debts[0] * n / 4);
    }

    function testScenario_AllLargeEqual() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 5;
        uint256[] memory debts = new uint256[](n);
        for (uint256 i; i < n; ++i) debts[i] = 10 ether;

        _runScenario(ctx, "AllLargeEqual(5x10)", debts, 0.7e18, debts[0] * n / 4);
    }

    function testScenario_MixedSmallAndLarge() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256[] memory debts = new uint256[](13);
        for (uint256 i; i < 10; ++i) debts[i] = 0.5 ether;
        debts[10] = 10 ether;
        debts[11] = 10 ether;
        debts[12] = 10 ether;

        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        _runScenario(ctx, "Mixed(10x0.5+3x10)", debts, 0.7e18, total / 4);
    }

    function testScenario_DustTailThenWhale() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256[] memory debts = new uint256[](11);
        for (uint256 i; i < 10; ++i) debts[i] = 0.1 ether;
        debts[10] = 40 ether;

        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        _runScenario(ctx, "DustTailThenWhale(10x0.1+1x40)", debts, 0.7e18, total / 4);
    }

    function testScenario_WhaleThenDustTail() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256[] memory debts = new uint256[](11);
        debts[0] = 40 ether;
        for (uint256 i = 1; i < 11; ++i) debts[i] = 0.1 ether;

        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        _runScenario(ctx, "WhaleThenDustTail(1x40+10x0.1)", debts, 0.7e18, total / 4);
    }

    function testScenario_TwoEqualWhalesAtTop() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256[] memory debts = new uint256[](5);
        debts[0] = 15 ether;
        debts[1] = 15 ether;
        debts[2] = 3 ether;
        debts[3] = 3 ether;
        debts[4] = 3 ether;

        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        _runScenario(ctx, "TwoEqualWhales(2x15+3x3)", debts, 0.7e18, total / 4);
    }

    function testScenario_GradientLTV() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256[] memory debts = new uint256[](10);
        uint256[] memory ltvFactors = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            debts[i] = 3 ether;
            ltvFactors[i] = 0.3e18 + (i * 0.045e18);
        }

        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        _runScenarioWithLTVs(ctx, "GradientLTV(10x3,LTV30-72%)", debts, ltvFactors, total / 4);
    }

    function testScenario_ClusterNearTop() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256[] memory debts = new uint256[](8);
        uint256[] memory ltvFactors = new uint256[](8);
        for (uint256 i; i < 5; ++i) {
            debts[i] = 5 ether;
            ltvFactors[i] = 0.69e18 + (i * 0.005e18);
        }
        for (uint256 i = 5; i < 8; ++i) {
            debts[i] = 5 ether;
            ltvFactors[i] = 0.4e18;
        }

        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        _runScenarioWithLTVs(ctx, "ClusterNearTop(5@69-71%+3@40%)", debts, ltvFactors, total / 4);
    }

    function testScenario_SmallExitLargePool() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 10;
        uint256[] memory debts = new uint256[](n);
        for (uint256 i; i < n; ++i) debts[i] = 5 ether;

        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        _runScenario(ctx, "SmallExit1%(10x5)", debts, 0.7e18, total / 100);
    }

    function testScenario_LargeExit50Pct() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 10;
        uint256[] memory debts = new uint256[](n);
        for (uint256 i; i < n; ++i) debts[i] = 5 ether;

        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        _runScenario(ctx, "LargeExit50%(10x5)", debts, 0.7e18, total / 2);
    }

    function testScenario_SerialSmallExits() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 10;
        uint256[] memory debts = new uint256[](n);
        for (uint256 i; i < n; ++i) debts[i] = 5 ether;
        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];

        uint256 totalSupply = total;
        _seedBorrowers(ctx, debts, 0.7e18, totalSupply);

        uint256 exitPerRound = total / 10;
        console2.log("=== SerialSmallExits(10x5%x10rounds) ===");

        for (uint256 round; round < 10; ++round) {
            (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
            if (lenderShares == 0) break;

            uint256 roundShares = _assetsToSupplyShares(ctx, exitPerRound);
            if (roundShares > lenderShares) roundShares = lenderShares;
            if (roundShares == 0) break;

            DeleverageResult memory res = _deleverageLoop(ctx, roundShares);
            console2.log("  round", round, "iter", res.iterations);
            console2.log("    debt_canceled", res.totalDebtCanceled);
            console2.log("    gas", res.gasUsed);
        }

        _logPositions(ctx, debts.length);
    }

    function testScenario_100DustPositions() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 100;
        uint256 debtPerBorrower = 0.3 ether;
        uint256 totalDebt = debtPerBorrower * n;

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
            address b = _borrowerAddr(i);
            vm.prank(b);
            ctx.market.borrow(ctx.marketParams, debtPerBorrower, 0, b, b);
        }

        for (uint256 i; i < n; ++i) {
            address b = _borrowerAddr(i);
            (,, uint128 col) = ctx.market.position(ctx.id, b);
            uint256 minCol = _collateralForDebt(debtPerBorrower, 0.78e18, ctx.price);
            uint256 toWithdraw = uint256(col) - minCol;
            if (toWithdraw > 0) {
                vm.prank(b);
                ctx.market.withdrawCollateral(ctx.marketParams, toWithdraw, b, b);
            }
        }

        console2.log("=== 100DustPositions(100x0.3@~78%LTV) ===");
        console2.log("  heap_size_before:", ctx.heap.size());

        uint256 exitShares = _assetsToSupplyShares(ctx, totalDebt / 4);
        DeleverageResult memory res = _deleverageLoop(ctx, exitShares);

        console2.log("  borrowers:", n);
        console2.log("  iterations:", res.iterations);
        console2.log("  total_debt_canceled:", res.totalDebtCanceled);
        console2.log("  total_col_seized:", res.totalCollateralSeized);
        console2.log("  gas_used:", res.gasUsed);
        _logPositions(ctx, n);
    }

    function testScenario_1000DustPositions() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 1000;
        uint256 debtPerBorrower = 0.3 ether;
        uint256 totalDebt = debtPerBorrower * n;

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
            address b = _borrowerAddr(i);
            vm.prank(b);
            ctx.market.borrow(ctx.marketParams, debtPerBorrower, 0, b, b);
        }

        for (uint256 i; i < n; ++i) {
            address b = _borrowerAddr(i);
            (,, uint128 col) = ctx.market.position(ctx.id, b);
            uint256 minCol = _collateralForDebt(debtPerBorrower, 0.78e18, ctx.price);
            uint256 toWithdraw = uint256(col) - minCol;
            if (toWithdraw > 0) {
                vm.prank(b);
                ctx.market.withdrawCollateral(ctx.marketParams, toWithdraw, b, b);
            }
        }

        console2.log("=== 1000DustPositions(1000x0.3@~78%LTV) ===");
        console2.log("  heap_size_before:", ctx.heap.size());

        uint256 exitShares = _assetsToSupplyShares(ctx, totalDebt / 4);
        DeleverageResult memory res = _deleverageLoop(ctx, exitShares);

        console2.log("  borrowers:", n);
        console2.log("  iterations:", res.iterations);
        console2.log("  total_debt_canceled:", res.totalDebtCanceled);
        console2.log("  total_col_seized:", res.totalCollateralSeized);
        console2.log("  gas_used:", res.gasUsed);

        uint256 dustCount;
        for (uint256 i; i < n; ++i) {
            address b = _borrowerAddr(i);
            (, uint128 bShares,) = ctx.market.position(ctx.id, b);
            if (bShares == 0) dustCount++;
        }
        console2.log("  positions_closed:", dustCount);
        console2.log("  heap_size:", ctx.heap.size());
    }

    function testScenario_1000MixedPositions() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 1000;
        uint256 totalDebt;
        uint256[] memory debts = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            if (i < 900) {
                debts[i] = 0.5 ether;
            } else if (i < 990) {
                debts[i] = 5 ether;
            } else {
                debts[i] = 20 ether;
            }
            totalDebt += debts[i];
        }

        _mintWETH(ctx.market, LENDER, totalDebt);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, totalDebt, 0, LENDER, "");

        for (uint256 i; i < n; ++i) {
            address b = _borrowerAddr(i);
            uint256 requiredCol = _collateralForDebt(debts[i], 0.7e18, ctx.price);
            uint256 ethForCol = (requiredCol * _wstEthRate / 1e18) * 13 / 10;
            if (ethForCol < 15 ether) ethForCol = 15 ether;
            uint256 col = _mintWstETH(ctx.market, b, ethForCol);
            vm.prank(b);
            ctx.market.supplyCollateral(ctx.marketParams, col, b, "");
        }

        vm.warp(block.timestamp + 2 hours + 1);

        for (uint256 i; i < n; ++i) {
            address b = _borrowerAddr(i);
            vm.prank(b);
            ctx.market.borrow(ctx.marketParams, debts[i], 0, b, b);
        }

        console2.log("=== 1000Mixed(900x0.5+90x5+10x20) ===");
        console2.log("  heap_size_before:", ctx.heap.size());
        console2.log("  total_debt:", totalDebt);

        uint256 exitShares = _assetsToSupplyShares(ctx, totalDebt / 4);
        DeleverageResult memory res = _deleverageLoop(ctx, exitShares);

        console2.log("  iterations:", res.iterations);
        console2.log("  total_debt_canceled:", res.totalDebtCanceled);
        console2.log("  gas_used:", res.gasUsed);
        console2.log("  heap_size:", ctx.heap.size());
    }

    function testScenario_DustAndOneWhale100() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 100;
        uint256 dustDebt = 0.3 ether;
        uint256 whaleDebt = 100 ether;
        uint256 totalDebt = dustDebt * (n - 1) + whaleDebt;

        _mintWETH(ctx.market, LENDER, totalDebt);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, totalDebt, 0, LENDER, "");

        // Whale at index 0
        {
            address whale = _borrowerAddr(0);
            uint256 requiredCol = _collateralForDebt(whaleDebt, 0.7e18, ctx.price);
            uint256 rate = WSTETH.stEthPerToken();
            uint256 ethForCol = (requiredCol * rate / 1e18) * 13 / 10;
            uint256 col = _mintWstETH(ctx.market, whale, ethForCol);
            vm.prank(whale);
            ctx.market.supplyCollateral(ctx.marketParams, col, whale, "");
        }

        // Dust positions
        for (uint256 i = 1; i < n; ++i) {
            address b = _borrowerAddr(i);
            uint256 col = _mintWstETH(ctx.market, b, 15 ether);
            vm.prank(b);
            ctx.market.supplyCollateral(ctx.marketParams, col, b, "");
        }

        vm.warp(block.timestamp + 2 hours + 1);

        vm.prank(_borrowerAddr(0));
        ctx.market.borrow(ctx.marketParams, whaleDebt, 0, _borrowerAddr(0), _borrowerAddr(0));
        for (uint256 i = 1; i < n; ++i) {
            address b = _borrowerAddr(i);
            vm.prank(b);
            ctx.market.borrow(ctx.marketParams, dustDebt, 0, b, b);
        }

        console2.log("=== DustAndOneWhale100(99x0.3lowLTV+1x100whale) ===");
        console2.log("  heap_size_before:", ctx.heap.size());

        // Exit 75 ETH — should come entirely from the whale
        uint256 exitShares = _assetsToSupplyShares(ctx, 75 ether);
        DeleverageResult memory res = _deleverageLoop(ctx, exitShares);

        (, uint128 whaleBorrowAfter, uint128 whaleColAfter) = ctx.market.position(ctx.id, _borrowerAddr(0));

        console2.log("  iterations:", res.iterations);
        console2.log("  total_debt_canceled:", res.totalDebtCanceled);
        console2.log("  total_col_seized:", res.totalCollateralSeized);
        console2.log("  gas_used:", res.gasUsed);
        console2.log("  whale_debt_remaining:", uint256(whaleBorrowAfter));
        console2.log("  whale_col_remaining:", uint256(whaleColAfter));
        console2.log("  heap_size:", ctx.heap.size());

        // Verify dust positions untouched
        uint256 dustTouched;
        for (uint256 i = 1; i < n; ++i) {
            (, uint128 bs,) = ctx.market.position(ctx.id, _borrowerAddr(i));
            if (bs == 0) dustTouched++;
        }
        console2.log("  dust_positions_touched:", dustTouched);
    }

    function testScenario_2000DustFullDrain() public {
        vm.skip(!_hasMainnet(), "mainnet fork required");
        Ctx memory ctx = _deployCtx();

        uint256 n = 2000;
        uint256 debtPerBorrower = 0.3 ether;
        uint256 totalDebt = debtPerBorrower * n; // 6000 ETH

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
            address b = _borrowerAddr(i);
            vm.prank(b);
            ctx.market.borrow(ctx.marketParams, debtPerBorrower, 0, b, b);
        }

        for (uint256 i; i < n; ++i) {
            address b = _borrowerAddr(i);
            (,, uint128 col) = ctx.market.position(ctx.id, b);
            uint256 minCol = _collateralForDebt(debtPerBorrower, 0.78e18, ctx.price);
            uint256 toWithdraw = uint256(col) - minCol;
            if (toWithdraw > 0) {
                vm.prank(b);
                ctx.market.withdrawCollateral(ctx.marketParams, toWithdraw, b, b);
            }
        }

        console2.log("=== 2000DustFullDrain ===");
        console2.log("  total_positions:", n);
        console2.log("  total_debt:", totalDebt);
        console2.log("  heap_size_before:", ctx.heap.size());

        // Drain fully in multiple rounds
        uint256 totalTx;
        uint256 totalGas;
        uint256 totalClosed;
        uint256 totalDebtDrained;

        while (true) {
            (uint256 lenderShares,,) = ctx.market.position(ctx.id, LENDER);
            if (lenderShares == 0) break;
            if (ctx.heap.size() == 0) break;

            DeleverageResult memory res = _deleverageLoop(ctx, lenderShares);
            totalTx++;
            totalGas += res.gasUsed;
            totalDebtDrained += res.totalDebtCanceled;

            if (res.iterations == 0) break;
            totalClosed += res.iterations;

            console2.log("  tx", totalTx, "iter", res.iterations);
            console2.log("    debt", res.totalDebtCanceled, "gas", res.gasUsed);
        }

        console2.log("  --- TOTALS ---");
        console2.log("  transactions:", totalTx);
        console2.log("  total_iterations:", totalClosed);
        console2.log("  total_debt_drained:", totalDebtDrained);
        console2.log("  total_gas:", totalGas);
        console2.log("  positions_remaining:", ctx.heap.size());
    }

    // ── Core runner ────────────────────────────────────────────────

    function _runScenario(
        Ctx memory ctx,
        string memory label,
        uint256[] memory debts,
        uint256 uniformLTV,
        uint256 exitAssets
    ) internal {
        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        uint256 totalSupply = total;

        _seedBorrowers(ctx, debts, uniformLTV, totalSupply);

        uint256 exitShares = _assetsToSupplyShares(ctx, exitAssets);
        DeleverageResult memory res = _deleverageLoop(ctx, exitShares);

        _logResult(ctx, label, debts.length, res);
    }

    function _runScenarioWithLTVs(
        Ctx memory ctx,
        string memory label,
        uint256[] memory debts,
        uint256[] memory ltvFactors,
        uint256 exitAssets
    ) internal {
        uint256 total;
        for (uint256 i; i < debts.length; ++i) total += debts[i];
        uint256 totalSupply = total;

        _seedBorrowersWithLTVs(ctx, debts, ltvFactors, totalSupply);

        uint256 exitShares = _assetsToSupplyShares(ctx, exitAssets);
        DeleverageResult memory res = _deleverageLoop(ctx, exitShares);

        _logResult(ctx, label, debts.length, res);
    }

    // ── Seeding ────────────────────────────────────────────────────

    function _seedBorrowers(Ctx memory ctx, uint256[] memory debts, uint256 uniformLTV, uint256 totalSupply) internal {
        uint256[] memory ltvs = new uint256[](debts.length);
        for (uint256 i; i < debts.length; ++i) ltvs[i] = uniformLTV;
        _seedBorrowersWithLTVs(ctx, debts, ltvs, totalSupply);
    }

    function _seedBorrowersWithLTVs(
        Ctx memory ctx,
        uint256[] memory debts,
        uint256[] memory ltvs,
        uint256 totalSupply
    ) internal {
        _mintWETH(ctx.market, LENDER, totalSupply);
        vm.prank(LENDER);
        ctx.market.supply(ctx.marketParams, totalSupply, 0, LENDER, "");

        for (uint256 i; i < debts.length; ++i) {
            address borrower = _borrowerAddr(i);
            uint256 requiredCol = _collateralForDebt(debts[i], ltvs[i], ctx.price);
            uint256 ethForCol = (requiredCol * 1.3e18) / 1e18;
            if (ethForCol < 15 ether) ethForCol = 15 ether;

            uint256 col = _mintWstETH(ctx.market, borrower, ethForCol);
            vm.prank(borrower);
            ctx.market.supplyCollateral(ctx.marketParams, col, borrower, "");
        }

        vm.warp(block.timestamp + 2 hours + 1);

        for (uint256 i; i < debts.length; ++i) {
            address borrower = _borrowerAddr(i);
            vm.prank(borrower);
            ctx.market.borrow(ctx.marketParams, debts[i], 0, borrower, borrower);
        }
    }

    // ── Deleverage loop (simulates vault's _deleverageFromHeap) ───

    function _deleverageLoop(Ctx memory ctx, uint256 exitShares)
        internal
        returns (DeleverageResult memory res)
    {
        uint256 remaining = exitShares;
        uint256 gasBefore = gasleft();

        for (uint256 i; i < MAX_ITERATIONS; ++i) {
            if (remaining == 0) break;
            if (ctx.heap.size() == 0) break;

            (address top, uint256 topKey) = ctx.heap.peek();

            (, uint128 topBorrowShares, uint128 topCol) = ctx.market.position(ctx.id, top);
            (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = ctx.market.market(ctx.id);

            uint256 sliceAssets = _computeSlice(ctx, top, topKey);
            uint256 sliceCol = sliceAssets * 1e36 / ctx.price;

            uint256 cutShares;
            if (uint256(topCol) - _min(sliceCol, uint256(topCol)) < MIN_COLLATERAL_ACTIVATION) {
                cutShares = uint256(topBorrowShares);
            } else {
                cutShares = (sliceAssets * (uint256(totalBorrowShares) + 1e6)) / (uint256(totalBorrowAssets) + 1);
                if (cutShares == 0) cutShares = 1;
            }
            if (cutShares > remaining) cutShares = remaining;

            vm.prank(LENDER);
            try ctx.market.deleverage(ctx.marketParams, cutShares, top, LENDER, LENDER) returns (
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
                try ctx.market.deleverage(ctx.marketParams, cutShares, top, LENDER, LENDER) returns (
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

    // ── Logging ────────────────────────────────────────────────────

    function _logResult(Ctx memory ctx, string memory label, uint256 borrowerCount, DeleverageResult memory res)
        internal
        view
    {
        console2.log("===", label, "===");
        console2.log("  borrowers:", borrowerCount);
        console2.log("  iterations:", res.iterations);
        console2.log("  total_debt_canceled:", res.totalDebtCanceled);
        console2.log("  total_col_seized:", res.totalCollateralSeized);
        console2.log("  gas_used:", res.gasUsed);

        _logPositions(ctx, borrowerCount);
    }

    function _logPositions(Ctx memory ctx, uint256 borrowerCount) internal view {
        uint256 dustCount;
        for (uint256 i; i < borrowerCount; ++i) {
            address b = _borrowerAddr(i);
            (, uint128 bShares, uint128 col) = ctx.market.position(ctx.id, b);
            if (bShares > 0 && col < uint128(DUST_THRESHOLD)) dustCount++;
        }
        console2.log("  dust_positions:", dustCount);
        console2.log("  heap_size:", ctx.heap.size());
    }

    // ── Deployment ─────────────────────────────────────────────────

    function _deployCtx() internal returns (Ctx memory ctx) {
        if (_wstEthRate == 0) _wstEthRate = WSTETH.stEthPerToken();
        ctx.market = new MorphoBlueFork(address(this));
        ctx.oracle = new ControllableWstEthOracle(WSTETH_ADDRESS);
        AdaptiveCurveIrm irm = new AdaptiveCurveIrm(address(ctx.market));

        ctx.marketParams = MarketParams({
            loanToken: WETH_ADDRESS,
            collateralToken: WSTETH_ADDRESS,
            oracle: address(ctx.oracle),
            irm: address(irm),
            lltv: LLTV
        });
        ctx.id = ctx.marketParams.id();
        ctx.price = ctx.oracle.price();

        address accessRegistry =
            _deployArtifact("MarketAccessRegistry.sol:MarketAccessRegistry", abi.encode(address(this)));
        address impl = _deployArtifact("LidoMarketController.sol:LidoMarketController", "");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)",
            address(ctx.market),
            Id.unwrap(ctx.id),
            accessRegistry,
            address(this)
        );
        address proxy =
            _deployArtifact("OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, address(this), initData));
        IControllerDeleverageHeapAdmin admin = IControllerDeleverageHeapAdmin(proxy);
        admin.grantRole(admin.CONFIGURATOR_ROLE(), address(this));
        address heapAddr = _deployArtifact("DeleverageHeap.sol:DeleverageHeap", abi.encode(proxy));
        admin.setDeleverageHeap(heapAddr);
        admin.setDeleverageHeapConfig(
            ctx.id,
            IMarketController.DeleverageHeapConfig({
                sliceFloorAssets: SLICE_FLOOR,
                maxIterations: uint32(MAX_ITERATIONS),
                dustDebtThreshold: DUST_THRESHOLD
            })
        );

        ctx.controller = IMarketController(proxy);
        ctx.heap = IDeleverageHeap(heapAddr);

        ctx.market.enableIrm(address(irm));
        ctx.market.enableLltv(LLTV);
        ctx.market.createMarket(ctx.marketParams, proxy, true);
    }

    // ── Helpers ─────────────────────────────────────────────────────

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _borrowSharesToAssets(uint128 shares, uint128 totalAssets, uint128 totalShares)
        internal
        pure
        returns (uint256)
    {
        return (uint256(shares) * (uint256(totalAssets) + 1)) / (uint256(totalShares) + 1e6);
    }

    function _computeSlice(Ctx memory ctx, address top, uint256 topKey) internal view returns (uint256) {
        uint256 runnerUpKey = ctx.heap.rootRunnerUpKey();
        if (runnerUpKey == 0 || runnerUpKey >= topKey) return uint256(SLICE_FLOOR);

        (,, uint128 topCol) = ctx.market.position(ctx.id, top);
        if (topCol == 0) return uint256(SLICE_FLOOR);

        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = ctx.market.market(ctx.id);
        if (totalBorrowAssets == 0 || totalBorrowShares == 0) return uint256(SLICE_FLOOR);

        uint256 collateralPrice = ctx.oracle.price();
        if (collateralPrice == 0) return uint256(SLICE_FLOOR);

        uint256 numerator = (topKey - runnerUpKey) * uint256(topCol);
        uint256 denomT1 = (uint256(totalBorrowShares) * 1e18) / uint256(totalBorrowAssets);
        uint256 denomT2 = (runnerUpKey * 1e36) / collateralPrice;
        if (denomT1 <= denomT2) return uint256(SLICE_FLOOR);

        uint256 d = numerator / (denomT1 - denomT2);
        d += uint256(SLICE_FLOOR);
        return d;
    }

    function _borrowerAddr(uint256 i) internal pure returns (address) {
        return address(uint160(0x2000 + i));
    }

    function _collateralForDebt(uint256 debt, uint256 targetLTV, uint256 price) internal pure returns (uint256) {
        return (debt * 1e36) / (price * targetLTV / 1e18);
    }

    function _assetsToSupplyShares(Ctx memory ctx, uint256 assets) internal view returns (uint256) {
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = ctx.market.market(ctx.id);
        return (assets * (uint256(totalSupplyShares) + 1e6)) / (uint256(totalSupplyAssets) + 1);
    }

    function _mintWETH(MorphoBlueFork market, address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        WETH.deposit{value: amount}();
        vm.prank(user);
        WETH.approve(address(market), type(uint256).max);
    }

    function _mintWstETH(MorphoBlueFork market, address user, uint256 ethAmount) internal returns (uint256) {
        uint256 wstETHAmount = (ethAmount * 1e18) / _wstEthRate;
        // balanceOf slot: _balances mapping at slot 0
        bytes32 balSlot = keccak256(abi.encode(user, uint256(0)));
        vm.store(WSTETH_ADDRESS, balSlot, bytes32(wstETHAmount));
        // allowance slot: _allowances mapping at slot 1, allowances[owner][spender]
        bytes32 allowSlot = keccak256(abi.encode(address(market), keccak256(abi.encode(user, uint256(1)))));
        vm.store(WSTETH_ADDRESS, allowSlot, bytes32(type(uint256).max));
        return wstETHAmount;
    }

    function _deployArtifact(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory bytecode = vm.getCode(artifact);
        bytes memory creationCode = bytes.concat(bytecode, args);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "artifact deploy failed");
    }

    function _hasMainnet() internal view returns (bool) {
        return block.chainid == 1 && WETH_ADDRESS.code.length != 0 && STETH_ADDRESS.code.length != 0
            && WSTETH_ADDRESS.code.length != 0;
    }
}
