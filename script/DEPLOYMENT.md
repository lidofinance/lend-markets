# Deployment

Scripts deploy inert markets. Activation is a separate EasyTrack motion. Role ownership is documented in
`docs/specs/roles.md`.

## Setup

Configuration lives under `script/config/`:

- `<config>.toml`: network, governance, optional exit books, and market names;
- `markets/<market>.toml`: market parameters, roles, and artifact references;
- `circuit-breakers/<name>.toml`: immutable bounds and initial pause/heartbeat settings;
- `oracles/<name>.toml`: oracle inputs;
- `guardians/<group>.toml`: GuardianSignals inputs;
- `vaults/<name>.toml` and `adapters/<name>.toml`: an external vault-v2 vault and its Morpho adapter.

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
irms/<name>.toml
vaults/<name>.toml
adapters/<name>.toml
exit-books.toml
transactions/<step>.json
```

Each market artifact contains its resolved addresses, market ID, final controller role holders,
CircuitBreaker reference, activation, settlement, and curve parameters. Separate CircuitBreaker, oracle, and
GuardianSignals artifacts contain their resolved configuration.

Deploy each referenced CircuitBreaker before the protocol. The script fixes `ADMIN = evm_script_executor`;
the remaining immutable bounds and initial settings come from `circuit-breakers/<name>.toml`. A market names
the artifact through `market.circuit_breaker_artifact`; the resolved address is prepended to
`roles.pausers`, whose configured entries are additional direct pausers. One CircuitBreaker may serve several
markets.

Zero `market.oracle` resolves `oracle_artifact`. `deploy-protocol` requires zero `market.guardian_signals`
and deploys or shares the configured group. `deploy-market` may reuse a non-zero instance.

`market.irm_artifact` selects the interest-rate model the activation motion routes. It defaults to
`adaptive-curve`, the protocol singleton recorded in `protocol.toml`; any other value names an `irms/<name>.toml`
artifact in the same run, which must already be deployed. The model and its parameters travel together: an
adaptive-curve market carries `[curve]`, a kinked market carries `[kink]`, and a config with the wrong pair
fails when it is read. Two markets over the same tokens, oracle and LLTV would hash to the same market id
regardless of the routed model, so a second market on the same pair needs its own oracle instance.

## Deploy

Deploy the required CircuitBreaker and oracle, then the protocol:

```sh
make deploy-circuit-breaker CONFIG=mainnet RUN=mainnet-weth-wsteth CIRCUIT_BREAKER=lido-lend
make deploy-oracle CONFIG=mainnet RUN=mainnet-weth-wsteth ORACLE=weth-wsteth
make deploy-protocol CONFIG=mainnet RUN=mainnet-weth-wsteth
```

`deploy-protocol` includes exit books when `exit_books = true`. Use `deploy-oracle-usdy` for USDY or
`deploy-run` for the current single-CircuitBreaker, single-WstETH-oracle flow.

Deploy any standalone IRM a market names **before** the protocol: `deploy-protocol` reads every market config,
and a market whose `irm_artifact` does not resolve stops the run.

```sh
make deploy-linear-kink-irm CONFIG=mainnet RUN=mainnet-weth-wsteth IRM=linear-kink
```

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
make deploy-vault-v2 CONFIG=mainnet RUN=mainnet-weth-wsteth VAULT=weth-wsteth ADAPTER=weth-wsteth
make deploy-exit-books CONFIG=mainnet RUN=mainnet-weth-wsteth
```

`deploy-vault-v2` needs an existing run: the adapter's Morpho and IRM-router immutables come from its
`protocol.toml`, and the vault is the adapter's own constructor immutable, so both are created in one broadcast.
Both are left unconfigured — curator, adapter registration and caps are the vault owner's calls.
`deploy-exit-books` writes `exit-books.toml` without modifying the protocol artifact.

## Activate

Activation inputs are runtime EasyTrack motion choices, not deployment artifacts. No separate activation
artifact is generated or required. EasyTrack acceptance reads reviewed values and resolved addresses from
`deployed/<RUN>/markets/<market-name>.toml`. The motion sets the routed model's per-market parameters, routes
that model on the IRM router, creates the market through `LidoLendOwner`, and registers the CircuitBreaker
pauser.

Exit-book allow-listing is a separate `LidoLendSetMarketExitBookAllowed` motion.

On a fork or devnet there is no EasyTrack, so `make activate-markets CONFIG=<config> RUN=<run>` replays the
motion for every market in the run as the impersonated `EVMScriptExecutor` (read from the run's
`protocol.toml`). It is idempotent, so an interrupted run can be repeated. Never a substitute for the motion on
a real network.

## Verify

```sh
make acceptance-run RUN=mainnet-weth-wsteth MARKET=weth-wsteth
make acceptance-run-multi RUN=mainnet-weth-wsteth MARKET_A=market-a MARKET_B=market-b
```

The read-only fork suites bind to a run the same way, reading `deployed/<RUN>/` directly:

```sh
make fork-run RUN=mainnet-weth-wsteth
```

## The fork profile

`script/config/fork.toml` is an ordinary config that stands the whole stack up on a local anvil fork of
mainnet, so `test/fork/` has a deployment to drive before any real network is live. It runs through the same
scripts, artifact layout and activation as above; what makes it fork-only is its governance addresses —
mainnet's Agent and EVMScriptExecutor, which only an impersonating node can act as.

```sh
make provision-fork RPC_URL=<mainnet-archive-rpc>   # deploy + activate into deployed/fork/; leaves anvil up
make test-fork RPC_URL=http://127.0.0.1:8545 ARTIFACTS_DIR=fork
make provision-stop
```

`make test-fork-provision RPC_URL=<mainnet-archive-rpc>` chains the three. `script/provision-fork.sh` is a thin
driver over the `deploy-*` targets in the order this document describes: CircuitBreaker, oracles, the kinked
IRM, the protocol, the vault-v2 pair, then `activate-markets`. It finishes by running `acceptance-run` for every
market in the config, so provisioning only reports success once the deployed stack verifies against its own
artifacts — the same check a real deployment gets.
