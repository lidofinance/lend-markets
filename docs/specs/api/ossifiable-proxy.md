<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# OssifiableProxy

This page covers the local proxy-admin extension. Standard inherited ERC-1967 proxy surface, including the delegated calldata fallback, is not repeated. The ossify, change-admin, and upgrade methods require the current nonzero proxy admin; after ossification they remain permanently unavailable.

An ossifiable proxy contract. Extends the ERC1967Proxy contract by adding admin functionality

## Events

### `ProxyOssified`

```solidity
event ProxyOssified();
```

## Errors

### `NotAdmin`

```solidity
error NotAdmin();
```

### `ProxyIsOssified`

```solidity
error ProxyIsOssified();
```

## Functions

### `constructor`

```solidity
constructor(address implementation_, address admin_, bytes memory data_);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `implementation_` | `address` | Address of the implementation |
| `admin_` | `address` | Address of the admin of the proxy |
| `data_` | `bytes` | Data used in a delegate call to implementation. The delegate call will be skipped if the data is empty bytes |

Initializes the upgradeable proxy with the initial implementation and admin

### `receive`

```solidity
receive() external payable;
```

Fallback function that delegates calls to the address returned by `_implementation()`.

### `proxy__ossify`

```solidity
function proxy__ossify() external;
```

Allows to transfer admin rights to zero address and prevent future upgrades of the proxy

### `proxy__changeAdmin`

```solidity
function proxy__changeAdmin(address newAdmin_) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `newAdmin_` | `address` | Address of the new admin |

Changes the admin of the proxy

### `proxy__upgradeTo`

```solidity
function proxy__upgradeTo(address newImplementation_) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `newImplementation_` | `address` | Address of the new implementation |

Upgrades the implementation of the proxy

### `proxy__upgradeToAndCall`

```solidity
function proxy__upgradeToAndCall(
    address newImplementation_,
    bytes calldata setupCalldata_
) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `newImplementation_` | `address` | Address of the new implementation |
| `setupCalldata_` | `bytes` | Data for the setup call. The call is skipped if setupCalldata_ is empty |

Upgrades the proxy to a new implementation, optionally performing an additional setup call.

### `proxy__getAdmin`

```solidity
function proxy__getAdmin() external view returns (address);
```

Returns the current admin of the proxy

### `proxy__getImplementation`

```solidity
function proxy__getImplementation() external view returns (address);
```

Returns the current implementation address

### `proxy__getIsOssified`

```solidity
function proxy__getIsOssified() external view returns (bool);
```

Returns whether the implementation is locked forever
