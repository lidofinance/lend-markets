# Settlement and Lender Exits

Lenders normally exit by withdrawing loan assets from the market's free liquidity. That path cannot satisfy a large exit when most supplied assets are currently borrowed. Settlement is an alternative exit path: it cancels a borrower's debt against an authorized lender's supply and transfers collateral of the same oracle value to a chosen receiver, subject to rounding. No liquidation incentive is added.

Settlement does not create loan-token liquidity. It reduces market supply and debt together, removes the corresponding collateral from the borrower, and pays that collateral directly to the receiver.

## Entry paths

| Path | Supplier position | Borrower selection | Receiver gets |
|---|---|---|---|
| Direct core settlement | A direct core supplier, or its authorized operator | One borrower selected by the caller; personal policy is available for any borrower, while root policy requires the live queue root | Collateral |
| Targeted vault settlement | A vault-share owner, or its approved operator | A caller-ordered list; personal policy only | Collateral |
| Vault fallback exit | A vault-share owner, or its approved operator | No caller list; free liquidity is used first, then the live queue root | Loan assets first, then collateral if settlement is needed |

This is distinct from an [Exit Book](exit-books.md). Settlement changes the composition of a lender position from market supply to borrower collateral. An Exit Book instead coordinates a permissionless filler around an existing vault or direct supply position.

## Terms used in this document

| Term | Meaning |
|---|---|
| Borrow share | The core's integer unit of borrower debt. Its value in loan assets changes as interest accrues. |
| Supply share | The core's integer unit of supplier ownership. Its value in loan assets changes as interest accrues. |
| Raw unit | The smallest integer unit of a token or share value. It is not one whole token. |
| Oracle price | The collateral value quoted in loan-token raw units, scaled by `1e36` and adjusted for the two tokens' decimals. |
| Supply-share budget | The maximum core supply shares that one quote may consume. |

## Setup and authorization

Settlement must have been enabled when the market was created; that choice cannot be changed later. The direct path requires the caller to own or be authorized over the core supplier position. Vault paths instead require ownership or allowance over vault shares. These permissions are independent: neither grants the other. The receiver may differ from the position owner.

## Core settlement accounting

### Amounts and rounding

The core accepts an exact positive number of borrow shares as the settlement input. After accruing interest it derives every other amount from the live market totals.

| Result | Calculation |
|---|---|
| Debt canceled | Convert the borrow-share input to loan assets and round up. |
| Supplier shares burned | Convert the canceled debt assets to supply shares and round up. |
| Collateral seized | Convert the borrow-share input to loan assets and round down, then convert that asset value to collateral-token units and round down again. |

Core share conversions include Morpho's fixed buffer of one virtual asset and `1e6` virtual shares. These are accounting constants, not real assets or user-owned shares. They remain in the conversion near an empty market and create the final raw-unit boundaries described below; the exact formulas are in the [core specification](https://github.com/lidofinance/lido-lend/blob/main/SPECIFICATION.md#settlement).

Passing the borrower's entire borrow-share balance closes that debt position exactly. The up-rounded debt amount can exceed the remaining total borrow assets by one raw unit at the final boundary, so the core floors the market total at zero when applying the settlement.

The core rejects a zero borrow-share input or receiver, a settlement larger than the borrower's debt, a derived supply burn larger than the supplier's position, and a seizure that is zero or exceeds the borrower's collateral. If positive debt rounds to zero collateral-token units, that debt must be repaid or removed through another path before settlement can succeed.

The collateral calculation intentionally rounds in the other direction. The loan-asset value used to calculate collateral is at most one raw loan-token unit below the up-rounded canceled debt. Rounding down again to collateral-token units can increase that value difference. The borrower therefore never pays a rounding premium to the lender, and there is no liquidation bonus.

### Execution

After interest accrual and before settlement-specific writes, the core sends the resolved supply burn, debt cancellation, and collateral seizure to the market controller. If policy allows the settlement, the core:

1. burns the derived supply shares from the authorized supplier;
2. reduces total supply assets by the canceled debt assets;
3. burns the requested borrow shares and reduces total borrow assets;
4. removes the priced collateral from the borrower; and
5. transfers that collateral directly to the receiver.

The core deliberately performs no borrower-health check for settlement. The controller's queue and bad-debt rules are the policy boundary. The core and controller read the same oracle separately during one settlement, so the oracle price must be nonzero, consistent across those reads, and independent of the caller. The collateral token can reject the transfer to the receiver. Loan and collateral tokens must transfer the exact requested amount, must not rebase during the operation, and must not call back into the protocol during transfer.

