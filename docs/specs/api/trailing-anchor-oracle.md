<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# Trailing Anchor Oracle

`TrailingAnchorOracleBase` holds every rule, and each adapter binds one source and overrides only how it is read. The mechanism, its invariants and its calibration are specified in [Trailing Anchor Oracle](../trailing-anchor-oracle.md).

Standard inherited role-membership and role-administration functions are not repeated; see [OpenZeppelin AccessControlEnumerable](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControlEnumerable).

## TrailingAnchorOracleBase

Lido Lend oracle for collateral priced from a source quoted in the loan token's currency, at one loan token per unit of that currency. It returns the current price scaled by `PRICE_SCALE`, and reverts while that price sits outside the bounds around the anchor price and while the manager suspends pricing.

Concrete oracles bind one source in their constructor and override `_currentPrice()` with its ABI. Each declares its own storage namespace, so an anchor never carries over to an adapter of another kind. Anyone can call `updateAnchor()`. A current price within the bounds drags the anchor toward it at the yearly speeds, so the bounds follow a source that changes slowly. A current price outside them is recorded as a pending anchor. While the price stays outside the bounds on the pending anchor's side the anchor holds still, and once the pending anchor has waited `reanchorDelay` an update within `reanchorWindow` moves the anchor onto the pending anchor, or onto the price if it sits nearer the anchor. So a move past the bounds becomes the price only after it has been public for a whole delay: the time to stop the markets that read the oracle. No update takes the anchor more than `maxAnchorBelowMark` below `highWaterMark`, and no re-anchor more than `maxAnchorAboveMark` above it. That mark is the seed or the last accepted price, and only a drift up raises it, so however many steps a source takes past the bounds, it moves the anchor at most down to the floor and up to the ceiling; going further takes `acceptPrice()`.

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

What one `updateAnchor()` call did, by the case it took:

- `WithinBounds`: the anchor moved toward the price as far as the speeds and the floor allow, and the pending anchor, if any, was dropped;
- `PendingAnchorRecorded`: the price, outside the bounds with no held pending anchor, became the pending anchor;
- `PendingAnchorHeld`: the held pending anchor waits out its delay; nothing changed;
- `PendingAnchorApplied`: the anchor moved onto the pending anchor or the price, whichever is nearer, and no further than the floor or the ceiling; a price still outside the new bounds became the next pending anchor;
- `AnchorOnFloor`: the delay passed, but the anchor sits on or below the floor; nothing changed;
- `AnchorOnCeiling`: the delay passed, but the anchor sits on or above the ceiling; nothing changed.

### Structs

#### `Parameters`

```solidity
struct Parameters {
    uint64 maxPriceAboveAnchor;
    uint64 maxPriceBelowAnchor;
    uint64 maxAnchorRisePerYear;
    uint64 maxAnchorFallPerYear;
    uint64 maxAnchorBelowMark;
    uint64 maxAnchorAboveMark;
    uint40 reanchorDelay;
    uint40 reanchorWindow;
}
```

What `initialize()` and `setParameters()` store, in the units of the getters of the same names.

### Events

#### `AnchorSet`

```solidity
event AnchorSet(uint256 anchorPrice, uint40 anchorAt, bool accepted);
```

The anchor was set; `accepted` is true for the seed in `initialize()` and for `acceptPrice()`, false for an update.

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

An `updateAnchor()` call ran: what it did and the current price it read. Emitted after the events of the state it changed.

#### `ParametersSet`

```solidity
event ParametersSet(Parameters parameters);
```

The parameters changed.

#### `PricingResumesAtSet`

```solidity
event PricingResumesAtSet(uint40 resumesAt);
```

The time pricing resumes at changed.

### Errors

#### `ZeroAddress`

```solidity
error ZeroAddress();
```

An address argument was the zero address.

#### `UnsupportedDecimals`

```solidity
error UnsupportedDecimals(uint256 loanDecimals, uint256 collateralDecimals);
```

The loan and collateral decimals leave no room for the 1e36 convention.

