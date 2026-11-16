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
- `PendingAnchorHeld`: the held pending anchor is still in its delay. Nothing changed.
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
    uint64 maxAnchorBelowFenceBase;
    uint64 maxAnchorAboveFenceBase;
    uint40 reanchorDelay;
    uint40 reanchorWindow;
}
```

The values that `initialize()` and `setParameters()` store. Each field has the units of the getter with the same name.

### Events

#### `AnchorSet`

```solidity
event AnchorSet(uint256 anchorPrice, uint40 anchorAt, bool accepted);
```

The anchor changed. `accepted` is true for the seed in `initialize()` and for `acceptPrice()`, and false for an update.

#### `PendingAnchorSet`

```solidity
event PendingAnchorSet(uint256 pendingAnchorPrice, uint40 pendingAnchorAt);
```

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

An `updateAnchor()` call completed, with its result and the current price that it read. The call emits this event after the events of its state changes.

#### `ParametersSet`

```solidity
event ParametersSet(Parameters parameters);
```

The parameters changed.

#### `PricingResumesAtSet`

```solidity
event PricingResumesAtSet(uint40 resumesAt);
```

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

#### `InvalidParameters`

```solidity
error InvalidParameters();
```

A parameter is outside the range that `setParameters()` permits.

#### `InvalidPricingResumesAt`

```solidity
error InvalidPricingResumesAt(uint40 resumesAt);
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
error PricingSuspended(uint40 resumesAt);
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
| `outcome` | `UpdateOutcome` | The result of the call. A keeper can read it with `eth_call` before it sends the transaction. |

Updates the anchor from the current price. Anyone can call it in any block, also while `price()` reverts.

- Price inside the bounds: the anchor drifts toward it, and the pending anchor is dropped.
- Price outside the bounds with no held pending anchor: the price becomes the pending anchor.
- Held pending anchor in its delay: nothing changes.
- Held pending anchor after its delay: the anchor moves onto the pending anchor or the price, whichever is nearer. No update moves the anchor below the floor, and no re-anchor moves it above the ceiling. An anchor that is already past one of them does not move further past it.

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

Sets the anchor and `fenceBasePrice` to the current price, at any distance from the old anchor, and drops the pending anchor. It ends a revert on the bounds without the delay. It is the only way to move the anchor past the floor or the ceiling.

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

Sets all parameters and drops the pending anchor. The anchor and `fenceBasePrice` do not change. The call reverts unless:

- each bound is above zero and below 1e18;
- `maxAnchorBelowFenceBase` and `maxAnchorAboveFenceBase` are below 1e18;
- each rate is at most 1e18;
- the delay is at least `MIN_REANCHOR_DELAY`, and the window is above zero;
- a source that moves at a rate for one delay stays inside the bound on that side.

