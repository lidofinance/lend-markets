<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# Shared Types

The core market types (`Id`, `MarketParams`, `Position`) belong to the forked Morpho core — their full semantics live in the [Lido Lend specification](https://github.com/lidofinance/lend/blob/main/SPECIFICATION.md).

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

One settlement cut. All three fields describe the same cut, so a budgeted quote stays consistent. A cut that cannot execute has zero `borrowShares` and `supplyShares`.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `supplyShares` | `uint256` | Core supply shares the cut burns, computed the way the core computes it. Exact for the market state it was read at; interest accrued before execution raises it. |
| `borrowShares` | `uint256` | Borrow shares canceled by the cut. |
| `remainingBorrowShares` | `uint256` | Borrow shares left after the cut: 0 for a full close or a debtless position, the borrower's untouched debt for a cut that cannot execute. |

## `SettlementQuote`

```solidity
struct SettlementQuote {
    SettlementSlice personal;
    SettlementSlice queueRoot;
}
```

The two cuts a borrower may be eligible for, each already shrunk to the requesting caller's supply budget. Both are still subject to the pause and bad-debt gates at execution.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `personal` | `SettlementSlice` | Cut allowed by the borrower's personal settlement-LTV target, independent of queue membership, market liquidity, and the settling lender's illiquid supply tail. |
| `queueRoot` | `SettlementSlice` | Cut allowed by the queue-root policy. Execution requires the borrower to be the live queue root, and a cut above `personal` must fit the settling lender's illiquid supply tail in full, not just the excess. |

## `SettlementConfig`

```solidity
struct SettlementConfig {
    uint16 sliceFloorBps;
    uint96 sliceFloorAssets;
    uint96 fullCutBelowCollateral;
    uint16 ltvStepBps;
}
```

Sizing policy for the queue-root settlement cut, set together via `setSettlementConfig`. The queue root did not opt into settlement, so this policy decides how much of its debt one cut may settle: the largest of the three allowances below, capped at the debt. The uint96 amounts are policy bounds, not accounting: for a loan or collateral token whose plausible amounts exceed uint96 (~7.9e28 base units) the configurable floors cannot be set high enough to match; the policy weakens but nothing reverts or loses accounting.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `sliceFloorBps` | `uint16` | Debt-fraction term of the root cut: one allowance is `debt * sliceFloorBps / BPS`. |
| `sliceFloorAssets` | `uint96` | Absolute term of the root cut: one allowance is this many loan assets. |
| `fullCutBelowCollateral` | `uint96` | Queue-root sweep floor in collateral units: when a positive root-policy cut would leave the borrower's remaining collateral below this, the policy requests the full debt instead. Applies only to the queue-root cut, never the personal settlement-LTV cut. 0 disables the sweep. |
| `ltvStepBps` | `uint16` | LTV-step term of the root cut: one allowance is the cut that lowers the root's LTV by `ltvStepBps / BPS`. The root cut is the largest of the three terms (debt-fraction, absolute, LTV-step). |
