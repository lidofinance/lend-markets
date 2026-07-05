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

## `SettlementConfig`

```solidity
struct SettlementConfig {
    uint16 sliceFloorBps;
    uint96 sliceFloorAssets;
    uint96 fullCutBelowCollateral;
    uint16 ltvStepBps;
}
```

Settlement slice policy, set together via `setSettlementConfig`. The knobs tune the settlement slice cut. The uint96 amounts are policy bounds, not accounting: for a loan or collateral token whose plausible amounts exceed uint96 (~7.9e28 base units) the configurable floors saturate low — the policy weakens but nothing reverts or loses accounting.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `sliceFloorBps` | `uint16` | Debt-fraction term of the root cut: one allowance is `debt * sliceFloorBps / BPS`. |
| `sliceFloorAssets` | `uint96` | Absolute term of the root cut: one allowance is this many loan assets. |
| `fullCutBelowCollateral` | `uint96` | Sweep floor in collateral units: when a cut would leave the borrower's remaining collateral below this, the slice lifts to the full debt so the position closes in one cut, leaving no dust tail. 0 disables the sweep. |
| `ltvStepBps` | `uint16` | LTV-step term of the root cut: one allowance is the cut that lowers the root's LTV by `ltvStepBps / BPS`. The root cut is the largest of the three terms (debt-fraction, absolute, LTV-step). |
