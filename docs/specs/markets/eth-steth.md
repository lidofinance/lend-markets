# WETH / wstETH Market

Borrow **WETH** against **wstETH** collateral. The market uses the shared controller, guardian, collateral-activation, vault, freeze, and pause mechanisms described in [Architecture](../architecture.md). Lender settlement is available but is enabled or disabled when governance creates the market.

## Configuration source

The values below mirror the committed [market configuration](../../../script/config/markets/weth-wsteth.toml) and [guardian-group configuration](../../../script/config/guardians/weth-wsteth.toml). The configuration marks its economic values as draft. A deployed market's immutable artifact is authoritative for that deployment.

### Market

| Field | Draft value |
|---|---|
| Loan token | WETH, `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| Collateral token | wstETH, `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |
| Oracle | `WstEthRateOracle`, resolved from the `weth-wsteth` oracle artifact |
| IRM | `IrmRouter` routed to `AdaptiveCurveIrm` |
| LLTV | 80% (`0.8 WAD`) |
| Supply cap | `0`, which means uncapped until governance sets one |
| Vault | `Lido wstETH/WETH Vault` (`lidoWSTETH-WETH`) |
| Guardian group | `weth-wsteth` |
| Settlement enablement | Runtime activation choice; not fixed by the committed market configuration |

### Collateral activation

| Field | Draft value |
|---|---|
| Minimum activation delay | 10 minutes |
| Maximum activation delay | 2 hours |
| Inflow at maximum delay | 10,000 wstETH |
| Minimum activation amount | 10 wstETH |
| Activating lock amount / duration | 0 / 0 |
| Delay per guardian strike | 2 hours |
| Delay per suspect report | 0 |
| Guardian-quorum fallback delay | 0, which disables the frontier wait |

The committed guardian-group template sets quorum to 1 and the suspect window to 0. Its guardian address list is empty; a concrete deployment must supply its committee addresses.

### Settlement

| Field | Draft value |
|---|---|
| Debt-fraction floor | 1% (`sliceFloorBps = 100`) |
| Absolute asset floor | 0 |
| Full settlement below remaining collateral | 10 wstETH |
| LTV reduction step | 1 percentage point (`ltvStepBps = 100`) |

### Adaptive interest-rate model

| Field | Draft value |
|---|---|
| Target utilization | 90% |
| Curve steepness | 4× |
| Adjustment speed | `50 WAD / 365 days` |
| Initial rate at target | approximately 4% per year |
| Minimum rate at target | approximately 0.1% per year |
| Maximum rate at target | approximately 200% per year |
| Maximum borrow-rate ceiling | 0, which disables the ceiling |

## Oracle: `WstEthRateOracle`

The oracle quotes wstETH in ETH from Lido's onchain accounting rate. WETH is the onchain loan token, and the market treats one WETH as one ETH unit. The oracle therefore needs no separate WETH conversion.

```text
price() = getStETHByWstETH(1e36)
```

The result is ETH per wstETH at the core oracle scale of `1e36`. Querying `getStETHByWstETH` with `1e36` preserves more low-order precision than reading a `1e18` rate and scaling it afterward.

> **Example.** If 1 wstETH is backed by 1.15 stETH, `price()` returns `1.15e36` and the market values 1 wstETH at 1.15 WETH.

The accounting rate normally increases as staking rewards accrue and can decrease if Lido recognizes losses such as slashing. The [oracle API](../api/wst-eth-rate-oracle.md) defines the exact callable surface.

> [!WARNING]
> **Accepted oracle-basis risk.** The oracle assumes stETH/ETH parity and does not include a secondary-market price. During a depeg or a fast impairment, the market may therefore value wstETH above the amount that can be realized by selling it, making ordinary liquidation or settlement unsafe. ADR 009 explains the selected price source.

## Liquidation and settlement

Ordinary unhealthy positions use the inherited Morpho liquidation path. If governance enables settlement when creating the market, the shared [lender-settlement paths](../lender-settlement.md) may instead cancel debt at par and transfer wstETH collateral to the selected receiver. No dedicated stETH-liquidity facility, AMM, or backstop is included in the design; see ADR 011 and ADR 013.

## Fast collateral depreciation

A sudden accounting-rate loss, oracle compromise, or failure in the collateral system is not handled only as an ordinary liquidation case. The immediate response is a controller **pause**, because [freeze deliberately leaves liquidation and settlement available](../market-controller.md#freeze-and-pause). Detection and response are operational.
