<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# NAV Oracle

The NAV oracle family. `NavOracleBase` holds every rule and each adapter binds one source and overrides only how it is read. The mechanism, its invariants and its calibration are specified in [NAV Oracle](../nav-oracle.md).

Standard inherited role-membership and role-administration functions are not repeated; see [OpenZeppelin AccessControlEnumerable](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControlEnumerable).

## NavOracleBase

Lido Lend oracle for collateral priced from an issuer-published net asset value, quoted in a USD stablecoin loan token at one loan token per USD. The price is the live source value held under an upper bound that grows from a stored reference price and above a floor that falls from a stored checkpoint price by one step per elapsed interval, and it reverts while the source sits outside a band around the expected price or the loan token is off its peg.

Concrete oracles bind one source in their constructor and override `_readSource()` with its ABI. All of them share one storage namespace, so one can replace another behind the proxy without losing the stored prices. `price()` is a view: the floor falls with time and needs no call. The checkpoint price and the reference price move through `checkpoint()` and `moveReferencePrice()`, both open to anyone and both unable to change the current price, or through the configurator role. A check parameter change keeps the expected price and the floor where they were, so it never changes the price by itself, except that a changed growth tolerance moves the upper bound at once.

### Structs

#### `NavOracleCheckParams`

```solidity
struct NavOracleCheckParams {
    uint256 yearlyGrowthRate;
    uint256 growthTolerance;
    uint256 maxFallPerInterval;
    uint256 maxDrawdown;
    uint256 maxOvershoot;
    uint256 maxLoanTokenDeviation;
    uint256 minPriceRatio;
    uint256 maxBorrowRate;
    uint40 fallInterval;
    uint40 referenceInterval;
}
```

Check parameters of one NAV oracle market that the configurator can change. The two intervals come last so that they share one storage slot.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `yearlyGrowthRate` | `uint256` | Yearly rate the expected price grows at from the reference price, WAD. |
| `growthTolerance` | `uint256` | Fraction above the expected price the upper price bound sits at, WAD. |
| `maxFallPerInterval` | `uint256` | Fraction of the checkpoint price the floor falls by per elapsed interval, WAD. |
| `maxDrawdown` | `uint256` | Fraction below the expected price the source price may sit before `price()` reverts, WAD. |
| `maxOvershoot` | `uint256` | Fraction above the expected price the source price may sit before `price()` reverts, WAD. |
| `maxLoanTokenDeviation` | `uint256` | Fraction around 1 USD inside which the loan token's feed answer is ignored, WAD. |
| `minPriceRatio` | `uint256` | Lowest allowed ratio between the lowest and the highest price the rules can return across one reference price move, `(1 − maxDrawdown) × (1 − growthTolerance) / (1 + protectedGrowthTolerance)`, before the interest allowance, WAD. |
| `maxBorrowRate` | `uint256` | Highest borrow rate per second the market's interest rate model can charge, WAD. Debt accrues at most this much while the floor holds the price above the source. |
| `fallInterval` | `uint40` | Seconds per floor step, and the least time between two checkpoints. |
| `referenceInterval` | `uint40` | Seconds after a reference price move before anyone may move it again. |

### Events

#### `CheckpointSet`

```solidity
event CheckpointSet(uint256 checkpointPrice, uint40 checkpointAt);
```

The checkpoint price the floor falls from was set: to the source price or the expected price, whichever is lower, by a checkpoint, to the source price by an acceptance, or to the current floor when the fall limit changed.

#### `ReferencePriceSet`

```solidity
event ReferencePriceSet(uint256 referencePrice, uint40 referencePriceSetAt, bool accepted);
```

The reference price was set: to the source price by an open move or by the configurator's acceptance, `accepted` telling which, or to the current expected price when the growth rate changed.

#### `CheckParamsSet`

```solidity
event CheckParamsSet(NavOracleCheckParams params);
```

Check parameters changed.

#### `ProtectedGrowthToleranceSet`

```solidity
event ProtectedGrowthToleranceSet(uint256 protectedGrowthTolerance);
```

The protected growth tolerance changed: raised with the growth tolerance, or released by the configurator.

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

#### `InvalidFallLimit`

```solidity
error InvalidFallLimit(uint256 maxFallPerInterval, uint40 fallInterval);
```

The fall limit has no interval, no step, or a step that drops the floor to zero in one interval.

#### `InvalidRevertBand`

```solidity
error InvalidRevertBand(uint256 maxDrawdown, uint256 maxOvershoot, uint256 growthTolerance);
```

The revert band would allow the price to reach zero or would sit inside the upper bound.

#### `ReferenceIntervalTooShort`

```solidity
error ReferenceIntervalTooShort(uint40 referenceInterval, uint256 leastAllowed);
```

The reference interval does not let the floor cross the corridor between two reference moves.

#### `InvalidLoanTokenDeviation`

```solidity
error InvalidLoanTokenDeviation(uint256 maxLoanTokenDeviation);
```

