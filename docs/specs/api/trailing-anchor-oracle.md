<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# Trailing Anchor Oracle

`TrailingAnchorOracleBase` holds every rule, and each adapter binds one source and overrides only how it is read. The mechanism, its invariants and its calibration are specified in [Trailing Anchor Oracle](../trailing-anchor-oracle.md).

Standard inherited role-membership and role-administration functions are not repeated; see [OpenZeppelin AccessControlEnumerable](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControlEnumerable).

## TrailingAnchorOracleBase

Oracle for a market. It returns the price of the collateral token in the loan token. The price comes from an external source. The oracle returns it only while it is near a stored anchor price. If the source moves far from the anchor, `price()` reverts. The anchor then moves to the new price only after a delay, which gives time to pause the market.

Each adapter reads one source in `_currentPrice()`. Each adapter has its own storage namespace, so an upgrade to a different adapter does not read the old anchor. The oracle assumes that one loan token is worth one unit of the source currency, for example 1 USDC = 1 USD. Anyone can call `updateAnchor()`:

- Price inside the bounds: the anchor moves toward the price, limited by the rise and fall rates. This is a drift.
- Price outside the bounds: the update records it as the pending anchor. If the price stays outside for `reanchorDelay`, the next update moves the anchor onto it. This is a re-anchor. A drift cannot move the anchor below the floor. A re-anchor cannot move it below the floor or above the ceiling. Only `acceptPrice()` moves it further.

### Enums

#### `UpdateOutcome`

```solidity
enum UpdateOutcome {
    WithinBounds,
    PendingAnchorRecorded,
    PendingAnchorHeld,
    PendingAnchorApplied,
    AnchorOnFloor,
    AnchorOnCeiling
}
```

The result of one `updateAnchor()` call:

- `WithinBounds`: the price is inside the bounds. The anchor drifted toward it as far as the rates and the floor permit, and the pending anchor was dropped.
- `PendingAnchorRecorded`: the price is outside the bounds, and it became the pending anchor.
- `PendingAnchorHeld`: the active pending anchor is still in its delay. Nothing changed.
- `PendingAnchorApplied`: the anchor moved onto the pending anchor or the price, whichever is nearer, but not past the floor or the ceiling. A price still outside the new bounds became the next pending anchor.
- `AnchorOnFloor`: the delay is over, but the anchor is on or below the floor. Nothing changed.
- `AnchorOnCeiling`: the delay is over, but the anchor is on or above the ceiling. Nothing changed.

### Structs

#### `Parameters`

```solidity
struct Parameters {
    uint64 maxPriceAboveAnchor;
    uint64 maxPriceBelowAnchor;
    uint64 maxAnchorContinuousRiseRate;
    uint64 maxAnchorContinuousFallRate;
    uint64 maxAnchorBelowBase;
    uint64 maxAnchorAboveBase;
    uint40 reanchorDelay;
    uint40 reanchorWindow;
}
```

The values that `initialize()` and `setParameters()` store. Each field has the units of the getter with the same name.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `maxPriceAboveAnchor` | `uint64` | Upper bound, as a fraction of the anchor price. |
| `maxPriceBelowAnchor` | `uint64` | Lower bound, as a fraction of the anchor price. |
| `maxAnchorContinuousRiseRate` | `uint64` | Largest yearly rate at which a drift raises the anchor. |
| `maxAnchorContinuousFallRate` | `uint64` | Largest yearly rate at which a drift lowers the anchor. |
| `maxAnchorBelowBase` | `uint64` | Floor, as a fraction of `basePrice`. |
| `maxAnchorAboveBase` | `uint64` | Ceiling, as a fraction of `basePrice`. |
| `reanchorDelay` | `uint40` | Seconds that a pending anchor waits before a re-anchor. |
| `reanchorWindow` | `uint40` | Seconds after the delay in which a re-anchor can occur. |

### Events

#### `AnchorSet`

