<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendERC4626

Standard inherited ERC-20 share-token and ERC-4626 vault functions are not repeated; see [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626).

Single-market ERC-4626 wrapper for a Morpho Blue fork market with settle exit support.

Assumes `asset()` and the market's collateral token are standard ERC-20s without transfer callbacks (no ERC-777 `tokensToSend`, no ERC-1363 `transferAndCall`).

## Events

### `FallbackExit`

```solidity
event FallbackExit(address indexed caller, address indexed owner, address indexed receiver, uint256 sharesBurned, uint256 sharesSettled, uint256 assetsWithdrawn, uint256 collateralSeized, uint256 debtCanceled);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The address that called the exit. |
| `owner` | `address` | The account whose shares were burned. |
| `receiver` | `address` | The recipient of the liquid-leg loan assets and seized collateral. |
| `sharesBurned` | `uint256` | Shares burned by the whole call — the liquid leg and the settle leg together. |
| `sharesSettled` | `uint256` | Shares burned by the settle leg alone, 0 when liquidity serviced the whole request or the queue funded no cut. |
| `assetsWithdrawn` | `uint256` | Loan assets the liquid leg paid out, 0 when the market had no free liquidity or the requested shares' floor-rounded value was zero. |
| `collateralSeized` | `uint256` | Collateral seized from the cut positions. |
| `debtCanceled` | `uint256` | Borrower debt cancelled by the cuts. |

A `fallbackExit` call completed with a positive, possibly partial fill — serviced from market liquidity, queue settlement, or both.

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

A targeted `settle` call completed with a positive, possibly partial fill.

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

Thrown when an exit maps to a zero core supply-share budget.

### `ZeroCoreSupplySharesMinted`

```solidity
error ZeroCoreSupplySharesMinted(uint256 assets);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `assets` | `uint256` | The deposited assets that mapped to zero core supply shares. |

Thrown when a nonzero deposit receives zero core supply shares.

### `NothingSettled`

```solidity
error NothingSettled();
```

Thrown when a targeted settlement consumes no core supply shares across all requested borrowers, or when a fallback exit burns no shares in either leg.

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

### `ZeroSharesMinted`

```solidity
error ZeroSharesMinted(uint256 assets);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `assets` | `uint256` | The deposited assets that mapped to zero shares. |

Thrown when a nonzero-asset deposit would mint zero vault shares.

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

### `managedSupplyShares`

```solidity
function managedSupplyShares() external view returns (uint256);
```

### `totalAssets`

```solidity
function totalAssets() public view returns (uint256);
```

Only vault-originated supply shares back shares — direct loan-token donations and permissionless core `supply` credits to the vault address are uncounted and cannot move the share price.

### `maxWithdraw`

```solidity
function maxWithdraw(address owner) public view returns (uint256);
```

Capped by the market's free liquidity, not just the owner's position: supplied tokens may be borrowed out, so withdrawing past liquidity reverts in the core. The illiquid remainder exits via `fallbackExit`. Zero while the controller is paused, since a real withdraw would revert then too.

### `maxRedeem`

```solidity
function maxRedeem(address owner) public view returns (uint256);
```

Liquidity cap of `maxWithdraw`, in shares. When the owner's whole position fits in nonzero free liquidity it returns the exact share balance. Otherwise the floor conversion is a conservative ERC-4626 gate; `fallbackExit` can also service the remaining shares on the same redeem rounding plateau. Zero when the controller reports no withdrawable assets, including while paused.

### `maxDeposit`

```solidity
function maxDeposit(address) public view returns (uint256);
```

Deferred to the controller, which decides how much the market accepts.

### `maxMint`

```solidity
function maxMint(address receiver) public view returns (uint256);
```

`maxDeposit` in shares, floored; the unlimited sentinel passes through unconverted.

### `settle`

```solidity
function settle(
    uint256 shares,
    address[] calldata borrowers,
    address receiver,
    address owner
) external returns (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled);
```

A targeted, liquidity-neutral cut of borrowers that expose a positive personal settlement-LTV slice. Current free liquidity is not redeemed or reserved against the request. Budget exhaustion partial-fills; a call that consumes no core supply shares reverts. Collateral goes from the core straight to `receiver`. `fallbackExit` instead consumes available liquidity first and selects risk-queue roots for the remainder.

### `fallbackExit`

```solidity
function fallbackExit(
    uint256 shares,
    address receiver,
    address owner,
    uint256 maxIterations
) external returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
```

Pays the liquid part to `receiver` before settling the remainder. When the controller reports nonzero withdrawable liquidity and the requested shares' entire floor-rounded value fits, the vault burns exactly those shares. Otherwise it withdraws the exact available asset amount so no liquidity is stranded by share rounding. The settle leg sends seized collateral from the core straight to the same receiver. Queue or iteration exhaustion partial-fills; controller and core errors revert the whole call. If neither leg burns any shares, the call reverts instead of silently returning a no-op.

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `DEFAULT_MAX_SETTLEMENT_ITERATIONS` | `uint256` (constant) |  |
| `LIDO_LEND` | `ILidoLend` (immutable) |  |
| `marketId` | `Id` |  |
| `controller` | `ILidoLendMarketController` |  |
