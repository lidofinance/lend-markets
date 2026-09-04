<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# Bundler3 Adapters

The local Bundler3 integration surface. Every non-constructor action below is callable only by the configured Bundler3 contract. Standard inherited Bundler3 adapter functions are documented by [Bundler3](https://github.com/morpho-org/bundler3) and are not repeated here.

## LidoLendVaultAdapter

Bundler3 adapter for the Lido Lend vault's fallback exit. Users approve their vault shares to this adapter; a bundle can then only ever exit the position of the user who started it.

### Errors

#### `ExitBelowMinimum`

```solidity
error ExitBelowMinimum(uint256 exitAssets, uint256 minExitAssets);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `exitAssets` | `uint256` | The exit's total payout in loan tokens: loan tokens paid plus debt cancelled. |
| `minExitAssets` | `uint256` | The caller's minimum total payout. |

The exit pays out less total value than the caller's minimum.

#### `BurnBelowMinimum`

```solidity
error BurnBelowMinimum(uint256 sharesBurned, uint256 minSharesBurned);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `sharesBurned` | `uint256` | Shares the exit burned. |
| `minSharesBurned` | `uint256` | The caller's minimum burn. |

The exit burns fewer shares than the caller's minimum.

### Functions

#### `constructor`

```solidity
constructor(address bundler3);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `bundler3` | `address` | The address of the Bundler3 contract. |

#### `fallbackExit`

```solidity
function fallbackExit(
    address vault,
    uint256 shares,
    uint256 maxIterations,
    address receiver,
    uint256 minExitAssets,
    uint256 minSharesBurned
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `vault` | `address` | The Lido Lend vault to exit. |
| `shares` | `uint256` | Vault shares to burn. Pass `type(uint256).max` for the initiator's full balance. |
| `maxIterations` | `uint256` | Cap on settlement-loop iterations; 0 uses the vault default. |
| `receiver` | `address` | Receives both payout tokens. When it is an adapter, later calls in the bundle must transfer both out of it. |
| `minExitAssets` | `uint256` | Minimum total payout, in loan tokens: the loan tokens paid plus the debt the settlement cancelled. One minimum covers both parts together, independent of how the payout splits between them. |
| `minSharesBurned` | `uint256` | Minimum shares the exit must burn. The exit may burn fewer than requested; pass `shares` to require all or nothing. |

Exits vault shares of the bundle initiator through the vault's fallback exit: what free market liquidity covers is paid in loan tokens, the rest is settled for borrower collateral.

The owner of the burned shares is always the bundle initiator, so a share approval given to this adapter can only be spent by a bundle its own owner started.

## EthereumGeneralAdapter1

Adapter contract specific to Ethereum n°1.

Vendored from bundler3's `EthereumGeneralAdapter1` with the MORPHO token surface removed (`MORPHO_TOKEN`, `MORPHO_TOKEN_LEGACY`, `MORPHO_WRAPPER`, their constructor arguments, and the `morphoWrapperDepositFor` / `morphoWrapperWithdrawTo` actions); everything else is upstream.

### Functions

#### `constructor`

```solidity
constructor(address bundler3, address morpho, address weth, address wStEth);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `bundler3` | `address` | The address of the Bundler3 contract. |
| `morpho` | `address` | The address of Morpho. |
| `weth` | `address` | The address of the WETH token. |
| `wStEth` | `address` | The address of the wstETH token. |

#### `stakeEth`

```solidity
function stakeEth(
    uint256 amount,
    uint256 maxSharePriceE27,
    address referral,
    address receiver
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `amount` | `uint256` | The amount of ETH to stake. Pass `type(uint).max` to stake the adapter's ETH balance. |
| `maxSharePriceE27` | `uint256` | The maximum amount of wei to pay for minting 1 share, scaled by 1e27. |
| `referral` | `address` | The address of the referral regarding the Lido Rewards-Share Program. |
| `receiver` | `address` | The account receiving the stETH tokens. |

Stakes ETH via Lido.

ETH must have been previously sent to the adapter.

#### `wrapStEth`

```solidity
function wrapStEth(uint256 amount, address receiver) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `amount` | `uint256` | The amount of stEth to wrap. Pass `type(uint).max` to wrap the adapter's balance. |
| `receiver` | `address` | The account receiving the wStETH tokens. |

Wraps stETH to wStETH.

stETH must have been previously sent to the adapter.

#### `unwrapStEth`

```solidity
function unwrapStEth(uint256 amount, address receiver) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `amount` | `uint256` | The amount of wStEth to unwrap. Pass `type(uint).max` to unwrap the adapter's balance. |
| `receiver` | `address` | The account receiving the stETH tokens. |

Unwraps wStETH to stETH.

wStETH must have been previously sent to the adapter.

### State variables

| Name | Type | Description |
| --- | --- | --- |
| `ST_ETH` | `address` (immutable) | The address of the stETH token. |
| `WST_ETH` | `address` (immutable) | The address of the wstETH token. |