## Risk queue and bad-debt gate

The controller tracks borrowers that have both debt and nonzero raw collateral in a max-heap. A borrower with debt but zero collateral is not tracked: its policy quotes are empty, and a direct core settlement cannot seize an allowed positive collateral amount. The position must receive collateral, be repaid, or be handled through liquidation. A max-heap is a queue whose first item has the largest key. The ordering key is:

```text
riskKey = borrowShares * 1e18 / rawCollateral
```

`rawCollateral` is the collateral-token balance before oracle conversion, and the integer division rounds down. Within one market, every borrower uses the same borrow-share rate and collateral price, so the unrounded ratio is monotonic in LTV. The stored key is a rounded risk estimate, not an exact onchain LTV. The heap root has the largest stored key. Different exact ratios can have the same key, and borrowers with equal keys are not ordered by exact LTV. The core calls the controller before applying each position change; the controller projects the resulting position and updates or removes that borrower's queue entry.

Before authorizing any settlement, the controller checks the tracked root for bad debt. If that root's debt value exceeds its collateral value, every settlement path reverts until the state is resolved outside settlement, for example through repayment or liquidation. The check is constant-time and covers only the selected root; it does not scan all tracked borrowers or untracked zero-collateral debt.

> [!NOTE]
> **Accepted root-only bad-debt detection risk.** Rounded queue keys can leave a solvent borrower at the root while another borrower with the same key is already in bad debt. The root-only check can then miss the bad debt, allowing settlement to shift the later loss to remaining suppliers.
>
> Liquidation is available before bad debt and normally acts first, but this is not guaranteed. See ADR 013 for ordinary bad debt.

## Two settlement policies

The two policies serve different purposes. A borrower enables personal settlement by selecting a target LTV. Root policy requires no borrower action and allows the current queue root to be settled during a lender exit. Both policies first calculate a loan-asset allowance, cap it by the borrower's debt, and convert it to the borrow-share limit enforced at execution. If either debt value or oracle-priced collateral value is zero, both policy candidates are empty. This includes a zero oracle price and a positive price that rounds the collateral value to zero; a direct core call cannot bypass the core's collateral checks.

### Personal settlement target

A borrower may select a target post-settlement LTV below 100%. A zero target disables the personal policy. When the position is above a positive target, the nominal loan-asset amount is:

```text
personalSliceAssets =
    (debtAssets * 1e18 - targetLtv * collateralValue)
    / (1e18 - targetLtv)
```

Here `debtAssets` is the borrower's share debt rounded up, while `collateralValue` prices its entire raw collateral balance rounded down. All raw collateral counts, including collateral that is not yet active for borrowing under the [activation rules](market-controller.md#collateral-activation). The final division rounds down.

The result is zero when debt or priced collateral value is zero, no target is set, or the current LTV is already at or below the target. A positive personal allowance is available regardless of queue position and current market liquidity. It opts the borrower into settlement by any supplier whose core position is properly authorized; it does not select a particular lender or receiver. Only the borrower can change the target. Closing the position does not clear it: the target applies to future debt until the borrower sets it to zero. The queue's collateral-dust rule does not increase the personal allowance.

> **Example.** Debt is 80 loan assets, collateral value is 100, and the target is 50%. The formula returns a settlement amount of 60. Ignoring token-unit rounding, settlement leaves debt of 20 and collateral value of 40, which is 50% LTV.

### Queue-root policy

The root policy requires no borrower opt-in, but it applies only while that borrower is the live heap root. Its nominal allowance is the largest of three controls:

| Rule | Loan-asset allowance |
|---|---|
| Debt fraction | `floor(debtAssets * sliceFloorBps / 10_000)` |
| Absolute floor | `sliceFloorAssets` |
| LTV step | the settlement amount that lowers the current LTV by `ltvStepBps / 10_000` |

The LTV-step rule reuses the personal-settlement formula with this target:

```text
currentLtv = floor(debtAssets * 1e18 / collateralValue)
ltvReduction = floor(ltvStepBps * 1e18 / 10_000)
stepTargetLtv = max(currentLtv - ltvReduction, 0)
```

The current LTV, configured reduction, target, and resulting allowance all use integer division rounded down.

