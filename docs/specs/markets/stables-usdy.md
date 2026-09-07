# USDY / Stablecoin Markets

This market family lets borrowers post **USDY** collateral and borrow a governance-selected USD stablecoin. Each stablecoin/USDY pair is a separate market with its own lender liquidity, debt, positions, and risk parameters. Shared behavior is described in [Architecture](../architecture.md), [Market Controller Policy](../market-controller.md), and [Settlement and Lender Exits](../lender-settlement.md).

The pair selection and risk parameters are not fixed by this document. The market-specific design is the USDY valuation and the effect of USDY's transfer restrictions.

## Parameters

| Field | Value |
|---|---|
| Loan token | Governance-selected USD stablecoin |
| Collateral token | USDY |
| Oracle | `UsdyStableOracle` |
| Interest-rate model | Governance-selected through `IrmRouter` |
| Liquidation loan-to-value threshold | Selected by governance and fixed when the market is created |
| Lender settlement | Enabled or disabled when the market is created |

## USDY valuation

`UsdyStableOracle` values USDY in the market's loan token. It divides the Ondo USDY/USD NAV by the matching Chainlink stablecoin/USD price. It does not use a secondary-market USDY price or guarantee the proceeds of redeeming or selling USDY.

```text
scale = 10 ** (36 + loanDecimals + feedDecimals - usdyDecimals - navDecimals)
price = floor(usdyNavUsd * scale / stablecoinUsdPrice)
```

`usdyNavUsd` and `stablecoinUsdPrice` use the decimals of their respective sources. The returned value follows the core convention for raw loan-token units per raw USDY unit, scaled by `1e36`. USDY and its NAV use 18 decimals; the loan-token and feed decimals are read for each oracle instance rather than hardcoded.

A stablecoin price below one dollar increases the reported value of USDY in that stablecoin's units. This keeps the quote denominated in the loan asset; it does not protect the lender from a loss in that asset's dollar value.

### Price sanity band

Each oracle instance carries an inclusive band `[MIN_PRICE, MAX_PRICE]`, fixed at deployment from the oracle's configuration and expressed in the same scaled domain as the returned price. The oracle reverts rather than return a price outside that band, so a mis-scaled NAV or a near-zero feed answer stops the market's price-dependent actions instead of repricing every position.

The band is a sanity check on the sources, not a risk parameter: it is chosen wide enough that NAV accrual and stablecoin depegs stay inside it, and changing it requires deploying a new oracle. Its magnitude depends on the loan token's decimals, so a band is valid only for the loan token its instance was initialized with. Deployment preflight and the acceptance suite both require the live price to sit strictly inside the band, which keeps a market from being wired to an oracle already at its edge.

If either source fails to return a usable positive value, or the result falls outside the band, price-dependent actions revert, including borrowing, debt-bearing collateral withdrawal, liquidation, and settlement. That oracle failure does not by itself block repayment or ordinary loan-asset withdrawal. A positive stale value inside the band is accepted because the oracle does not enforce freshness or deviation limits.

> [!WARNING]
> **NAV and feed trust boundary.** Health checks, liquidation, and settlement use the reported NAV conversion, not executable USDY sale or redemption proceeds. A stale feed, stale NAV, redemption delay or fee, transfer restriction, issuer freeze, or loss of redeemability can therefore make the onchain collateral value exceed what a receiver can realize.

## Token-transfer boundaries

The protocol relies on USDY's own transfer rules and adds no USDY-specific borrower, receiver, or liquidator eligibility registry. Supplying collateral transfers USDY from the supplier to the core; the recorded borrower may be another address. Collateral withdrawal and settlement send USDY to their selected receivers, while liquidation sends it to the liquidator. If USDY rejects one of those transfers, the action fails.

Market accounting remains separate, but `flashLoan(USDY)` is token-global. It can use the shared core's combined USDY balance and does not call a market controller, so a controller pause does not block it. The call still fails if USDY rejects either the transfer to the caller or the transfer back to the core.

Loan-token issuer controls apply independently to loan-token transfers. The protocol cannot bypass an issuer freeze, blocklist, or other transfer rejection.

## Liquidation, settlement, and incidents

Liquidation uses the inherited core path. Settlement, when enabled for a market, is a separate lender-exit path that uses the oracle price to calculate the USDY payout. Neither path sells or redeems USDY into the loan token. See [Settlement and Lender Exits](../lender-settlement.md).

A controller freeze leaves liquidation and settlement available. A controller pause blocks both for that market, together with other controller-hooked actions. Each market must be paused separately.

The current contracts provide no USDY-specific market-wide recovery path for NAV failure, redemption failure, or issuer intervention.
