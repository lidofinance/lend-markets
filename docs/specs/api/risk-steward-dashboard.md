<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# RiskStewardDashboard

Standard inherited role-membership and role-administration functions are not repeated; see [OpenZeppelin AccessControlEnumerable](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControlEnumerable).

Dashboard-specific external surface: per-market steward management and bounded risk-reduction controls. Access-control membership and administration use the inherited `IAccessControlEnumerable` surface.

## Events

### `MarketStewardSet`

```solidity
event MarketStewardSet(Id indexed marketId, address indexed steward, bool enabled);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market the steward is scoped to. |
| `steward` | `address` | The steward whose appointment was set. |
| `enabled` | `bool` | True when appointed, false when removed. |

Emitted when a steward is appointed to or removed from a market.

### `ActivationDelaysIncreased`

```solidity
event ActivationDelaysIncreased(Id indexed marketId, uint256 newMinActivationDelay, uint256 newMaxActivationDelay, uint256 newMaxGuardiansQuorumDelay);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The updated market. |
| `newMinActivationDelay` | `uint256` | The new activation delay floor, in seconds. |
| `newMaxActivationDelay` | `uint256` | The new activation delay cap, in seconds. |
| `newMaxGuardiansQuorumDelay` | `uint256` | The new guardian-quorum fallback delay, in seconds. |

Emitted after an accepted non-decreasing update to a market's activation delay floor, cap, and guardian-quorum fallback.

### `ActivatingLockDurationIncreased`

```solidity
event ActivatingLockDurationIncreased(Id indexed marketId, uint256 newDuration);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The updated market. |
| `newDuration` | `uint256` | The new activating-lock duration, in seconds. |

Emitted after an accepted update to a market's activating-lock duration.

### `MinDepositAmountIncreased`

```solidity
event MinDepositAmountIncreased(Id indexed marketId, uint256 newMinDepositAmount);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The updated market. |
| `newMinDepositAmount` | `uint256` | The new minimum deposit, in collateral units. |

Emitted after an accepted update to a market's minimum deposit.

### `InstantActivationRevoked`

```solidity
event InstantActivationRevoked(Id indexed marketId, address indexed caller);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market the revocation applies to. |
| `caller` | `address` | The supply caller losing instant activation. |

Emitted when a steward revokes a caller's instant activation on a market.

## Errors

### `NotTightened`

```solidity
error NotTightened();
```

A lever would loosen a parameter instead of tightening it.

### `NotMarketSteward`

```solidity
error NotMarketSteward();
```

The caller is not a steward of the target market.

### `ZeroSteward`

```solidity
error ZeroSteward();
```

A zero-address steward was supplied.

### `ZeroAddress`

```solidity
error ZeroAddress();
```

A required address argument is zero.

### `UnknownMarket`

```solidity
error UnknownMarket(Id marketId);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | The market id without a controller. |

The market id has no controller on the core (unknown or not yet created).

## Functions

### `STEWARD_ADMIN_ROLE`

```solidity
function STEWARD_ADMIN_ROLE() external view returns (bytes32);
```

Role allowed to appoint and remove per-market stewards.

### `addMarketSteward`

```solidity
function addMarketSteward(Id marketId, address steward) external;
```

Appoint a steward to a market.

### `removeMarketSteward`

```solidity
function removeMarketSteward(Id marketId, address steward) external;
```

Remove a steward from a market.

### `marketStewards`

```solidity
function marketStewards(Id marketId) external view returns (address[] memory);
```

The stewards currently appointed for a market.

### `isMarketSteward`

```solidity
function isMarketSteward(
    Id marketId,
    address steward
) external view returns (bool);
```

Whether `steward` may operate this dashboard's risk controls for `marketId`.

### `increaseActivationDelays`

```solidity
function increaseActivationDelays(
    Id marketId,
    uint40 newMinActivationDelay,
    uint40 newMaxActivationDelay,
    uint40 newMaxGuardiansQuorumDelay
) external;
```

Raise the activation delay floor, cap, and guardian-quorum fallback. Reverts unless all values rise or hold. The controller bounds the cap and fallback to 7 days and enforces floor <= cap and a nonzero fallback > cap on write.

### `increaseActivatingLockDuration`

```solidity
function increaseActivatingLockDuration(
    Id marketId,
    uint40 newDuration
) external;
```

Raise the activating-lock duration; a decrease reverts. The controller still bounds the duration on write.

### `increaseMinDepositAmount`

```solidity
function increaseMinDepositAmount(
    Id marketId,
    uint128 newMinDepositAmount
) external;
```

Increase the minimum non-instant deposit. It cannot decrease or exceed `minActivationAmount`.

### `revokeInstantActivation`

```solidity
function revokeInstantActivation(Id marketId, address caller) external;
```

Set a caller's instant activation permission to false on a market. Risk-reducing, so no direction guard; the controller records and emits the requested false value even if it was already false.

### `freezeMarket`

```solidity
function freezeMarket(Id marketId) external;
```

Freeze a market. Only an appointed steward of that market may call.
