# Lido Lending — Specifications

The specs come in two layers: hand-written concepts and a generated API reference.

## Conceptual specs (hand-written)

The system, the rules, and the trust assumptions the code cannot state itself.

- [architecture.md](architecture.md) — topology, hook flow, and the controller subsystems: collateral activation, settlement queue, guardian signals, freeze/pause. Carries the threat model and the invariants, each mapping to a test in `test/`.
- [roles.md](roles.md) — every privileged action mapped to its role, class, and intended holder.
- [markets/](markets/) — per-market assets, oracle, and risk parameters ([eth-steth.md](markets/eth-steth.md)).

## API reference (generated)

The contract surface — functions, structs, state variables — rendered from the Solidity NatSpec. This is the single source for per-member behaviour, so it is never hand-edited: keep the NatSpec accurate and regenerate.

- [api/](api/) — one page per Lido-layer contract: [LidoLendMarketController](api/lido-lend-market-controller.md), [LidoLendERC4626](api/lido-lend-erc4626.md), [GuardianSignals](api/guardian-signals.md), [LidoLendDepositGateway](api/lido-lend-deposit-gateway.md), [RiskStewardDashboard](api/risk-steward-dashboard.md), the [exit-book layer](api/exit-book.md) (ExitBookBase, Erc4626ExitBook, MorphoExitBook), the oracles ([WstEthRateOracle](api/wst-eth-rate-oracle.md), [UsdyStableOracle](api/usdy-stable-oracle.md)), and [shared types](api/shared-types.md).

The forked Morpho core's fork point and core changes are recorded in [`lib/lido-lend/FORK_NOTES.md`](../../lib/lido-lend/FORK_NOTES.md). The API reference here covers only the Lido layer on top.

## Regenerating

```
make doc
```

Runs `forge build --ast`, then `tools/gen_api_from_artifacts.py`, which rebuilds `api/*.md` from the compiler AST.
