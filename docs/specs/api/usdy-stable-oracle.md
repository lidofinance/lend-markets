<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# UsdyStableOracle

Morpho oracle for USDY collateral quoted in any USD-stablecoin loan asset with a Chainlink feed.

USDY is valued by its redemption value (NAV) from Ondo's dynamic-rate oracle, not a market price: USDY is transfer-gated and its secondary market is thin, so the NAV is the only sound basis and is not gameable. The stablecoin leg divides by its Chainlink USD feed, so a stablecoin depeg is reflected in the collateral valuation. No staleness/bounds guards (matches Morpho's stock oracle behaviour, which avoids bricking the market on a transient feed condition). price() = getPrice() * SCALE / stableUsdPrice SCALE   = 10^(36 + loanDecimals + feedDecimals - USDY_DECIMALS - NAV_DECIMALS) USDY is the only collateral (18 dec, NAV scaled 1e18), but the loan stablecoin is free: its token decimals and its Chainlink feed decimals are read at construction, so the same contract serves any Chainlink-priced stablecoin (USDC, USDT, DAI, ...). Matches Morpho's IOracle convention: price of 1 collateral asset quoted in 1 loan asset, scaled by 1e36.

## Errors

### `ZeroAddress`

```solidity
error ZeroAddress();
```

A constructor address argument was the zero address.

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
constructor(address usdyOracle, address stableUsdFeed, address loanToken);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `usdyOracle` | `address` | Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` scaled by 1e18. |
| `stableUsdFeed` | `address` | Chainlink USD feed for the loan stablecoin; its `decimals()` set the feed leg. |
| `loanToken` | `address` | Loan stablecoin token; its `decimals()` set the loan leg. |

### `price`

```solidity
function price() external view returns (uint256);
```

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `USDY_ORACLE` | `IRWADynamicOracle` (immutable) | Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` is the redemption value scaled by 1e18. |
| `STABLE_USD_FEED` | `IChainlinkAggregator` (immutable) | Chainlink USD feed for the loan stablecoin. The valuation divides by it, so a depeg flows through. |
| `SCALE` | `uint256` (immutable) | 10^(36 + loanDec + feedDec - 18 - 18): the 1e36 scaling for the loan token and feed decimals. |
