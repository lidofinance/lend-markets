<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendMarketController

Full external surface of `LidoLendMarketController`: the core hook interface and AccessControl (both inherited), the Lido-policy levers, freeze/pause, the settlement-queue views, and the borrower dashboard. The controller implements this interface, so it is the single source for the dashboard struct, events, errors, and the function docs the contract inherits.

## Structs

### `BorrowerPosition`

```solidity
struct BorrowerPosition {
    uint256 active;
    uint256 activating;
    uint256 dust;
    uint256 unlockTime;
    uint256 strikes;
    uint256 flagCount;
    bool banned;
    uint256 debtAssets;
    uint256 settlementLtv;
    bool isNextToSettle;
    uint256 slice;
}
```

One-read borrower snapshot for off-chain dashboards: collateral split, activation timer, guardian signal, debt, personal settle-down LTV, and live settle exposure.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `active` | `uint256` | Matured collateral, borrowable. |
| `activating` | `uint256` | Collateral inside the activation timer, not yet borrowable. |
| `dust` | `uint256` | Collateral below the activation threshold, withdrawable. |
| `unlockTime` | `uint256` | Activation unlock timestamp, 0 when there is no timer. |
| `strikes` | `uint256` | Effective guardian strike count driving the activation surcharge (0 while immune). |
| `flagCount` | `uint256` | Raw guardian flags on the account, regardless of status (visible even while immune). |
| `banned` | `bool` | Hard-blocked by a latched guardian ban. |
| `debtAssets` | `uint256` | Current borrow debt, in loan assets. |
| `settlementLtv` | `uint256` | Borrower's personal settle-down target LTV (WAD), 0 when unset. |
| `isNextToSettle` | `bool` | The borrower is next in line to be settled. |
| `slice` | `uint256` | Loan assets that may be cut from this position in one settle now. |

## Events

### `FrozenSet`

```solidity
event FrozenSet(bool frozen, address indexed account);
```

Emitted when the market is frozen or unfrozen.

### `BorrowUtilizationGapSet`

```solidity
event BorrowUtilizationGapSet(uint256 borrowUtilizationGap);
```

Emitted when the borrow utilization gap is set (WAD; 0 = no gap).

### `InstantActivationSet`

```solidity
event InstantActivationSet(address indexed borrower, bool enabled);
```

Emitted when a borrower's instant-activation (no maturation timer) status is set.

## Errors

### `Unauthorized`

```solidity
error Unauthorized();
```

Thrown when the hook caller is not the core.

### `InvalidMarketId`

```solidity
error InvalidMarketId();
```

Thrown when the hook id is not this controller's market.

### `UnknownHookEvent`

```solidity
error UnknownHookEvent();
```

Thrown when the hook event is unrecognized.

### `MarketIsFrozen`

```solidity
error MarketIsFrozen();
```

Thrown when a freeze blocks the action.

### `AddressBanned`

```solidity
error AddressBanned();
```

Thrown when a banned address borrows, receives a borrow, or initiates one.

### `ConfigNotTightened`

```solidity
error ConfigNotTightened();
```

Thrown when a risk-steward lever would loosen a parameter instead of tightening it.

### `InsufficientActiveCollateral`

```solidity
error InsufficientActiveCollateral();
```

Thrown when active (matured) collateral cannot cover the debt at the market LLTV.

### `CollateralFloorBreached`

```solidity
error CollateralFloorBreached();
```

Thrown when a withdrawal would draw a borrower's collateral below the activation minimum while it still owes debt. Repaying to zero lifts the floor.

### `MaxBorrowUtilizationExceeded`

```solidity
error MaxBorrowUtilizationExceeded();
```

Thrown when a borrow would push borrow utilization above the maximum (WAD - borrowUtilizationGap).

### `BorrowUtilizationGapTooHigh`

```solidity
error BorrowUtilizationGapTooHigh();
```

Thrown when the borrow utilization gap is set to WAD or more (would freeze borrowing).

### `PositionAccountingMismatch`

```solidity
error PositionAccountingMismatch();
```

Thrown when a core-applied position delta exceeds the controller's read of that position. The controller's accounting mirrors the core, so a divergence reverts instead of masking it.

### `SettlementBadDebt`

```solidity
error SettlementBadDebt();
```