The maximum is capped at the borrower's debt. Before borrow-share and supplier-budget rounding, the controller estimates the remaining collateral from the nominal asset allowance:

```text
estimatedSeizedCollateral = floor(nominalAllowance * 1e36 / oraclePrice)
estimatedRemainingCollateral = max(rawCollateral - estimatedSeizedCollateral, 0)
```

Both collateral values are raw collateral-token units. This estimate is evaluated only after debt and oracle-priced collateral value are both positive. If a positive allowance leaves `estimatedRemainingCollateral < fullCutBelowCollateral`, the nominal root allowance becomes the full debt. A zero allowance is not increased solely because the borrower's existing collateral is below the threshold. This rule applies only to root policy; it does not alter a borrower's personal target. `sliceFloorBps` and `ltvStepBps` cannot exceed 100%, and setting `fullCutBelowCollateral` to zero disables the rule.

> **Example.** A root has debt of 1,000 loan assets at 92% LTV. With `sliceFloorBps = 500` (5%), `sliceFloorAssets = 100`, and `ltvStepBps = 100` (one percentage point), the terms produce 50 from the debt fraction, 100 from the absolute floor, and approximately 120 from the LTV step. The nominal root-policy amount is 120. The supply-share budget and settleable-supply limit can still reduce or reject it.

## Budgeted quotes

Policy decides the nominal settlement amount; the settling supplier decides how many core supply shares it can spend. The controller combines both inputs into one self-consistent quote.

For a positive nominal asset amount, the controller first rounds the amount up into borrow shares. An amount that spans the whole debt is capped at the borrower's exact share balance. When the caller supplies a nonzero `budgetSupplyShares`, the controller also computes the maximum borrow shares that budget can fund:

```text
affordableBorrowShares =
    assets represented by budgetSupplyShares, rounded down,
    converted to borrow shares, rounded down

quotedBorrowShares = min(policyBorrowShares, affordableBorrowShares)
quotedSupplyShares = debt assets represented by quotedBorrowShares, rounded up,
                     converted to supply shares, rounded up
```

Policy allowances are calculated in loan assets, but the asset allowance is not a hard execution cap. The controller converts it to borrow shares and rounds up when needed; the core then values the canceled shares in loan assets. This round trip can make canceled debt larger than the calculated asset allowance. The excess is at most the up-rounded loan-asset value of one raw borrow-share unit. If that share unit is worth more than one raw loan-token unit, the difference can also exceed one raw loan-token unit.

Against the same market snapshot:

```text
canceledDebt - assetAllowance <= ceil((totalBorrowAssets + 1) / (totalBorrowShares + 1e6))
```

Each quote candidate contains:

- the predicted supply-share burn;
- the exact borrow shares to pass to the core; and
- the borrow shares remaining after settlement.

For a candidate with positive borrow shares, zero remaining borrow shares marks a full close. If the policy candidate would close the debt but the supply-share budget cannot fund that result, the quote returns a smaller partial settlement. An unavailable candidate has all three values set to zero.

At the market snapshot used for the quote, the opposing rounding directions guarantee that the core's derived supply burn does not exceed the supplied budget. If the budget funds no borrow share, the quote is empty.

Passing a zero budget asks for the policy quote without budget reduction and is useful for inspection. An executor should quote against its live supply-share budget and revalidate a quote that is not consumed immediately. Zero is a sentinel only at the controller view: a vault request whose pro-rata supply budget rounds to zero reverts before requesting a quote.

The controller exposes two views over this calculation:

- `settlementFor(borrower, budgetSupplyShares)` contains independently budgeted personal and prospective root-policy candidates. They are alternatives, not amounts to add together. The root-policy candidate is executable only if that borrower is still the live root;
- `nextSettlementBorrower(budgetSupplyShares)` returns the live root and whichever of its personal or root-policy allowances is larger, budgeted to the supplied core shares. An empty queue returns the zero address and an empty candidate.

Quotes simulate pending interest at the time of the read. The vault consumes each quote immediately without an intervening market-state change. A quote read for a later direct-core transaction is state-dependent: elapsed interest or another transaction can change debt, supply, the queue root, oracle price, settlement policy, personal target, or the settling position before inclusion.

## Controller execution rules

The hook validates the core's exact borrow-share cancellation and its live converted asset amounts. The table below describes the settlement-policy decision after the core input checks, controller pause check, and borrow-share-rate transition guard. Rows are evaluated from top to bottom.