```solidity
event AnchorSet(uint256 anchorPrice, uint256 anchorAt, bool accepted);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `anchorPrice` | `uint256` | The new anchor price, with `PRICE_DECIMALS` decimals. |
| `anchorAt` | `uint256` | Time when the anchor changed. |
| `accepted` | `bool` | True for the seed in `initialize()` and for `acceptPrice()`, false for an update. |

The anchor changed.

#### `PendingAnchorSet`

```solidity
event PendingAnchorSet(uint256 pendingAnchorPrice, uint256 pendingAnchorAt);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `pendingAnchorPrice` | `uint256` | Price of the pending anchor, with `PRICE_DECIMALS` decimals. |
| `pendingAnchorAt` | `uint256` | Time when the update recorded the pending anchor. |

An update recorded a pending anchor.

#### `PendingAnchorCleared`

```solidity
event PendingAnchorCleared();
```

The pending anchor was dropped.

#### `AnchorUpdated`

```solidity
event AnchorUpdated(UpdateOutcome indexed outcome, uint256 currentPrice);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `outcome` | `UpdateOutcome` | The result of the call. |
| `currentPrice` | `uint256` | The current price that the call read, with `PRICE_DECIMALS` decimals. |

An `updateAnchor()` call completed, with its result and the current price that it read. The call emits this event after the events of its state changes.

#### `ParametersSet`

```solidity
event ParametersSet(Parameters parameters);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `parameters` | `Parameters` | The new parameters. |

The parameters changed.

#### `PricingResumesAtSet`

```solidity
event PricingResumesAtSet(uint256 resumesAt);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `resumesAt` | `uint256` | Time at which pricing resumes. |

The time at which pricing resumes changed.

### Errors

#### `ZeroAddress`

```solidity
error ZeroAddress();
```

An address argument is zero.

#### `UnsupportedDecimals`

```solidity
error UnsupportedDecimals(uint256 loanDecimals, uint256 collateralDecimals);
```

The token decimals give a negative exponent for `PRICE_SCALE`.

#### `MaxPriceAboveAnchorIsZero`

```solidity
error MaxPriceAboveAnchorIsZero();
```

`maxPriceAboveAnchor` is zero.

#### `MaxPriceBelowAnchorIsZero`

```solidity
error MaxPriceBelowAnchorIsZero();
```

`maxPriceBelowAnchor` is zero.

#### `MaxPriceAboveAnchorNotBelowWad`

```solidity
error MaxPriceAboveAnchorNotBelowWad(uint256 maxPriceAboveAnchor);
```

`maxPriceAboveAnchor` is 1e18 or more.

#### `MaxPriceBelowAnchorNotBelowWad`

```solidity
error MaxPriceBelowAnchorNotBelowWad(uint256 maxPriceBelowAnchor);
```

`maxPriceBelowAnchor` is 1e18 or more.

#### `MaxAnchorBelowBaseNotBelowWad`

```solidity
error MaxAnchorBelowBaseNotBelowWad(uint256 maxAnchorBelowBase);
```

`maxAnchorBelowBase` is 1e18 or more.

#### `MaxAnchorAboveBaseNotBelowWad`

```solidity
error MaxAnchorAboveBaseNotBelowWad(uint256 maxAnchorAboveBase);
```

`maxAnchorAboveBase` is 1e18 or more.

#### `MaxAnchorContinuousRiseRateExceedsWad`

```solidity
error MaxAnchorContinuousRiseRateExceedsWad(uint256 maxAnchorContinuousRiseRate);
```

`maxAnchorContinuousRiseRate` is more than 1e18.

#### `MaxAnchorContinuousFallRateExceedsWad`

```solidity
error MaxAnchorContinuousFallRateExceedsWad(uint256 maxAnchorContinuousFallRate);
```

`maxAnchorContinuousFallRate` is more than 1e18.

#### `ReanchorDelayBelowMinReanchorDelay`

```solidity
error ReanchorDelayBelowMinReanchorDelay(uint256 reanchorDelay, uint256 minReanchorDelay);
```

`reanchorDelay` is shorter than `MIN_REANCHOR_DELAY`.

#### `ReanchorWindowBelowMinReanchorWindow`

```solidity
error ReanchorWindowBelowMinReanchorWindow(uint256 reanchorWindow, uint256 minReanchorWindow);
```

`reanchorWindow` is shorter than `MIN_REANCHOR_WINDOW`.

#### `RiseOverDelayExceedsMaxPriceAboveAnchor`

```solidity
error RiseOverDelayExceedsMaxPriceAboveAnchor(uint256 riseOverDelay, uint256 maxPriceAboveAnchor);
```

A source that rises at the rise rate for one delay goes above the upper bound.

#### `FallOverDelayExceedsMaxPriceBelowAnchor`

```solidity
error FallOverDelayExceedsMaxPriceBelowAnchor(uint256 fallOverDelay, uint256 maxPriceBelowAnchor);
```

A source that falls at the fall rate for one delay goes below the lower bound.

#### `InvalidPricingResumesAt`

```solidity
error InvalidPricingResumesAt(uint256 resumesAt);
```

`resumesAt` is more than `MAX_PRICING_SUSPENSION` after the current time.

#### `ZeroPrice`

```solidity
error ZeroPrice();
```

The source returned a zero price.

#### `PriceOutOfBounds`

```solidity
error PriceOutOfBounds(uint256 currentPrice, uint256 lowerBound, uint256 upperBound);
```

The current price is outside the bounds around the anchor price.

#### `PricingSuspended`

```solidity
error PricingSuspended(uint256 resumesAt);
```

Pricing is suspended until `resumesAt`.

#### `UnexpectedPrice`

```solidity
error UnexpectedPrice(uint256 currentPrice, uint256 minPrice, uint256 maxPrice);
```

The current price is outside the range that the caller gave.

### Functions

#### `constructor`

```solidity
constructor(address loanToken, address collateralToken);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `loanToken` | `address` | Loan token of the market. Its decimals set `PRICE_SCALE`. |
| `collateralToken` | `address` | Collateral token of the market. Its decimals set `PRICE_SCALE`. |

