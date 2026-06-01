# Heap Deleverage Benchmark Results

Binary max-heap implementation.

## Algorithm

Each fallback-exit call iterates the heap up to `maxIterations` times:

1. Compute slice: how much to cut so the top borrower's key drops to the runner-up's key, plus a fixed constant. This is the cut size.
2. Estimate remaining collateral after the cut. If it would drop below `minCollateralActivation` (10 wstETH) — close the position entirely instead of a partial cut.
3. Execute the cut, heap re-sorts, repeat.

`cut = gap_to_runner_up + constant`

When positions are equal (gap = 0), cut = constant.

Slice floor (the constant) is enforced in the vault/loop as a minimum cut size, not in the controller. The controller only enforces eligibility, over-cap, and full-close logic. This allows the lender's tail exit (remaining < constant) to complete without being blocked.

## Parameters

| Parameter | Value | Role |
|---|---|---|
| `maxIterations` | 150 | Max cuts per transaction |
| `sliceFloor` (constant) | 1 ETH | Added to gap; minimum cut size (enforced in vault/loop) |
| `dustDebtThreshold` | 0.005 ETH | Allows sub-floor final cut to clean up borrower dust |
| `minCollateralActivation` | 10 wstETH | Remaining collateral below this triggers full position close |
| `LLTV` | 80% | Market max LTV |

## Scenario Results

Exit target is 25% of total supply unless noted otherwise.

| Scenario | Borrowers | Iter | Debt Canceled | Target | Coverage | Gas |
|---|---|---|---|---|---|---|
| DustTailThenWhale (10x0.1 + 1x40) | 11 | 1 | 10.25 ETH | 10.25 ETH | 100% | 93k |
| WhaleThenDustTail (1x40 + 10x0.1) | 11 | 1 | 10.25 ETH | 10.25 ETH | 100% | 93k |
| DustAndOneWhale (99xLowLTV + 1x100) | 100 | 1 | 75 ETH | 75 ETH | 100% | 94k |
| SmallExit 1% (10x5) | 10 | 1 | 0.5 ETH | 0.5 ETH | 100% | 92k |
| Mixed (10x0.5 + 3x10) | 13 | 5 | 8.75 ETH | 8.75 ETH | 100% | 374k |
| TwoEqualWhales (2x15 + 3x3) | 5 | 6 | 9.75 ETH | 9.75 ETH | 100% | 458k |
| GradientLTV (10x3, LTV 30-72%) | 10 | 8 | 7.5 ETH | 7.5 ETH | 100% | 560k |
| AllLargeEqual (5x10) | 5 | 9 | 12.5 ETH | 12.5 ETH | 100% | 626k |
| ClusterNearTop (5@69-71% + 3@40%) | 8 | 9 | 10 ETH | 10 ETH | 100% | 628k |
| LargeExit 50% (10x5) | 10 | 20 | 25 ETH | 25 ETH | 100% | 1.4M |
| 1000 Dust (1000x0.3 @78% LTV) | 1000 | 150 | 45 ETH | 75 ETH | 60% | 9.2M |
| 1000 Mixed (900x0.5 + 90x5 + 10x20) | 1000 | 150 | 161 ETH | 275 ETH | 59% | 12.5M |

Notes:
- AllSmallEqual (20x0.5 ETH, 15 wstETH collateral each) — 0 iterations. The constant (1 ETH) exceeds each borrower's total debt (0.5 ETH), so the computed cut overshoots the position. These positions have large collateral (above min activation) so the full-close path does not apply. The constant should be tuned to market scale.

## Full Drain Test

2000 dust positions (0.3 ETH debt each, ~78% LTV), full drain of 600 ETH supply:

| Metric | Value |
|---|---|
| Transactions | 14 |
| Total iterations | 2000 (one per position) |
| Iterations per tx | 150 (last tx: 50) |
| Gas per tx | ~9.3M |
| Total gas | 125M |
| Positions remaining | 0 |

Each transaction closes 150 positions via the full-close path. For 20000 positions: ~134 transactions (linear).

## Key Observations

- **Whale-dominant**: 1 iteration covers the entire exit. Heap correctly targets the highest debt/collateral ratio regardless of how many small positions exist. 99 low-LTV dust positions stay untouched.
- **Equal large positions**: the constant (1 ETH) sets the pace. Positions that would drop below 10 wstETH collateral after a cut are closed entirely.
- **Tail exits**: when the lender's remaining exit is less than the constant, the cut is smaller than the constant. This is allowed because slice floor is enforced in the vault/loop, not in the controller.
- **Dust positions**: full-close path, 1 position per iteration. 150 positions per transaction at ~9.3M gas.
- **Gas per iteration**: ~60k for full-close, ~70k for slice-math cuts on large positions.
- **Block gas limit**: ~9.3M per 150 iterations, well within the 30M block limit.