The loan token deviation reaches a whole unit.

#### `InvalidMinPriceRatio`

```solidity
error InvalidMinPriceRatio(uint256 minPriceRatio);
```

The minimum price ratio is unset.

#### `InvalidReleasedTolerance`

```solidity
error InvalidReleasedTolerance(uint256 released, uint256 growthTolerance, uint256 protectedGrowthTolerance);
```

The released tolerance is under the current growth tolerance or over the protected one.

#### `PriceRatioBelowMinimum`

```solidity
error PriceRatioBelowMinimum(uint256 priceRatio, uint256 leastPriceRatio);
```

The drawdown and the tolerance let the price fall further across one reference move than the minimum price ratio allows, once grown by the interest debt accrues while the floor crosses the corridor.

#### `SourceReturnedZero`

```solidity
error SourceReturnedZero();
```

The source returned zero.

#### `PriceOutOfBounds`

```solidity
error PriceOutOfBounds(uint256 sourcePrice, uint256 lowestAllowed, uint256 highestAllowed);
```

The source price sits outside the revert band around the expected price.

#### `LoanTokenOffPeg`

```solidity
error LoanTokenOffPeg();
```

The loan token's feed answer is outside its allowed deviation.

#### `CheckpointIntervalNotElapsed`

```solidity
error CheckpointIntervalNotElapsed(uint40 checkpointAt, uint40 fallInterval);
```

The fall interval has not passed since the last checkpoint.

#### `ReferenceIntervalNotElapsed`

```solidity
error ReferenceIntervalNotElapsed(uint40 referencePriceSetAt, uint40 referenceInterval);
```

The reference interval has not passed since the reference price last moved.

#### `SourceBelowFloor`

```solidity
error SourceBelowFloor(uint256 sourcePrice, uint256 floor);
```

The floor holds the price above the source, so the checkpoint cannot move.

#### `SourceOutsideFloorAndBound`

```solidity
error SourceOutsideFloorAndBound(uint256 sourcePrice, uint256 floor, uint256 upperBound);
```

The source price is under the floor or over the upper bound, so the reference price move that must keep the price cannot run.

#### `SourceBelowGrowthTolerance`

```solidity
error SourceBelowGrowthTolerance(uint256 sourcePrice, uint256 lowestAllowed);
```

The source price sits further under the expected price than the growth tolerance.

#### `InvalidAcceptRange`

```solidity
error InvalidAcceptRange(uint256 lowest, uint256 highest);
```

The accepted range is empty.

#### `SourceOutsideAcceptRange`

```solidity
error SourceOutsideAcceptRange(uint256 sourcePrice, uint256 lowest, uint256 highest);
```

The source price sits outside the range the configurator accepts.

### Functions

#### `constructor`

