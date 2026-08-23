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
| Oracle price | The conversion rate from collateral-token raw units to loan-token raw units, scaled by `1e36` and adjusted for the two tokens' decimals. |
| LTV | Debt divided by oracle-valued collateral. The controller rounds debt up and collateral value down before comparing them. |
| LLTV | The market's liquidation loan-to-value threshold. A position becomes liquidatable when its debt exceeds its LLTV-adjusted collateral value. |
| Supply-share budget | The maximum core supply shares that one quote may consume. |

## Setup and authorization

Settlement must have been enabled when the market was created; that choice cannot be changed later. The direct path requires the caller to own or be authorized over the core supplier position. Vault paths instead require ownership or allowance over vault shares. These permissions are independent: neither grants the other. The receiver may differ from the position owner.

## Core settlement boundary

The controller quotes an exact borrow-share amount because that is the core settlement input. From the live totals after interest accrual, the core derives the debt cancellation, supply-share burn, and collateral payout. The exact formulas, rounding, checks, state transition, and debt-clearing boundaries are defined in the [LidoLend core specification](https://github.com/lidofinance/lido-lend/blob/main/SPECIFICATION.md#settlement).

Before applying the settlement, the core sends the resolved amounts to the controller. The controller may allow or reject the settlement, but it cannot change those amounts. The core does not check borrower health; the queue and settlement policies below provide that additional policy layer.

## Risk queue and bad-debt gate

The queue selects one borrower for automatic settlement during a lender exit. This borrower is the queue root.

During normal operation, every borrower with debt stays in the queue until that debt is cleared. A collateral withdrawal cannot take the last collateral from a position with debt. A settlement of a solvent position cannot exhaust its collateral while leaving debt, and liquidation clears the remaining debt when it exhausts collateral. The queue can therefore remove an entry when either balance reaches zero.

A max-heap is a queue whose first item has the largest key. The ordering key is:

```text
riskKey = borrowShares * 1e18 / rawCollateral
```

`rawCollateral` is the collateral-token balance before oracle conversion, and the integer division rounds down. Within one market, every borrower uses the same borrow-share rate and collateral price, so the unrounded ratio is monotonic in LTV. The stored key is a rounded risk estimate, not an exact onchain LTV. The heap root has the largest stored key. Different exact ratios can have the same key, and borrowers with equal keys are not ordered by exact LTV. The core calls the controller before applying each position change; the controller projects the resulting position and updates or removes that borrower's queue entry.

Before authorizing any settlement, the controller checks the tracked root for bad debt. If that root's debt value exceeds its collateral value, every settlement path reverts until the root becomes solvent or its debt is cleared. Checking one borrower keeps the cost independent of queue length, but it does not prove that every other borrower is solvent.

> [!WARNING]
> **A rounded root check can miss an insolvent borrower.** Two borrowers can have the same rounded `riskKey` even when the non-root borrower's unrounded share-to-collateral ratio is higher. The heap may then keep the other borrower at the root. Near the insolvency boundary, the root can pass the bad-debt test while the tied non-root borrower is already insolvent.
>
> This does not change the missed position by itself. To create zero-collateral debt, the borrower must also have enabled personal settlement. A caller must then select a partial cut whose rounded collateral payout equals the borrower's full collateral balance while borrow shares remain.
>
> The controller then removes the zero-collateral borrower from the queue, while the core keeps the remaining debt shares. If that debt is later written off, the remaining suppliers take the loss. The remaining debt can be much larger than one raw loan-token unit.
>
> Positions become liquidatable before insolvency, and normal operation assumes that liquidators act in that window. This path also requires the exact `riskKey` tie, personal opt-in, and a partial cut that takes all collateral while leaving debt. Under that assumption, the combination is expected to be extremely rare, although the contracts allow it.

> [!WARNING]
> **Liquidation-loss boundary.** The bad-debt check compares debt with 100% of collateral value and does not account for the liquidation incentive factor (`LIF`). Ignoring raw-unit rounding, a root with `1 / LIF < LTV <= 100%` passes the settlement gate even though a collateral-exhausting liquidation would write unpaid debt off against suppliers.
>
> The design assumes liquidators act once `LTV > LLTV`, before a position reaches this range. The contracts do not enforce that timing.

## Two settlement policies

A borrower enables personal settlement by selecting a target LTV. Root policy requires no borrower action and allows the current queue root to be settled during a lender exit. Both policies calculate a loan-asset allowance, cap it by the borrower's debt, and convert it to the borrow-share limit enforced at execution. Both candidates are empty when debt or oracle-valued collateral is zero.

### Personal settlement target

A borrower may select a target post-settlement LTV below 100%. A zero target disables the personal policy. When the position is above a positive target, the nominal loan-asset amount is:

```text
personalSliceAssets =
    (debtAssets * 1e18 - targetLtv * collateralValue)
    / (1e18 - targetLtv)
```

Here `debtAssets` is the borrower's share debt rounded up, while `collateralValue` prices its entire raw collateral balance rounded down. All raw collateral counts, including collateral that is not yet active for borrowing under the [activation rules](market-controller.md#collateral-activation). The final division rounds down.

The result is zero when debt or priced collateral value is zero, no target is set, or the current LTV is already at or below the target. A positive allowance lets any properly authorized supplier target the borrower, regardless of queue position or free liquidity. The borrower selects only the target LTV, not the supplier or receiver.

A cut within the personal allowance is treated as personal even when the borrower is the current root. The root-only rule that promotes a small collateral remainder to a full close and the settleable-supply limit do not apply, even when settleable supply is zero. A larger cut is treated as root policy and must pass every root-policy check.

Only the borrower can change the target. Closing the position does not clear it: the target applies to future debt until the borrower sets it to zero.

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

### Seizure floor

The core prices the collateral seizure off the canceled debt rounded **down**, then divides by the oracle price and rounds down again:

```text
cutAssets        = assets represented by quotedBorrowShares, rounded down
seizedCollateral = floor(cutAssets * 1e36 / oraclePrice)
```

`LidoLend.settle()` rejects a cut whose `seizedCollateral` is zero, so above parity — `oraclePrice > 1e36`, as for wstETH collateral against WETH — the smallest executable cut is `ceil(oraclePrice / 1e36)` loan assets rather than one. The controller applies the same calculation to the quoted borrow shares and reports a cut that buys no whole collateral unit as an unavailable candidate, so a quote handed to the core is never rejected for seizing nothing. A market whose oracle reports a zero price quotes nothing for the same reason.

The floor binds on whichever input drives the amount down: a policy allowance of a few loan-asset units, or a supply-share budget shrunk onto that range. Because it is reported as budget exhaustion rather than an error, an executor sees the documented stop condition — `settle` reverts `NothingSettled` when the whole list yields nothing, and `fallbackExit` partial-fills on its liquid leg.

Passing a zero budget asks for the policy quote without budget reduction and is useful for inspection. An executor should quote against its live supply-share budget and revalidate a quote that is not consumed immediately. Zero is a sentinel only at the controller view: a vault request whose pro-rata supply budget rounds to zero reverts before requesting a quote.

The controller exposes two views over this calculation:

- [`settlementFor`](api/lido-lend-market-controller.md#settlementfor) contains independently budgeted personal and prospective root-policy candidates. They are alternatives, not amounts to add together. The root-policy candidate is executable only if that borrower is still the live root;
- [`nextSettlementBorrower`](api/lido-lend-market-controller.md#nextsettlementborrower) returns the live root and whichever of its personal or root-policy allowances is larger, budgeted to the supplied core shares. An empty queue returns the zero address and an empty candidate.

Quotes simulate pending interest at the time of the read. The vault consumes each quote immediately without an intervening market-state change. A quote read for a later direct-core transaction is state-dependent: elapsed interest or another transaction can change debt, supply, the queue root, oracle price, settlement policy, personal target, or the settling position before inclusion.

## Controller execution rules

The hook validates the core's exact borrow-share cancellation and its live converted asset amounts. The table below describes the settlement-policy decision after the core input checks, controller pause check, and borrow-share-rate transition guard. Rows are evaluated from top to bottom.

The core prices the collateral before calling the hook. The controller reads the oracle again to evaluate queue health and policy limits. Its decision assumes that these reads, and any earlier vault quote in the same transaction, return the same price.

Settleable supply is:

```text
supplierSupplyAssets   = supplier's live core supply value, rounded down
marketFreeLiquidity    = max(totalSupplyAssets - totalBorrowAssets, 0)
settleableSupplyAssets = max(supplierSupplyAssets - marketFreeLiquidity, 0)
```

This models the supplier withdrawing all available market liquidity first: root policy can convert only the part of that supplier position that would remain. Personal policy is the borrower's own authorization and does not use this limit. The calculation uses live market totals, so an earlier withdrawal or borrow in the same transaction can change it.

- `P` is the personal policy allowance in borrow shares before supply-budget reduction.
- `R` is the effective root-policy allowance in borrow shares before supply-budget reduction, or zero when the target borrower is not the live root.
- `C` is the positive number of borrow shares actually canceled by the core.
- `A` is the corresponding debt canceled in loan assets.
- `T` is the settling supplier's live settleable supply in loan assets.

| First matching condition | Result |
|---|---|
| The live queue root has bad debt | Reject every settlement target. |
| `C <= P` | Allow a personal-policy settlement whether or not the borrower is the root. Do not check `T`. |
| The borrower is not the live root | Reject the settlement. |
| `C > max(P, R)` | Reject the settlement. |
| `A > T` | Reject the settlement. |
| Otherwise: the borrower is the root, `P < C <= max(P, R)`, and `A <= T` | Allow a root-policy settlement. |

The table classifies the whole cut; it never splits one settlement between the two policies. If `C <= P`, the cut is personal and `T` is ignored. Otherwise the borrower must be the root, the cut must fit the root allowance, and the entire canceled asset amount must fit `T`. When market free liquidity is zero, `T` equals the supplier's full live supply value.

The policy limits are converted to borrow shares before comparison. If the personal and root-policy asset limits round to the same borrow-share amount, the cut is personal.

At the exact boundary, a root-policy settlement equal to the settleable supply succeeds; one raw loan-token unit more is rejected. There is no prior-block snapshot or cooldown.

Every successful settlement also passes the [borrow-share-rate guard](market-controller.md#borrow-share-rate-transition-guard): settlement cannot create a new ceiling breach, but it may reduce debt while cleaning up an existing breach. The controller removes seized collateral from the borrower's activation buckets before the core reduces raw collateral. Freeze, guardian bans, and activation locks do not block settlement because it reduces the position instead of increasing risk. A controller pause blocks it because pause blocks every market hook.

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

Targeted settlement does not withdraw or reserve existing loan-token liquidity. The caller supplies an ordered borrower list. For each borrower, the vault asks the controller for the **personal** settlement budgeted to the remaining supply shares and sends the resulting borrow-share amount unchanged to the core. Root policy is reserved for the queue-driven fallback path and cannot be invoked through the caller's list.

Borrowers with no positive personal settlement consume nothing — including one whose remaining budget only funds a cut under the [seizure floor](#seizure-floor). Iteration stops when the budget is exhausted or the list ends. If no core supply share is consumed across the entire list, the call reverts instead of silently burning nothing.

The receiver gets only seized collateral; the returned loan-asset amount is zero. If settlement consumes the full core budget, the vault burns all requested vault shares. If it consumes only part, the vault burns the same proportion of the request, rounded up so remaining holders are not diluted:

```text
vaultSharesBurned =
    ceil(requestedVaultShares * consumedSupplyShares / settlingSupplyShares)
```

The owner and caller may differ. In that case the caller must have sufficient vault-share allowance for the amount actually burned. An attempted settlement that reverts is not skipped. A successful call emits one aggregate vault `Settled` event; each core settlement emits a separate borrower-specific `Settle` event.

## Vault fallback exit

Fallback exit combines two payout steps in one transaction. An approved caller may act for `owner`; allowance is spent only for the shares each step actually burns.

### 1. Liquid loan-asset withdrawal

The vault reads how many loan assets its core position can currently withdraw. When that amount is nonzero and the floor-rounded value of the requested vault shares fits, it redeems the whole request. If only part of the owner's position fits, `maxRedeem` converts the available assets to shares and rounds down. Additional shares can have the same floor-rounded asset value, so fallback exit may redeem slightly more shares than `maxRedeem` without withdrawing another raw loan-token unit. Otherwise the vault withdraws the exact available loan-asset amount and forwards it to the receiver.

If the liquid withdrawal covers the whole request, the call returns without settlement and does not read the oracle.

### 2. Queue settlement

For the remaining vault shares, the vault computes the pro-rata managed supply budget and repeatedly requests the live queue root's larger personal-or-root settlement, already reduced to the remaining budget. Each successful core settlement transfers collateral to the same receiver, consumes budget, and updates the root's queue entry before the next iteration. The vault does not search non-root borrowers for personal candidates.

The loop stops when:

- the remaining budget is exhausted;
- the queue produces no executable positive settlement, including a root cut under the [seizure floor](#seizure-floor); or
- the caller's iteration bound is reached.

A zero iteration input selects the contract's default bound of 150 settlement attempts. Each root quote consumes one iteration, including a zero candidate that stops the loop. The bound counts attempts, not distinct borrowers: a partial settlement can leave the same borrower at the root for another attempt. Queue or iteration exhaustion returns a partial result when the call has made progress, so a large exit may need repeated calls. A root candidate the controller still quotes but the core rejects is not skipped; it reverts the call.

> [!NOTE]
> **Head-of-line rounding boundary.** A root whose executable cut falls under the [seizure floor](#seizure-floor) quotes nothing, so the loop stops on it rather than advancing to later borrowers. This depends on the settlement amount, not the borrower's collateral balance: tiny debt, a partial-repayment remainder, or a supply budget shrunk onto the floor can all produce it, and above parity the floor is more than one loan-asset unit.
>
> A call that has already made progress — a liquid leg, or earlier successful cuts — keeps that progress and returns a partial result. A call that reaches settlement with nothing settled reverts. The operational mitigation is to repay the root's exact remaining borrow shares on its behalf; once that succeeds, `fallbackExit` advances past it.

The vault burns shares for the liquid withdrawal plus the pro-rata shares covered by settlement. If neither step burns any share, the call reverts.

The return value `sharesBurned` covers both steps. The `FallbackExit` event is emitted only when the call reaches queue settlement, and its `sharesBurned` field covers that step alone. The standard ERC-4626 `Withdraw` event describes the liquid withdrawal. Each core settlement emits a borrower-specific `Settle` event, which is required to attribute an aggregate multi-borrower exit.

> [!NOTE]
> **Final virtual-share boundary.** At the specific final boundary where the vault is the only supplier, `totalSupplyAssets == totalBorrowAssets`, and fallback exit consumes the vault's full managed supply budget, Morpho's virtual shares can leave zero-value core supply shares and residual total borrow assets. The lender can still burn all vault shares and exit because the residual does not represent a remaining lender claim. Its raw size depends on the live share price; there is no universal one-raw-unit bound.

## Related references

- [Architecture](architecture.md) — system topology and runtime boundaries.
- [Market controller](market-controller.md) — hook lifecycle, collateral activation, freeze/pause, and share-rate guard.
- [LidoLendERC4626 API](api/lido-lend-erc4626.md) — generated vault surface.
- [LidoLendMarketController API](api/lido-lend-market-controller.md) — generated queue, quote, and policy surface.
- [Lido Lend core specification](https://github.com/lidofinance/lido-lend/blob/main/SPECIFICATION.md#settlement) — canonical core settlement accounting and trust assumptions.
