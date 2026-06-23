<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendERC4626

Single-market ERC-4626 wrapper for a Morpho Blue fork market with settle exit support.

Assumes `asset()` and the market's collateral token are standard ERC-20s without transfer callbacks (no ERC-777 `tokensToSend`, no ERC-1363 `transferAndCall`). Adding a market with a callback-bearing loan or collateral token invalidates the reentrancy analysis here.

## Events

### `FallbackExit`

```solidity
event FallbackExit(address indexed caller, address indexed owner, address indexed receiver, uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled);
```

An automatic `fallbackExit` settled its illiquid remainder against the risk queue.

### `Settled`

```solidity
event Settled(address indexed caller, address indexed owner, address indexed receiver, uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled);
```

A targeted `settle` cut the caller-named borrowers.

## Errors

### `ZeroShares`

```solidity
error ZeroShares();
```

Thrown when an exit is requested for zero shares.

### `ZeroAddress`

```solidity
error ZeroAddress();
```

Thrown when the seized-collateral receiver is the zero address.

### `ZeroLidoLend`

```solidity
error ZeroLidoLend();
```

Thrown when the LidoLend core address is zero at construction.

### `ZeroController`

```solidity
error ZeroController();
```

Thrown when the controller address is zero at initialization.

### `ZeroLoanToken`

```solidity
error ZeroLoanToken();
```

Thrown when the market's loan token is the zero address at initialization.

### `ZeroCollateralToken`

```solidity
error ZeroCollateralToken();
```

Thrown when the market's collateral token is the zero address at initialization.

### `ZeroMorphoSupplyShares`

```solidity
error ZeroMorphoSupplyShares();
```

Thrown when an exit reaches its settle leg but the vault holds no Morpho supply shares to cut against, so the requested slice maps to a zero supply-share budget.

### `ExceededBalance`

```solidity
error ExceededBalance(address owner, uint256 shares, uint256 balance);
```

Thrown when the requested exit shares exceed the owner's balance.

### `EmptyBorrowers`

```solidity
error EmptyBorrowers();
```

Thrown when `settle` is called with an empty borrowers list.

## Functions

### `constructor`

