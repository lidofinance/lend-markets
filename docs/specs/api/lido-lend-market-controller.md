<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendMarketController

Full external surface of `LidoLendMarketController`: the core hook interface and AccessControlEnumerable (both inherited), the Lido-policy levers, freeze/pause, the settlement-queue views, and the borrower dashboard. The controller implements this interface, so it is the single source for the dashboard struct, events, errors, and the function docs the contract inherits.

## Enums

### `HookEvent`

```solidity
enum HookEvent {
    Supply,
    Withdraw,
    Borrow,
    Repay,
    SupplyCollateral,
    WithdrawCollateral,
    Liquidate,
    AccrueInterest,
    Settle
}
```

The action being dispatched to the controller.

## Structs

### `BorrowerPosition`

```solidity
struct BorrowerPosition {
    uint256 active;
    uint256 activating;
    uint256 dust;
    uint256 unlockTime;
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
| `flagCount` | `uint256` | Raw guardian flags on the account, regardless of status. |
| `banned` | `bool` | Hard-blocked by a latched guardian ban. |
| `debtAssets` | `uint256` | Current borrow debt, in loan assets. |
| `settlementLtv` | `uint256` | Borrower's personal settle-down target LTV (WAD), 0 when unset. |
| `isNextToSettle` | `bool` | The borrower is next in line to be settled. |
| `slice` | `uint256` | Loan assets that may be cut from this position in one settle now. |

### `SupplyHookData`

```solidity
struct SupplyHookData {
    address caller;
    address onBehalf;
    uint256 assets;
    uint256 shares;
}
```

Payload for the `Supply` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The supply call's msg.sender. |
| `onBehalf` | `address` | The address whose supply position grows. |
| `assets` | `uint256` | The loan-token amount supplied, after resolution. |
| `shares` | `uint256` | The supply shares minted, after resolution. |

### `WithdrawHookData`

```solidity
struct WithdrawHookData {
    address caller;
    address onBehalf;
    address receiver;
    uint256 assets;
    uint256 shares;
}
```

Payload for the `Withdraw` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The withdraw call's msg.sender. |
| `onBehalf` | `address` | The address whose supply position shrinks. |
| `receiver` | `address` | The address receiving the withdrawn loan tokens. |
| `assets` | `uint256` | The loan-token amount withdrawn, after resolution. |
| `shares` | `uint256` | The supply shares burned, after resolution. |

### `AccrueInterestHookData`

```solidity
struct AccrueInterestHookData {
    address caller;
}
```

Payload for the `AccrueInterest` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The accrueInterest call's msg.sender. |

### `SupplyCollateralHookData`

```solidity
struct SupplyCollateralHookData {
    address caller;
    address onBehalf;
    uint256 assets;
}
```

Payload for the `SupplyCollateral` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The supplyCollateral call's msg.sender. |
| `onBehalf` | `address` | The address whose collateral grows. |
| `assets` | `uint256` | The collateral-token amount supplied. |

### `BorrowHookData`

```solidity
struct BorrowHookData {
    address caller;
    address onBehalf;
    address receiver;
    uint256 assets;
    uint256 shares;
}
```

Payload for the `Borrow` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The borrow call's msg.sender. |
| `onBehalf` | `address` | The address whose borrow position grows. |
| `receiver` | `address` | The address receiving the borrowed loan tokens. |
| `assets` | `uint256` | The loan-token amount borrowed, after resolution. |
| `shares` | `uint256` | The borrow shares minted, after resolution. |

### `WithdrawCollateralHookData`

```solidity
struct WithdrawCollateralHookData {
    address caller;
    address onBehalf;
    address receiver;
    uint256 assets;
}
```

Payload for the `WithdrawCollateral` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The withdrawCollateral call's msg.sender. |
| `onBehalf` | `address` | The address whose collateral shrinks. |
| `receiver` | `address` | The address receiving the collateral. |
| `assets` | `uint256` | The collateral-token amount withdrawn. |

### `RepayHookData`

```solidity
struct RepayHookData {
    address caller;
    address onBehalf;
    uint256 assets;
    uint256 shares;
}
```

Payload for the `Repay` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The repay call's msg.sender. |
| `onBehalf` | `address` | The address whose borrow position shrinks. |
| `assets` | `uint256` | The loan-token amount repaid, after resolution. |
| `shares` | `uint256` | The borrow shares burned, after resolution. |

### `LiquidateHookData`

```solidity
struct LiquidateHookData {
    address caller;
    address borrower;
    uint256 seizedAssets;
    uint256 repaidAssets;
    uint256 repaidShares;
}
```

Payload for the `Liquidate` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The liquidator, and the address the seized collateral goes to. |
| `borrower` | `address` | The position being liquidated. |
| `seizedAssets` | `uint256` | The collateral-token amount seized, after resolution. |
| `repaidAssets` | `uint256` | The loan-token debt repaid, after resolution. |
| `repaidShares` | `uint256` | The borrow shares repaid, after resolution. |

### `SettleHookData`

```solidity
struct SettleHookData {
    address caller;
    address onBehalf;
    address borrower;
    address receiver;
    uint256 supplySharesBurned;
    uint256 borrowAssetsCanceled;
    uint256 borrowSharesCanceled;
    uint256 seizedAssets;
}
```

Payload for the `Settle` hook.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `caller` | `address` | The settle call's msg.sender. |
| `onBehalf` | `address` | The address whose supply shares are burned. |
| `borrower` | `address` | The address whose debt is canceled and collateral seized. |
| `receiver` | `address` | The address receiving the seized collateral. |
| `supplySharesBurned` | `uint256` | The supply shares burned from onBehalf, after resolution. |
| `borrowAssetsCanceled` | `uint256` | The loan-token debt canceled, computed in core. |
| `borrowSharesCanceled` | `uint256` | The borrow shares burned from borrower, computed in core. |
| `seizedAssets` | `uint256` | The collateral-token amount seized, computed in core. |

### `CollateralActivationConfig`

```solidity
struct CollateralActivationConfig {
    uint40 minActivationDelay;
    uint40 maxActivationDelay;
    uint128 maxDelayInflow;
    uint128 activatingLockAmount;
    uint40 activatingLockDuration;
    uint128 minActivationAmount;
    uint40 maxGuardiansQuorumDelay;
    uint40 delayPerStrike;
    uint40 delayPerSuspect;
}
```

Governance-tunable activation parameters, validated by `CollateralActivationLib.setConfig`.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `minActivationDelay` | `uint40` | Base delay floor, at zero inflow. |
| `maxActivationDelay` | `uint40` | Base delay cap, reached at inflow >= maxDelayInflow. Also the inflow decay horizon: the accumulator drains from `maxDelayInflow` to zero over this duration. |
| `maxDelayInflow` | `uint128` | Inflow reference at which the base delay reaches the cap, and the ceiling the inflow accumulator saturates at. |
| `activatingLockAmount` | `uint128` | Lock on activating collateral, honored by `withdraw`. 0 disables it. Forced paths pass floor 0. |
| `activatingLockDuration` | `uint40` | How long, from `activatingStart`, the `activatingLockAmount` portion stays unwithdrawable. Once it elapses the locked collateral becomes withdrawable even if the lot has not matured. 0 disables the lock. |
| `minActivationAmount` | `uint128` | Dust threshold. Collateral below it does not enter activation. |
| `maxGuardiansQuorumDelay` | `uint40` | Liveness fallback for the quorum gate, measured from the lot's start. Once it elapses the lot matures even if the guardian quorum has not scanned past the unlock. Must exceed the base-delay cap (maxActivationDelay), else it fires at the unlock and the quorum gets no window. 0 matures at the base unlock (no gate). A nonzero value cannot exceed 7 days. |
| `delayPerStrike` | `uint40` | Activation-delay surcharge added per guardian strike. 0 disables it, so strikes do not slow activation and only the ban gates a flagged borrower. |
| `delayPerSuspect` | `uint40` | Activation-delay surcharge added per active suspect report, applied only to lots whose activation started before the suspect snapshot lapses. 0 disables it. |

## Events

### `FrozenSet`

```solidity
event FrozenSet(bool frozen, address indexed account);
```

Emitted when the market is frozen or unfrozen.

### `InstantActivationSet`

```solidity
event InstantActivationSet(address indexed caller, bool enabled);
```

Emitted when a trusted caller's instant-activation status is set.

### `SupplyCapSet`

```solidity
event SupplyCapSet(uint256 cap, address indexed account);
```

Emitted when the supply cap is set.

### `GuardianSignalsSet`

```solidity
event GuardianSignalsSet(address indexed guardianSignals);
```

Emitted once when the market binds its guardian-signals registry at initialization.

## Errors

### `Unauthorized`

```solidity
error Unauthorized();
```

Thrown when the hook caller is not the core.

### `ZeroAddress`

```solidity
error ZeroAddress();
```

Thrown when a required address argument is zero.

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

### `SupplyCapExceeded`

```solidity
error SupplyCapExceeded(uint256 cap, uint256 attempted);
```

Thrown when a supply would push the market's total supplied loan assets above the cap.

### `InsufficientActiveCollateral`

```solidity
error InsufficientActiveCollateral();
```

Thrown when active (matured) collateral cannot cover the debt at the market LLTV.

### `ActivationLockActive`

```solidity
error ActivationLockActive();
```

Thrown when a withdrawal would leave raw collateral below the amount still held in the un-matured buckets (a locked activating lot plus dust).

### `ZeroBorrowAssets`

```solidity
error ZeroBorrowAssets();
```

Thrown when a borrow would mint borrow shares while transferring zero loan assets.

### `BorrowShareRateExceeded`

```solidity
error BorrowShareRateExceeded();
```

Thrown when a borrow, repay, or settle would push the market's borrow-share rate over the ceiling.

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

### `SettlementExceedsAllowed`

```solidity
error SettlementExceedsAllowed();
```

Thrown when the requested cut exceeds the policy-allowed slice (a zero slice means ineligible).

## Functions

### `MANAGER_ROLE`

```solidity
function MANAGER_ROLE() external view returns (bytes32);
```

The single governance role: full activation and settlement config, the supply cap, and grant and revoke instant activation.

### `FREEZER_ROLE`

```solidity
function FREEZER_ROLE() external view returns (bytes32);
```

Role allowed to freeze the market.

### `UNFREEZER_ROLE`

```solidity
function UNFREEZER_ROLE() external view returns (bytes32);
```

Role allowed to lift a freeze.

### `PAUSER_ROLE`

```solidity
function PAUSER_ROLE() external view returns (bytes32);
```

Role allowed to pause the hooks.

### `RESUMER_ROLE`

```solidity
function RESUMER_ROLE() external view returns (bytes32);
```

Role allowed to lift a pause.

### `MAX_BORROW_SHARE_RATE`

```solidity
function MAX_BORROW_SHARE_RATE() external view returns (uint256);
```

Ceiling on the market's borrow-share rate; borrow/repay/settle may not push past it (liquidation exempt). Bounds rounding-driven borrow-share inflation.

### `maxDeposit`

```solidity
function maxDeposit() external view returns (uint256);
```

Loan assets the market still accepts from lenders: the remaining supply-cap headroom, `type(uint256).max` when uncapped, 0 while paused.

### `maxWithdrawableAssets`

```solidity
function maxWithdrawableAssets(
    address supplier
) external view returns (uint256);
```

Loan assets `supplier` can withdraw from its market supply right now: its position capped by the idle liquidity, 0 while paused.

### `guardianSignals`

```solidity
function guardianSignals() external view returns (address);
```

The guardian-signals registry this controller reads for the borrow gate and activation scaling.

### `currentInflow`

```solidity
function currentInflow() external view returns (uint256);
```

Current decayed activation inflow (the throttle accumulator) — for monitoring and tests.

### `currentActivationDelay`

```solidity
function currentActivationDelay(
    uint256 inflowIncrement
) external view returns (uint256);
```

Activation delay a deposit of `inflowIncrement` would incur at the current inflow — for borrowers gauging the wait.

### `hasInstantActivation`

```solidity
function hasInstantActivation(address caller) external view returns (bool);
```

Whether `caller`'s supplies skip the activation timer.

### `setSettlementConfig`

```solidity
function setSettlementConfig(SettlementConfig calldata config) external;
```

Set the settlement config in one shot — the knobs size the same cut and move together. A cut is the largest of `sliceFloorBps` of the debt, `sliceFloorAssets`, and the cut that lowers the borrower's LTV by `ltvStepBps`. `fullCutBelowCollateral` lifts the cut to the full debt when the post-cut collateral would be dust.

### `settlementConfig`

```solidity
function settlementConfig() external view returns (SettlementConfig memory);
```

The current settlement config.

### `setSettlementLtv`

```solidity
function setSettlementLtv(uint256 ltv) external;
```

Borrower opts into auto-settle down to a target post-cut LTV (WAD). 0 clears it.

### `settlementLtv`

```solidity
function settlementLtv(
    address borrower
) external view returns (uint256 ltv, uint256 sliceAssets);
```

Borrower's personal settle-down target LTV (WAD) and the slice it currently implies.

### `settlementBorrowersCount`

```solidity
function settlementBorrowersCount() external view returns (uint256);
```

Number of borrowers tracked in the settlement queue.

### `hasBadDebt`

```solidity
function hasBadDebt() external view returns (bool);
```

True if any tracked borrower is bad debt — its debt value exceeds its collateral value.

O(1): it checks the riskiest tracked position (the highest debt/collateral), whose solvency implies every tracked position is solvent, so the settle gate need only check that one.

### `nextSettlementBorrower`

```solidity
function nextSettlementBorrower() external view returns (address borrower, uint256 supplyShares, uint256 borrowShares, uint256 remainingBorrowShares);
```

The settle cut the policy allows against the queue root (the borrower a head-first settle cuts first): `settlementFor` applied to it, with the root address. `borrower` is address(0) when empty.

### `settlementFor`

```solidity
function settlementFor(
    address borrower
) external view returns (uint256 supplyShares, uint256 borrowShares, uint256 remainingBorrowShares);
```

The settle cut the policy allows against `borrower`, as the two anchors a core `settle` accepts: the caller passes one and 0 for the other — `supplyShares` to settle supply-anchored, `borrowShares` borrow-anchored. `remainingBorrowShares` is the debt left after the cut, 0 for a full close. All zero when ineligible.

### `settlementBorrowers`

```solidity
function settlementBorrowers(
    uint256 offset,
    uint256 maxCount
) external view returns (address[] memory borrowers, uint256[] memory keys);
```

A window of queued borrowers (approximate top-down order) and their risk keys: up to `maxCount` starting at `offset`. Past the end the arrays are empty, so callers can page.

### `freeze`

```solidity
function freeze() external;
```

Freeze the market: new borrows and debt-bearing collateral withdrawals revert, and activation maturation is deferred. Debt-free positions can still withdraw their collateral.

### `unfreeze`

```solidity
function unfreeze() external;
```

Lift the freeze.

### `pauseFor`

```solidity
function pauseFor(uint256 duration) external;
```

Pause every hook for `duration` seconds. Pass PAUSE_INFINITELY for an indefinite pause.

### `resume`

```solidity
function resume() external;
```

Lift the pause.

### `isFrozen`

```solidity
function isFrozen() external view returns (bool);
```

Whether the market is frozen.

### `positionOf`

```solidity
function positionOf(
    address borrower
) external view returns (BorrowerPosition memory);
```

One-call borrower dashboard: collateral split, activation unlock, guardian signal, debt, personal settle-down LTV, and live settle exposure (next-to-settle flag + slice).

### `collateralActivationConfig`

```solidity
function collateralActivationConfig() external view returns (CollateralActivationConfig memory);
```

The market's current collateral-activation config.

### `setCollateralActivationConfig`

```solidity
function setCollateralActivationConfig(
    CollateralActivationConfig calldata cfg
) external;
```

Replace the collateral-activation config.

### `setInstantActivation`

```solidity
function setInstantActivation(address caller, bool enabled) external;
```

Set whether a caller's supplies activate instantly.

### `supplyCap`

```solidity
function supplyCap() external view returns (uint256);
```

The market's supply cap.

### `setSupplyCap`

```solidity
function setSupplyCap(uint256 cap) external;
```

Set the supply cap. 0 disables it.

### `on`

```solidity
function on(Id id, HookEvent hookEvent, bytes calldata data) external;
```

Core hook entrypoint: dispatches each market action to its internal handler.

Reverts on an unknown event so any future Morpho-fork-side change without a controller update fails closed instead of silently skipping policy.
