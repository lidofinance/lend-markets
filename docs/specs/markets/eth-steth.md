# ETH / wstETH Market

Borrow **WETH** against **wstETH** collateral. The market runs the shared stack unchanged — controller, guardian signals, collateral activation, settlement queue, vault, freeze/pause — described in [architecture.md](../architecture.md). Only the oracle, the deposit gateway, the liquidation path, and the risk parameters are market-specific.

## Parameters

| Field | Value |
|---|---|
| Loan token | WETH |
| Collateral token | wstETH |
| Oracle | `WstEthRateOracle` |
| IRM | `AdaptiveCurveIrm` |
| LLTV | set at market creation (governance parameter) |

## Oracle — WstEthRateOracle

wstETH is priced by its **on-chain accounting rate**, not a market price. stETH is valued at par to ETH, so 1 wstETH is worth its wstETH→stETH rate in ETH.

```
price() = getStETHByWstETH(1e36)        // ETH per wstETH, at ORACLE_PRICE_SCALE = 1e36
```

Querying at the `1e36` input keeps the rate's low-order digits, rather than flooring `stEthPerToken()` at `1e18` and then scaling.

> **Example.** 1 wstETH backed by 1.15 stETH → `price() = 1.15e36`: 1 wstETH ≈ 1.15 ETH.

The rate rises monotonically as staking rewards accrue. It does **not** reflect a stETH/ETH market depeg. Depeg and slashing risk are handled by the activation delay, freeze, and the fast-depreciation response below — not by the price feed (ADR 009).

## Deposit gateway

`LidoLendDepositGateway` is a stateless convenience zap, so users need not pre-wrap:

- `supplyCollateralWithStEth(stEthAmount, onBehalf)` — wrap stETH → wstETH, post as collateral.
- `supplyWithEth(onBehalf)` / `supplyWithWeth(wethAmount, onBehalf)` — supply the loan side.
- `depositEthToVault(receiver)` / `depositWethToVault(wethAmount, receiver)` — deposit into the vault.

It holds no funds between calls and routes through the core and the vault.

## Liquidation

- **Morpho liquidation** — the inherited path for ordinary unhealthy positions.
- **Lender self-liquidation** — a lender settles an unhealthy borrower through its own lending position (the settlement queue), only when pool liquidity is exhausted and the position is **not** bad debt (ADR 013).

No dedicated stETH-liquidity facility (no AMM, no backstop) is included (ADR 011).

## Fast collateral depreciation

A sudden wstETH value drop (slashing, oracle compromise, bridge hack) is not a normal liquidation case. The response is a **freeze**, followed by an operational incident response.