- `P` is the personal policy allowance in borrow shares before supply-budget reduction.
- `R` is the effective root-policy allowance in borrow shares before supply-budget reduction, or zero when the target borrower is not the live root.
- `C` is the positive number of borrow shares actually canceled by the core.
- `A` is the corresponding debt canceled in loan assets.
- `T` is the settling supplier's live settleable supply in loan assets, as defined below.

| First matching condition | Result |
|---|---|
| The live queue root has bad debt | Revert `SettlementBadDebt` for every settlement target. This check covers only the selected root; it is not a scan of every borrower. |
| `C <= P` | Allow a personal-policy settlement whether or not the borrower is the root. Do not check `T`. |
| The borrower is not the live root | Revert `SettlementExceedsAllowed`. |
| `C > max(P, R)` | Revert `SettlementExceedsAllowed`. |
| `A > T` | Revert `SettlementExceedsSettleableSupply`. |
| Otherwise: the borrower is the root, `P < C <= max(P, R)`, and `A <= T` | Allow a root-policy settlement. |

The policy limits are converted to borrow shares before comparison. If personal and root-policy asset limits round to the same borrow-share amount, the settlement fits the personal limit and the settleable-supply check does not apply.

Settleable supply is:

```text
supplierSupplyAssets  = supplier's live core supply value, rounded down
marketFreeLiquidity   = max(totalSupplyAssets - totalBorrowAssets, 0)
settleableSupplyAssets = max(supplierSupplyAssets - marketFreeLiquidity, 0)
```

This models the supplier withdrawing all available market liquidity first: root policy can convert only the part of that supplier position that would remain. A personal settlement target is the borrower's own authorization and therefore does not use this limit. At the exact boundary, a root-policy settlement equal to the settleable supply succeeds; one raw loan-token unit more reverts. The calculation uses live market totals: a withdrawal or borrow earlier in the same transaction can change the result, and there is no prior-block snapshot or cooldown.

