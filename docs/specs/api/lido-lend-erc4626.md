<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendERC4626

Standard inherited ERC-20 share-token and ERC-4626 vault functions are not repeated; see [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626).

ERC-4626 vault over one LidoLend (Morpho Blue fork) market. Lenders deposit the loan token; the vault supplies it to the market, and shares grow with the market's interest. A normal withdrawal requires free market liquidity, which a heavily borrowed market may not have. Settlement is the exit for that case: the vault cancels borrower debt against its market supply and pays the exiting lender that borrower's collateral of the same oracle value, subject to rounding, so the exit requires no loan-token liquidity.

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
| `sharesBurned` | `uint256` | Shares burned by the whole call: the liquid leg and the settle leg together. |
| `sharesSettled` | `uint256` | Shares burned by the settle leg alone, 0 when liquidity serviced the whole request or no cut was executable. |
| `assetsWithdrawn` | `uint256` | Loan assets the liquid leg paid out, 0 when the market had no free liquidity or the requested shares' floor-rounded value was zero. |
| `collateralSeized` | `uint256` | Collateral seized from the cut positions. |
| `debtCanceled` | `uint256` | Borrower debt canceled by the cuts. |

Emitted when a `fallbackExit` call completes with a positive, possibly partial fill: serviced from market liquidity, settlement, or both.

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
| `debtCanceled` | `uint256` | Borrower debt canceled by the cuts. |

Emitted when a targeted `settle` call completes with a positive, possibly partial fill.

## Errors

### `ZeroShares`

```solidity
error ZeroShares();
```

The exit requests zero shares.

### `ZeroAddress`

```solidity
error ZeroAddress();
```

The seized-collateral receiver is the zero address.

### `ZeroLidoLend`

```solidity
error ZeroLidoLend();
```

The LidoLend core address is zero at construction.

### `ZeroController`

```solidity
error ZeroController();
```

The controller address is zero at initialization.

### `ControllerMarketMismatch`

```solidity
error ControllerMarketMismatch();
```

The bound controller governs a different market than the vault's.

### `ZeroLoanToken`

```solidity
error ZeroLoanToken();
```

The market's loan token is the zero address at initialization.

### `ZeroCollateralToken`

```solidity
error ZeroCollateralToken();
```

The market's collateral token is the zero address at initialization.

### `ZeroMorphoSupplyShares`

```solidity
error ZeroMorphoSupplyShares();
```

The exit maps to a zero core supply-share budget.

### `ZeroCoreSupplySharesMinted`

```solidity
error ZeroCoreSupplySharesMinted(uint256 assets);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `assets` | `uint256` | The deposited assets that mapped to zero core supply shares. |

A nonzero deposit received zero core supply shares.

### `NothingSettled`

```solidity
error NothingSettled();
```

A targeted settlement consumed no core supply shares across all requested borrowers, or a fallback exit burned no shares in either leg.

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

The requested exit shares exceed the owner's balance.

### `EmptyBorrowers`

```solidity
error EmptyBorrowers();
```

`settle` was called with an empty borrowers list.

### `ZeroSharesMinted`

```solidity
error ZeroSharesMinted(uint256 assets);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `assets` | `uint256` | The deposited assets that mapped to zero shares. |

A nonzero-asset deposit would mint zero vault shares.

## Functions

### `constructor`

```solidity
constructor(address lidoLend);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `lidoLend` | `address` | The LidoLend core. |

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

Only vault-originated supply shares back shares: direct loan-token donations and permissionless core `supply` credits to the vault address are uncounted and cannot move the share price.

### `maxWithdraw`

```solidity
function maxWithdraw(address owner) public view returns (uint256);
```

Capped by the market's free liquidity, not just the owner's position: supplied tokens may be borrowed out, so withdrawing past liquidity reverts in the core. The illiquid remainder exits via `fallbackExit`. Zero while the controller is paused, since a real withdraw would revert then too.

### `maxRedeem`

```solidity
function maxRedeem(address owner) public view returns (uint256);
```

Liquidity cap of `maxWithdraw`, in shares. When the owner's whole position fits in nonzero free liquidity it returns the exact share balance. Otherwise the floor conversion is a conservative ERC-4626 gate; shares excluded by that rounding can still exit through `fallbackExit`. Zero when the controller reports no withdrawable assets, including while paused.

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

Cuts only borrowers with a positive personal settlement-LTV slice, in the caller's order. Market liquidity is neither withdrawn nor reserved. Shares burn pro rata to the budget the cuts consumed: a budget exhausted before the list ends burns all requested shares, and a list whose cuts fall short of the budget burns only the settled fraction. A call that settles nothing reverts. Seized collateral moves from the core directly to `receiver`.

The budget is `previewRedeem(shares)` converted down into core supply shares at the accrued rate.

### `fallbackExit`

```solidity
function fallbackExit(
    uint256 shares,
    address receiver,
    address owner,
    uint256 maxIterations
) external returns (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled);
```

Pays out available market liquidity first, then settles the remainder. When nonzero available liquidity covers the requested shares' floor-rounded value, the vault burns exactly those shares. Otherwise it withdraws the exact liquid amount, so share rounding cannot strand liquidity, and settles the rest against borrowers the controller selects. Seized collateral moves from the core directly to the same `receiver`. When no executable cut remains or the iteration cap ends the loop early, the call burns shares only for what was serviced; controller and core errors revert the whole call. The settlement budget is the remaining shares' `previewRedeem` value after the liquid withdrawal, converted down into core supply shares. A nonzero remainder with a zero budget reverts the whole call. A call that burns no shares in either leg reverts.

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `DEFAULT_MAX_SETTLEMENT_ITERATIONS` | `uint256` (constant) |  |
| `LIDO_LEND` | `ILidoLend` (immutable) |  |
| `marketId` | `Id` |  |
| `controller` | `ILidoLendMarketController` |  |
