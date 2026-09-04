<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# WstEthRateOracle

Morpho oracle for wstETH quoted in ETH using Lido's accounting rate.

Returns ETH per 1 wstETH scaled by 1e36, assuming stETH/ETH par for protocol accounting. No market-price dependency. price() = getStETHByWstETH(1e36) = stETH backing 1e36 wstETH = ETH per wstETH, scaled 1e36 (under stETH/ETH par) Querying at the 1e36 input (rather than `stEthPerToken() * 1e18`) keeps the rate's low-order digits instead of flooring at 1e18 and then scaling. This matches Morpho's IOracle convention: "price of 1 collateral asset (wstETH, 18 dec) quoted in 1 loan asset (ETH, 18 dec), scaled by 1e36", i.e. 36 + 18 - 18 = 36 decimals of precision.

## Errors

### `ZeroAddress`

```solidity
error ZeroAddress();
```

The wstETH address passed to the constructor was the zero address.

## Functions

### `constructor`

```solidity
constructor(address wstETH_);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `wstETH_` | `address` | wstETH token whose stETH-per-wstETH rate this oracle returns. |

### `price`

```solidity
function price() external view returns (uint256);
```

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `WSTETH` | `IWstETH` (immutable) | wstETH token queried for its stETH-per-wstETH accounting rate. |