#### `InvalidParameters`

```solidity
error InvalidParameters();
```

A parameter is outside the range `setParameters()` names.

#### `InvalidPricingResumesAt`

```solidity
error InvalidPricingResumesAt(uint40 resumesAt);
```

The suspension would end more than `MAX_PRICING_SUSPENSION` from now.

#### `ZeroPrice`

```solidity
error ZeroPrice();
```

The source returned zero.

#### `PriceOutOfBounds`

```solidity
error PriceOutOfBounds(uint256 currentPrice, uint256 lowerBound, uint256 upperBound);
```

The current price sits outside the bounds around the anchor price.

#### `PricingSuspended`

```solidity
error PricingSuspended(uint40 resumesAt);
```

Pricing is suspended until `resumesAt`.

#### `UnexpectedPrice`

```solidity
error UnexpectedPrice(uint256 currentPrice, uint256 minPrice, uint256 maxPrice);
```

The current price sits outside the range the price acceptor passed.

### Functions

#### `constructor`

```solidity
constructor(address loanToken, address collateralToken);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `loanToken` | `address` | Loan token; its decimals set `PRICE_SCALE`. |
| `collateralToken` | `address` | Collateral token; its decimals set `PRICE_SCALE`. |

#### `initialize`

```solidity
function initialize(address admin, Parameters calldata parameters) external;
```

Grants the admin, stores the parameters as `setParameters()` does and seeds the anchor from the current price.

#### `price`

```solidity
function price() external view returns (uint256);
```

#### `updateAnchor`

```solidity
function updateAnchor() external returns (UpdateOutcome outcome);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `outcome` | `UpdateOutcome` | What the call did; a keeper can read it with `eth_call` before sending the call. |

Moves the anchor toward a current price within the bounds, or, once a pending anchor has waited out the delay with the price outside the bounds on its side, onto the pending anchor or the price, whichever is nearer the anchor; records any other current price outside the bounds as the pending anchor. Neither move takes the anchor under the floor, `maxAnchorBelowMark` below `highWaterMark`, nor a re-anchor over the ceiling, `maxAnchorAboveMark` above it; an anchor already past one moves no further past it. Open to anyone in any block, also while `price()` reverts. Each call emits `AnchorUpdated`.

`block.timestamp` sets the time counted: a validator's few seconds of skew move the speeds' reach and the pending anchor's delay and window by those seconds.

#### `acceptPrice`

