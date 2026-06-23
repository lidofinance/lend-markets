<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# WithdrawalQueue

Lender stablecoin-exit queue for a single LidoLend market. A lender posts a request to exit a fixed size of their supply position; anyone (a "keeper") then drains whatever liquidity the market currently has into the request, earning the lender's priority fee. The lender claims the freed stablecoin; the keeper claims the fee. Large exits no longer need the lender to chase liquidity transaction by transaction.

Two entry modes feed one registry:

- Direct: the lender authorizes this contract on the core (`setAuthorization`) and the fill withdraws straight from their core position. The position stays with the lender, who may undo the authorization or withdraw themselves — then the request simply stops filling.
- Vault: the lender escrows ERC-4626 vault shares here at request time (core supply shares are not transferable, so escrow is only possible through the tokenized layer); the fill redeems them. The priority fee is a Dutch auction: the lender sets a cap and the fee a fill earns ramps linearly from 0 at request time to the cap at the deadline, so a liquidity-starved request grows more attractive to fill the longer it waits, while one filled early costs the lender almost nothing. The request registry lives in `WithdrawalQueueLib`; this contract owns the token movement, pricing, and the per-fill settlement split. Bolt-on: no core changes. Pause and freeze interactions are out of scope for this revision.

## Events

### `WithdrawalRequested`

```solidity
event WithdrawalRequested(uint256 indexed id, address indexed owner, Mode mode, uint256 size, uint256 maxPriorityFee, uint256 deadline, bool fullFillOnly);
```

Emitted when a lender opens an exit request. `size` is the loan-asset amount requested; the queue stores the matching shares at the price fixed by this call.

### `WithdrawalProcessed`

```solidity
event WithdrawalProcessed(uint256 indexed id, address indexed keeper, uint256 filledShares, uint256 lenderAssets, uint256 keeperFee, uint256 protocolFee);
```

Emitted on each fill, recording the per-fill settlement split between the lender, the keeper, and the protocol.

### `WithdrawalCancelled`

```solidity
event WithdrawalCancelled(uint256 indexed id);
```

Emitted when the owner cancels their request.

### `WithdrawalExpired`

```solidity
event WithdrawalExpired(uint256 indexed id);
```

Emitted when an expired request is pruned from the active set.

### `Claimed`

```solidity
event Claimed(address indexed account, uint256 assets);
```

Emitted when an account withdraws its accumulated loan-asset balance.

### `ProtocolFeeSet`

```solidity
event ProtocolFeeSet(address indexed feeRecipient, uint256 protocolFeeBps);
```

Emitted when the protocol-fee recipient and rate are set together.

## Errors

### `ZeroSize`

```solidity
error ZeroSize();
```

A request was opened with zero `assets`.

### `ZeroAddress`

```solidity
error ZeroAddress();
```

The vault or core address passed to the constructor was zero.

### `AssetMismatch`

```solidity
error AssetMismatch();
```

The vault's `asset()` does not match the market loan token.

### `FeeTooHigh`

```solidity
error FeeTooHigh();
```

The protocol fee exceeds `MAX_PROTOCOL_FEE_BPS`.

### `FeeRecipientRequired`

```solidity
error FeeRecipientRequired();
```

A non-zero protocol fee was set with a zero recipient (nowhere to send the cut).

### `DeadlineInPast`

```solidity
error DeadlineInPast();
```

A request was opened with a deadline at or before the current time.

### `NothingAvailable`

```solidity
error NothingAvailable();
```

The fill produced no shares or assets — the market is dry, or a `fullFillOnly` request cannot yet be covered in one shot.

### `NotAuthorizedOnCore`

```solidity
error NotAuthorizedOnCore();
```

A Direct-mode request was opened before the caller authorized this contract on the core.

## Functions

### `constructor`

```solidity
constructor(
    address vault,
    address core,
    MarketParams memory params,
    address owner,
    address recipient,
    uint256 bps
);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `vault` | `address` | ERC-4626 vault wrapping this market; its `asset()` must equal `params.loanToken`. |
| `core` | `address` | The LidoLend core the Direct mode withdraws from. |
| `params` | `MarketParams` | Market the queue serves (its id and loan asset are derived here). |
| `owner` | `address` | Owner that may set the protocol fee. |
| `recipient` | `address` | Initial protocol-fee recipient. |
| `bps` | `uint256` | Initial protocol fee, capped at `MAX_PROTOCOL_FEE_BPS`. |

Bind the queue to one market: cache its core, vault, loan asset, and id, and set the initial protocol fee.

### `marketParams`

```solidity
function marketParams() external view returns (MarketParams memory params);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `params` | `MarketParams` | The stored market parameters. |

The market parameters this queue serves.

### `setProtocolFee`