Thrown when a tracked borrower is bad debt, blocking settlement.

### `SettlementIneligible`

```solidity
error SettlementIneligible();
```

Thrown when the settle target is neither next in line to settle nor has a settlement LTV set.

### `SettlementExceedsAllowed`

```solidity
error SettlementExceedsAllowed();
```

Thrown when the requested cut exceeds the policy-allowed slice.

### `SettlementExceedsDebt`

```solidity
error SettlementExceedsDebt();
```

Thrown when the cut's shares exceed the borrower's debt.

### `SettlementInvalidSeize`

```solidity
error SettlementInvalidSeize();
```

Thrown when the seized collateral is zero or exceeds the borrower's collateral.

## Functions

### `MANAGER_ROLE`

```solidity
function MANAGER_ROLE() external view returns (bytes32);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bytes32` | The role identifier. |

Role gating the risk-increasing levers: full activation config, granting instant activation, the borrow-utilization gap, and the settlement config. Meant for the EasyTrack factory.

### `RISK_STEWARD_ROLE`

```solidity
function RISK_STEWARD_ROLE() external view returns (bytes32);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bytes32` | The role identifier. |

Role gating the fast risk-reducing levers, each one-directional toward tighter policy: raise the activation delay floor/cap, set the Sybil hold, revoke instant activation, widen the borrow gap.

### `FREEZER_ROLE`

```solidity
function FREEZER_ROLE() external view returns (bytes32);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bytes32` | The role identifier. |

Role allowed to freeze the market.

### `UNFREEZER_ROLE`

```solidity
function UNFREEZER_ROLE() external view returns (bytes32);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bytes32` | The role identifier. |

Role allowed to lift a freeze.

### `PAUSER_ROLE`

```solidity
function PAUSER_ROLE() external view returns (bytes32);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bytes32` | The role identifier. |

Role allowed to pause the hooks.

### `RESUMER_ROLE`

```solidity
function RESUMER_ROLE() external view returns (bytes32);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bytes32` | The role identifier. |

Role allowed to lift a pause.

### `setConfig`

```solidity
function setConfig(Config calldata cfg) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `cfg` | `Config` | The full activation config to validate and store. Overwrites the current config in one shot. |

Update the governance-tunable activation parameters. Risk-increasing path: the role is meant to be held by the EasyTrack factory, which adds the objection window.

Restricted to `MANAGER_ROLE`. Reverts if the config violates the activation-ramp bounds (delays out of order or above the 7-day sanity ceiling, or a zero floor/threshold/inflow reference).

### `increaseMinActivationDelay`

```solidity
function increaseMinActivationDelay(uint64 newMinActivationDelay) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `newMinActivationDelay` | `uint64` | New base delay floor, in seconds. Must be >= the current floor and not exceed the current delay cap. |

Fast risk-reducing lever: raise the activation delay floor. Reverts if it would lower.

Restricted to `RISK_STEWARD_ROLE`. Reverts with `ConfigNotTightened` if below the current floor.

### `increaseMaxActivationDelay`

```solidity
function increaseMaxActivationDelay(uint64 newMaxActivationDelay) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `newMaxActivationDelay` | `uint64` | New base delay cap, in seconds. Must be >= the current cap and within the 7-day sanity ceiling. |

Fast risk-reducing lever: raise the activation delay cap. Reverts if it would lower.

Restricted to `RISK_STEWARD_ROLE`. Reverts with `ConfigNotTightened` if below the current cap.

### `setActivatingHold`

```solidity
function setActivatingHold(uint128 activatingHold) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `activatingHold` | `uint128` | Amount of activating collateral per position held back until it matures, in collateral units. 0 disables the hold. |

Risk-steward lever (Sybil protection): hold up to `activatingHold` of each position's activating collateral unwithdrawable until it matures. 0 (the default) disables it.

Restricted to `RISK_STEWARD_ROLE`. Forced paths (liquidation, settle) ignore the hold. The hold is temporary: held collateral matures into `active` on its timer and becomes withdrawable, so this is not a custody power.

### `currentInflow`

```solidity
function currentInflow() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | The recent collateral inflow with its fixed-rate time decay applied, in collateral units. |

Current decayed activation inflow (the throttle accumulator) — for monitoring and tests.

### `grantInstantActivation`

```solidity
function grantInstantActivation(address borrower) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `borrower` | `address` | Address to grant instant activation to. |

