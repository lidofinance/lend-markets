# Deployment

Scripts deploy inert markets. Activation is a separate EasyTrack motion. Role ownership is documented in
`docs/specs/roles.md`.

## Setup

Configuration lives under `script/config/`:

- `<config>.toml`: network, governance, and optional exit books;
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

A market declares `market.role` — the part it plays, e.g. `weth-wsteth` — which is recorded in its artifact.
Roles are shared across networks while market names are not, so a consumer names the role it needs rather than
a network's market. `test/fork/` binds by role and skips a role the deployment has no market for.

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

`deploy-protocol` deploys the backbone and, when `exit_books = true`, the exit books. Markets are not part of
it: each is its own `deploy-market` run against that backbone, so a run's market set is the sequence of those
runs and is recorded in `deployed/<RUN>/markets/`.

Every artifact a market references is deployed before the market, each by its own step: its CircuitBreaker, its
oracle, any standalone IRM it names, and the `GuardianSignals` registry of its guardian group. The registry
belongs to a committee rather than to a market — several markets under one committee share one — so it is a
step, not a side effect of the first market that needs it. It comes after the backbone, which records the
builder it is created through:

```sh
make deploy-linear-kink-irm CONFIG=mainnet RUN=mainnet-weth-wsteth IRM=linear-kink
make deploy-guardian CONFIG=mainnet RUN=mainnet-weth-wsteth GUARDIAN_GROUP=weth-wsteth
make deploy-market CONFIG=mainnet RUN=mainnet-weth-wsteth MARKET=weth-wsteth
```

The full order is CircuitBreaker, oracles, any standalone IRM, the protocol, the guardian registries, the
markets, then anything optional (`deploy-vault-v2`, `deploy-exit-books`).

If broadcast or verification is interrupted, immediately repeat the same target and arguments with
`RESUME=true`. Do not send another transaction from the deployer first: Foundry resumes the saved nonce
sequence.

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

On a fork or devnet there is no EasyTrack, so `make activate-markets RUN=<run>` replays the motion for every
market recorded in the run, as the impersonated `EVMScriptExecutor` (read from the run's `protocol.toml`). It is idempotent, so an interrupted run can be repeated. Never a substitute for the motion on
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

## Fork provisioning

`test/fork/` needs a deployment to drive before any real network is live, so provisioning stands one up on a
local anvil fork of a real network. There is no separate deploy config for it: `provision-fork.sh` takes an
ordinary one and forks the network its `chain_id` names, deploying the `fork-*` market
configs against it. Those markets differ from production only where a test needs them to — a second IRM, a
higher LLTV — and go through the same scripts, artifact layout and activation as everything above. What confines
the result to a fork is the governance addresses in the config: only an impersonating node can act as them.

```sh
make provision-fork RPC_URL=<archive-rpc>            # CONFIG=mainnet by default; leaves anvil up
make test-fork-live                                 # the suites against it; re-runnable without re-provisioning
make provision-stop
```

`PIN_BLOCK=<n>` on `provision-fork` pins the upstream block anvil forks from, which is what makes a run
reproducible. `deploy-vault-v2` verifies its pair through `verify-vault-v2`, a separate target because the
pair is created with `vm.deployCode` and `forge script --verify` cannot name those creations.

`make test-fork-provision RPC_URL=<archive-rpc>` chains the three. The driver runs the `deploy-*` targets in the
order this document describes — CircuitBreaker, oracles, the kinked IRM, the backbone, the guardian registries,
the markets, the vault-v2 pair, then `activate-markets` — and finishes with `acceptance-run` per market, so provisioning reports success
only once the deployed stack verifies against the artifacts it wrote.
