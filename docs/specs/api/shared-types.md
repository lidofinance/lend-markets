<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# Shared Types

The core market types (`Id`, `MarketParams`, `Position`) belong to the forked Morpho core — their full semantics live in [`lib/lido-lend/FORK_NOTES.md`](../../../lib/lido-lend/FORK_NOTES.md).

## `Id`

```solidity
type Id is bytes32
```

A market identifier, the `keccak256` hash of a `MarketParams`.

## `MarketParams`

```solidity
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}
```

## `Position`

```solidity
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}
```

> [!WARNING]
> For `feeRecipient`, `supplyShares` does not contain the accrued shares since the last interest accrual.

## `SettlementSlice`

```solidity
struct SettlementSlice {
    uint256 supplyShares;
    uint256 borrowShares;
    uint256 remainingBorrowShares;
}
```

One policy-sized settlement cut expressed in the two core anchors. A caller passes exactly one anchor to the core. For a nonzero cut, `remainingBorrowShares == 0` identifies a full close; an unavailable cut is represented by an all-zero struct.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `supplyShares` | `uint256` | Supply-share cost of the cut. |
| `borrowShares` | `uint256` | Borrow shares canceled by the cut. |
| `remainingBorrowShares` | `uint256` | Borrow shares left after a nonzero cut, 0 for a full close. |

## `SettlementQuote`

```solidity
struct SettlementQuote {
    SettlementSlice personal;
    SettlementSlice queueRoot;
}
```

The two independently sized policy candidates for a borrower at the current position state. Both remain subject to the global pause and bad-debt gates and to the caller's execution budget.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `personal` | `SettlementSlice` | Cut allowed by the borrower's personal settlement-LTV target, independent of queue membership, market liquidity, and the settling lender's illiquid supply tail. |
| `queueRoot` | `SettlementSlice` | Prospective queue-policy allowance. Execution requires the borrower to be the live queue root; any executed amount above `personal` must fit the settling lender's live illiquid supply tail. |

## `SettlementConfig`

```solidity
struct SettlementConfig {
    uint16 sliceFloorBps;
    uint96 sliceFloorAssets;
    uint96 fullCutBelowCollateral;
    uint16 ltvStepBps;
}
```

Settlement slice policy, set together via `setSettlementConfig`. The knobs tune the settlement slice cut. The uint96 amounts are policy bounds, not accounting: for a loan or collateral token whose plausible amounts exceed uint96 (~7.9e28 base units) the configurable floors cannot be set high enough to match — the policy weakens but nothing reverts or loses accounting.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `sliceFloorBps` | `uint16` | Debt-fraction term of the root cut: one allowance is `debt * sliceFloorBps / BPS`. |
| `sliceFloorAssets` | `uint96` | Absolute term of the root cut: one allowance is this many loan assets. |
| `fullCutBelowCollateral` | `uint96` | Sweep floor in collateral units: when a cut would leave the borrower's remaining collateral below this, the policy requests a full-debt slice. The vault closes the position in one cut only when the exiting lender's settleable budget covers it; otherwise it applies a supply-anchored partial. 0 disables the sweep. |
| `ltvStepBps` | `uint16` | LTV-step term of the root cut: one allowance is the cut that lowers the root's LTV by `ltvStepBps / BPS`. The root cut is the largest of the three terms (debt-fraction, absolute, LTV-step). |
