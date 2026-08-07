<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# RiskStewardDashboard

Dashboard-specific external surface: per-market steward management and bounded risk-reduction levers. Access-control membership and administration use the inherited `IAccessControlEnumerable` surface.

## Events

### `MarketStewardSet`

```solidity
event MarketStewardSet(Id indexed marketId, address indexed steward, bool enabled);
```

Emitted when a steward is appointed to or removed from a market.

### `ActivationDelaysIncreased`

```solidity
event ActivationDelaysIncreased(Id indexed marketId, uint256 newMinActivationDelay, uint256 newMaxActivationDelay, uint256 newMaxGuardiansQuorumDelay);
```

Emitted when the activation delay floor, cap, and guardian-quorum fallback are raised on a market.

### `ActivatingLockIncreased`

```solidity
event ActivatingLockIncreased(Id indexed marketId, uint256 newAmount, uint256 newDuration);
```

Emitted when the Sybil lock amount and duration are raised on a market.

### `InstantActivationRevoked`

```solidity
event InstantActivationRevoked(Id indexed marketId, address indexed caller);
```

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

Thrown when a required address argument is zero.

### `UnknownMarket`

```solidity
error UnknownMarket(Id marketId);
```

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

Whether `steward` may pull this dashboard's levers on `marketId`.

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

### `increaseActivatingLock`

```solidity
function increaseActivatingLock(
    Id marketId,
    uint128 newAmount,
    uint40 newDuration
) external;
```

Raise the Sybil lock amount and duration. Reverts unless both rise or hold. The controller still bounds the duration on write.

### `revokeInstantActivation`

```solidity
function revokeInstantActivation(Id marketId, address caller) external;
```

Revoke a caller's instant activation on a market. Risk-reducing, so no direction guard; forwards to the controller, which emits the state change.

### `freezeMarket`

```solidity
function freezeMarket(Id marketId) external;
```

Freeze a market. Only an appointed steward of that market may call.
