<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# Exit Books

The lender exit-book layer. An abstract `ExitBookBase` holds the shared fill, cancel, and fee surface, and a concrete book binds it to a source — `Erc4626ExitBook` over a vault, `MorphoExitBook` over a market. Standard inherited `AccessControlEnumerable` surface is not repeated here. On Exit Books, every recovery function requires `RECOVERER_ROLE`.

## ExitBookBase

Source-agnostic surface of an exit book: configure the service fee, fill and cancel requests, and read them. Concrete books (ERC-4626, Morpho, ...) add their own `placeExitRequest` and allow-list admin on top.

### Enums

#### `ExitStatus`

```solidity
enum ExitStatus {
    NotCreated,
    Open,
    Filled,
    Cancelled
}
```

Lifecycle marker. `NotCreated` is the zero-value sentinel for unknown ids, not a stored request state. `Expired` is not stored — it is derived from `block.timestamp > deadline`.

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

Lender-set priority-fee schedule — a Dutch auction on the fee carved out of each fill. The rate holds at `startRate` for `rampStart` seconds from creation, then climbs linearly to `endRate` by `rampEnd`, then holds at `endRate` until the deadline. Rates are WAD fractions, each capped at `MAX_PRIORITY_FEE`.

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
    address receiver;
    ExitStatus status;
    IERC20 asset;
    uint128 assetsRemaining;
    uint128 assetsTotal;
    uint128 minFillAssets;
    uint128 maxShareBurn;
    uint96 startRate;
    uint96 endRate;
    uint32 rampStart;
    uint32 rampEnd;
}
```

One exit request's source-agnostic lifecycle state. The backing source (which vault / which market) lives in a per-id mapping outside this record. Remaining and total assets are stored as `uint128`.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | The exiting lender whose position the fill withdraws from, and the only address that may cancel. |
| `createdAt` | `uint40` | Creation timestamp: the fee schedule's start. |
| `deadline` | `uint40` | Last timestamp the request may be filled. Chosen by the lender, capped at `createdAt + MAX_REQUEST_LIFETIME` and never earlier than `createdAt + rampEnd`. |
| `receiver` | `address` | Address credited the filled amount minus the priority fee. |
| `status` | `ExitStatus` | NotCreated for an unknown id; stored requests are Open / Filled / Cancelled (Expired is derived). |
| `asset` | `IERC20` | The underlying loan token paid out — the request, proceeds, and fees are denominated in it. |
| `assetsRemaining` | `uint128` | Outstanding asset amount to exit. |
| `assetsTotal` | `uint128` | Original asset amount requested. |
| `minFillAssets` | `uint128` | Minimum non-final fill; 0 disables it. Whole-remainder fills qualify; capped at assetsTotal. |
| `maxShareBurn` | `uint128` | Nominal full-request share budget. A fill may burn at most `ceil(maxShareBurn * fillAssets / assetsTotal)`; across split fills, total burn may exceed this value by at most one raw share unit per additional fill. |
| `startRate` | `uint96` | Priority-fee rate (WAD) in force from `createdAt` through the `rampStart` hold. |
| `endRate` | `uint96` | Priority-fee rate (WAD) reached at `createdAt + rampEnd` and held to the deadline. |
| `rampStart` | `uint32` | Seconds from `createdAt` the rate holds at `startRate` before the climb begins. |
| `rampEnd` | `uint32` | Seconds from `createdAt` the climb reaches `endRate`. |

### Events

#### `ExitRequested`

```solidity
event ExitRequested(uint256 indexed id, address indexed owner, address indexed receiver, address asset, uint256 assets, uint256 minFillAssets, uint256 maxShareBurn, PriorityRamp ramp, uint256 deadline);
```

#### `ExitProcessed`

```solidity
event ExitProcessed(uint256 indexed id, address indexed executor, address indexed rewardRecipient, address asset, uint256 filledAssets, uint256 sharesBurned, uint256 fillerReward, uint256 serviceCut);
```

#### `ExitCancelled`

```solidity
event ExitCancelled(uint256 indexed id);
```

#### `ServiceFeeSet`

```solidity
event ServiceFeeSet(address indexed feeRecipient, uint256 serviceFee);
```

#### `Paused`

```solidity
event Paused(address account);
```

#### `Unpaused`

```solidity
event Unpaused(address account);
```

#### `EtherRecovered`

```solidity
event EtherRecovered(address indexed recipient, uint256 amount);
```

#### `ERC20Recovered`

```solidity
event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);
```

#### `ERC721Recovered`

```solidity
event ERC721Recovered(address indexed token, uint256 tokenId, address indexed recipient);
```

#### `ERC1155Recovered`

```solidity
event ERC1155Recovered(address indexed token, uint256 tokenId, address indexed recipient, uint256 amount);
```

### Errors

#### `ZeroAddress`

```solidity
error ZeroAddress();
```

#### `ZeroAssets`

```solidity
error ZeroAssets();
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

#### `FillExceedsRemaining`

```solidity
error FillExceedsRemaining(uint256 requested, uint256 remaining);
```

