<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# Exit Books

The lender exit-book layer. An abstract `ExitBookBase` holds the shared fill, cancel, and fee surface, and a concrete book binds it to a source — `Erc4626ExitBook` over a vault, `MorphoExitBook` over a market.

## ExitBookBase

Source-agnostic surface of an exit book: configure the service fee, fill and cancel requests, and read them (with optional live fill previews). Concrete books (ERC-4626, Morpho, ...) add their own `placeExitRequest` and allow-list admin on top.

### Enums

#### `ExitStatus`

```solidity
enum ExitStatus {
    Open,
    Filled,
    Cancelled
}
```

Lifecycle marker. `Expired` is not stored — it is derived from `block.timestamp > deadline`.

### Structs

#### `PriorityRamp`

```solidity
struct PriorityRamp {
    uint256 startRate;
    uint256 endRate;
    uint256 rampStart;
    uint256 rampEnd;
}
```

Lender-set priority-fee schedule — a Dutch auction on the fee carved out of the amount owed. The rate holds at `startRate` for `rampStart` seconds from creation, then climbs linearly to `endRate` by `rampEnd`, then holds at `endRate` until the deadline. Rates are WAD fractions, each capped at `MAX_PRIORITY_FEE`.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `startRate` | `uint256` | Priority-fee rate (WAD) charged from creation through the `rampStart` hold. |
| `endRate` | `uint256` | Priority-fee rate (WAD) reached after the ramp and held to the deadline; `>= startRate`. |
| `rampStart` | `uint256` | Seconds from creation the rate holds at `startRate` before the climb begins (0 climbs immediately). |
| `rampEnd` | `uint256` | Seconds from creation the climb reaches `endRate` (>= `rampStart`, equal means an instant jump). |

#### `Request`

```solidity
struct Request {
    address owner;
    uint40 createdAt;
    uint40 deadline;
    ExitStatus status;
    address receiver;
    uint128 sizeRemaining;
    uint128 sizeTotal;
    uint256 quotedAssets;
    uint256 minShareRate;
    uint256 minFillShares;
    uint96 startRate;
    uint96 endRate;
    uint32 rampStart;
    uint32 rampEnd;
}
```

One exit request's source-agnostic lifecycle state. The backing source (which vault / which market) lives in a per-id mapping outside this record. Shares are `uint128` (capped via SafeCast at creation) so the record packs tighter.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | The exiting lender whose position the fill redeems, and the only address that may cancel. |
| `createdAt` | `uint40` | Creation timestamp: the fee schedule's start. |
| `deadline` | `uint40` | Last timestamp the request may be filled. Chosen by the lender, capped at `createdAt + MAX_REQUEST_LIFETIME` and never earlier than `createdAt + rampEnd`. |
| `status` | `ExitStatus` | Open / Filled / Cancelled (Expired is derived). |
| `receiver` | `address` | Address credited the lender's proceeds. |
| `sizeRemaining` | `uint128` | Outstanding shares to fill. The concrete book defines the fixed placement entitlement. |
| `sizeTotal` | `uint128` | Original shares used to apportion the full placement quote across fills. |
| `quotedAssets` | `uint256` | Asset value quoted for all `sizeTotal` shares at sizing. |
| `minShareRate` | `uint256` | Loan assets per `SHARE_RATE_UNIT` source shares at sizing. A fill is rejected while the source quotes less. |
| `minFillShares` | `uint256` | Smallest size a single fill may close; 0 for no minimum. A fill qualifies at or above it, or when it takes the whole remaining size. At or above `sizeTotal` only a full close qualifies. |
| `startRate` | `uint96` | Priority-fee rate (WAD) in force from `createdAt` through the `rampStart` hold. |
| `endRate` | `uint96` | Priority-fee rate (WAD) reached at `createdAt + rampEnd` and held to the deadline. |
| `rampStart` | `uint32` | Seconds from `createdAt` the rate holds at `startRate` before the climb begins. |
| `rampEnd` | `uint32` | Seconds from `createdAt` the climb reaches `endRate`. |

