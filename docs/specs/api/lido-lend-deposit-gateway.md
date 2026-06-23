<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendDepositGateway

Stateless entry zaps for a WETH/wstETH `LidoLend` market: lenders supply in ETH or WETH (or straight into the vault), borrowers post collateral in stETH. Wrapping convenience lives here so the core stays WETH/wstETH-only.

Entry-only: every zap adds value to `onBehalf` / `receiver`, so none of them needs a core authorization — a token approval to this gateway is enough. Holds no funds between transactions, which is also what makes the unlimited constructor approvals to the core and the vault safe: there is never a balance for them to spend outside a zap.

## Events

### `SuppliedCollateralWithStETH`

```solidity
event SuppliedCollateralWithStETH(address indexed caller, address indexed onBehalf, uint256 stEthAmount, uint256 wstEthAmount);
```

Emitted when stETH is wrapped and posted as collateral. `stEthAmount` is the measured stETH received (post rebasing-dust), `wstEthAmount` the wstETH supplied to core.

### `SuppliedWithETH`

```solidity
event SuppliedWithETH(address indexed caller, address indexed onBehalf, uint256 ethAmount, uint256 shares);
```

Emitted when ETH is wrapped to WETH and supplied to the market for `onBehalf`.

### `SuppliedWithWETH`

```solidity
event SuppliedWithWETH(address indexed caller, address indexed onBehalf, uint256 wethAmount, uint256 shares);
```

Emitted when WETH is pulled from the caller and supplied to the market for `onBehalf`.

### `DepositedETHToVault`

```solidity
event DepositedETHToVault(address indexed caller, address indexed receiver, uint256 ethAmount, uint256 shares);
```

Emitted when ETH is wrapped to WETH and deposited into the vault for `receiver`.

### `DepositedWETHToVault`

```solidity
event DepositedWETHToVault(address indexed caller, address indexed receiver, uint256 wethAmount, uint256 shares);
```

Emitted when WETH is pulled from the caller and deposited into the vault for `receiver`.

## Errors

### `ZeroAmount`

```solidity
error ZeroAmount();
```

A zap was passed a zero deposit (`msg.value` or amount argument).

### `ZeroAddress`

```solidity
error ZeroAddress();
```

A zap was passed the zero address as `onBehalf` / `receiver`, or the constructor as a core, token, or vault address.

### `ZeroShares`

```solidity
error ZeroShares();
```

A vault deposit minted zero shares, so the zap would credit `receiver` nothing.

### `VaultAssetMismatch`

```solidity
error VaultAssetMismatch();
```

The vault's underlying asset does not match the market loan token, so it cannot back this market's lenders. Checked once at construction.

## Functions

### `constructor`

```solidity
constructor(address morpho, MarketParams memory params, address vault);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `morpho` | `address` | The `LidoLend` core the supply/collateral zaps route into. |
| `params` | `MarketParams` | The market identity frozen into the gateway. Its loan token becomes `WETH`, its collateral token `WSTETH`, and `WSTETH.stETH()` becomes `STETH`. |
| `vault` | `address` | The ERC-4626 vault the deposit zaps route into. Its asset must be the loan token. |

Bind the gateway to one market and its vault, and grant the unlimited approvals the zaps rely on: loan and collateral tokens to the core, stETH to wstETH for wrapping, loan token to the vault. Reverts on any zero address or a vault whose asset is not the loan token.

### `marketParams`

```solidity
function marketParams() external view returns (MarketParams memory);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `MarketParams` | The frozen market identity passed to every core supply / collateral call. |

The market this gateway zaps into.

### `supplyCollateralWithStEth`

```solidity
function supplyCollateralWithStEth(
    uint256 stEthAmount,
    address onBehalf
) external returns (uint256 wstEthAmount);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `stEthAmount` | `uint256` | stETH amount to pull from the caller. The measured received delta is wrapped, not this figure, since stETH transfers can deliver 1-2 wei less. |
| `onBehalf` | `address` | Position owner the collateral is credited to. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `wstEthAmount` | `uint256` | wstETH supplied as collateral. |

Pull stETH from the caller, wrap it to wstETH and post it as collateral for `onBehalf`.

### `supplyWithEth`

```solidity
function supplyWithEth(
    address onBehalf
) external payable returns (uint256 assets, uint256 shares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `onBehalf` | `address` | Lender the supply shares are credited to. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `assets` | `uint256` | WETH supplied (equals `msg.value`). |
| `shares` | `uint256` | Supply shares credited to `onBehalf`. |

Wrap `msg.value` to WETH and supply it for `onBehalf`.

### `supplyWithWeth`

```solidity
function supplyWithWeth(
    uint256 wethAmount,
    address onBehalf
) external returns (uint256 assets, uint256 shares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `wethAmount` | `uint256` | WETH amount to pull from the caller and supply. |
| `onBehalf` | `address` | Lender the supply shares are credited to. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `assets` | `uint256` | WETH supplied (equals `wethAmount`). |
| `shares` | `uint256` | Supply shares credited to `onBehalf`. |

Pull WETH from the caller and supply it for `onBehalf`.

### `depositEthToVault`

```solidity
function depositEthToVault(
    address receiver
) external payable returns (uint256 shares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `receiver` | `address` | Account the vault shares are minted to. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `shares` | `uint256` | Vault shares minted to `receiver`. |

Wrap `msg.value` to WETH and deposit it into the vault, minting shares to `receiver`.

### `depositWethToVault`

```solidity
function depositWethToVault(
    uint256 wethAmount,
    address receiver
) external returns (uint256 shares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `wethAmount` | `uint256` | WETH amount to pull from the caller and deposit. |
| `receiver` | `address` | Account the vault shares are minted to. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `shares` | `uint256` | Vault shares minted to `receiver`. |

Pull WETH from the caller and deposit it into the vault for `receiver`.

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `MORPHO` | `IMorpho` (immutable) | The `LidoLend` core the supply/collateral zaps route into. |
| `WETH` | `IWETH` (immutable) | The market loan token. Lenders' ETH is wrapped into it before supply. |
| `WSTETH` | `IWstETH` (immutable) | The market collateral token. Borrowers' stETH is wrapped into it before `supplyCollateral`. |
| `STETH` | `IERC20` (immutable) | The stETH wrapped into `WSTETH`. Read off `WSTETH.stETH()` at construction. |
| `VAULT` | `ILidoLendVault` (immutable) | The ERC-4626 vault the deposit zaps route into. Its asset is the loan token. |
