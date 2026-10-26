<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# NAV Oracle

The NAV oracle family. `TrailingAnchorOracleBase` holds every rule and each adapter binds one source and overrides only how it is read. The mechanism, its invariants and its calibration are specified in [Trailing Anchor Oracle](../trailing-anchor-oracle.md).

Standard inherited role-membership and role-administration functions are not repeated; see [OpenZeppelin AccessControlEnumerable](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControlEnumerable).

## TrailingAnchorOracleBase

Lido Lend oracle for collateral priced from a source quoted in the loan token's currency, at one loan token per unit of that currency. It returns the current price scaled by `PRICE_SCALE`, and reverts while that price sits outside the bounds around the stored anchor price or while the anchor is older than its lifetime.

Concrete oracles bind one source in their constructor and override `_currentPrice()` with its ABI. Each declares its own storage namespace, so an anchor never carries over to an adapter of another kind. Anyone can move the anchor toward the current price, in any block and also while that price sits outside the bounds, by at most `maxAnchorRise` up or `maxAnchorFall` down a year for the time since the anchor last moved, capped at its lifetime. So the bounds are how far the price can move from the anchor at once, and the speeds how fast the anchor, and the bounds with it, can follow a source that keeps moving: a source held at the upper bound gains the bound once and then the rise speed. An update needs a current price other than the one the anchor last moved on, so a source that stops changing moves the anchor at most once more, and the oracle goes stale one lifetime later even while the anchor still trails it. An update refuses a stale anchor, so reviving one, like a move faster than the speeds, needs the price acceptor or the manager.

### Events

#### `AnchorSet`

```solidity
event AnchorSet(uint256 anchorPrice, uint40 anchorAt, bool accepted);
```

The anchor was set: by an open update, toward the current price as far as the speeds allow, or to the current price by the seed in `initialize()` or by `acceptPrice()`, `accepted` telling which.

#### `MaxPriceIncreaseSet`

```solidity
event MaxPriceIncreaseSet(uint256 maxPriceIncrease);
```

The allowed price increase changed.

#### `MaxPriceDecreaseSet`

```solidity
event MaxPriceDecreaseSet(uint256 maxPriceDecrease);
```

The allowed price decrease changed.

#### `AnchorLifetimeSet`

```solidity
event AnchorLifetimeSet(uint256 anchorLifetime);
```

The anchor lifetime changed.

#### `MaxAnchorRiseSet`

```solidity
event MaxAnchorRiseSet(uint256 maxAnchorRise);
```

The anchor's rise speed changed.

#### `MaxAnchorFallSet`

```solidity
event MaxAnchorFallSet(uint256 maxAnchorFall);
```

The anchor's fall speed changed.

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

#### `InvalidMaxPriceIncrease`

```solidity
error InvalidMaxPriceIncrease(uint256 maxPriceIncrease);
```

The allowed price increase is zero or reaches a whole price.

#### `InvalidMaxPriceDecrease`

```solidity
error InvalidMaxPriceDecrease(uint256 maxPriceDecrease);
```

The allowed price decrease is zero or reaches a whole price.

#### `InvalidAnchorLifetime`

```solidity
error InvalidAnchorLifetime(uint256 anchorLifetime);
```

The anchor lifetime is zero or not below `MAX_ANCHOR_LIFETIME`.

#### `InvalidMaxAnchorRise`

```solidity
error InvalidMaxAnchorRise(uint256 maxAnchorRise);
```

The anchor's rise speed is above a whole price a year.

#### `InvalidMaxAnchorFall`

```solidity
error InvalidMaxAnchorFall(uint256 maxAnchorFall);
```

The anchor's fall speed is above a whole price a year.

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

#### `StaleAnchor`

```solidity
error StaleAnchor(uint40 anchorAt, uint40 anchorLifetime);
```

The anchor is older than its lifetime.

#### `SourceUnchanged`

```solidity
error SourceUnchanged(uint256 currentPrice);
```

The current price is the one the anchor last moved on: the source has not changed since.

#### `AnchorUnchanged`

```solidity
error AnchorUnchanged(uint256 currentPrice);
```