```solidity
function setProtocolFee(address recipient, uint256 bps) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `recipient` | `address` | Account credited the protocol cut (zero to disable, which forces `bps` zero). |
| `bps` | `uint256` | Protocol cut of the keeper's reward, in basis points (≤ `MAX_PROTOCOL_FEE_BPS`). |

Set the protocol fee recipient and rate together. `bps` is capped at `MAX_PROTOCOL_FEE_BPS`; a zero recipient requires a zero rate (no fee with nowhere to send it).

### `requestWithdrawal`

```solidity
function requestWithdrawal(
    Mode mode,
    uint256 assets,
    uint256 maxPriorityFee,
    uint256 deadline,
    bool fullFillOnly
) external returns (uint256 id);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `mode` | `Mode` | Direct (core authorization) or Vault (escrowed shares). |
| `assets` | `uint256` | Loan-asset amount the lender wants to free; the request fixes the share price now and queues the matching shares. |
| `maxPriorityFee` | `uint256` | Priority-fee cap, in loan-asset units. The fee a fill earns ramps from 0 at this call to the cap at `deadline` (a Dutch auction), charged out of the lender's owed. |
| `deadline` | `uint256` | Last timestamp the request may be filled, and the ramp's full-fee point. |
| `fullFillOnly` | `bool` | When true the request may only be filled in a single shot covering its whole size; a fill is rejected while the market cannot cover it all, never leaving it partial. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The new request id. |

Open an exit request. Direct mode: caller must have authorized this contract on the core first; `assets` worth of their supply position is queued. Vault mode: caller must have approved this contract for the vault shares worth `assets`, which are escrowed.

### `processWithdrawal`

```solidity
function processWithdrawal(uint256 id) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request to fill. |

Fill request `id`, splitting the proceeds between the lender, the caller (keeper), and the protocol. Callable by anyone, repeatedly, until the request is fully filled.

### `fillWithLiquidity`

```solidity
function fillWithLiquidity(uint256 id, uint256 liquidity) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request to fill. |
| `liquidity` | `uint256` | Loan-asset amount to deposit into the vault before filling. |

Bring liquidity and close a request in one call: deposit `liquidity` of the loan token into the vault (the caller becomes a vault depositor) so the market has the idle assets to honour the fill, then fill request `id` for the caller. Atomic so no other keeper can fill the request on the liquidity this caller just supplied. Caller must have approved this contract for `liquidity` of the loan token.

### `cancelWithdrawal`

```solidity
function cancelWithdrawal(uint256 id) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request to cancel. |

Cancel request `id`. Vault mode returns the unfilled escrowed shares; Direct mode just drops the request (the position never left the lender). Caller must be the owner.

### `pruneExpired`

```solidity
function pruneExpired(uint256[] calldata ids) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `ids` | `uint256[]` | Candidate request ids to prune. |

Permissionlessly drop expired requests from the active set, refunding the escrowed shares of Vault-mode requests to their owners. Ids that are not open-and-expired are skipped, so a stale batch never reverts.

### `claim`

```solidity
function claim() external returns (uint256 assets);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `assets` | `uint256` | The amount transferred to the caller. |

Withdraw the caller's accumulated loan-asset balance (lender proceeds or keeper fees).

### `getRequest`

```solidity
function getRequest(uint256 id) external view returns (Request memory request);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | `uint256` | The request id to read. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `request` | `Request` | The stored request record. |

The full record for request `id` (zero-valued struct if it never existed).

### `activeRequests`

```solidity
function activeRequests(
    uint256 offset,
    uint256 limit
) external view returns (uint256[] memory ids);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `offset` | `uint256` | Start index into the active set. |
| `limit` | `uint256` | Maximum number of ids to return. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `ids` | `uint256[]` | The open ids in the `[offset, offset + limit)` window. |

Open request ids, paginated.

### `activeRequestCount`

```solidity
function activeRequestCount() external view returns (uint256 count);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `count` | `uint256` | The active request count. |

Number of open requests in the active set.

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `MAX_PROTOCOL_FEE_BPS` | `uint256` (constant) | Hard cap on the protocol cut of the keeper's priority fee (1%). |
| `CORE` | `IMorpho` (immutable) | The LidoLend core a Direct-mode fill withdraws from. |
| `VAULT` | `IERC4626` (immutable) | ERC-4626 vault wrapping this market; Vault-mode escrows and redeems its shares, and `fillWithLiquidity` deposits into it. |
| `ASSET` | `IERC20` (immutable) | The market loan token — the asset lenders exit into and the unit all proceeds settle in. |
| `MARKET_ID` | `Id` (immutable) | Id of the market this queue serves, derived from the constructor's `params`. |
| `feeRecipient` | `address` | Account credited the protocol cut; claims it through the shared `claim` path. The cut is taken only from the keeper's reward, never from the lender's proceeds. |
| `protocolFeeBps` | `uint256` | Protocol cut of the keeper's priority fee, in basis points (≤ `MAX_PROTOCOL_FEE_BPS`). |
| `claimable` | `mapping(address => uint256)` | Loan-asset balance withdrawable by each account (lender proceeds or keeper fees). |