```solidity
constructor(address loanToken, address collateralToken, address loanTokenFeed);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `loanToken` | `address` | Loan stablecoin; its decimals set the returned domain. |
| `collateralToken` | `address` | Collateral token; its decimals set the returned domain. |
| `loanTokenFeed` | `address` | Chainlink USD feed of the loan token. |

#### `initialize`

```solidity
function initialize(
    address admin,
    NavOracleCheckParams calldata params
) external;
```

Grants the admin, stores the check parameters, and seeds the reference price and the checkpoint price from the current source price.

#### `price`

```solidity
function price() external view returns (uint256);
```

#### `checkParams`

```solidity
function checkParams() external view returns (NavOracleCheckParams memory);
```

Current check parameters.

#### `checkpoint`

```solidity
function checkpoint() external;
```

Raises the floor by setting the checkpoint at the source price, or at the expected price while the source sits above it, once the fall interval has passed since the last checkpoint. The floor trails an honest source and never climbs above the expected path, so a print above it is never recorded and its reversal is held by nothing but the path. Refused while the floor holds the price above the source, so a call can never lift a held price or restart a fall.

#### `moveReferencePrice`

```solidity
function moveReferencePrice() external;
```

Moves the reference price to the current source price, once the reference interval has passed since the last move. Allowed only while the source sits within the growth tolerance of the expected price and between the floor and the upper bound, so the move corrects the drift between the configured and the realized yield without changing the price or touching the floor.

#### `acceptCurrentPrice`

```solidity
function acceptCurrentPrice(uint256 lowest, uint256 highest) external;
```

Moves the reference price and the checkpoint price to the current source price, provided it sits inside the accepted range: the way out of a revert on the band, and the way to admit a rise above the upper bound or a fall faster than the floor. The range is the one the configurator decided on, so a source that moved since cannot be accepted by mistake.

#### `setGrowthLimit`

```solidity
function setGrowthLimit(
    uint256 yearlyGrowthRate,
    uint256 growthTolerance
) external;
```

Sets the yearly growth rate of the expected price and the tolerance of the upper bound above it. A new rate applies from now on, the expected price stays where it is. A changed tolerance moves the upper bound at once.

#### `setFallLimit`

```solidity
function setFallLimit(uint256 maxFallPerInterval, uint40 fallInterval) external;
```

Sets the floor's step per interval and the interval, which is also the least time between two checkpoints. The new step and interval apply from now on, the floor stays where it is.

#### `setRevertBand`

```solidity
function setRevertBand(
    uint256 maxDrawdown,
    uint256 maxOvershoot,
    uint40 referenceInterval
) external;
```

Sets the revert band around the expected price and the interval between two open reference price moves.

#### `setMarketLimits`

```solidity
function setMarketLimits(uint256 minPriceRatio, uint256 maxBorrowRate) external;
```

Sets what the corridor answers for that only the market knows: the lowest ratio the drawdown and the tolerance may leave between the lowest and the highest returnable price across one reference move, which the market's LLTV and liquidation incentive decide, and the highest borrow rate per second its interest rate model can charge, which sets how much debt grows while the floor holds the price.

#### `releaseGrowthTolerance`

```solidity
function releaseGrowthTolerance(uint256 released) external;
```

Lowers the protected growth tolerance, the one the corridor check still answers for after the growth tolerance was lowered, to `released`, no lower than the current growth tolerance. Debt taken under the old upper bound may still be open, so this is the configurator's statement that it no longer needs the old room.

#### `setLoanTokenPegCheck`

```solidity
function setLoanTokenPegCheck(uint256 maxLoanTokenDeviation) external;
```

Sets the allowed deviation of the loan token's feed answer from 1 USD.

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `CONFIG_ROLE` | `bytes32` (constant) | Sets the check parameters and accepts the current source price as the new reference and checkpoint price. |
| `PRICE_SCALE` | `uint256` (immutable) | 10^(36 + loanDecimals - collateralDecimals - 18): the 1e36 scaling of an 18-decimal NAV. |
| `LOAN_TOKEN_FEED` | `IChainlinkAggregator` (immutable) | Chainlink USD feed of the loan token, read as a peg signal only. |
| `ONE_USD_IN_FEED_DECIMALS` | `uint256` (immutable) | One USD in the feed's decimals. |
| `referencePrice` | `uint256` | Price the expected price grows from. |
| `checkpointPrice` | `uint256` | Price the floor falls from. |
| `referencePriceSetAt` | `uint40` | When the reference price was set. |
| `checkpointAt` | `uint40` | When the checkpoint price was set. |
| `protectedGrowthTolerance` | `uint256` | The largest growth tolerance debt may still have been taken under: it rises with the tolerance and falls only through `releaseGrowthTolerance()`. |

## UsdyOracle

NAV oracle for USDY, reading Ondo's price getter.

### Functions

#### `constructor`

```solidity
constructor(
    address source,
    address loanToken,
    address collateralToken,
    address loanTokenFeed
);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `SOURCE` | `IOndoPriceGetter` (immutable) | Ondo's documented price getter for USDY. |

## CentrifugeOracle

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
    address collateralToken,
    address loanTokenFeed
);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `SPOKE` | `ICentrifugeSpoke` (immutable) | Centrifuge Spoke holding the price registry. |
| `POOL_ID` | `uint64` (immutable) | Pool and share class the collateral token belongs to. |
| `SHARE_CLASS_ID` | `bytes16` (immutable) |  |

## ChainlinkNavOracle

NAV oracle for a collateral whose issuer or vendor publishes the NAV through a Chainlink-shaped feed.

`updatedAt` is not read: feeds refresh it on every heartbeat even while the value stands still.

### Errors

#### `UnsupportedFeedDecimals`

```solidity
error UnsupportedFeedDecimals(uint8 decimals);
```

The feed has more than 18 decimals.

#### `InvalidAnswer`

```solidity
error InvalidAnswer(int256 answer);
```

The feed answered zero or a negative value.

### Functions

#### `constructor`

```solidity
constructor(
    address source,
    address loanToken,
    address collateralToken,
    address loanTokenFeed
);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `SOURCE` | `IChainlinkAggregator` (immutable) | NAV feed. |
| `SOURCE_SCALE` | `uint256` (immutable) | 10^(18 - feed decimals): the scaling of the feed's answer to 18 decimals. |

## Erc4626Oracle

NAV oracle for a vault share, reading the vault's exchange rate into its asset.

The vault share is the collateral itself, so the source doubles as the collateral token. The asset is taken as one loan token per unit, so the vault's asset is the currency the market prices in.

### Errors

#### `UnsupportedAssetDecimals`

```solidity
error UnsupportedAssetDecimals(uint8 decimals);
```

The vault's asset has more than 18 decimals.

### Functions

#### `constructor`

```solidity
constructor(address source, address loanToken, address loanTokenFeed);
```

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `SOURCE` | `IERC4626` (immutable) | Vault whose share is the collateral. |
| `ONE_SHARE` | `uint256` (immutable) | One share in the vault's share decimals. |
| `SOURCE_SCALE` | `uint256` (immutable) | 10^(18 - asset decimals): the scaling of the exchange rate to 18 decimals. |
