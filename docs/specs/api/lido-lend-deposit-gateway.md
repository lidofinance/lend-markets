<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendDepositGateway

Stateless entry zaps for WETH/wstETH `LidoLend` markets: lenders supply in ETH or WETH (or straight into the vault), borrowers post collateral in stETH. Wrapping convenience lives here so the core stays WETH/wstETH-only.

Entry-only: every zap adds value to `onBehalf` / `receiver`, so none of them needs a core authorization — a token approval to this gateway is enough. Holds no funds between transactions, which is also what makes the unlimited constructor approvals to the core and the vault safe: there is never a balance for them to spend outside a zap. Each zap names its target market in calldata and checks the one token it actually moves — the WETH supply zaps require the loan token to be WETH, the stETH collateral zap requires the collateral token to be wstETH — so the gateway only ever supplies the token it just wrapped; the market identity itself is never stored.

## Events

### `SuppliedCollateralWithStETH`

```solidity
event SuppliedCollateralWithStETH(address indexed caller, address indexed onBehalf, uint256 stEthAmount, uint256 wstEthAmount);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The address that called the zap. |
| `onBehalf` | `address` | The address credited the collateral. |
| `stEthAmount` | `uint256` | The measured stETH received (post rebasing-dust). |
| `wstEthAmount` | `uint256` | The wstETH supplied to the core. |

Emitted when stETH is wrapped and posted as collateral.

### `SuppliedWithETH`

```solidity
event SuppliedWithETH(address indexed caller, address indexed onBehalf, uint256 ethAmount, uint256 shares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The address that called the zap. |
| `onBehalf` | `address` | The address credited the supply. |
| `ethAmount` | `uint256` | The ETH wrapped and supplied. |
| `shares` | `uint256` | Supply shares credited to `onBehalf`. |

Emitted when ETH is wrapped to WETH and supplied to the market.

### `SuppliedWithWETH`

```solidity
event SuppliedWithWETH(address indexed caller, address indexed onBehalf, uint256 wethAmount, uint256 shares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The address that called the zap. |
| `onBehalf` | `address` | The address credited the supply. |
| `wethAmount` | `uint256` | The WETH supplied. |
| `shares` | `uint256` | Supply shares credited to `onBehalf`. |

Emitted when WETH is pulled from the caller and supplied to the market.

### `DepositedETHToVault`

```solidity
event DepositedETHToVault(address indexed caller, address indexed receiver, uint256 ethAmount, uint256 shares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The address that called the zap. |
| `receiver` | `address` | The address credited the vault shares. |
| `ethAmount` | `uint256` | The ETH wrapped and deposited. |
| `shares` | `uint256` | Vault shares minted to `receiver`. |

Emitted when ETH is wrapped to WETH and deposited into the vault.

### `DepositedWETHToVault`

```solidity
event DepositedWETHToVault(address indexed caller, address indexed receiver, uint256 wethAmount, uint256 shares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The address that called the zap. |
| `receiver` | `address` | The address credited the vault shares. |
| `wethAmount` | `uint256` | The WETH deposited. |
| `shares` | `uint256` | Vault shares minted to `receiver`. |

Emitted when WETH is pulled from the caller and deposited into the vault.

## Errors

### `ZeroAmount`

```solidity
error ZeroAmount();
```

A zap was passed a zero deposit (`msg.value` or amount argument).

### `ZeroOnBehalf`

```solidity
error ZeroOnBehalf();
```

A supply zap was passed the zero address as `onBehalf`.

### `ZeroReceiver`

```solidity
error ZeroReceiver();
```

A vault deposit zap was passed the zero address as `receiver`.

### `ZeroShares`

```solidity
error ZeroShares();
```

A vault deposit minted zero shares, so the zap would credit `receiver` nothing.

### `ZeroMorpho`

```solidity
error ZeroMorpho();
```

The constructor was passed the zero address as the LidoLend core.

### `ZeroWeth`

```solidity
error ZeroWeth();
```

The constructor was passed the zero address as WETH.

### `ZeroWstEth`

```solidity
error ZeroWstEth();
```

The constructor was passed the zero address as wstETH.

### `ZeroVault`

```solidity
error ZeroVault();
```

The constructor was passed the zero address as the vault.

### `LoanTokenMismatch`

```solidity
error LoanTokenMismatch();
```

A supply zap was given a market whose loan token is not the pinned WETH.

### `CollateralTokenMismatch`

```solidity
error CollateralTokenMismatch();
```

The collateral zap was given a market whose collateral token is not the pinned wstETH.

### `VaultAssetMismatch`

```solidity
error VaultAssetMismatch();
```

The vault's underlying asset is not WETH, so it cannot back the gateway's lenders. Checked once at construction.

## Functions

### `constructor`

```solidity
constructor(address morpho, address weth, address wstEth, address vault);
```

Pin the gateway to the `weth` / `wstEth` token pair and to `vault`, and grant the unlimited approvals the zaps rely on: WETH and wstETH to the core, stETH to wstETH for wrapping, WETH to the vault. stETH is read from `wstEth`. Reverts on any zero address or a vault whose asset is not WETH.

### `supplyCollateralWithStEth`

```solidity
function supplyCollateralWithStEth(
    MarketParams calldata params,
    uint256 stEthAmount,
    address onBehalf
) external returns (uint256 wstEthAmount);
```

### `supplyWithEth`

```solidity
function supplyWithEth(
    MarketParams calldata params,
    address onBehalf
) external payable returns (uint256 assets, uint256 shares);
```

### `supplyWithWeth`

```solidity
function supplyWithWeth(
    MarketParams calldata params,
    uint256 wethAmount,
    address onBehalf
) external returns (uint256 assets, uint256 shares);
```

### `depositEthToVault`

```solidity
function depositEthToVault(
    address receiver
) external payable returns (uint256 shares);
```

### `depositWethToVault`

```solidity
function depositWethToVault(
    uint256 wethAmount,
    address receiver
) external returns (uint256 shares);
```

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `WETH` | `IWETH` (immutable) |  |
| `STETH` | `IERC20` (immutable) |  |
| `WSTETH` | `IWstETH` (immutable) |  |
| `MORPHO` | `IMorpho` (immutable) |  |
| `WETH_VAULT` | `IERC4626` (immutable) |  |