#### `initialize`

```solidity
function initialize(
    address admin,
    Parameters calldata parameters,
    uint256 minPrice,
    uint256 maxPrice
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `admin` | `address` | First holder of `DEFAULT_ADMIN_ROLE`. |
| `parameters` | `Parameters` | The parameters, with the same checks as in `setParameters()`. |
| `minPrice` | `uint256` | Lowest current price to accept, inclusive, with `PRICE_DECIMALS` decimals. |
| `maxPrice` | `uint256` | Highest current price to accept, inclusive, with `PRICE_DECIMALS` decimals. |

Grants the admin role, stores the parameters and sets the first anchor to the current price. The call reverts if the current price is outside `minPrice` and `maxPrice`.

#### `price`

```solidity
function price() external view returns (uint256);
```

Reverts while pricing is suspended, on a zero price, and while the current price is outside the bounds.

#### `updateAnchor`

```solidity
function updateAnchor() external returns (UpdateOutcome outcome);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `outcome` | `UpdateOutcome` | The result of the call. |

Updates the anchor from the current price. Anyone can call it in any block, also while `price()` reverts. The returned outcome tells what changed.

The call uses `block.timestamp`. A few seconds of validator skew change the drift limit, the delay and the window by those seconds.

#### `acceptPrice`

```solidity
function acceptPrice(uint256 minPrice, uint256 maxPrice) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `minPrice` | `uint256` | Lowest current price to accept, inclusive, with `PRICE_DECIMALS` decimals. |
| `maxPrice` | `uint256` | Highest current price to accept, inclusive, with `PRICE_DECIMALS` decimals. |

Sets the anchor and `basePrice` to the current price, at any distance from the old anchor, and drops the pending anchor. It ends a revert on the bounds without the delay. It is the only way to move the anchor past the floor or the ceiling.

The call reverts if the current price is outside `minPrice` and `maxPrice`. Thus a price that changed after the caller checked it is not accepted.

#### `setPricingResumesAt`

```solidity
function setPricingResumesAt(uint40 resumesAt) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `resumesAt` | `uint40` | Time at which pricing resumes, at most `MAX_PRICING_SUSPENSION` after the current time. |