#### `FillBelowMinimum`

```solidity
error FillBelowMinimum(uint256 requested, uint256 minimum);
```

#### `MaxShareBurnBelowQuote`

```solidity
error MaxShareBurnBelowQuote(uint256 maximum, uint256 quote);
```

#### `ShareBurnExceedsMaximum`

```solidity
error ShareBurnExceedsMaximum(uint256 actual, uint256 maximum);
```

#### `AssetsOutMismatch`

```solidity
error AssetsOutMismatch(uint256 expected, uint256 actual);
```

#### `DeadlineInPast`

```solidity
error DeadlineInPast();
```

#### `DeadlineTooFar`

```solidity
error DeadlineTooFar();
```

#### `EnforcedPause`

```solidity
error EnforcedPause();
```

#### `RequestClosed`

```solidity
error RequestClosed();
```

The request does not exist or is not open.

#### `RequestExpired`

```solidity
error RequestExpired();
```

The request is past its `deadline` and can no longer be filled.

#### `NotOwner`

```solidity
error NotOwner();
```

The caller is not the request's owner.

#### `ZeroRecipient`

```solidity
error ZeroRecipient();
```

The recovery recipient was the zero address.

#### `EtherTransferFailed`

```solidity
error EtherTransferFailed();
```

The Ether transfer to the recipient failed.

### Functions

#### `PAUSER_ROLE`

```solidity
function PAUSER_ROLE() external view returns (bytes32);
```

Role allowed to pause request placement and fills.

#### `RESUMER_ROLE`

```solidity
function RESUMER_ROLE() external view returns (bytes32);
```

Role allowed to resume request placement and fills.

#### `setServiceFee`

