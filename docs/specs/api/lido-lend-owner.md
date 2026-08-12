<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendOwner

Standard inherited role-membership and role-administration functions are not repeated; see [OpenZeppelin AccessControlEnumerable](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControlEnumerable).

Role-gated governance facade bound to a `LidoLend` core. It is designed to hold the core's single-owner authority, which must be transferred separately and can later be moved away. While it is the owner, the facade splits the core's owner-only surface and per-market governance surface across distinct roles so each capability can be delegated independently. Per-market calls resolve the target controller and guardian registry from the core, giving governance one stable facade address for every market.

Role-management events and the unauthorized-caller error come from OpenZeppelin's `IAccessControlEnumerable`.

## Errors

### `ZeroAddress`

```solidity
error ZeroAddress();
```

Thrown when the core, required admin, or an ownership target is the zero address.

### `UnknownMarket`

```solidity
error UnknownMarket(Id marketId);
```

The market id has no controller on the core (unknown or controller-less).

## Functions

### `constructor`

```solidity
constructor(
    ILidoLend core,
    address admin,
    address marketCreator,
    address feeManager
);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `core` | `ILidoLend` | The `LidoLend` core this facade will own. The deploy must hand the core's `owner` to this facade after construction; the facade cannot do it itself. |
| `admin` | `address` | Holder of `DEFAULT_ADMIN_ROLE`, which manages the capability roles and core ownership. Required. |
| `marketCreator` | `address` | Initial `MARKET_CREATOR_ROLE` holder; `address(0)` grants none (admin can later). |
| `feeManager` | `address` | Initial `FEE_MANAGER_ROLE` holder; `address(0)` grants none (admin can later). |

### `LIDO_LEND`

```solidity
function LIDO_LEND() external view returns (ILidoLend);
```

The `LidoLend` core this facade is bound to.

### `MARKET_CREATOR_ROLE`

```solidity
function MARKET_CREATOR_ROLE() external view returns (bytes32);
```

Role allowed to create markets on the core.

### `FEE_MANAGER_ROLE`

```solidity
function FEE_MANAGER_ROLE() external view returns (bytes32);
```

Role allowed to update core fees.

### `MARKET_MANAGER_ROLE`

```solidity
function MARKET_MANAGER_ROLE() external view returns (bytes32);
```

Role allowed to update per-market controller policy.

### `GUARDIAN_MANAGER_ROLE`

```solidity
function GUARDIAN_MANAGER_ROLE() external view returns (bytes32);
```

Role allowed to manage guardian registries.

### `createMarket`

```solidity
function createMarket(MarketParams calldata marketParams) external;
```

Create a controller-less market on the core.

Requires `MARKET_CREATOR_ROLE`.

### `createMarket`

```solidity
function createMarket(
    MarketParams calldata marketParams,
    address controller,
    bool enableSettlement
) external;
```

Create a controlled market on the core, binding `controller` and the `settle` opt-in.

Requires `MARKET_CREATOR_ROLE`.

### `setFee`

```solidity
function setFee(MarketParams calldata marketParams, uint256 newFee) external;
```

Set the fee of an existing market.

Requires `FEE_MANAGER_ROLE`.

### `setFeeRecipient`

```solidity
function setFeeRecipient(address newFeeRecipient) external;
```

Set the global fee recipient.

Requires `FEE_MANAGER_ROLE`.

### `setMarketSupplyCap`

```solidity
function setMarketSupplyCap(Id marketId, uint256 cap) external;
```

Set a market's supply cap. A zero cap disables it.

Requires `MARKET_MANAGER_ROLE`.

### `unfreezeMarket`

```solidity
function unfreezeMarket(Id marketId) external;
```

Lift a market's freeze.

Requires `MARKET_MANAGER_ROLE`.

### `setMarketCollateralActivationConfig`

```solidity
function setMarketCollateralActivationConfig(
    Id marketId,
    CollateralActivationConfig calldata config
) external;
```

Replace a market's collateral-activation configuration.

Requires `MARKET_MANAGER_ROLE`.

### `setMarketSettlementConfig`

```solidity
function setMarketSettlementConfig(
    Id marketId,
    SettlementConfig calldata config
) external;
```

Replace a market's settlement configuration.

Requires `MARKET_MANAGER_ROLE`.

### `setInstantActivation`

```solidity
function setInstantActivation(
    Id marketId,
    address caller,
    bool enabled
) external;
```

Set whether a caller's supplies activate instantly on a market.

Requires `MARKET_MANAGER_ROLE`.

### `addGuardian`

```solidity
function addGuardian(Id marketId, address guardian) external;
```

Add a guardian to the registry used by a market.

Requires `GUARDIAN_MANAGER_ROLE`.

### `replaceGuardian`

```solidity
function replaceGuardian(
    Id marketId,
    address oldGuardian,
    address newGuardian
) external;
```

Replace one guardian with another in the registry used by a market.

Requires `GUARDIAN_MANAGER_ROLE`.

### `removeGuardian`

```solidity
function removeGuardian(Id marketId, address guardian) external;
```

Remove a guardian from the registry used by a market.

Requires `GUARDIAN_MANAGER_ROLE`.

### `setGuardiansQuorum`

```solidity
function setGuardiansQuorum(Id marketId, uint256 quorum) external;
```

Set the quorum of the guardian registry used by a market.

Requires `GUARDIAN_MANAGER_ROLE`.

### `setGuardiansSuspectWindow`

```solidity
function setGuardiansSuspectWindow(Id marketId, uint256 suspectWindow) external;
```

Set the suspect window of the guardian registry used by a market.

Requires `GUARDIAN_MANAGER_ROLE`.

### `unbanGuardianSignals`

```solidity
function unbanGuardianSignals(
    Id[] calldata marketIds,
    address account
) external;
```

Lift `account`'s ban in each market, resolving that market's guardian registry independently.

Requires `GUARDIAN_MANAGER_ROLE`.

### `transferLidoLendOwnership`

```solidity
function transferLidoLendOwnership(address newOwner) external;
```

Hand the core's `owner` to `newOwner`, relinquishing this facade's control of the core. The escape hatch for migrating to a different owner; irreversible from the facade's side. Only core ownership moves: facade role memberships remain unchanged and are not granted to `newOwner`.

Requires `DEFAULT_ADMIN_ROLE`.