The oracle does not know the markets that read it, so it does not check the parameters against their LLTV. The manager must keep this rule for each market: a position borrowed at the LLTV against the highest price still covers its debt and the liquidation incentive at the lowest price. Highest price = ceiling × (1 + maxPriceAboveAnchor). Lowest price = floor × (1 − maxPriceBelowAnchor).

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `MANAGER_ROLE` | `bytes32` (constant) | Can set the parameters and suspend pricing. |
| `PRICE_ACCEPTOR_ROLE` | `bytes32` (constant) | Can accept the current price as the anchor, at any distance from the old anchor. |
| `PRICE_SCALE` | `uint256` (immutable) | Factor that converts a source price to the price that the core reads. 10^(ORACLE_PRICE_DECIMALS + loanDecimals − collateralDecimals − PRICE_DECIMALS). |
| `MIN_REANCHOR_DELAY` | `uint256` (constant) | Shortest permitted `reanchorDelay`. |
| `MAX_PRICING_SUSPENSION` | `uint256` (constant) | Longest time that one call can suspend pricing, counted from that call. |
| `maxPriceAboveAnchor` | `uint64` | Upper bound: how far above the anchor price the current price can be, as a fraction of the anchor price, WAD. Above it, `price()` reverts. 0.0005e18 is 0.05%. |
| `maxPriceBelowAnchor` | `uint64` | Lower bound: how far below the anchor price the current price can be, as a fraction of the anchor price, WAD. Below it, `price()` reverts. 0.001e18 is 0.1%. |
| `anchorAt` | `uint40` | Time when the anchor price was last set. |
| `pricingResumesAt` | `uint40` | Time before which `price()` reverts with `PricingSuspended`. |
| `anchorPrice` | `uint256` | Price that the bounds are measured from, with `PRICE_DECIMALS` decimals. |
| `maxAnchorContinuousRiseRate` | `uint64` | Largest rate at which a drift can raise the anchor, continuously compounded per year, WAD. 0.06e18 permits a rise of e^0.06 − 1, about 6.18%, in a year. The update schedule does not change that. |
| `maxAnchorContinuousFallRate` | `uint64` | Largest rate at which a drift can lower the anchor, continuously compounded per year, WAD. 0.01e18 permits a fall of 1 − e^−0.01, about 0.995%, in a year. The update schedule does not change that. |
| `reanchorDelay` | `uint40` | Seconds that a pending anchor must wait before an update can re-anchor. |
| `reanchorWindow` | `uint40` | Seconds after the delay in which an update can re-anchor. After the window, the pending anchor expires: the next update drops it or records a new one. |
| `pendingAnchorAt` | `uint40` | Time when the pending anchor was recorded. Zero means no pending anchor. |
| `pendingAnchorPrice` | `uint256` | Price of the pending anchor, with `PRICE_DECIMALS` decimals. Zero means no pending anchor. |
| `maxAnchorBelowFenceBase` | `uint64` | Floor: how far below `fenceBasePrice` an update can move the anchor, as a fraction of that price, WAD. 0.01e18 is 1%. |
| `maxAnchorAboveFenceBase` | `uint64` | Ceiling: how far above `fenceBasePrice` a re-anchor can move the anchor, as a fraction of that price, WAD. 0.002e18 is 0.2%. |
| `fenceBasePrice` | `uint256` | Price that the floor and the ceiling are measured from, with `PRICE_DECIMALS` decimals. It starts at the seed price, and `acceptPrice()` restarts it at the accepted price. A drift up raises it. A re-anchor does not change it, so a re-anchor up can leave the anchor above it, up to the ceiling. |

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

NAV oracle for a Centrifuge share class. It reads the share price from the Centrifuge Spoke.

The adapter does not use the validity check of the Spoke, because a pool can set an unbounded maximum age. The adapter refuses a price older than its own `MAX_PRICE_AGE`. The issuer supplies the time of the price, so the adapter also refuses a time after the block time.

### Errors

#### `ShareTokenMismatch`

```solidity
error ShareTokenMismatch(address shareToken, address collateralToken);
```

The token of the share class on the Spoke is not the collateral token.

#### `ZeroMaxPriceAge`

```solidity
error ZeroMaxPriceAge();
```

`maxPriceAge` is zero.

#### `StalePrice`

```solidity
error StalePrice(uint64 computedAt);
```

The Spoke computed the share price at `computedAt`, which is more than `MAX_PRICE_AGE` ago.

#### `PriceFromFuture`

```solidity
error PriceFromFuture(uint64 computedAt);
```

The Spoke gives the share price the time `computedAt`, which is after the block time.

### Functions

#### `constructor`

```solidity
constructor(
    address spoke,
    uint64 poolId,
    bytes16 scId,
    uint256 maxPriceAge,
    address loanToken,
    address collateralToken
);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `SPOKE` | `ICentrifugeSpoke` (immutable) | Centrifuge Spoke that holds the share prices. |
| `POOL_ID` | `uint64` (immutable) | Pool of the collateral token. |
| `SHARE_CLASS_ID` | `bytes16` (immutable) | Share class of the collateral token. |
| `MAX_PRICE_AGE` | `uint256` (immutable) | Largest age of a share price that the adapter returns, in seconds since the Spoke computed it. |