```solidity
constructor(address lidoLend);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `lidoLend` | `address` | The LidoLend core (Morpho Blue fork) the vault supplies into and settles against. |

Sets the immutable LidoLend core; the proxy is bound to a market later via `initialize`.

### `initialize`

```solidity
function initialize(
    MarketParams memory marketParams_,
    address controller_,
    string memory name_,
    string memory symbol_
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketParams_` | `MarketParams` | The market this vault wraps; its loan token becomes the ERC-4626 asset. |
| `controller_` | `address` | The market's policy controller, read for settlement-queue sizing. |
| `name_` | `string` | ERC-20 name of the share token. |
| `symbol_` | `string` | ERC-20 symbol of the share token. |

Bind the proxy to one market: cache its params, point at the controller, freeze the virtual-share decimals offset, and grant the core an unbounded loan-token allowance so deposits can supply without a per-call approval.

### `marketParams`

```solidity
function marketParams() external view returns (MarketParams memory);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `MarketParams` | The cached `MarketParams` of the market this vault wraps. |

The wrapped market's params (loan/collateral/oracle/irm/lltv), as cached at init.

### `totalAssets`

```solidity
function totalAssets() public view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | The loan assets backing all shares, equal to the vault's Morpho supply position valued at current totals. |

Only the Morpho supply position backs shares. Loan tokens sent directly to the vault (donations) are not counted, so they cannot move the share price — this is the donation / inflation defense. Stray idle stays inert until a fresh deposit's supply folds it into the position.

### `maxWithdraw`

```solidity
function maxWithdraw(address owner) public view returns (uint256);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | Account whose withdrawable loan assets are measured. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | Loan assets `owner` can withdraw now, the lesser of its position's value and the market's free liquidity. |

Capped by the market's free liquidity, not just the owner's position: the supplied loan token can be borrowed out, so withdrawing past available liquidity reverts in the core. The illiquid remainder exits through `fallbackExit`.

### `maxRedeem`

```solidity
function maxRedeem(address owner) public view returns (uint256);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | Account whose redeemable shares are measured. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | Shares `owner` can redeem now, its full balance when liquidity covers it, otherwise the shares liquidity covers. |

Liquidity cap of `maxWithdraw`, in shares. When the owner's whole position fits in free liquidity it returns the exact share balance, avoiding a `convertToShares` round-trip that could round the last wei down and strand a share. Otherwise it caps to the shares liquidity covers.

### `settle`

```solidity
function settle(
    uint256 shares,
    address[] calldata borrowers,
    address receiver,
    address owner
) external returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `shares` | `uint256` | Vault shares to settle against; bounds the Morpho supply consumed by the cuts. |
| `borrowers` | `address[]` | Positions to cut, in order; each sized via `controller.settlementFor`. |
| `receiver` | `address` | Recipient of the seized collateral. |
| `owner` | `address` | Account whose shares are burned; the caller must hold its allowance if not the owner. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `sharesBurned` | `uint256` | Shares burned for the settled slice. |
| `loanAssets` | `uint256` | Always 0 — a targeted settle pays only seized collateral and withdraws no liquidity. |
| `collateralSeized` | `uint256` | Collateral seized from the cut positions and sent to `receiver`. |
| `debtCanceled` | `uint256` | Borrower debt cancelled by the cuts. |

Targeted settlement: cuts the caller-supplied `borrowers` in order (sizing each via `controller.settlementFor`) against the owner's Morpho supply, paying seized collateral to `receiver`. Best-effort, no revert on shortfall.

Unlike `fallbackExit`, this does NOT redeem ordinary liquidity first — a targeted settle must stay liquidity-neutral and only cut the named positions, never draining lender withdraw liquidity. It therefore remains subject to the core's `SETTLEMENT_LIQUIDITY_AVAILABLE` gate: a cut whose cancelled debt does not exceed the market's ordinary liquidity reverts. Use `fallbackExit` for the griefing-resistant lender exit; `settle` is the precise cut. Collateral is transferred directly by Morpho to `receiver`; the vault does not custody it.

### `fallbackExit`

```solidity
function fallbackExit(
    uint256 shares,
    address receiver,
    address owner,
    uint256 maxIterations
) external returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `shares` | `uint256` | Vault shares to exit (redeemed first, then the remainder settled). |
| `receiver` | `address` | Recipient of both the redeemed loan assets and the seized collateral. |
| `owner` | `address` | Account whose shares are burned; the caller must hold its allowance if not the owner. |
| `maxIterations` | `uint256` | Cap on borrowers the settle leg cuts; 0 uses `DEFAULT_MAX_SETTLEMENT_ITERATIONS`. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `sharesBurned` | `uint256` | Total shares burned across the redeem and settle legs. |
| `loanAssets` | `uint256` | Loan assets paid to `receiver` by the redeem leg (the settle leg pays only collateral). |
| `collateralSeized` | `uint256` | Collateral seized from settled positions and sent to `receiver`. |
| `debtCanceled` | `uint256` | Borrower debt cancelled by the settle leg. |

Automatic fallback exit. First pays out as much as ordinary market liquidity covers via a normal redeem, then settles the remainder against the controller's risk queue (head first), seizing collateral to `receiver`. The caller does not pick the positions. Settling is best-effort: whatever fraction is serviced is burned, no revert on shortfall.

Redeeming what liquidity covers before settling closes a griefing vector: the core blocks `settle` while idle liquidity still covers the amount (`SETTLEMENT_LIQUIDITY_AVAILABLE`), so without the redeem an attacker could add idle right before the call and force the whole exit to revert. Here that liquidity instead flows to the owner as loan assets. Reverts `ZeroMorphoSupplyShares` only if settling is reached with no Morpho position. Collateral is transferred directly by Morpho to `receiver`; the vault does not custody it.

### `previewFallbackExit`

```solidity
function previewFallbackExit(
    uint256 shares
) external view returns (uint256 loanAssets, uint256 morphoSupplyShares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `shares` | `uint256` | Vault shares the caller intends to exit. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `loanAssets` | `uint256` | Loan assets the redeem leg would pay, capped at the Morpho-withdrawable amount (stray idle excluded). |
| `morphoSupplyShares` | `uint256` | The owner's pro-rata slice of the vault's Morpho supply-share position for `shares`. |

Returns the loan assets and Morpho supply shares consumed by `fallbackExit(shares, ...)`.

`view`, but result tracks the current block's accrued totals. If blocks pass between this call and the matching `fallbackExit` transaction the numbers may shift slightly; the on-chain pro-rate is recomputed at execution time so the actual burn matches live state.

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `DEFAULT_MAX_SETTLEMENT_ITERATIONS` | `uint256` (constant) | Default per-call cut bound for the fallback-exit loop (gas safety). `fallbackExit` callers can override it; passing 0 falls back to this. |
| `LIDO_LEND` | `ILidoLend` (immutable) | The LidoLend core (Morpho Blue fork) this vault supplies into and settles against. |
| `marketId` | `Id` | Id of the market this vault wraps. |
| `controller` | `ILidoLendMarketController` | The market's policy controller. The vault reads its settlement-queue views to size exit cuts. |
