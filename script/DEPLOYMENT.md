# Deployment

Scripts deploy inert markets. Activation is a separate EasyTrack motion. Role ownership is documented in
`docs/specs/roles.md`.

## Setup

Configuration lives under `script/config/`:

- `<config>.toml`: network, governance, optional exit books, and market names;
- `markets/<market>.toml`: market parameters, roles, and artifact references;
- `circuit-breakers/<name>.toml`: immutable bounds and initial pause/heartbeat settings;
- `oracles/<name>.toml`: oracle inputs;
- `guardians/<group>.toml`: GuardianSignals inputs.

Set `RPC_URL`, `DEPLOYER_PRIVATE_KEY`, and `ETHERSCAN_API_KEY` in `.env`. Deployment targets broadcast and
verify by default; use `VERIFY=false` only for networks without a verifier. `RUN` selects `deployed/<RUN>/`;
all steps for one deployment must use the same `RUN`. Artifacts are immutable and are not overwritten.

The run directory contains:

```text
protocol.toml
markets/<market>.toml
circuit-breakers/<name>.toml
guardians/<group>.toml
oracles/<oracle>.toml
exit-books.toml
transactions/<step>.json
```

The protocol artifact records the shared permissionless `IrmConfigFactory`. Each market artifact contains its
resolved addresses, market ID, final controller role holders, CircuitBreaker reference, activation, settlement,
and curve parameters. Separate CircuitBreaker, oracle, and GuardianSignals artifacts contain their resolved
configuration.

Deploy each referenced CircuitBreaker before the protocol. The script fixes `ADMIN = evm_script_executor`;
the remaining immutable bounds and initial settings come from `circuit-breakers/<name>.toml`. A market names
the artifact through `market.circuit_breaker_artifact`; the resolved address is prepended to
`roles.pausers`, whose configured entries are additional direct pausers. One CircuitBreaker may serve several
markets.

Zero `market.oracle` resolves `oracle_artifact`. `deploy-protocol` requires zero `market.guardian_signals`
and deploys or shares the configured group. `deploy-market` may reuse a non-zero instance.

## Deploy

Deploy the required CircuitBreaker and oracle, then the protocol:

```sh
make deploy-circuit-breaker CONFIG=mainnet RUN=mainnet-weth-wsteth CIRCUIT_BREAKER=lido-lend
make deploy-oracle CONFIG=mainnet RUN=mainnet-weth-wsteth ORACLE=weth-wsteth
make deploy-protocol CONFIG=mainnet RUN=mainnet-weth-wsteth
```

`deploy-protocol` includes exit books when `exit_books = true`. Use `deploy-oracle-usdy` for USDY or
`deploy-run` for the current single-CircuitBreaker, single-WstETH-oracle flow.

If broadcast or verification is interrupted, immediately repeat the same target and arguments with
`RESUME=true`. Do not send another transaction from the deployer first: Foundry resumes the saved nonce
sequence.

To add a market to an existing run:

```sh
make deploy-market CONFIG=mainnet RUN=mainnet-weth-wsteth MARKET=weth-wsteth
```

Deploy a shared GuardianSignals instance for an existing run when needed:

```sh
make deploy-guardian CONFIG=mainnet RUN=mainnet-weth-wsteth GUARDIAN_GROUP=shared-group
```

Optional standalone deployments:

```sh
make deploy-linear-kink-irm CONFIG=mainnet RUN=mainnet-weth-wsteth
make deploy-exit-books CONFIG=mainnet RUN=mainnet-weth-wsteth
```

The kinked IRM is recorded but not routed. `deploy-exit-books` writes `exit-books.toml` without modifying the
protocol artifact.

## Activate

No separate activation artifact is generated or required. EasyTrack acceptance reads reviewed values and
resolved addresses from `deployed/<RUN>/markets/<market-name>.toml`. Deployment ensures that the shared
`IrmConfigFactory` contains an immutable config for the recorded curve parameters. After the deployment
transactions are confirmed, activation resolves that config through the factory's typed getter, applies it,
routes the IRM, creates the market through `LidoLendOwner`, and registers the CircuitBreaker pauser. Other
motion choices, such as settlement enablement and the pauser committee, remain runtime inputs.

Exit-book allow-listing is a separate `LidoLendSetMarketExitBookAllowed` motion.

## Verify

```sh
make acceptance-run RUN=mainnet-weth-wsteth MARKET=weth-wsteth
make acceptance-run-multi RUN=mainnet-weth-wsteth MARKET_A=market-a MARKET_B=market-b
```