The update would leave the anchor where it is: the current price equals it, or the speeds allow no move yet.

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
function initialize(
    address admin,
    uint256 maxPriceIncrease_,
    uint256 maxPriceDecrease_,
    uint256 anchorLifetime_,
    uint256 maxAnchorRise_,
    uint256 maxAnchorFall_
) external;
```

Grants the admin, stores the allowed price increase and decrease, the anchor lifetime and the anchor's rise and fall speeds, and seeds the anchor from the current price.

#### `price`

```solidity
function price() external view returns (uint256);
```

#### `updateAnchor`

```solidity
function updateAnchor() external;
```

Moves the anchor toward the current price, by at most `maxAnchorRise` up or `maxAnchorFall` down a year for the time since it last moved, capped at its lifetime. Open to anyone in any block, also while `price()` reverts on the bounds: the speeds alone limit how far the anchor follows the source, and since each update counts only the time since the last move, the anchor follows at the speeds however often it is called. It reverts on a stale anchor, which only the price acceptor or a longer lifetime revives; on a source that has not changed since the anchor last moved, so a frozen source cannot keep it fresh; and when it would not move the anchor.

`block.timestamp` sets the time counted: a validator's few seconds of skew move the reach by the speeds times those seconds. Both reach terms round down, toward the anchor, and the fall term stays under the anchor price, since the fall speed is at most a whole price a year and the lifetime under a month.

#### `acceptPrice`

```solidity
function acceptPrice(uint256 minPrice, uint256 maxPrice) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `minPrice` | `uint256` | Lowest current price to accept, inclusive, with `PRICE_DECIMALS` decimals. |
| `maxPrice` | `uint256` | Highest current price to accept, inclusive, with `PRICE_DECIMALS` decimals. |

Moves the anchor to the current price wherever it sits, once the price acceptor has checked the value: the way out of a stale anchor short of a longer lifetime, and out of a revert on the bounds faster than the speeds allow. A current price outside `minPrice` and `maxPrice` is refused, so a price that moved after the check is not accepted.

#### `setMaxPriceIncrease`

```solidity
function setMaxPriceIncrease(uint256 newMaxPriceIncrease) external;
```

Sets the allowed price increase. It applies at once and leaves the anchor where it is.

#### `setMaxPriceDecrease`

```solidity
function setMaxPriceDecrease(uint256 newMaxPriceDecrease) external;
```

Sets the allowed price decrease. It applies at once and leaves the anchor where it is.

#### `setAnchorLifetime`

```solidity
function setAnchorLifetime(uint256 newAnchorLifetime) external;
```

Sets the anchor lifetime. It applies at once, also to the time since the anchor last moved, and leaves the anchor where it is.

#### `setMaxAnchorRise`

```solidity
function setMaxAnchorRise(uint256 newMaxAnchorRise) external;
```

Sets the anchor's yearly rise speed, `maxAnchorRise`. It applies at once, also to the time since the anchor last moved, and leaves the anchor where it is.

#### `setMaxAnchorFall`

```solidity
function setMaxAnchorFall(uint256 newMaxAnchorFall) external;
```

Sets the anchor's yearly fall speed, `maxAnchorFall`. It applies at once, also to the time since the anchor last moved, and leaves the anchor where it is.

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `MANAGER_ROLE` | `bytes32` (constant) | Sets the allowed price increase and decrease, the anchor lifetime and the anchor's rise and fall speeds. |
| `PRICE_ACCEPTOR_ROLE` | `bytes32` (constant) | Accepts the current price as the anchor, whatever its distance from the last one. |
| `PRICE_SCALE` | `uint256` (immutable) | 10^(ORACLE_PRICE_DECIMALS + loanDecimals - collateralDecimals - PRICE_DECIMALS): the scaling of a price to the price Morpho reads. |
| `MAX_ANCHOR_LIFETIME` | `uint256` (constant) | Bound `anchorLifetime` stays below. |
| `maxPriceIncrease` | `uint64` | How far the current price may sit above the anchor price before `price()` reverts, as a fraction of the anchor price, WAD: the rise the price may make from the anchor at once. 0.0005e18 allows 0.05%. |
| `maxPriceDecrease` | `uint64` | How far the current price may sit below the anchor price before `price()` reverts, as a fraction of the anchor price, WAD: the fall the price may make from the anchor at once. 0.001e18 allows 0.1%. |
| `anchorLifetime` | `uint40` | Seconds after the anchor last moved before `price()` and `updateAnchor()` revert as stale, so an update counts at most one lifetime of movement. |
| `anchorAt` | `uint40` | When the anchor price was last set. |
| `anchorPrice` | `uint256` | Price the current price is compared with, with `PRICE_DECIMALS` decimals. |
| `maxAnchorRise` | `uint64` | Yearly speed at which an update may raise the anchor: the fraction of the anchor price it may add per year since the anchor last moved, WAD. 0.06e18 lets it rise 6% a year, about 0.016% a day. |
| `maxAnchorFall` | `uint64` | Yearly speed at which an update may lower the anchor: the fraction of the anchor price it may take off per year since the anchor last moved, WAD. 0.01e18 lets it fall 1% a year, about 0.003% a day. |
| `sourcePrice` | `uint256` | Current price the anchor last moved on, read by the seed, an acceptance or an update, with `PRICE_DECIMALS` decimals. An update that reads the same price reverts, so a source that stops changing cannot keep the anchor fresh. |

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
