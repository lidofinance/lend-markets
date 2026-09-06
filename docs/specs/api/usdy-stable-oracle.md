<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# UsdyStableOracle

Morpho oracle for USDY collateral quoted in any USD-stablecoin loan asset with a Chainlink feed.

Values USDY by its NAV (Ondo dynamic-rate oracle), not a market price; the stablecoin leg divides by its Chainlink USD feed, so a stablecoin depeg flows into the collateral valuation. No staleness guard, matching Morpho's stock oracle; the immutable price band below is the only guard. price() = getPrice() * scale / stableUsdPrice scale   = 10^(36 + loanDecimals + feedDecimals - USDY_DECIMALS - NAV_DECIMALS) `price()` reverts outside the inclusive band [`MIN_PRICE`, `MAX_PRICE`], so a mis-scaled NAV or a collapsing feed answer stops every price-dependent action instead of repricing every position. The band is a sanity check on the sources, not a risk parameter: it is wide enough that NAV accrual and stablecoin depegs stay inside it. The NAV oracle and the band are fixed for the life of an instance, so both are immutable; the per-market stablecoin feed and decimal-derived `scale` are set in `initialize`. The bounds are in the returned 1e36-convention domain, whose magnitude depends on the loan token's decimals, so a band is valid only for the loan token its instance is initialized with. Matches Morpho's IOracle convention: price of 1 collateral asset quoted in 1 loan asset, scaled by 1e36.

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

### `InvalidPriceBounds`

```solidity
error InvalidPriceBounds(uint256 minPrice, uint256 maxPrice);
```

The constructor's price band was not a usable range: a zero lower bound would admit a collapsed price, and an upper bound below the lower one would reject every price.

### `PriceOutOfBounds`

```solidity
error PriceOutOfBounds(uint256 price);
```

The computed price fell outside the immutable [`MIN_PRICE`, `MAX_PRICE`] band, so the NAV or the feed reported a magnitude this market does not price against.

## Functions

### `constructor`

```solidity
constructor(address usdyOracle, uint256 minPrice, uint256 maxPrice);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `usdyOracle` | `address` | Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` scaled by 1e18. |
| `minPrice` | `uint256` | Inclusive lower bound on `price()`, scaled by 10^(36 + loanDecimals - USDY_DECIMALS) for the loan token passed to `initialize`. |
| `maxPrice` | `uint256` | Inclusive upper bound on `price()`, in the same domain as `minPrice`. |

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

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `USDY_ORACLE` | `IRWADynamicOracle` (immutable) | Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` is the redemption value scaled by 1e18. |
| `MIN_PRICE` | `uint256` (immutable) | Inclusive lower bound on `price()`, in the returned 1e36-convention domain. |
| `MAX_PRICE` | `uint256` (immutable) | Inclusive upper bound on `price()`, in the returned 1e36-convention domain. |
| `stableUsdFeed` | `IChainlinkAggregator` | Chainlink USD feed for the loan stablecoin. |
| `scale` | `uint256` | 10^(36 + loanDec + feedDec - 18 - 18): the 1e36 scaling for the loan token and feed decimals. |