Makes `price()` revert until `resumesAt`. Liquidations stop during that time, and borrowers can still repay. A time that is not in the future ends the suspension. `updateAnchor()` and `acceptPrice()` still work during a suspension.

#### `setParameters`

```solidity
function setParameters(Parameters calldata parameters) external;
```

Sets all parameters and drops the pending anchor. The anchor and `basePrice` do not change. The call reverts if a value is outside its range. Each check has its own error.

The oracle does not know the markets that read it, so it does not check the parameters against their LLTV. The manager must keep this rule for each market: a position borrowed at the LLTV against the highest price still covers its debt and the liquidation incentive at the lowest price. Highest price = ceiling × (1 + maxPriceAboveAnchor). Lowest price = floor × (1 − maxPriceBelowAnchor).

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `MANAGER_ROLE` | `bytes32` (constant) | Can set the parameters and suspend pricing. |
| `PRICE_ACCEPTOR_ROLE` | `bytes32` (constant) | Can accept the current price as the anchor, at any distance from the old anchor. |
| `PRICE_SCALE` | `uint256` (immutable) | Factor that converts a source price to the price that the core reads. 10^(ORACLE_PRICE_DECIMALS + loanDecimals − collateralDecimals − PRICE_DECIMALS). |
| `MIN_REANCHOR_DELAY` | `uint256` (constant) | Shortest permitted `reanchorDelay`. |
| `MIN_REANCHOR_WINDOW` | `uint256` (constant) | Shortest permitted `reanchorWindow`. Block times have a fixed step. A window shorter than that step can contain no block, and then a pending anchor never applies. |
| `MAX_PRICING_SUSPENSION` | `uint256` (constant) | Longest time that one call can suspend pricing, counted from that call. |
| `anchorPrice` | `uint104` | Price that the bounds are measured from, with `PRICE_DECIMALS` decimals. |
| `basePrice` | `uint104` | Price that the floor and the ceiling are measured from, with `PRICE_DECIMALS` decimals. It starts at the seed price, and `acceptPrice()` restarts it at the accepted price. A drift up raises it. A re-anchor does not change it, so a re-anchor up can leave the anchor above it, up to the ceiling. |
| `anchorAt` | `uint40` | Time when the anchor price was last set. |
| `maxPriceAboveAnchor` | `uint64` | Upper bound: how far above the anchor price the current price can be, as a fraction of the anchor price, WAD. Above it, `price()` reverts. 0.0005e18 is 0.05%. |
| `maxPriceBelowAnchor` | `uint64` | Lower bound: how far below the anchor price the current price can be, as a fraction of the anchor price, WAD. Below it, `price()` reverts. 0.001e18 is 0.1%. |
| `pricingResumesAt` | `uint40` | Time before which `price()` reverts with `PricingSuspended`. |
| `pendingAnchorAt` | `uint40` | Time when the pending anchor was recorded. Zero means no pending anchor. |
| `maxAnchorContinuousRiseRate` | `uint64` | Largest rate at which a drift can raise the anchor, continuously compounded per year, WAD. 0.06e18 permits a rise of e^0.06 − 1, about 6.18%, in a year. The update schedule does not change that. |
| `maxAnchorContinuousFallRate` | `uint64` | Largest rate at which a drift can lower the anchor, continuously compounded per year, WAD. 0.01e18 permits a fall of 1 − e^−0.01, about 0.995%, in a year. The update schedule does not change that. |
| `maxAnchorBelowBase` | `uint64` | Floor: how far below `basePrice` an update can move the anchor, as a fraction of that price, WAD. 0.01e18 is 1%. |
| `maxAnchorAboveBase` | `uint64` | Ceiling: how far above `basePrice` a re-anchor can move the anchor, as a fraction of that price, WAD. 0.002e18 is 0.2%. |
| `pendingAnchorPrice` | `uint104` | Price of the pending anchor, with `PRICE_DECIMALS` decimals. Zero means no pending anchor. |
| `reanchorDelay` | `uint40` | Seconds that a pending anchor must wait before an update can re-anchor. |
| `reanchorWindow` | `uint40` | Seconds after the delay in which an update can re-anchor. After the window, the pending anchor expires: the next update drops it or records a new one. |

