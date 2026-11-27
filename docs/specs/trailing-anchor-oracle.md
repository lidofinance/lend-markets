# Trailing Anchor Oracle

The Trailing Anchor Oracle prices a market's collateral from a single price source and protects the market from a faulty or compromised value of that source. It returns the current price only near a stored **anchor** that trails the source, and a larger move becomes the price only after it has been public for a delay:

- `price()` returns the source's current price only while it is within the **bounds**, a narrow range around the anchor. Otherwise, or while the manager has suspended pricing, it reverts, and the market actions that need a price stop.
- Anyone can call `updateAnchor()`, and a bot calls it periodically. While the price is within the bounds, the update moves the anchor toward it at no more than continuous **rates**: a **drift**.
- An update records a price outside the bounds as a **pending anchor**. If the price stays outside for `reanchorDelay`, a later update moves the anchor toward it: a **re-anchor**. Until then `price()` reverts, which gives the markets time to stop before the move becomes their price.
- The **floor** and the **ceiling**, the two lines, limit how far a wrong source can move the anchor. No update takes it below the floor, `maxAnchorBelowBase` under `basePrice`, and no re-anchor takes it above the ceiling, `maxAnchorAboveBase` over that price. `basePrice` is the first anchor or the last accepted price, and only drifts raise it. It is not a high-water mark: a re-anchor up can leave the anchor above it, up to the ceiling.
- Past these lines, or before the delay, the anchor moves only by the price acceptor's `acceptPrice`, which sets it to the current price. The manager can instead widen the bounds, which lets the price through without moving the anchor, or the lines, which a re-anchor reaches only after a new delay.

