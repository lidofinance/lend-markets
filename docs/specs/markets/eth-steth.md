# WETH / wstETH Market

This market lets borrowers borrow **WETH** against **wstETH** collateral. It uses the shared [architecture](../architecture.md), [controller policy](../market-controller.md), and lender-settlement mechanisms.

## Parameters

| Field | Value |
|---|---|
| Loan token | WETH |
| Collateral token | wstETH |
| Oracle | `WstEthRateOracle` |
| Interest-rate model | Governance-selected through `IrmRouter` |
| Liquidation loan-to-value threshold | Selected by governance and fixed when the market is created |
| Lender settlement | Enabled or disabled when the market is created |

Market lending and collateral flows transfer WETH and wstETH. Converting between ETH and WETH, or between stETH and wstETH, is a separate user or adapter action.

## Oracle

`WstEthRateOracle` values one wstETH in WETH from the amount of stETH that backs it, assuming one stETH equals one ETH:

```text
price() = getStETHByWstETH(1e36)
```

The result uses the core oracle scale of `1e36`.

> **Example.** If 1 wstETH is backed by 1.15 stETH, the oracle values it at 1.15 WETH and returns `1.15e36`.

The accounting rate normally rises with staking rewards but can decrease when Lido recognizes losses.

> [!WARNING]
> The oracle does not use a secondary-market stETH/ETH price. A depeg that does not reduce the accounting rate can therefore make the protocol overvalue wstETH. Liquidation may become uneconomic, and settlement may transfer collateral whose realizable value is below the debt canceled. Collateral activation and freeze do not correct this price-basis gap.

## Liquidation and lender settlement

Ordinary unhealthy positions use the inherited core liquidation path. If lender settlement was enabled at market creation, its collateral leg transfers wstETH to the selected receiver using the same accounting-rate oracle. The shared rules are described in [Settlement and Lender Exits](../lender-settlement.md).

The current v1 design adds no dedicated stETH liquidity facility or protocol liquidity backstop.

## Fast collateral depreciation

A fast market-value loss or compromise of the accounting-rate source can make the reported price unsuitable for ordinary liquidation or settlement. A controller pause blocks both paths; freeze does not.

The contracts do not detect such an incident. Detection and response are operational.