Whitelist `borrower` to skip the activation maturation timer — its collateral becomes active on deposit. Risk-increasing path (waives the anti-flash/Sybil delay): meant for the EasyTrack factory and reserved for trusted addresses. Ban and freeze still gate as usual.

Restricted to `MANAGER_ROLE`.

### `revokeInstantActivation`

```solidity
function revokeInstantActivation(address borrower) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `borrower` | `address` | Address to revoke instant activation from. |

Fast risk-reducing lever: remove `borrower`'s instant activation, restoring the timer.

Restricted to `RISK_STEWARD_ROLE`.

### `hasInstantActivation`

```solidity
function hasInstantActivation(address borrower) external view returns (bool);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `borrower` | `address` | Address to query. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bool` | True if `borrower` has instant activation, false otherwise. |

Whether `borrower` skips the activation maturation timer.

### `setBorrowUtilizationGap`

```solidity
function setBorrowUtilizationGap(uint256 newBorrowUtilizationGap) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `newBorrowUtilizationGap` | `uint256` | New minimum gap, in WAD. Must be below `WAD`; 0 disables the gap. |

Set the minimum gap kept between borrow utilization and 100% (WAD; 0 = no gap, must be < WAD). Reserves that share of supply for lender withdrawals — a borrow that would close the gap reverts. Risk-increasing path (shrinking or disabling the gap): meant for the EasyTrack factory.

### `increaseBorrowUtilizationGap`

```solidity
function increaseBorrowUtilizationGap(uint256 newBorrowUtilizationGap) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `newBorrowUtilizationGap` | `uint256` | New minimum gap, in WAD. Must be strictly greater than the current gap. |

Fast risk-reducing lever: widen the gap. Reverts if it would not raise it.

### `borrowUtilizationGap`

```solidity
function borrowUtilizationGap() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | The minimum gap between borrow utilization and 100%, in WAD. 0 when no gap is set. |

The minimum gap kept between borrow utilization and 100% (WAD; 0 = no gap).

### `maxBorrowUtilization`

```solidity
function maxBorrowUtilization() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | Maximum borrow utilization allowed, in WAD (`WAD - borrowUtilizationGap`). `WAD` when no gap is set. |

Max borrow utilization permitted (WAD), i.e. WAD - borrowUtilizationGap. WAD when no gap is set.

### `currentBorrowUtilization`

```solidity
function currentBorrowUtilization() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | Borrowed / supplied for the market, in WAD, with pending interest simulated. 0 when supply is zero. |

The market's current borrow utilization (borrowed / supplied, WAD) with pending interest accrued.

### `setSettlementConfig`

```solidity
function setSettlementConfig(SettlementConfig calldata config) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `config` | `SettlementConfig` | The full slice policy to store. Overwrites the current config in one shot. |

Set the settlement config in one shot — the knobs size the same cut and move together. A cut is the largest of `sliceFloorBps` of the debt, `sliceFloorAssets`, and the cut that lowers the borrower's LTV by `ltvStepBps`. `fullCutBelowCollateral` lifts the cut to the full debt when the post-cut collateral would be dust.

Restricted to `MANAGER_ROLE`. Reverts if a basis-point knob (`sliceFloorBps` or `ltvStepBps`) exceeds 100%.

### `settlementConfig`

```solidity
function settlementConfig() external view returns (SettlementConfig memory);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `SettlementConfig` | The stored slice policy. |

The current settlement config.

### `setSettlementLtv`

```solidity
function setSettlementLtv(uint256 ltv) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `ltv` | `uint256` | Target post-cut LTV, in WAD. Must be strictly below WAD. 0 clears the opt-in. |

Borrower opts into auto-settle down to a target post-cut LTV (WAD). 0 clears it.

`msg.sender` is the borrower. Setting it makes the caller settle-eligible even when the settlement would not otherwise pick it next, capped at the slice that brings its LTV to `ltv`. Reverts if `ltv` is at or above WAD.

### `settlementLtv`

```solidity
function settlementLtv(
    address borrower
) external view returns (uint256 ltv, uint256 sliceAssets);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `borrower` | `address` | Address to query. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `ltv` | `uint256` | Borrower's personal settle-down target LTV (WAD), 0 when unset. |
| `sliceAssets` | `uint256` | Loan-asset slice the target LTV currently implies. |