Two things it does not stop. A wrong value within the bounds is returned at once. A wrong value that rises slowly, inside the bounds at every update, drags the anchor up at the rise rate, and the price with it; only monitoring catches that. [What a faulty source can do](#what-a-faulty-source-can-do) gives how far each can go.

```mermaid
flowchart LR
    S["Source"] -->|current price| O["Oracle<br/>anchor, bounds,<br/>pending anchor,<br/>floor, ceiling"]
    K["Anyone, a keeper"] -->|updateAnchor| O
    A["Price acceptor"] -->|acceptPrice| O
    G["Manager"] -->|"setParameters<br/>setPricingResumesAt"| O
    X["Proxy admin"] -->|upgrade| O
    O -->|"price(): the current price within the bounds, or a revert"| M["Markets<br/>core and controller"]
```

## Scope

In scope are `TrailingAnchorOracleBase`, which holds the rules and implements the core's `IOracle`, and its three adapters, which supply the current price: `UsdyNavOracle` reads USDY's redemption value from Ondo's USDY oracle, `CentrifugeNavOracle` a share class's price from its Centrifuge vault, and `ChainlinkOracle` a price from a feed with Chainlink's aggregator interface ([Adapters](#adapters)).

Out of scope: who holds the roles, in [Privileged Roles](roles.md), and the markets' freeze and pause, in [Market controller](market-controller.md).

## How it works

### Bounds around the anchor

```text
lowerBound = floor(anchorPrice × (1e18 − maxPriceBelowAnchor) / 1e18)
upperBound = floor(anchorPrice × (1e18 + maxPriceAboveAnchor) / 1e18)
```

Inside them, edges included, `price()` returns the current price. Outside them it reverts until the source comes back, the anchor moves or the manager widens the bounds.

### How the anchor moves

| Current price `P` | What happens to the anchor | Limit |
|---|---|---|
| within the bounds | an update moves it toward `P`: a **drift** | `maxAnchorContinuousRiseRate` up and `maxAnchorContinuousFallRate` down, each compounded continuously, counted since the anchor was last set; down not below the floor |
| outside the bounds | an update records `P` as the pending anchor; later updates hold it while `P` stays outside on its side | — |
| outside, on the pending anchor's side, from `reanchorDelay` after it was recorded until `reanchorWindow` later | an update moves it onto the pending anchor or `P`, whichever is nearer: a **re-anchor** | the delay; down not below the floor, up not above the ceiling |
| anywhere | the price acceptor moves it onto `P` with `acceptPrice` | the range the acceptor passes; the floor and the ceiling restart there |

### The floor and the ceiling

`basePrice`, here `H`, is the anchor `initialize` seeded or the last accepted price. Between acceptances only a drift up raises it: onto the new anchor when that passes `H`, or by the drift's step while the anchor already sits above `H`. A re-anchor never moves it, and it never falls by itself. The floor and the ceiling hang off it:

```text
floorPrice   = H − floor(H × maxAnchorBelowBase / 1e18)
ceilingPrice = H + floor(H × maxAnchorAboveBase / 1e18)
```

The floor binds on the way down, once an update would take the anchor more than `maxAnchorBelowBase` below `H`. The ceiling binds on the way up, once a re-anchor would take it more than `maxAnchorAboveBase` above `H`; a drift is not held by it, since a drift raises `H` as it goes. Because re-anchors do not move `H`, each line caps the total of all re-anchors on its side, not each one. Were a re-anchor to raise `H`, each one the ceiling stopped would lift the ceiling by `maxAnchorAboveBase`, and a source held above the bounds would climb by as much every delay.

A line's bounds are the bounds around an anchor that sits on it. From `A` = `H` = 100, in % of the seed, with a floor 1% under `H`, a ceiling 0.2% over it, bounds of +0.05% and −0.1% and rates of 0.06 up and 0.01 down, the floor is 99 with bounds from 98.901 to 99.0495, and the ceiling is 100.2 with bounds from 100.0998 to 100.2501:

| Change of the source | Anchor after it |
|---|---|
| a 0.1% rise that stays past the delay | 100.1, as without the ceiling; `H` stays 100 |
| a rise within the bounds at up to 6.18% a year | follows by drift, with `H`, the floor and the ceiling |
| a fall within the bounds at 0.995% a year | follows by drift for about a year, to 99, where it stays |
| growth to 104 by drift, then a fall to 100 | 102.96, the floor under `H` = 104 |

### Examples

The examples use illustrative values, not any market's: bounds of +0.05% and −0.1%, rates of 0.06 up and 0.01 down, a floor 1% under `H`, a ceiling 0.2% over it, a 6-hour delay and a 1-day window. A keeper calls `updateAnchor()` every hour, and prices are in % of the seed. The charts plot the oracle's state after each hour's update.

**Example 1: a real fall within the floor lands after one delay.** The source falls 0.5% at 1h. The update at 1h records it as the pending anchor, the updates from 2h to 6h hold it, and the update at 7h moves the anchor onto it. `price()` reverts from 1h to 7h.

![Example 1: the source steps from 100 to 99.5 at 1h; the anchor stays at 100 until 7h and then steps onto 99.5; price() reverts from 1h to 7h; the floor stays at 99.](img/trailing-anchor-oracle/real-fall.svg)

**Example 2: a wrong value that clears up within the delay never becomes the price.** The source jumps 0.6% at 1h and comes back at 3h. The update at 3h finds it within the bounds and drops the pending anchor. Had it stayed past the delay, it would have moved the anchor only onto the ceiling, as in example 5.

![Example 2: the source jumps from 100 to 100.6 at 1h, above the ceiling at 100.2, and returns to 100 at 3h; the anchor stays at 100; price() reverts from 1h to 3h.](img/trailing-anchor-oracle/passing-value.svg)

**Example 3: a walk down stops at the floor.** The source steps down by 0.2 every 8 hours from 2h. Each step lands after a delay until the anchor reaches the floor, 99, at 40h. The step at 42h takes the source below the floor's bounds: once its delay passes, the updates leave the anchor on the floor, and `price()` reverts until the source returns or the price acceptor or the manager acts.

![Example 3: the source steps down by 0.2 every 8 hours from 2h; the anchor follows each step 6 hours later until it reaches the floor, 99, at 40h, and stays there while the source goes on to 98.6; price() reverts during each delay and from 42h on.](img/trailing-anchor-oracle/floor-walk.svg)

**Example 4: a deep wrong fall stops at the floor, and the price comes back with the source.** The source falls 2% at 1h. At 7h the re-anchor goes only onto the floor and records the price again, and from 13h the updates change nothing. At 20h the source comes back to 100, above the floor's bounds: the update records it on the other side, and the re-anchor at 26h makes it the price. Had the fall been real, `acceptPrice` would have priced it with no delay in the contract.

![Example 4: the source falls from 100 to 98 at 1h; the anchor stays at 100 until 7h and then steps onto the floor, 99; the source returns to 100 at 20h and the anchor follows at 26h; price() reverts from 1h to 26h.](img/trailing-anchor-oracle/deep-fall.svg)

**Example 5: a wrong jump up stops at the ceiling, and the price comes back with the source.** Example 4 mirrored: the source jumps 1% at 1h, the re-anchor at 7h goes only onto the ceiling, 100.2, and the source's return at 20h lands at 26h.

![Example 5: the source jumps from 100 to 101 at 1h; the anchor stays at 100 until 7h and then steps onto the ceiling, 100.2; the source returns to 100 at 20h and the anchor follows at 26h; price() reverts from 1h to 26h.](img/trailing-anchor-oracle/wrong-jump.svg)

## Parameters

| Parameter | Type | Allowed values | Purpose |
|---|---|---|---|
| `maxPriceAboveAnchor` | `uint64`, WAD fraction | `0 < x < 1e18` | upper bound above the anchor |
| `maxPriceBelowAnchor` | `uint64`, WAD fraction | `0 < x < 1e18` | lower bound below the anchor |
| `maxAnchorContinuousRiseRate` | `uint64`, WAD continuous rate a year | `0 ≤ x ≤ 1e18` | how fast a drift may raise the anchor; zero stops it. In a year the anchor rises at most `e^x − 1`: 6.18% at `0.06e18`, for any schedule of updates; how far it actually moves depends on the schedule |
| `maxAnchorContinuousFallRate` | `uint64`, WAD continuous rate a year | `0 ≤ x ≤ 1e18` | how fast a drift may lower the anchor; zero stops it. In a year the anchor falls at most `1 − e^(−x)`: 0.995% at `0.01e18`, for any schedule of updates; how far it actually moves depends on the schedule |
| `maxAnchorBelowBase` | `uint64`, WAD fraction | `0 ≤ x < 1e18` | how far below `basePrice` updates may take the anchor; zero stops every update from lowering it below that |
| `maxAnchorAboveBase` | `uint64`, WAD fraction | `0 ≤ x < 1e18` | how far above `basePrice` a re-anchor may take the anchor; zero stops every re-anchor from raising it above that |
| `reanchorDelay` | `uint40`, seconds | `x ≥ MIN_REANCHOR_DELAY` (1 hour), `e^(maxAnchorContinuousRiseRate × x / (1e18 × 365 days)) − 1 ≤ maxPriceAboveAnchor / 1e18` and `1 − e^(−maxAnchorContinuousFallRate × x / (1e18 × 365 days)) ≤ maxPriceBelowAnchor / 1e18` | how long a pending anchor waits before a re-anchor |
| `reanchorWindow` | `uint40`, seconds | `x ≥ MIN_REANCHOR_WINDOW` (1 hour) | how long after the delay a re-anchor may come before the pending anchor expires |

The contract does not check the [sizing rule](#choosing-values), because it does not know the LLTV of the markets that read it. The deployment preflight checks the rule at the LLTV of the market, and the acceptance suite makes the same check on the live deployment. The manager must keep the rule in each later `setParameters` call. No contract makes this check, so a too-wide corridor from a `setParameters` call stays until the manager corrects it.

Every `e^y − 1` in the contract is the sum of the first three Taylor terms, `y + y²/2 + y³/6`, each rounded down. This sum is never more than `e^y − 1`. Every `1 − e^(−y)` is `c / (1 + c)`, rounded down, where `c` is that sum for `y`. This value is never more than `1 − e^(−y)`.

## Price check

`price()` applies these steps in order and reverts at the first one that fails:

1. **Suspension.** It reverts with `PricingSuspended(pricingResumesAt)` while `block.timestamp < pricingResumesAt`, without reading the source.
2. **Source read.** A revert in the source propagates unchanged. An adapter can add its own reverts to the read: `CentrifugeNavOracle` reverts with `StalePrice` or `PriceFromFuture`, and `ChainlinkOracle` also with `NegativePrice`.
3. **Zero.** It reverts with `ZeroPrice` on a zero current price.
4. **Bounds.** It reverts with `PriceOutOfBounds(currentPrice, lowerBound, upperBound)` outside the bounds.
5. **Result.** It returns `currentPrice × PRICE_SCALE` ([Units and scaling](#units-and-scaling)); only a current price above `type(uint256).max / PRICE_SCALE` overflows here.

`price()` never reads the pending anchor, the floor or the ceiling: they act only through the anchor that updates set.

## Anchor updates

`updateAnchor()` runs in any block, also while `price()` reverts or pricing is suspended. It reverts only when the source read reverts or returns zero, or when it must store a price above the `uint104` maximum. That maximum is about 2.03e13 whole units at 18 decimals. Otherwise it takes the first case that applies, returns its `UpdateOutcome`, and emits `AnchorUpdated(outcome, currentPrice)` after the events of the state it changed:

```mermaid
flowchart LR
    B{"P within<br/>the bounds?"} -- yes --> WB(["WithinBounds<br/>drift"])
    B -- no --> HD{"pending anchor<br/>held?"}
    HD -- no --> PR(["PendingAnchorRecorded<br/>record P"])
    HD -- yes --> T{"delay<br/>passed?"}
    T -- no --> PH(["PendingAnchorHeld"])
    T -- yes --> F{"target equals<br/>the anchor?"}
    F -- yes --> AF(["AnchorOnFloor<br/>AnchorOnCeiling"])
    F -- no --> PA(["PendingAnchorApplied<br/>re-anchor"])
```

The re-anchor's target equals the anchor only when the anchor sits on or past the line it moves toward: `AnchorOnFloor` for a pending anchor below, `AnchorOnCeiling` for one above.

### Pending anchor lifecycle

```mermaid
stateDiagram-v2
    direction LR
    state "No pending anchor" as None
    state "Waiting out reanchorDelay" as Waiting
    state "Open for reanchorWindow" as Open
    [*] --> None
    None --> Waiting: price outside
    Waiting --> None: price within
    Waiting --> Open: delay passes
    Open --> None: price within, before or after a re-anchor
    Open --> Waiting: re-anchor, price still outside
    Open --> Expired: window passes
    Expired --> None: price within
    Expired --> Waiting: price outside
```

Each arrow is an update or the time passing. "Price within" and "price outside" are what an update reads, against the new bounds after a re-anchor. A price outside on the other side of the anchor replaces the pending anchor and restarts the wait. In the open state with the anchor on or past its line, an update moves nothing, and the pending anchor stays until the window passes.

### Rules

With `A` the anchor price and `H` = `basePrice`, no update sets the anchor below `low`, and no re-anchor sets it above `high`:

```text
low  = min(floorPrice, A)
high = max(ceilingPrice, A)
```

The `min` and the `max` keep each line from moving an anchor already past it, as after the manager narrows `maxAnchorBelowBase` or `maxAnchorAboveBase`. A drift up from `A` to `A′` sets `H = max(H, A′ − max(A − H, 0))`. Besides drifts only `initialize` and `acceptPrice` change `H`.

**Drift.** With `t = block.timestamp − anchorAt`:

```text
reachLow       = max(A − floor(A × (1 − e^(−maxAnchorContinuousFallRate × t / (1e18 × 365 days)))), low)
reachHigh      = A + floor(A × (e^(maxAnchorContinuousRiseRate × t / (1e18 × 365 days)) − 1))
newAnchorPrice = min(max(P, reachLow), reachHigh)
```

It writes the anchor, with `AnchorSet(newAnchorPrice, block.timestamp, false)`, only when the value changes, and emits `PendingAnchorCleared` only when it drops a pending anchor. The outcome is `WithinBounds` either way.

**Hold.** A pending anchor is held while `pendingAnchorAt ≠ 0`, `block.timestamp ≤ pendingAnchorAt + reanchorDelay + reanchorWindow`, and `P` sits on its side of the anchor: above it for a pending anchor above, below it for one below.

**Re-anchor.** The target:

```text
target = min(pendingAnchorPrice, P, high)   for a pending anchor above A
target = max(pendingAnchorPrice, P, low)    for a pending anchor below A
```

When the target equals `A`, nothing changes. Otherwise the anchor moves onto the target with `AnchorSet`. The pending anchor is then dropped when `P` is within the new bounds, or replaced by `P` with `PendingAnchorSet` when it is not, so a move that goes on waits another delay.

**Record.** The current price becomes the pending anchor, `pendingAnchorPrice = P` and `pendingAnchorAt = block.timestamp`, with `PendingAnchorSet`. This replaces an expired pending anchor or one on the other side.

What follows:

- A drift counts the time since the anchor was last set, and nothing compounds within one block. The rise is compounded continuously, so the update schedule changes the largest rise in a given time only by rounding and by the three-term sum. At a rate of 0.06, one update after a year gives 6.1836%, and frequent updates give up to 6.18365%. The fall is compounded continuously in the same way. At a rate of 0.01, one update after a year and frequent updates both give a fall of 0.995%. A drift that stops at the price still sets the anchor, so the unused rise or fall is lost, and where the anchor stands depends on when updates run. It moves toward a price within the bounds, so a long rest builds a reach of at most one bound.
- The hold is sampled only when an update runs. A price that clears up and returns to the same side between two updates keeps the pending anchor, and one that leaves the bounds and comes back between them leaves no trace.

## Setup and privileged actions

`initialize(admin, parameters, minPrice, maxPrice)` stores the parameters as `setParameters` does, seeds the anchor and `basePrice` from the current price with `AnchorSet(price, block.timestamp, true)`, and grants `DEFAULT_ADMIN_ROLE` to `admin`. It reverts with `UnexpectedPrice(currentPrice, minPrice, maxPrice)` when the current price is outside `[minPrice, maxPrice]`, as `acceptPrice` does. Thus, a wrong source value at deployment causes a revert. No action writes a zero anchor, and no caller chooses the price: each reads the source.

**`acceptPrice(minPrice, maxPrice)`**, for `PRICE_ACCEPTOR_ROLE`, moves the anchor onto the current price at any distance, past the floor or the ceiling included. It sets `basePrice` to that price, drops the pending anchor and emits `AnchorSet(price, block.timestamp, true)`.

- It reverts with `UnexpectedPrice(currentPrice, minPrice, maxPrice)` when the current price is outside `[minPrice, maxPrice]`, so a price that moved after the acceptor's check is refused. The range is its only binding: it has no deadline.
- A reverting source makes it revert with the source's error, and a zero current price with `ZeroPrice`, inside the range or outside it.

**`setParameters(parameters)`**, for `MANAGER_ROLE`, sets all eight parameters at once and drops the pending anchor, which restarts the delay of a waiting move even with unchanged values. The anchor and `basePrice` stay. It reverts, as `initialize` does, when a value is outside its range in [Parameters](#parameters). Each check has its own error, which carries the values that failed it. Each change applies in the same transaction:

- a tighter bound can make `price()` revert at once, and a wider one let a price through with no pending anchor;
- a new rate applies to the time since the anchor was last set, so a higher one lets the next drift go further, up to one bound;
- a wider `maxAnchorBelowBase` lowers the floor for the next update, and a narrower one leaves an anchor already below the new floor where it is;
- a wider `maxAnchorAboveBase` raises the ceiling for the next re-anchor, and a narrower one leaves an anchor already above the new ceiling where it is.

**`setPricingResumesAt(resumesAt)`**, for `MANAGER_ROLE`, makes `price()` revert until `resumesAt`. It reverts with `InvalidPricingResumesAt(resumesAt)` when that is more than `MAX_PRICING_SUSPENSION` (7 days) after the call. A time not in the future lifts the suspension, and each call overwrites the last, so repeated calls can keep pricing suspended. Updates and acceptances run during a suspension, so the anchor at its end may differ from the one at its start.

## What a faulty source can do

The limits below hold while the parameters stay as they were at the last seed or acceptance.

Between re-anchors, the price `price()` returns stays within these limits, up to a wei of rounding, for a time `T` after the last seed, acceptance or re-anchor set `anchor0`:

```text
currentPrice ≤ anchor0 × (1 + maxPriceAboveAnchor / 1e18) × e^(maxAnchorContinuousRiseRate × T / (1e18 × 365 days))
currentPrice ≥ anchor0 × (1 − maxPriceBelowAnchor / 1e18) × e^(−maxAnchorContinuousFallRate × T / (1e18 × 365 days))
```

Each limit is the bound times its rate compounded continuously, for any schedule of updates. At the examples' values, a source can keep to the edge of the bounds. It then moves the price by at most +0.54% or −0.18% in 30 days, and +6.24% or −1.09% in a year. Upward that is a creep no update stops. Over a flat real price at a 98% LLTV, it reaches 1.43% in about 83 days, where a position borrowed at LLTV at the inflated price can be liquidated only at a loss to suppliers, and 2.04% in about 120, where that position is insolvent at the real price. Over an asset with a yield, the gap grows only at `maxAnchorContinuousRiseRate` less the yield. A monitor that compares the anchor's rise with the asset's yield must catch the creep well before.

Through re-anchors:

- **Upward**, a re-anchor stops at the ceiling, and a drift never takes the anchor above the ceiling. So at all times, short of an acceptance or a parameter change, `currentPrice ≤ H × (1 + maxAnchorAboveBase / 1e18) × (1 + maxPriceAboveAnchor / 1e18)`, with `H` the current `basePrice`. At the examples' values, this limit is 0.25% over `H`. A re-anchor does not raise `H`. But while the anchor sits above `H`, a drift up raises `H` by its full step, so the ceiling rises faster than the anchor. Thus, a second re-anchor can go above `anchor0 × e^(maxAnchorContinuousRiseRate × T / (1e18 × 365 days))`: by about 0.0116% after a year at the top of the bounds, at the examples' values. `H` rises at most at `maxAnchorContinuousRiseRate × (1 + maxAnchorAboveBase / 1e18)`, compounded continuously.
- **Downward**, drift and re-anchors stop at the floor, so however many delays pass, short of an acceptance, `currentPrice ≥ floorPrice × (1 − maxPriceBelowAnchor / 1e18)`: 1.1% under `H` at the examples' values.

## Market impact

While `price()` reverts, the priced actions revert: borrowing, collateral withdrawal from a position with debt, liquidation and settlement, and with settlement the lender exits that need it. So do the controller views `nextSettlementBorrower`, `settlementFor` and `positionOf`, `settlementLtv` for a borrower with a settlement target, and `hasBadDebt` while the settlement queue is not empty. Supply, lender withdrawals from free liquidity, repayment, collateral top-ups and debt-free collateral withdrawal keep working. A pricing suspension has the same effect, and an oracle that serves several markets stops all of them at once.

A freeze stops borrowing but leaves liquidation and settlement running, and a pause stops every hooked action ([Market controller](market-controller.md)). Updates go on under both, so a pending anchor can re-anchor meanwhile.

> [!WARNING]
> **A move past the bounds stops the price for a delay and then lands, upward at most on the ceiling and downward at most on the floor.**
> - On a real fall, liquidations wait at least `reanchorDelay`. Lenders can withdraw free liquidity meanwhile at a share price that does not yet count the bad debt the later liquidations realize. A real fall past the floor's bounds, or a real rise past the ceiling's, waits for the price acceptor or the manager, and the priced actions with it.
> - A faulty value that stays past the delay is priced the same way, up to its line. Upward, one past the ceiling's bounds keeps the price reverting, and one up to their top becomes the price: at most `maxAnchorAboveBase` and the upper bound over `H`, which [the sizing rule](#choosing-values) covers. A freeze within the delay stops borrowing against it but not settlement, which then short-pays exiting lenders by up to that much. The re-anchor does not move `H`; the drifts that follow the value raise `H`, and the floor with it, by at most `maxPriceAboveAnchor` of the ceiling.
> - Against a downward one above the floor's lower bound, once it has landed, only a pause or a pricing suspension stops liquidation and settlement, and it must hold until the source is fixed or the proxy admin upgrades the oracle to a working source.

## Choosing values

The contract does not check the sizing rule below. The deployment preflight checks it at the LLTV of each market it creates. The manager must keep it in each `setParameters` call, for the highest LLTV among the markets that read the oracle.

| Parameter | At least | At most |
|---|---|---|
| `maxPriceAboveAnchor`, `maxPriceBelowAnchor` | the largest honest move between two source values, plus how far the anchor lags a source faster than the rates | the move the markets can take with no delay, and the sizing rule below |
| `maxAnchorContinuousRiseRate` | the asset's highest honest yield | close to that yield: it is the rate of a faulty creep |
| `maxAnchorContinuousFallRate` | the fastest honest decline to follow without a stop | under `−ln(1 − maxPriceBelowAnchor) × 365 days / (reanchorDelay + the keeper's interval)` |
| `maxAnchorBelowBase` | the deepest honest fall from a high | the sizing rule below |
| `maxAnchorAboveBase` | the largest honest rise over `basePrice` that drifts do not follow | the sizing rule below |
| `reanchorDelay` | the time to pause the markets | how long the markets can go without liquidations, and under `ln(1 + maxPriceAboveAnchor) × 365 days / maxAnchorContinuousRiseRate` less the keeper's interval |
| `reanchorWindow` | the keeper's interval | a few keeper intervals: until the window ends, a pending anchor that an unseen return left can stand in for a later move's delay |

Below the "At least" column, honest moves stop the price: a move past the bounds for a delay; a yield or a decline faster than the rates each time the anchor's lag passes a bound; a fall past the floor or a rise past the ceiling until the price acceptor or the manager acts; and an expired pending anchor for another delay. The contract checks the delay against both rates, without the keeper's interval. Past either rate's limit, a source that keeps moving at that rate after a move past the bound lands short of every re-anchor and keeps the price stopped while it moves and for up to two delays after.

The sizing rule keeps a position borrowed at LLTV against the highest price the oracle returns, `ceilingPrice × (1 + maxPriceAboveAnchor)`, covering its debt and incentive in a full liquidation at the lowest one, `floorPrice × (1 − maxPriceBelowAnchor)`, with the parameters as plain fractions:

```text
(1 − maxAnchorBelowBase) × (1 − maxPriceBelowAnchor) ≥ LLTV × LIF × (1 + maxAnchorAboveBase) × (1 + maxPriceAboveAnchor)
LIF = min(1.15, 1 / (1 − 0.3 × (1 − LLTV)))
```

`LIF` is the core's liquidation incentive factor. `maxAnchorBelowBase` and `maxAnchorAboveBase` share one budget: at the examples' bounds and a 98% LLTV, a floor 1% under `H` leaves a ceiling at most 0.26% over it, and a 0.2% ceiling a floor at most 1.06% under it; with ±0.3% bounds at 92%, a 4% floor leaves 1.23%. The rule holds however the source grew before, since a position opens only at a price the oracle returned and `H` never falls without an acceptance. A narrower `maxAnchorBelowBase` or `maxAnchorAboveBase` leaves an anchor already past its new line where it is, and a position opened under wider bounds keeps its debt, so the rule must hold for the widest values of all four parameters set since the last acceptance. The contract checks only the values of each call. Interest that accrues while a market waits on a line eats into it, so keep some slack under the limit.

## Invariants

The invariants hold for one storage namespace behind its proxy, from its `initialize` on, while the proxy runs the adapter it was initialized with, as specified here. An upgrade to any other implementation can break any of them.

| # | Invariant |
|---|---|
| I1 | `price()` returns only when pricing is not suspended and the current price is non-zero and inside the bounds, and then exactly `currentPrice × PRICE_SCALE`; otherwise it reverts with the error of the first failed step |
| I2 | The stored parameters always satisfy the constraints in [Parameters](#parameters) |
| I3 | `anchorAt ≤ block.timestamp` and `pendingAnchorAt ≤ block.timestamp` |
| I4 | `anchorPrice` is never zero |
| I5 | `pendingAnchorPrice` and `pendingAnchorAt` are both zero or both non-zero, and a recorded pending anchor lies outside the bounds around the anchor |
| I6 | A drift moves the anchor toward a current price within the bounds, never past it, by at most `anchorPrice × (e^(maxAnchorContinuousRiseRate × t / (1e18 × 365 days)) − 1)` up or `anchorPrice × (1 − e^(−maxAnchorContinuousFallRate × t / (1e18 × 365 days)))` down, each rounded down, where `t` is the time since the anchor was last set, `block.timestamp − anchorAt` |
| I7 | A re-anchor moves the anchor onto the pending anchor or the current price, whichever is nearer it, or onto the floor or the ceiling when that is nearer still, only with a pending anchor recorded at least `reanchorDelay` before and unexpired, and the current price outside the bounds on its side |
| I8 | Short of `acceptPrice`, the anchor moves only by I6 and I7 |
| I9 | An update never stops or changes a price `price()` returned just before it. Short of an upgrade, no call to the oracle changes the value `price()` returns, only whether it returns: the value is the source's |
| I10 | A suspension never ends more than `MAX_PRICING_SUSPENSION` after the call that set it |
| I11 | `acceptPrice` moves the anchor only to a current price inside the range its caller passed |
| I12 | Each adapter keeps its state in its own namespace, in the layout in [Interfaces and stored data](#interfaces-and-stored-data) |
| I13 | No update sets the anchor below `min(floorPrice, anchor before the update)` |
| I14 | `basePrice` changes only in `initialize` and `acceptPrice`, which set it to the price, and in a drift up from `A` to `A′`, which sets it to `max(H, A′ − max(A − H, 0))` |
| I15 | Every `updateAnchor()` that does not revert returns the outcome of the case it took and emits it in exactly one `AnchorUpdated`, its last event |
| I16 | Every update keeps `max(A′ − H′, 0) ≤ max(floor(H′ × maxAnchorAboveBase / 1e18), max(A − H, 0))`, with `A` and `H` the anchor and `basePrice` before it and `A′` and `H′` after |

## Trust model

`initialize` has no caller check. The proxy must be initialized in the call that deploys it; otherwise whoever calls `initialize` first becomes the admin and sets the parameters. `initialize` grants only `DEFAULT_ADMIN_ROLE`; the admin then grants `MANAGER_ROLE` and `PRICE_ACCEPTOR_ROLE`.

| Actor | Can | Trusted not to |
|---|---|---|
| Price source | set the current price | report a wrong price inside the bounds, revert, or keep a wrong value outside them for a delay: [What a faulty source can do](#what-a-faulty-source-can-do) |
| Anyone | call `updateAnchor()` and `price()`, and so pick when an update runs | nothing: an update takes only the source's own value and chooses only when a drift, a record or a re-anchor happens |
| Keeper | call `updateAnchor()` after each change of the source and in each window | stop updating: drifts and re-anchors need updates, and short of the price acceptor and the manager, only an update drops a pending anchor a passing wrong value left. Without updates, a source that grows at a yield `g` leaves the upper bound after about `maxPriceAboveAnchor / g`, and `price()` reverts. Once the source is more than one bound above the ceiling, an update moves the anchor only onto the ceiling, and the market prices again only after `acceptPrice`, or after the manager widens the ceiling or the upper bound |
| Block proposer | choose which block includes an update, and so the time it reads | nothing for safety: the time moves only the rates' reach, a pending anchor's delay and window, and the end of a suspension, by as long as a proposer can hold an update back |
| `PRICE_ACCEPTOR_ROLE` | move the anchor to the current source price at any distance, past the floor or the ceiling included, inside a range it passes, at once, restarting `basePrice` there | pass a range it has not checked |
| `MANAGER_ROLE` | set the bounds, `maxAnchorBelowBase` and `maxAnchorAboveBase` up to almost a whole price, with no check of the sizing rule, the rise rate and the fall rate up to `1e18`, a rise of about 171.8% and a fall of about 63.2% a year, the delay down to an hour and the window, each at once; drop the pending anchor with any `setParameters` call, again and again; suspend pricing for up to 7 days per call, again and again, or lift the suspension | loosen the parameters until the checks mean nothing; or tighten them, suspend pricing or drop pending anchors again and again to stop the markets or keep a real move off the price |
| `DEFAULT_ADMIN_ROLE` | grant and revoke the roles | grant them to unvetted holders |
| Market freezer and pauser | freeze or pause each market that reads the oracle | act slower than `reanchorDelay` |
| Monitor, off-chain | watch `PendingAnchorSet`, `AnchorUpdated`, `price()` reverts and the anchor's moves | miss a pending anchor, whose delay counts from the record whether anyone saw it or not, or a creep at the rise rate, which no check in the contract stops |
| Proxy admin | upgrade to any implementation, which can return any price; transfer the proxy administration; ossify the proxy | point the oracle at an unvetted source or another token pair |

What the code does not check:

- **Source age.** `UsdyNavOracle` does not read when the source last updated, and an anchor never goes stale. A USDY source that stops changing stays priced; a monitor and the markets' freeze have to catch it. `CentrifugeNavOracle` reverts on a vault price stamp older than `MAX_PRICE_AGE`. The stamp is the later of the share price's and the asset price's, so a newer asset price can hide an older share price. `ChainlinkOracle` reverts on a feed value written more than `MAX_PRICE_AGE` ago; the feed's `updatedAt` is when the feed wrote the value, so a value that stops changing stays priced while the feed keeps writing it.
- **Source binding.** The base reads `loanToken` and `collateralToken` only for their decimals. Nothing ties the USDY source to the USDY token. `CentrifugeNavOracle` requires the vault's share token to be the collateral token and its asset to be the loan token. Nothing ties a `ChainlinkOracle` feed to its token; `initialize`'s price range is the only check that the feed prices the collateral.
- **Loan-token price.** One loan token counts as one unit of the source's currency, and the oracle does not read the loan token's own price. This is an accepted risk. A loan token below one unit makes the price too low, so borrowers can be liquidated early. A loan token above one unit makes the price too high by the same fraction. At a 98% LLTV, the sizing budget for a high price is 1.43%, so a 1% move uses most of it. For `CentrifugeNavOracle` the source's currency is the loan token: the vault converts the share price at the pool's own price of the loan token.
- **Sizing by the manager.** No contract checks the sizing rule. A `setParameters` call with a too-wide corridor lets a faulty source leave bad debt. A parameter change is a Lido DAO governance action, and its reviewers must check the rule.
- **Earlier parameters.** The sizing rule speaks for one set of values, and the anchor keeps its place past a new floor or ceiling. Two calls that each pass the rule can together break it. An example at a 98% LLTV: the first call sets no floor and a 1.27% ceiling, and a re-anchor moves the anchor up. The second call sets no ceiling and a 1.26% floor, and a re-anchor moves the anchor down. The lowest price is then under the debt of a position opened at the highest price.
- **Market value.** The price is the source's value. A secondary-market discount of the collateral token, or limits on redeeming it, are not reflected.

## Interfaces and stored data

### Entry points

The [API reference](api/trailing-anchor-oracle.md) gives every signature, with a getter for each stored value. `updateAnchor()` returns the `UpdateOutcome` it took, so a keeper can read it with `eth_call` first. No view returns the current price without the checks.

### Events

- `AnchorSet(anchorPrice, anchorAt, accepted)` on every anchor write: `accepted` is true for the seed and `acceptPrice`, and false for a drift (`WithinBounds`) or a re-anchor (`PendingAnchorApplied`).
- `PendingAnchorSet(pendingAnchorPrice, pendingAnchorAt)` whenever an update records a pending anchor, a replacement included.
- `PendingAnchorCleared()` whenever a pending anchor is dropped: by an update, `acceptPrice` or `setParameters`. An expiry emits nothing.
- `AnchorUpdated(outcome, currentPrice)` on every `updateAnchor()` that does not revert, after the events above, with `outcome` indexed so a monitor can filter on it, for example on `AnchorOnFloor` or `AnchorOnCeiling`. The outcomes are numbered in their order from 0: `WithinBounds`, `PendingAnchorRecorded`, `PendingAnchorHeld`, `PendingAnchorApplied`, `AnchorOnFloor`, `AnchorOnCeiling`.
- `ParametersSet(parameters)` on every `setParameters` call, unchanged values included, and in `initialize`; `PricingResumesAtSet(resumesAt)` on every call to `setPricingResumesAt`.

`price()` emits nothing, so a price outside the bounds shows only after an update records it. A monitor works out a pending anchor's window from `pendingAnchorAt` and the parameters.

### Units and scaling

| Value | Unit |
|---|---|
| current price, `anchorPrice`, `pendingAnchorPrice`, `basePrice`, bounds, floor, ceiling, the acceptance range, and the prices in errors and events | loan-token currency per collateral token, with `PRICE_DECIMALS` = 18 decimals |
| `maxPriceAboveAnchor`, `maxPriceBelowAnchor` | fraction of the anchor price, WAD |
| `maxAnchorBelowBase`, `maxAnchorAboveBase` | fraction of `basePrice`, WAD |
| `maxAnchorContinuousRiseRate` | continuously compounded rate per 365-day year, WAD |
| `maxAnchorContinuousFallRate` | continuously compounded rate per 365-day year, WAD |
| `reanchorDelay`, `reanchorWindow` | seconds |
| `anchorAt`, `pendingAnchorAt`, `pricingResumesAt` | Unix time, seconds |
| `price()` | loan-token units per collateral-token unit, scaled by 1e36 |

```text
PRICE_SCALE = 10^(36 + loanDecimals − collateralDecimals − 18)
price()     = currentPrice × PRICE_SCALE
```

The constructor reverts with `UnsupportedDecimals` when `36 + loanDecimals < collateralDecimals + 18`. For USDY (18 decimals) against USDC (6 decimals), `PRICE_SCALE = 1e6`, and a current price of `1.15e18` is returned as `1.15e24`.

### Adapters

| Contract | Constructor | Source call | Current price |
|---|---|---|---|
| `UsdyNavOracle` | `(source, loanToken, collateralToken)` | Ondo's USDY oracle, `getPrice()` | USDY redemption value in USD, 18 decimals |
| `CentrifugeNavOracle` | `(vault, maxPriceAge, loanToken, collateralToken)` | vault `priceLastUpdated()`, then `convertToAssets(10^36 / PRICE_SCALE)` | share price in the loan token, 18 decimals |
| `ChainlinkOracle` | `(feed, maxPriceAge, loanToken, collateralToken)` | the feed's `latestRoundData()` | the feed's `answer`, scaled from its `decimals()` to 18 decimals |

The fork tests read these mainnet sources:

| Source | Address | Collateral |
|---|---|---|
| Ondo's `USDYOracleWrapper` | `0x87b126e5518b6a1Bb8465779b4607C45C643DF90` | USDY |
| Centrifuge JTRSY/USDC vault | `0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A` | JTRSY |
| Centrifuge JAAA/USDC vault | `0x4880799eE5200fC58DA299e965df644fBf46780B` | JAAA |
| Centrifuge deJTRSY/USDC vault | `0x18Ab9fC0B2e4Fef9e0e03c8EC63BA287a3238257` | deJTRSY |
| Centrifuge deJAAA/USDC vault | `0x4865BC9701fBD1207A7B50e2aF442C7DAf154c9c` | deJAAA |
| Chainlink "JTRSY NAV" | `0x0C2e4Df738e99e8db80012f5bb2a303f3f48Ca74` | JTRSY |
| Chainlink "JAAA NAV" | `0x3BbccB2301759D2e4A5692bA72DAb4b75dC43B1a` | JAAA |

`ZeroAddress` refuses a zero token, source, vault or feed in a constructor, and a zero `admin` in `initialize`.

`CentrifugeNavOracle` adds its own checks:

- The constructor reverts with `MaxPriceAgeIsZero` on a zero `maxPriceAge`.
- The constructor reverts with `ShareTokenMismatch(shareToken, collateralToken)` when the vault's `share()` is not the collateral token, and with `AssetMismatch(asset, loanToken)` when its `asset()` is not the loan token.
- Each price read reverts with `StalePrice(computedAt)` when `block.timestamp − computedAt > MAX_PRICE_AGE`, with `computedAt` the vault's `priceLastUpdated()`. Thus, `price()`, `updateAnchor()`, `acceptPrice()` and `initialize` revert on an old price.
- Each price read reverts with `PriceFromFuture(computedAt)` when `computedAt > block.timestamp`. The issuer supplies `computedAt`, so it can be later than the block time.

From February to November 2026, the oldest JTRSY and JAAA prices were about 131 hours old, after the Easter holidays. A `MAX_PRICE_AGE` of 7 days does not stop these honest prices.

`ChainlinkOracle` scales the feed's `answer` by `10^(18 − decimals())`, with the decimals read in its constructor, and does not read the round fields. The adapter adds its own checks:

- The constructor reverts with `MaxPriceAgeIsZero` on a zero `maxPriceAge`, and with `UnsupportedFeedDecimals(feedDecimals)` when the feed has more than 18 decimals.
- Each price read reverts with `PriceFromFuture(updatedAt)` when `updatedAt > block.timestamp`, then with `StalePrice(updatedAt)` when `block.timestamp − updatedAt > MAX_PRICE_AGE`, then with `NegativePrice(answer)` when `answer < 0`.

Each adapter returns the source's value as is: one loan token counts as one unit of the source's currency, and nothing checks the loan token's own price.

### Storage

Each adapter stores its state at `erc7201("lido.lend.storage.<ContractName>")`, in four slots, with packed fields from the low bits up. The fields are grouped by use, so a drift reads three slots and writes one. The base is `0x122c02b6c23a425b38bb372a8ef92bda1cb6c1f0f92387327be1d4669516e800` for `UsdyNavOracle`, `0xadd8a162807c0a5c641cbb443f3a5adf7735f0856ce3d3f8789bb5d6d97ba000` for `CentrifugeNavOracle` and `0x2b94dcc1f7c452973fef7f3857ccee6b1304e3e10b7af5d9d15a3e1188eb9000` for `ChainlinkOracle`.

| Slot | Fields, with bits |
|---|---|
| base + 0 | `anchorPrice` (`uint104`, 0 to 103), `basePrice` (`uint104`, 104 to 207), `anchorAt` (`uint40`, 208 to 247) |
| base + 1 | `maxPriceAboveAnchor` (`uint64`, 0 to 63), `maxPriceBelowAnchor` (`uint64`, 64 to 127), `pricingResumesAt` (`uint40`, 128 to 167), `pendingAnchorAt` (`uint40`, 168 to 207) |
| base + 2 | `maxAnchorContinuousRiseRate` (`uint64`, 0 to 63), `maxAnchorContinuousFallRate` (`uint64`, 64 to 127), `maxAnchorBelowBase` (`uint64`, 128 to 191), `maxAnchorAboveBase` (`uint64`, 192 to 255) |
| base + 3 | `pendingAnchorPrice` (`uint104`, 0 to 103), `reanchorDelay` (`uint40`, 104 to 143), `reanchorWindow` (`uint40`, 144 to 183) |

Roles and the initializer flag live in OpenZeppelin's own namespaces (`openzeppelin.storage.AccessControl`, `openzeppelin.storage.AccessControlEnumerable` and `openzeppelin.storage.Initializable`), which every implementation behind the same proxy shares.

### Upgrades

The implementation's constructor disables initializers and fixes the immutables: `PRICE_SCALE`, the source address and the adapter's own constants, such as `MAX_PRICE_AGE`. An upgrade to another implementation with the same storage namespace keeps the anchor, `basePrice`, the pending anchor, the suspension and the parameters, whatever its immutables: one bound to another source starts from the old anchor and any pending anchor the old source left, and one that changes the layout misreads them.
An upgrade must keep the adapter's namespace. An implementation with another one, such as another adapter, reads empty storage, and that case is not supported.

## Related references

- [Architecture](architecture.md) for where the oracle sits in the market runtime.
- [Market controller](market-controller.md) and [Lender settlement](lender-settlement.md) for the controller paths that read the price, and the freeze and pause.
- [Privileged roles](roles.md) for the oracle's roles and the proxy admin of oracle proxies.
- [API reference](api/trailing-anchor-oracle.md) for every function, event, error and state variable.
