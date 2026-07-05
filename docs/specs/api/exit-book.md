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
    IERC20 asset;
    uint128 sizeRemaining;
    uint128 sizeTotal;
    uint128 pricePerShare;
    uint96 startRate;
    uint96 endRate;
    uint32 rampStart;
    uint32 rampEnd;
    uint40 createdAt;
    uint40 deadline;
    bool fullFillOnly;
    ExitStatus status;
}
```

One exit request — lifecycle and pricing only. The backing source (which vault / which market) lives in the concrete book's per-id mappings, not here, so this struct is source-agnostic. Shares and the price snapshot are `uint128` (capped via SafeCast at creation) so the record packs tighter.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | The exiting lender, credited the proceeds and the only address that may cancel. |
| `asset` | `IERC20` | The underlying loan token paid out — proceeds and fees are denominated in it. |
| `sizeRemaining` | `uint128` | Outstanding shares to fill. The fixed-price amount owed is `sizeRemaining * pricePerShare`. |
| `sizeTotal` | `uint128` | Original shares at creation (informational). |
| `pricePerShare` | `uint128` | Assets per share (WAD), snapshotted at creation; yield above it is the filler's. |
| `startRate` | `uint96` | Priority-fee rate (WAD) in force from `createdAt` through the `rampStart` hold. |
| `endRate` | `uint96` | Priority-fee rate (WAD) reached at `createdAt + rampEnd` and held to the deadline. |
| `rampStart` | `uint32` | Seconds from `createdAt` the rate holds at `startRate` before the climb begins. |
| `rampEnd` | `uint32` | Seconds from `createdAt` the climb reaches `endRate`. |
| `createdAt` | `uint40` | Creation timestamp: the fee schedule's start. |
| `deadline` | `uint40` | Last timestamp the request may be filled. Chosen by the lender, capped at `createdAt + MAX_REQUEST_LIFETIME` and never earlier than `createdAt + rampEnd`. |
| `fullFillOnly` | `bool` | When true a fill must cover the whole remaining size in one shot or be rejected. |
| `status` | `ExitStatus` | Open / Filled / Cancelled (Expired is derived). |

#### `RequestPreview`

```solidity
struct RequestPreview {
    uint256 id;
    Request request;
    uint256 filledShares;
    uint256 assetsOut;
}
```

A request paired with its live fill preview, for one-call scans. `id` is the registry key (a `Request` does not carry its own id); `filledShares`/`assetsOut` mirror `previewFill` and are 0 when the request is closed, expired, or has no backing right now.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request's registry id. |
| `request` | `Request` | The stored request. |
| `filledShares` | `uint256` | Shares fillable right now (see `previewFill`). |
| `assetsOut` | `uint256` | Assets those shares would yield right now (see `previewFill`). |

### Events

#### `ExitRequested`

```solidity
event ExitRequested(uint256 indexed id, address indexed owner, address asset, uint256 shares, PriorityRamp ramp, uint256 deadline, bool fullFillOnly);
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

#### `setServiceFee`

```solidity
function setServiceFee(address recipient, uint256 fee) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `recipient` | `address` | Address paid the service fee (a cut of each fill's filler reward); the zero address is allowed only when `fee` is 0. |
| `fee` | `uint256` | Service-fee rate (WAD), capped at `MAX_SERVICE_FEE`. |

Set the service fee and its recipient. Owner only.

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
| `<none>` | `RequestPreview` | The request with the shares fillable now and the assets they would yield (all 0 if the request is closed, expired, or has no backing). |

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

#### `InsufficientBacking`

```solidity
error InsufficientBacking();
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

Allow or disallow `vault` for new requests. Owner only.

#### `placeExitRequest`

```solidity
function placeExitRequest(
    IERC4626 vault,
    uint256 shares,
    PriorityRamp calldata ramp,
    uint256 deadline,
    bool fullFillOnly
) external returns (uint256 id);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `vault` | `IERC4626` | The allowed ERC-4626 vault. |
| `shares` | `uint256` | Vault shares to exit. |
| `ramp` | `PriorityRamp` | Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end. |
| `deadline` | `uint256` | Fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends. |
| `fullFillOnly` | `bool` | When true a fill must cover the whole remaining size in one shot. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The new request id. |

Open an exit backed by `shares` of an allowed `vault`. Permission-only: the caller must have approved this book for `shares` and hold them; the fill redeems them via the allowance.

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

#### `InsufficientBacking`

```solidity
error InsufficientBacking();
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

Register `marketParams` (which must name a live Morpho market, checked on both allow and disallow) and allow or disallow it for new requests. The params are kept permanently (so requests already placed stay fillable after a disallow); disallowing only flips the gate. Owner only.

#### `placeExitRequest`

```solidity
function placeExitRequest(
    Id marketId,
    uint256 shares,
    PriorityRamp calldata ramp,
    uint256 deadline,
    bool fullFillOnly
) external returns (uint256 id);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The allowed market's id (its `MarketParams` hash, registered via `setMarketAllowed`). |
| `shares` | `uint256` | Supply shares to exit. |
| `ramp` | `PriorityRamp` | Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end. |
| `deadline` | `uint256` | Fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends. |
| `fullFillOnly` | `bool` | When true a fill must cover the whole remaining size in one shot. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The new request id. |

Open an exit backed by `shares` of the caller's supply in an allowed Morpho market, named by its `marketId`. Permission-only: the caller must have authorized this book on Morpho and hold the `shares`.