```solidity
function setServiceFee(address recipient, uint256 fee) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `recipient` | `address` | Address paid the service fee (a cut of the priority fee); the zero address is allowed only when `fee` is 0. |
| `fee` | `uint256` | Service-fee rate (WAD), capped at `MAX_SERVICE_FEE`. |

Set the service fee and its recipient. `FEE_MANAGER_ROLE` only.

#### `paused`

```solidity
function paused() external view returns (bool);
```

Whether request placement and fills are paused.

#### `pause`

```solidity
function pause() external;
```

Pause request placement and fills until an authorized resume. `PAUSER_ROLE` only.

#### `resume`

```solidity
function resume() external;
```

Resume request placement and fills. `RESUMER_ROLE` only.

#### `fillExitRequest`

```solidity
function fillExitRequest(
    uint256 id,
    uint256 fillAssets,
    address rewardRecipient
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request to fill. |
| `fillAssets` | `uint256` | Exact asset amount to debit from the request, withdraw, and use as the priority-fee basis. |
| `rewardRecipient` | `address` | Non-zero address credited the priority fee minus the service cut. |

Debit request `id` and withdraw exactly `fillAssets` from its source. The receiver gets `fillAssets` minus the priority fee; `rewardRecipient` gets the priority fee minus the service cut. Reverts unless the source can honour the exact withdrawal. When share-burn protection is enabled, every fill must also fit its independently rounded-up share limit. Callers prepare any required source liquidity before filling, either beforehand or earlier in the same transaction.

#### `cancelExitRequest`

```solidity
function cancelExitRequest(uint256 id) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request to cancel. |

Cancel an open request, including while paused or after its deadline. Sets the remaining amount to zero and moves no assets. Caller must own it.

#### `getExitRequest`

```solidity
function getExitRequest(uint256 id) external view returns (Request memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request id. |

The stored request at `id` (a zeroed `NotCreated` record if it never existed).

#### `getRequests`

```solidity
function getRequests(
    uint256[] calldata ids
) external view returns (Request[] memory requests);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `ids` | `uint256[]` | The request ids to read. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `requests` | `Request[]` | The request records, one per id, in the same order. |

The stored requests at `ids` (closed and `NotCreated` records included) with no source calls.

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
) external view returns (uint256[] memory ids);
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
| `ids` | `uint256[]` | The owner's request ids in `[offset, offset + count)`. |

A page of `owner`'s request ids in creation order (closed ones included).

#### `recoverEther`

```solidity
function recoverEther(address recipient) external;
```

Recover the contract's full Ether balance to `recipient`.

#### `recoverERC20`

```solidity
function recoverERC20(
    address token,
    address recipient,
    uint256 amount
) external;
```

Recover `amount` of the ERC-20 `token` to `recipient`.

#### `recoverERC721`

```solidity
function recoverERC721(
    address token,
    address recipient,
    uint256 tokenId
) external;
```

Recover `tokenId` of the ERC-721 `token` to `recipient`.

#### `recoverERC1155`

```solidity
function recoverERC1155(
    address token,
    address recipient,
    uint256 tokenId
) external;
```

Recover the full balance of `tokenId` of the ERC-1155 `token` to `recipient`.

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `ALLOWLIST_MANAGER_ROLE` | `bytes32` (constant) | Role allowed to manage which markets or vaults may receive new requests. |
| `FEE_MANAGER_ROLE` | `bytes32` (constant) | Role allowed to set the service fee and its recipient. |
| `RECOVERER_ROLE` | `bytes32` (constant) | Role allowed to recover tokens held by the contract. |
| `MAX_PRIORITY_FEE` | `uint256` (constant) | Cap on a request's priority-fee rate (WAD), checked at `place` — 10%. |
| `MAX_SERVICE_FEE` | `uint256` (constant) | Hard cap on the service fee — a cut of the priority fee (WAD) — 25%. |
| `MAX_REQUEST_LIFETIME` | `uint256` (immutable) | Cap on a request's lifetime: its `deadline` may be at most `createdAt + MAX_REQUEST_LIFETIME`. |
| `feeRecipient` | `address` | Recipient of the service fee. |
| `serviceFee` | `uint256` | Service fee: a cut of each fill's priority fee, as a WAD rate. |

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

#### `constructor`

```solidity
constructor(address admin, uint256 maxLifetime_);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `admin` | `address` | Non-zero initial holder of `DEFAULT_ADMIN_ROLE`. |
| `maxLifetime_` | `uint256` | Non-zero maximum request lifetime in seconds. |

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
| `allowed` | `bool` | True to allow new requests; false to block them without changing existing fill eligibility. |

Allow or disallow `vault` for new requests. `ALLOWLIST_MANAGER_ROLE` only.

#### `placeExitRequest`

```solidity
function placeExitRequest(
    IERC4626 vault,
    uint256 assets,
    address receiver,
    uint256 minFillAssets,
    uint256 maxShareBurn,
    PriorityRamp calldata ramp,
    uint256 deadline
) external returns (uint256 id);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `vault` | `IERC4626` | The allowed ERC-4626 vault. |
| `assets` | `uint256` | Loan-asset amount to debit across fills. Must fit `uint128`. |
| `receiver` | `address` | Address credited the filled amount minus the priority fee. |
| `minFillAssets` | `uint256` | Smallest amount a non-final fill may process; 0 for no minimum. A fill that closes the whole remaining request always qualifies. Values above `assets` are capped to `assets`. |
| `maxShareBurn` | `uint256` | Nominal full-request vault-share budget. A fill may burn at most `ceil(maxShareBurn * fillAssets / assetsTotal)`. Across a split request, total burn may exceed this value by at most one raw share unit per additional fill. Must fit `uint128`; 0 disables the limit, and a non-zero value must cover the placement share quote. |
| `ramp` | `PriorityRamp` | Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end. |
| `deadline` | `uint256` | Strictly future fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The new request id. |

Open an asset-denominated exit against the caller's shares in an allowed `vault`. Nothing is escrowed. Placement snapshots the full request's `previewWithdraw` share quote and requires enough current balance and allowance, but does not reserve either. Each fill debits and withdraws the same exact asset amount.

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

#### `constructor`

```solidity
constructor(address morpho, address admin, uint256 maxLifetime_);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `morpho` | `address` | Non-zero Morpho deployment used as the source. |
| `admin` | `address` | Non-zero initial holder of `DEFAULT_ADMIN_ROLE`. |
| `maxLifetime_` | `uint256` | Non-zero maximum request lifetime in seconds. |

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
| `allowed` | `bool` | True to allow new requests; false to block them without changing existing fill eligibility. |

Register `marketParams` (which must name a live Morpho market, checked on both allow and disallow) and allow or disallow it for new requests. The params are kept permanently; disallowing only flips the placement gate and does not change existing fill eligibility. `ALLOWLIST_MANAGER_ROLE` only.

#### `placeExitRequest`

```solidity
function placeExitRequest(
    Id marketId,
    uint256 assets,
    address receiver,
    uint256 minFillAssets,
    uint256 maxShareBurn,
    PriorityRamp calldata ramp,
    uint256 deadline
) external returns (uint256 id);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The allowed market's id (its `MarketParams` hash, registered via `setMarketAllowed`). |
| `assets` | `uint256` | Loan-asset amount to debit across fills. Must fit `uint128`. |
| `receiver` | `address` | Address credited the filled amount minus the priority fee. |
| `minFillAssets` | `uint256` | Smallest amount a non-final fill may process; 0 for no minimum. A fill that closes the whole remaining request always qualifies. Values above `assets` are capped to `assets`. |
| `maxShareBurn` | `uint256` | Nominal full-request supply-share budget. A fill may burn at most `ceil(maxShareBurn * fillAssets / assetsTotal)`. Across a split request, total burn may exceed this value by at most one raw share unit per additional fill. Must fit `uint128`; 0 disables the limit, and a non-zero value must cover the placement share quote. |
| `ramp` | `PriorityRamp` | Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end. |
| `deadline` | `uint256` | Strictly future fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The new request id. |

Open an asset-denominated exit against the caller's supply position in an allowed Morpho market. Nothing is escrowed. Placement snapshots the full request's supply-share quote and requires enough current supply, but does not reserve it. Each fill debits and withdraws the same exact asset amount, so authorization must remain live.