#### `RequestPreview`

```solidity
struct RequestPreview {
    uint256 id;
    Request request;
    IERC20 asset;
    uint256 filledShares;
    uint256 assetsOut;
}
```

A request paired with its live fill preview, for one-call scans. `id` is the registry key (a `Request` does not carry its own id, and does not copy the source's loan token); `filledShares` and `assetsOut` mirror `previewFill` and are 0 when the request is closed, expired, unbacked, below its minimum fill, or under its rate floor.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request's registry id. |
| `request` | `Request` | The stored request. |
| `asset` | `IERC20` | The loan token this request pays out in, resolved from its source at read time. |
| `filledShares` | `uint256` | Shares fillable right now (see `previewFill`). |
| `assetsOut` | `uint256` | Assets those shares would yield right now (see `previewFill`). |

### Events

#### `ExitRequested`

```solidity
event ExitRequested(uint256 indexed id, address indexed owner, address indexed receiver, address asset, uint256 shares, uint256 minShareRate, uint256 minFillShares, PriorityRamp ramp, uint256 deadline);
```

#### `ExitProcessed`

```solidity
event ExitProcessed(uint256 indexed id, address indexed filler, address asset, uint256 filledShares, uint256 lenderAssets, uint256 fillerFee, uint256 serviceCut);
```

#### `ExitCancelled`

```solidity
event ExitCancelled(uint256 indexed id);
```

#### `ServiceFeeSet`

```solidity
event ServiceFeeSet(address indexed feeRecipient, uint256 serviceFee);
```

### Errors

#### `ZeroAssetQuote`

```solidity
error ZeroAssetQuote();
```

Thrown when a request's full share amount quotes to zero assets at placement.

#### `ZeroAddress`

```solidity
error ZeroAddress();
```

#### `ZeroShares`

```solidity
error ZeroShares();
```

#### `ZeroMaxLifetime`

```solidity
error ZeroMaxLifetime();
```

#### `FeeTooHigh`

```solidity
error FeeTooHigh();
```

#### `FeeRecipientRequired`

```solidity
error FeeRecipientRequired();
```

#### `PriorityFeeTooHigh`

```solidity
error PriorityFeeTooHigh();
```

#### `StartFeeAboveEnd`

```solidity
error StartFeeAboveEnd();
```

#### `RampStartAfterEnd`

```solidity
error RampStartAfterEnd();
```

#### `RampPastDeadline`

```solidity
error RampPastDeadline();
```

#### `ShareRateBelowMinimum`

```solidity
error ShareRateBelowMinimum();
```

#### `NoFillableShares`

```solidity
error NoFillableShares();
```

#### `NoAssetsRedeemed`

```solidity
error NoAssetsRedeemed();
```

#### `AssetsOutBelowMin`

```solidity
error AssetsOutBelowMin();
```

#### `DeadlineInPast`

```solidity
error DeadlineInPast();
```

#### `DeadlineTooFar`

```solidity
error DeadlineTooFar();
```

### Functions

#### `SHARE_RATE_UNIT`

```solidity
function SHARE_RATE_UNIT() external view returns (uint256);
```

Share amount a source share rate is quoted per — the unit of a request's `minShareRate`.

#### `setServiceFee`

```solidity
function setServiceFee(address recipient, uint256 fee) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `recipient` | `address` | Address paid the service fee (a cut of each fill's filler reward); the zero address is allowed only when `fee` is 0. |
| `fee` | `uint256` | Service-fee rate (WAD), capped at `MAX_SERVICE_FEE`. |

Set the service fee and its recipient. `FEE_MANAGER_ROLE` only.

#### `fillExitRequest`

```solidity
function fillExitRequest(
    uint256 id,
    uint256 depositAssets,
    uint256 minAssetsOut
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request to fill. |
| `depositAssets` | `uint256` | Asset amount to first deposit into the request's source (becoming the depositor) so the fill can be honoured; 0 to fill against existing liquidity only. |
| `minAssetsOut` | `uint256` | Slippage floor on the redeem proceeds: the fill reverts (rolling back any deposit) if fewer assets arrive; 0 to skip. |

Fill request `id` against available source liquidity, paying the lender, the filler (caller), and the service in the same transaction.

#### `cancelExitRequest`

```solidity
function cancelExitRequest(uint256 id) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request to cancel. |

Cancel an open request; nothing is refunded (the book holds no balances). Caller must own it.

#### `getExitRequest`

```solidity
function getExitRequest(uint256 id) external view returns (Request memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request id. |

The stored request at `id` (a zeroed record if it never existed).

#### `getRequests`

```solidity
function getRequests(
    uint256[] calldata ids
) external view returns (Request[] memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `ids` | `uint256[]` | The request ids to read. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `Request[]` | The request records, one per id, in the same order. |

The stored requests at `ids` (closed ones included) — a cheap batch read with no source calls.

#### `lastRequestId`

```solidity
function lastRequestId() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | The highest request id issued so far; callers scan the `[1, lastRequestId]` range. |

The last request id issued (ids start at 1; 0 means none yet).

#### `getOwnerRequestCount`

```solidity
function getOwnerRequestCount(address owner) external view returns (uint256);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | The lender to count requests for. |

How many requests `owner` has ever opened.

#### `getOwnerRequestIds`

```solidity
function getOwnerRequestIds(
    address owner,
    uint256 offset,
    uint256 count
) external view returns (uint256[] memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | The lender whose request ids to read. |
| `offset` | `uint256` | Index in the owner's id list to start from. |
| `count` | `uint256` | Maximum number of ids to return (clamped to what remains). |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256[]` | The owner's request ids in `[offset, offset + count)`. |

A page of `owner`'s request ids in creation order (closed ones included).

#### `getRequestPreviews`

```solidity
function getRequestPreviews(
    uint256[] calldata ids
) external view returns (RequestPreview[] memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `ids` | `uint256[]` | The request ids to preview. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `RequestPreview[]` | One preview per id, in the same order. |

`previewFill` for each id in `ids` (an off-chain-gathered set), in one call.

#### `previewFill`

```solidity
function previewFill(uint256 id) external view returns (RequestPreview memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request to preview. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `RequestPreview` | The request with the shares fillable now and the assets they would yield (all 0 when the request is closed, expired, unbacked, below its minimum fill, or quoting under its `minShareRate` floor). |

The request at `id` paired with its live fill preview — the single-id `getRequestPreviews`.

## Erc4626ExitBook

Exit book backed by shares of governance-allowed ERC-4626 vaults. Extends the common exit-book surface (`IExitBook`) with vault placement and allow-list admin.

### Events

#### `VaultAllowedSet`

```solidity
event VaultAllowedSet(address indexed vault, bool allowed);
```

### Errors

#### `VaultNotAllowed`

```solidity
error VaultNotAllowed();
```

#### `ZeroVault`

```solidity
error ZeroVault();
```

### Functions

#### `isVaultAllowed`

```solidity
function isVaultAllowed(IERC4626 vault) external view returns (bool);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `vault` | `IERC4626` | The vault to query. |

Whether `vault` is allowed for new requests.

#### `vaultOf`

```solidity
function vaultOf(uint256 id) external view returns (IERC4626);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request id. |

The source vault request `id` was placed against (zero if none).

#### `setVaultAllowed`

```solidity
function setVaultAllowed(IERC4626 vault, bool allowed) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `vault` | `IERC4626` | The vault to allow or disallow. |
| `allowed` | `bool` | True to allow new requests against it; false to block them (already-placed ones still fill). |

Allow or disallow `vault` for new requests. `ALLOWLIST_MANAGER_ROLE` only.

#### `placeExitRequest`

```solidity
function placeExitRequest(
    IERC4626 vault,
    uint256 assets,
    address receiver,
    uint256 minFillAssets,
    PriorityRamp calldata ramp,
    uint256 deadline
) external returns (uint256 id);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `vault` | `IERC4626` | The allowed ERC-4626 vault. |
| `assets` | `uint256` | Loan-asset amount to exit. Converted to source shares at the vault's current share rate and stored as the request's fixed size; the caller's holdings are not checked here, the fill reads them live. |
| `receiver` | `address` | Address credited the lender's proceeds of every fill. |
| `minFillAssets` | `uint256` | Smallest amount a single fill may close; 0 for no minimum. A fill qualifies at or above it, or when it takes the whole of what is left, so the minimum never locks in a sub-minimum remainder on its own. At or above the request's own quote only a full close qualifies. Converted to shares at placement and enforced in shares thereafter. |
| `ramp` | `PriorityRamp` | Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end. |
| `deadline` | `uint256` | Fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The new request id. |

Open an exit against the caller's shares in an allowed `vault`, sized by the asset amount they want out. Permission-only: nothing is escrowed, and the fill redeems the caller's shares through the allowance they granted this book.

## MorphoExitBook

Exit book backed by supply positions in governance-allowed Morpho markets. Extends the common exit-book surface (`IExitBook`) with market placement and allow-list admin.

### Events

#### `MarketAllowedSet`

```solidity
event MarketAllowedSet(Id indexed marketId, bool allowed);
```

### Errors

#### `MarketNotAllowed`

```solidity
error MarketNotAllowed();
```

#### `MarketNotCreated`

```solidity
error MarketNotCreated();
```

#### `NotAuthorizedOnMorpho`

```solidity
error NotAuthorizedOnMorpho();
```

#### `ZeroMorpho`

```solidity
error ZeroMorpho();
```

### Functions

#### `MORPHO`

```solidity
function MORPHO() external view returns (IMorpho);
```

The Morpho deployment this book reads positions from and withdraws against.

#### `isMarketAllowed`

```solidity
function isMarketAllowed(Id marketId) external view returns (bool);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id to query. |

Whether market `marketId` is allowed for new requests.

#### `marketParamsOf`

```solidity
function marketParamsOf(
    uint256 requestId
) external view returns (MarketParams memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `requestId` | `uint256` | The request id. |

The market params request `requestId` was placed against (empty if none).

#### `setMarketAllowed`

```solidity
function setMarketAllowed(
    MarketParams calldata marketParams,
    bool allowed
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketParams` | `MarketParams` | The market's full params; its id (the params' hash) is the allow-list key. |
| `allowed` | `bool` | True to allow new requests against it; false to block them (already-placed ones still fill). |

Register `marketParams` (which must name a live Morpho market, checked on both allow and disallow) and allow or disallow it for new requests. The params are kept permanently (so requests already placed stay fillable after a disallow); disallowing only flips the gate. `ALLOWLIST_MANAGER_ROLE` only.

#### `placeExitRequest`

```solidity
function placeExitRequest(
    Id marketId,
    uint256 assets,
    address receiver,
    uint256 minFillAssets,
    PriorityRamp calldata ramp,
    uint256 deadline
) external returns (uint256 id);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The allowed market's id (its `MarketParams` hash, registered via `setMarketAllowed`). |
| `assets` | `uint256` | Loan-asset amount to exit. Converted to supply shares at the market's current share rate and stored as the request's fixed size; the caller's holdings are not checked here, the fill reads them live. |
| `receiver` | `address` | Address credited the lender's proceeds of every fill. |
| `minFillAssets` | `uint256` | Smallest amount a single fill may close; 0 for no minimum. A fill qualifies at or above it, or when it takes the whole of what is left, so the minimum never locks in a sub-minimum remainder on its own. At or above the request's own quote only a full close qualifies. Converted to shares at placement and enforced in shares thereafter. |
| `ramp` | `PriorityRamp` | Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end. |
| `deadline` | `uint256` | Fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The new request id. |

Open an exit against the caller's supply position in an allowed Morpho market, named by its `marketId` and sized by the asset amount they want out. Permission-only: nothing is escrowed, and the fill withdraws on the caller's behalf, so they must have authorized this book on Morpho.
