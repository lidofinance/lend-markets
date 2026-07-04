<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendERC4626

Single-market ERC-4626 wrapper for a Morpho Blue fork market with settle exit support.

Assumes `asset()` and the market's collateral token are standard ERC-20s without transfer callbacks (no ERC-777 `tokensToSend`, no ERC-1363 `transferAndCall`).

## Events

### `FallbackExit`

```solidity
event FallbackExit(address indexed caller, address indexed owner, address indexed receiver, uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The address that called the exit. |
| `owner` | `address` | The account whose shares were burned. |
| `receiver` | `address` | The recipient of the redeemed assets and seized collateral. |
| `sharesBurned` | `uint256` | Shares burned by the settle leg. |
| `collateralSeized` | `uint256` | Collateral seized from the cut positions. |
| `debtCanceled` | `uint256` | Borrower debt cancelled by the cuts. |

An automatic `fallbackExit` settled its illiquid remainder against the risk queue.

### `Settled`

```solidity
event Settled(address indexed caller, address indexed owner, address indexed receiver, uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The address that called the settle. |
| `owner` | `address` | The account whose shares were burned. |
| `receiver` | `address` | The recipient of the seized collateral. |
| `sharesBurned` | `uint256` | Shares burned for the settled slice. |
| `collateralSeized` | `uint256` | Collateral seized from the cut positions. |
| `debtCanceled` | `uint256` | Borrower debt cancelled by the cuts. |

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

### `ControllerMarketMismatch`

```solidity
error ControllerMarketMismatch();
```

Thrown when the bound controller governs a different market than the vault's.

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `owner` | `address` | The account whose balance was checked. |
| `shares` | `uint256` | The requested shares. |
| `balance` | `uint256` | The owner's actual balance. |

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

### `initialize`

```solidity
function initialize(
    MarketParams memory marketParams_,
    address controller_,
    string memory name_,
    string memory symbol_
) external;
```

### `marketParams`

```solidity
function marketParams() external view returns (MarketParams memory);
```

### `totalAssets`

```solidity
function totalAssets() public view returns (uint256);
```

Only the Morpho supply position backs shares — direct loan-token donations are uncounted and cannot move the share price.

### `maxWithdraw`

```solidity
function maxWithdraw(address owner) public view returns (uint256);
```

Capped by the market's free liquidity, not just the owner's position: supplied tokens may be borrowed out, so withdrawing past liquidity reverts in the core. The illiquid remainder exits via `fallbackExit`.

### `maxRedeem`

```solidity
function maxRedeem(address owner) public view returns (uint256);
```

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

A targeted, liquidity-neutral cut of the named borrowers: it redeems no liquidity first (unlike `fallbackExit`), so it stays subject to the core's `SETTLEMENT_LIQUIDITY_AVAILABLE` gate. Collateral goes from Morpho straight to `receiver`. For the griefing-resistant exit use `fallbackExit`.

### `fallbackExit`

```solidity
function fallbackExit(
    uint256 shares,
    address receiver,
    address owner,
    uint256 maxIterations
) external returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
```

Redeems what liquidity covers before settling, closing a griefing vector: the core blocks `settle` while idle liquidity still covers the amount, so without the redeem an attacker could add idle right before the call to force the exit to revert. That liquidity goes to the owner as loan assets; collateral goes from Morpho straight to `receiver`.

### `previewFallbackExit`

```solidity
function previewFallbackExit(
    uint256 shares
) external view returns (uint256 loanAssets, uint256 morphoSupplyShares);
```

A `view` preview on this block's accrued totals. The figures may shift if blocks pass before the `fallbackExit`, which recomputes the pro-rata on-chain at execution so the burn matches live state.

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `DEFAULT_MAX_SETTLEMENT_ITERATIONS` | `uint256` (constant) |  |
| `LIDO_LEND` | `ILidoLend` (immutable) |  |
| `marketId` | `Id` |  |
| `controller` | `ILidoLendMarketController` |  |