## UsdyNavOracle

NAV oracle for USDY. It reads the price from the price getter of Ondo.

### Functions

#### `constructor`

```solidity
constructor(address source, address loanToken, address collateralToken);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `SOURCE` | `IOndoPriceGetter` (immutable) | Price getter of Ondo for USDY. |

## CentrifugeNavOracle

NAV oracle for a Centrifuge share class. It reads the share price in the loan token from the share class's Centrifuge vault, whose asset is the loan token.

The vault's time stamp is the later of the share price's and the asset price's. The adapter refuses a stamp older than its own `MAX_PRICE_AGE`. The issuer supplies the stamp, so the adapter also refuses one after the block time.

### Errors

#### `ShareTokenMismatch`

```solidity
error ShareTokenMismatch(address shareToken, address collateralToken);
```

The share token of the vault is not the collateral token.

#### `AssetMismatch`

```solidity
error AssetMismatch(address asset, address loanToken);
```

The asset of the vault is not the loan token.

#### `MaxPriceAgeIsZero`

```solidity
error MaxPriceAgeIsZero();
```

`maxPriceAge` is zero.

#### `StalePrice`

```solidity
error StalePrice(uint256 computedAt);
```

The vault's price stamp `computedAt` is more than `MAX_PRICE_AGE` ago.

#### `PriceFromFuture`

```solidity
error PriceFromFuture(uint256 computedAt);
```

The vault's price stamp `computedAt` is after the block time.

### Functions

#### `constructor`

```solidity
constructor(
    address vault,
    uint256 maxPriceAge,
    address loanToken,
    address collateralToken
);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `VAULT` | `ICentrifugeVault` (immutable) | Centrifuge vault of the collateral token. |
| `MAX_PRICE_AGE` | `uint256` (immutable) | Largest age of the vault's price stamp that the adapter accepts, in seconds. |

## ChainlinkNavOracle

NAV oracle that reads the collateral's price from a feed with Chainlink's aggregator interface.

The feed's `updatedAt` is when the feed wrote the value, not when the issuer computed it. The adapter refuses a value older than `MAX_PRICE_AGE` and one written after the block time.

### Errors

#### `MaxPriceAgeIsZero`

```solidity
error MaxPriceAgeIsZero();
```

`maxPriceAge` is zero.

#### `UnsupportedFeedDecimals`

```solidity
error UnsupportedFeedDecimals(uint8 feedDecimals);
```

The feed has more decimals than `PRICE_DECIMALS`.

#### `NegativePrice`

```solidity
error NegativePrice(int256 answer);
```

The feed's value is below zero.

#### `StalePrice`

```solidity
error StalePrice(uint256 updatedAt);
```

The feed wrote its value at `updatedAt`, which is more than `MAX_PRICE_AGE` ago.

#### `PriceFromFuture`

```solidity
error PriceFromFuture(uint256 updatedAt);
```

The feed gives its value the time `updatedAt`, which is after the block time.

### Functions

#### `constructor`

```solidity
constructor(
    address feed,
    uint256 maxPriceAge,
    address loanToken,
    address collateralToken
);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `FEED` | `IChainlinkFeed` (immutable) | Feed of the collateral's price in the loan token's currency. |
| `MAX_PRICE_AGE` | `uint256` (immutable) | Largest age of a feed value that the adapter returns, in seconds since the feed wrote it. |
| `ANSWER_SCALE` | `uint256` (immutable) | Factor from the feed's decimals to `PRICE_DECIMALS`. |
