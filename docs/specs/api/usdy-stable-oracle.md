<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# UsdyStableOracle

Morpho oracle for USDY collateral quoted in a USD stablecoin (USDC/USDT) loan asset.

USDY is valued by its redemption value (NAV) from Ondo's dynamic-rate oracle, not a market price: USDY is transfer-gated and its secondary market is thin, so the NAV is the only sound basis and is not gameable. The stablecoin leg divides by its Chainlink USD feed, so a stablecoin depeg is reflected in the collateral valuation. No staleness/bounds guards (matches Morpho's stock oracle behaviour, which avoids bricking the market on a transient feed condition). price() = getPrice() * SCALE / stableUsdPrice SCALE   = 10^(36 + loanDecimals + feedDecimals - collateralDecimals - usdyOracleDecimals) = 10^(36 + 6 + 8 - 18 - 18) = 1e14 for USDY collateral (18 dec), USDC/USDT loan (6 dec), Ondo oracle (1e18), Chainlink (1e8). This matches Morpho's IOracle convention: price of 1 collateral asset (USDY) quoted in 1 loan asset (stablecoin), scaled by 1e36.

## Errors

### `ZeroAddress`

```solidity
error ZeroAddress();
```

A constructor argument (USDY oracle or stablecoin feed) was the zero address.

## Functions

### `constructor`

```solidity
constructor(address usdyOracle, address stableUsdFeed);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `usdyOracle` | `address` | Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` scaled by 1e18. |
| `stableUsdFeed` | `address` | Chainlink USD feed for the loan stablecoin (USDC/USD or USDT/USD), 8 dec. |

### `initialize`

```solidity
function initialize() external;
```

No-op that satisfies the proxy's mandatory init call; the config is immutable in the impl.

### `price`

```solidity
function price() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | Price of 1 USDY collateral quoted in 1 stablecoin loan asset, scaled by 1e36. |

USDY value in the loan stablecoin: the USDY NAV (USD, from the Ondo oracle) divided by the stablecoin's USD price (Chainlink), so a stablecoin depeg flows through. Scaled to `1e36`.

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `USDY_ORACLE` | `IRWADynamicOracle` (immutable) | Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` is the redemption value scaled by 1e18. |
| `STABLE_USD_FEED` | `IChainlinkAggregator` (immutable) | Chainlink USD feed for the loan stablecoin (USDC/USD or USDT/USD), 8 decimals. The collateral valuation divides by it, so a stablecoin depeg flows through. |
