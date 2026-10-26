# Lido Lend Specifications

Start with [Architecture](architecture.md). It explains the system and links to every detailed mechanism guide and API page.

The specifications have two layers: hand-written concepts and a generated API reference.

## Conceptual specs (hand-written)

These documents explain system behavior, cross-contract rules, formulas, invariants, and trust assumptions.

- [architecture.md](architecture.md) — the entry point: system model, topology, runtime boundaries, contract map, control layers, and trust overview.
- [market-controller.md](market-controller.md) — hook policy, collateral activation, freeze/pause behavior, and controller safety invariants.
- [guardian-signals.md](guardian-signals.md) — guardian identity, account signals, ban lifecycle, and liveness frontier.
- [lender-settlement.md](lender-settlement.md) — direct and vault settlement, lender exits, queue policy, budgets, and rounding boundaries.
- [exit-books.md](exit-books.md) — request lifecycle, exact-asset fill accounting, external liquidity composition, and the filler workflow.
- [roles.md](roles.md) — every privileged action mapped to its role, class, and intended holder.
- [WETH / wstETH](markets/eth-steth.md) and [USDY / Stablecoin Markets](markets/stables-usdy.md) — market-specific assets, oracle assumptions, transfer constraints, and parameters.

## API reference (generated)

These pages render the documented local contract surface from Solidity NatSpec: functions, structs, events, errors, and state variables. They are never hand-edited. Standard inherited surfaces may remain in the relevant upstream standard or dependency and are not repeated unless the page says otherwise.

- Market runtime: [LidoLendMarketController](api/lido-lend-market-controller.md), [LidoLendERC4626](api/lido-lend-erc4626.md), [GuardianSignals](api/guardian-signals.md), [WstEthRateOracle](api/wst-eth-rate-oracle.md), and [UsdyStableOracle](api/usdy-stable-oracle.md).
- Governance and deployment: [LidoLendOwner](api/lido-lend-owner.md), [LidoLendMarketFactory](api/lido-lend-market-factory.md), [RiskStewardDashboard](api/risk-steward-dashboard.md), and [OssifiableProxy](api/ossifiable-proxy.md).
- Optional user periphery: the [Exit Book family](api/exit-book.md) and [Bundler3 adapters](api/bundler3-adapters.md).
- Common ABI definitions: [shared types](api/shared-types.md).

The forked core is documented in the [Lido Lend specification](https://github.com/lidofinance/lend/blob/main/SPECIFICATION.md). Its fork point and local change record are in [FORK_NOTES](https://github.com/lidofinance/lend/blob/main/FORK_NOTES.md). The API reference here covers only the Lido layer on top.

## Regenerating

```
make doc
```

Runs `forge build --ast`, then `tools/gen_api_from_artifacts.py`, which rebuilds `api/*.md` from the compiler AST.