Every successful settlement also passes the [borrow-share-rate guard](market-controller.md#borrow-share-rate-invariant): settlement cannot create a new ceiling breach, but it may reduce debt while cleaning up an existing breach. The controller removes seized collateral from the borrower's activation buckets before the core reduces raw collateral. Freeze, guardian bans, and activation locks do not block settlement because it reduces the position instead of increasing risk. A controller pause blocks it because pause blocks every market hook.

## Vault accounting boundary

`LidoLendERC4626` represents one market supplier position. Vault shares are freely transferable and their asset value is backed only by **managed supply shares**: core supply shares created or consumed by the vault's own deposit, withdrawal, and settlement operations.

Core supply is permissionless and accepts an arbitrary `onBehalf`. Without separate managed accounting, a third party could credit core shares to the vault address without receiving vault shares, changing the wrapper price and settlement budgets. The vault therefore excludes such external credits from `totalAssets` and from both exit budgets. Loan tokens sent directly to the vault are likewise not counted as backing. Neither form of unsolicited value becomes claimable by vault shareholders through the current vault exit functions.

The invariant is:

```text
managedSupplyShares <= actual core supply shares held by the vault
```

For either settlement entrypoint, a request for `requestedVaultShares` receives this core budget:

```text
settlingSupplyShares =
    floor(managedSupplyShares * requestedVaultShares / totalVaultShareSupply)
```

The vault spends only that budget and later removes the consumed core shares from managed accounting.

Both vault exits require nonzero requested shares, a nonzero receiver, and a request no larger than the owner's current vault-share balance. Targeted settlement additionally requires a nonempty borrower list.

## Targeted vault settlement

Targeted settlement is liquidity-neutral: it does not withdraw or reserve free loan assets. The caller supplies an ordered borrower list. For each borrower, the vault asks the controller for the **personal** settlement budgeted to the remaining supply shares and sends the resulting borrow-share amount unchanged to the core. Root policy is reserved for the queue-driven fallback path and cannot be invoked through the caller's list.

Borrowers with no positive personal settlement consume nothing. Iteration stops when the budget is exhausted or the list ends. If no core supply share is consumed across the entire list, the call reverts instead of silently burning nothing.

The receiver gets only seized collateral; the returned loan-asset amount is zero. If settlement consumes the full core budget, the vault burns all requested vault shares. If it consumes only part, the vault burns the same proportion of the request, rounded up so remaining holders are not diluted:

```text
vaultSharesBurned =
    ceil(requestedVaultShares * consumedSupplyShares / settlingSupplyShares)
```

The owner and caller may differ. In that case the caller must have sufficient vault-share allowance for the amount actually burned. Borrowers with empty candidates are skipped. Any later revert—from quoting, the oracle, the controller, the core, a token transfer, or the final allowance check—aborts the batch and rolls back every earlier settlement. A successful call emits one aggregate vault `Settled` event; each core settlement emits a separate borrower-specific `Settle` event.

## Vault fallback exit

Fallback exit combines two payout steps in one transaction. An approved caller may act for `owner`; allowance is spent only for the shares each step actually burns.

### 1. Liquid loan-asset withdrawal

The vault reads how many loan assets its core position can currently withdraw. When that amount is nonzero and the floor-rounded value of the requested vault shares fits, it redeems the whole request. If only part of the owner's position fits, `maxRedeem` converts the available assets to shares and rounds down. Additional shares can have the same floor-rounded asset value, so fallback exit may redeem slightly more shares than `maxRedeem` without withdrawing another raw loan-token unit. Otherwise the vault withdraws the exact available loan-asset amount and forwards it to the receiver.

If the liquid withdrawal covers the whole request, the call returns without settlement and does not read the oracle.

### 2. Queue settlement

For the remaining vault shares, the vault computes the pro-rata managed supply budget and repeatedly requests the live queue root's larger personal-or-root settlement, already reduced to the remaining budget. Each successful core settlement transfers collateral to the same receiver, consumes budget, and updates the root's queue entry before the next iteration. The vault does not search non-root borrowers for personal candidates.

The loop stops when:

- the remaining budget is exhausted;
- the queue produces no executable positive settlement; or
- the caller's iteration bound is reached.

A zero iteration input selects the contract's default bound of 150 settlement attempts. Each root quote consumes one iteration, including a zero candidate that stops the loop. The bound counts attempts, not distinct borrowers: a partial settlement can leave the same borrower at the root for another attempt. Queue or iteration exhaustion returns a partial result when the call has made progress, so a large exit may need repeated calls. A positive root candidate that the core cannot execute is not skipped.

> [!NOTE]
> **Accepted head-of-line rounding boundary.** A positive root quote can still produce zero collateral: canceled debt rounds up, while the collateral seizure is calculated separately and rounds down. `LidoLend.settle()` then reverts before the controller hook, so `fallbackExit` cannot advance to later borrowers.
>
> This concerns a dust-sized settlement cut, not necessarily a dust collateral balance. It is reachable through deliberately tiny debt, a partial-repayment remainder, or budget clipping, but is not expected for normally sized WETH/wstETH settlements. A larger budget can fix budget clipping; otherwise, when repayment is available, repaying the root's exact remaining borrow shares removes it from the queue. There is no automatic skip path.

The vault burns shares for the liquid withdrawal plus the pro-rata shares covered by settlement. If neither step burns any share, the call reverts.

Any later revert in fallback exit rolls back the complete transaction, including the earlier liquid withdrawal and successful settlement iterations. Queue exhaustion or the effective iteration bound may return a partial result, but an oracle, controller, core, token-transfer, or allowance failure does not.

The return value `sharesBurned` covers both steps. The `FallbackExit` event is emitted only when the call reaches queue settlement, and its `sharesBurned` field covers that step alone. The standard ERC-4626 `Withdraw` event describes the liquid withdrawal. Each core settlement emits a borrower-specific `Settle` event, which is required to attribute an aggregate multi-borrower exit.

At the specific final boundary where the vault is the only supplier, `totalSupplyAssets == totalBorrowAssets`, and fallback exit consumes the vault's full managed supply budget, Morpho's virtual shares can leave zero-value core supply shares and residual total borrow assets. The lender can still burn all vault shares and exit because the residual does not represent a remaining lender claim. Its raw size depends on the live share price; there is no universal one-raw-unit bound.

## Related references

- [Architecture](architecture.md) — system topology and runtime boundaries.
- [Market controller](market-controller.md) — hook lifecycle, collateral activation, freeze/pause, and share-rate guard.
- [LidoLendERC4626 API](api/lido-lend-erc4626.md) — generated vault surface.
- [LidoLendMarketController API](api/lido-lend-market-controller.md) — generated queue, quote, and policy surface.
- [Lido Lend core specification](https://github.com/lidofinance/lido-lend/blob/main/SPECIFICATION.md) — canonical core accounting and trust assumptions.