```solidity
function acceptPrice(uint256 minPrice, uint256 maxPrice) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `minPrice` | `uint256` | Lowest current price to accept, inclusive, with `PRICE_DECIMALS` decimals. |
| `maxPrice` | `uint256` | Highest current price to accept, inclusive, with `PRICE_DECIMALS` decimals. |

Moves the anchor to the current price wherever it sits, once the price acceptor has checked the value, restarts `highWaterMark` there and drops the pending anchor: the way out of a revert on the bounds without waiting out the delay, and the only way under the floor or over the ceiling. A current price outside `minPrice` and `maxPrice` is refused, so a price that moved after the check is not accepted.

#### `setPricingResumesAt`

```solidity
function setPricingResumesAt(uint40 resumesAt) external;
```

Makes `price()` revert until `resumesAt`, at most `MAX_PRICING_SUSPENSION` from now, so liquidations wait while borrowers can still repay. A time not in the future lifts the suspension. Updates and acceptances run during a suspension.

#### `setParameters`

```solidity
function setParameters(Parameters calldata parameters) external;
```

Sets every parameter at once and drops the pending anchor; the anchor and `highWaterMark` stay where they are. Each bound must be above zero and below a whole price, each speed at most a whole price a year, `maxAnchorBelowMark` and `maxAnchorAboveMark` below a whole price, the delay at least `MIN_REANCHOR_DELAY` and no longer than the rise speed takes to cover the upper bound, and the window above zero.

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `MANAGER_ROLE` | `bytes32` (constant) | Sets the parameters and suspends pricing. |
| `PRICE_ACCEPTOR_ROLE` | `bytes32` (constant) | Accepts the current price as the anchor, whatever its distance from the last one. |
| `PRICE_SCALE` | `uint256` (immutable) | 10^(ORACLE_PRICE_DECIMALS + loanDecimals - collateralDecimals - PRICE_DECIMALS): the scaling of a price to the price Morpho reads. |
| `MIN_REANCHOR_DELAY` | `uint256` (constant) | Shortest `reanchorDelay`. |
| `MAX_PRICING_SUSPENSION` | `uint256` (constant) | Longest a pricing suspension may run from the call that sets it. |
| `maxPriceAboveAnchor` | `uint64` | How far the current price may sit above the anchor price before `price()` reverts, as a fraction of it, WAD. 0.0005e18 allows 0.05%. |
| `maxPriceBelowAnchor` | `uint64` | How far the current price may sit below the anchor price before `price()` reverts, as a fraction of it, WAD. 0.001e18 allows 0.1%. |
| `anchorAt` | `uint40` | When the anchor price was last set. |
| `pricingResumesAt` | `uint40` | Time before which `price()` reverts with `PricingSuspended`. |
| `anchorPrice` | `uint256` | Price the current price is compared with, with `PRICE_DECIMALS` decimals. |
| `maxAnchorRisePerYear` | `uint64` | Yearly speed at which an update may raise the anchor toward a price within the bounds, as a fraction of the anchor price, WAD. 0.06e18 lets it rise 6% a year, about 0.016% a day. |
| `maxAnchorFallPerYear` | `uint64` | Yearly speed at which an update may lower the anchor toward a price within the bounds, as a fraction of the anchor price, WAD. 0.01e18 lets it fall 1% a year, about 0.003% a day. |
| `reanchorDelay` | `uint40` | Seconds a pending anchor waits before an update can re-anchor. |
| `reanchorWindow` | `uint40` | Seconds after the delay during which an update can re-anchor; after them the pending anchor expires, and the next update drops it or replaces it with a current price outside the bounds. |
| `pendingAnchorAt` | `uint40` | When the pending anchor was recorded; zero for none. |
| `pendingAnchorPrice` | `uint256` | Current price an update recorded outside the bounds, with `PRICE_DECIMALS` decimals; zero for none. The next re-anchor moves the anchor at most onto it: onto the current price if that sits nearer, and never past the floor or the ceiling. |
| `maxAnchorBelowMark` | `uint64` | How far below `highWaterMark` an update may take the anchor, as a fraction of it, WAD. 0.01e18 allows 1%. |
| `maxAnchorAboveMark` | `uint64` | How far above `highWaterMark` a re-anchor may take the anchor, as a fraction of it, WAD. 0.002e18 allows 0.2%. |
| `highWaterMark` | `uint256` | Price the floor and the ceiling are measured from, with `PRICE_DECIMALS` decimals: the seed or the last accepted price, raised by a drift up, onto the new anchor when that passes it, or by the drift's step while the anchor already sits above it. A re-anchor never moves it, so a re-anchor up may leave the anchor above it, up to the ceiling. |

## UsdyNavOracle

NAV oracle for USDY, reading Ondo's price getter.

### Functions

#### `constructor`

```solidity
constructor(address source, address loanToken, address collateralToken);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `SOURCE` | `IOndoPriceGetter` (immutable) | Ondo's documented price getter for USDY. |

## CentrifugeNavOracle

NAV oracle for a Centrifuge share class, reading the Spoke's share price.

The Spoke's own validity check is not requested, since its maximum age is unbounded on the deployed pools.

### Functions

#### `constructor`

```solidity
constructor(
    address spoke,
    uint64 poolId,
    bytes16 scId,
    address loanToken,
    address collateralToken
);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `SPOKE` | `ICentrifugeSpoke` (immutable) | Centrifuge Spoke holding the price registry. |
| `POOL_ID` | `uint64` (immutable) | Pool and share class the collateral token belongs to. |
| `SHARE_CLASS_ID` | `bytes16` (immutable) |  |