Borrower's personal settle-down target LTV (WAD) and the slice it currently implies.

### `settlementBorrowersCount`

```solidity
function settlementBorrowersCount() external view returns (uint256);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `uint256` | The count of borrowers currently in the queue. |

Number of borrowers tracked in the settlement queue.

### `hasBadDebt`

```solidity
function hasBadDebt() external view returns (bool);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bool` | True if the riskiest tracked position is bad debt, false otherwise (including an empty queue). |

True if any tracked borrower is bad debt — its debt value exceeds its collateral value.

O(1): it checks the riskiest tracked position (the highest debt/collateral), whose solvency implies every tracked position is solvent, so the settle gate need only check that one.

### `nextSettlementBorrower`

```solidity
function nextSettlementBorrower() external view returns (address borrower, uint256 sliceAssets, uint256 sliceShares);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `borrower` | `address` | Next borrower the settlement would cut, address(0) when the queue is empty. |
| `sliceAssets` | `uint256` | Max slice allowed for it, in loan assets. |
| `sliceShares` | `uint256` | The same slice, in Morpho supply shares. |

The next borrower the settlement would cut and the max slice allowed for it (the larger of the config slice and the borrower's settlement-LTV slice, the bound the hook caps at), as both loan assets and the equivalent Morpho supply shares. `borrower` is address(0) when the queue is empty.

### `settlementFor`

```solidity
function settlementFor(
    address borrower
) external view returns (uint256 sliceAssets, uint256 sliceShares);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `borrower` | `address` | Address to size the cut for. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `sliceAssets` | `uint256` | Max single-cut slice against `borrower`, in loan assets. 0 when ineligible. |
| `sliceShares` | `uint256` | The same slice, in Morpho supply shares. |

Maximum slice allowed for a single settle cut against `borrower` (the larger of the config slice and the borrower's settlement-LTV slice), as both loan assets and the equivalent Morpho supply shares. Zero means ineligible.

### `settlementBorrowers`

```solidity
function settlementBorrowers(
    uint256 offset,
    uint256 maxCount
) external view returns (address[] memory borrowers, uint256[] memory keys);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `offset` | `uint256` | Index into the queue to start the window at. |
| `maxCount` | `uint256` | Maximum number of borrowers to return in the window. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `borrowers` | `address[]` | The window of queued borrowers, in approximate top-down (riskiest-first) order. |
| `keys` | `uint256[]` | Their risk keys, index-aligned with `borrowers`. |

A window of queued borrowers (approximate top-down order) and their risk keys: up to `maxCount` starting at `offset`. Past the end the arrays are empty, so callers can page.

### `freeze`

```solidity
function freeze() external;
```

Freeze the market: new borrows and debt-bearing collateral withdrawals revert, and activation settlement is deferred. Debt-free positions can still withdraw their collateral.

Restricted to `FREEZER_ROLE`. Emits `FrozenSet(true, msg.sender)`.

### `unfreeze`

```solidity
function unfreeze() external;
```

Lift the freeze.

Restricted to `UNFREEZER_ROLE`. Emits `FrozenSet(false, msg.sender)`.

### `pauseFor`

```solidity
function pauseFor(uint256 duration) external;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `duration` | `uint256` | Pause length in seconds, or PAUSE_INFINITELY for an indefinite pause. |

Pause every hook for `duration` seconds. Pass PAUSE_INFINITELY for an indefinite pause.

Restricted to `PAUSER_ROLE`. While paused, `on` reverts for every hook event.

### `resume`

```solidity
function resume() external;
```

Lift the pause.

Restricted to `RESUMER_ROLE`.

### `isFrozen`

```solidity
function isFrozen() external view returns (bool);
```

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `bool` | True if the market is frozen, false otherwise. |

Whether the market is frozen.

### `positionOf`

```solidity
function positionOf(
    address borrower
) external view returns (BorrowerPosition memory);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `borrower` | `address` | Address to build the dashboard for. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `<none>` | `BorrowerPosition` | The borrower's full dashboard snapshot. |

One-call borrower dashboard: collateral split, activation unlock, guardian signal, debt, personal settle-down LTV, and live settle exposure (next-to-settle flag + slice).
