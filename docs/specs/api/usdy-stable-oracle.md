<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# UsdyStableOracle

Morpho oracle for USDY collateral quoted in any USD-stablecoin loan asset with a Chainlink feed.

Values USDY by its NAV (Ondo dynamic-rate oracle), not a market price; the stablecoin leg divides by its Chainlink USD feed, so a stablecoin depeg flows into the collateral valuation. No staleness/bounds guards, matching Morpho's stock oracle. price() = getPrice() * scale / stableUsdPrice scale   = 10^(36 + loanDecimals + feedDecimals - USDY_DECIMALS - NAV_DECIMALS) The USDY NAV oracle is shared across markets, so it stays immutable; the per-market stablecoin feed and decimal-derived `scale` are set in `initialize`, so one implementation behind per-market proxies serves any Chainlink-priced stablecoin. Matches Morpho's IOracle convention: price of 1 collateral asset quoted in 1 loan asset, scaled by 1e36.

## Errors

### `ZeroAddress`

```solidity
error ZeroAddress();
```

An address argument was the zero address.

### `InvalidStablePrice`

```solidity
error InvalidStablePrice();
```

The stablecoin USD feed returned a non-positive answer (zero would brick `price()` on a division by zero; a negative cast would silently collapse the price toward zero).

### `InvalidNavPrice`

```solidity
error InvalidNavPrice();
```

The USDY NAV oracle returned zero, which would collapse the collateral price to zero.

## Functions

### `constructor`

```solidity
constructor(address usdyOracle);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `usdyOracle` | `address` | Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` scaled by 1e18. |

### `initialize`

```solidity
function initialize(address feed, address loanToken) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `feed` | `address` | Chainlink USD feed for the loan stablecoin; its `decimals()` set the feed leg. |
| `loanToken` | `address` | Loan stablecoin token; its `decimals()` set the loan leg. |

Bind the per-market stablecoin leg: the Chainlink USD feed and the decimal-derived scale.

### `price`

```solidity
function price() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | Price of 1 USDY quoted in the loan stablecoin, scaled by `1e36`. |

USDY NAV divided by the stablecoin feed and scaled to 1e36: `getPrice() * scale / stableUsdPrice`. Reverts on a zero NAV or a non-positive feed answer (zero divisor / negative cast).

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `USDY_ORACLE` | `IRWADynamicOracle` (immutable) | Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` is the redemption value scaled by 1e18. |
| `stableUsdFeed` | `IChainlinkAggregator` | Chainlink USD feed for the loan stablecoin. |
| `scale` | `uint256` | 10^(36 + loanDec + feedDec - 18 - 18): the 1e36 scaling for the loan token and feed decimals. |
