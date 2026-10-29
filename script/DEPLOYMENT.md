# Deployment

Scripts deploy inert markets. Activation is a separate EasyTrack motion. Role ownership is documented in `docs/specs/roles.md`.

## Setup

Configuration lives under `script/config/`:

- `<config>.toml`: network, governance including the Reseal Manager, the CircuitBreaker artifact selector, and optional exit books;
- `markets/<market>.toml`: market parameters, vault metadata, role, and artifact references;
- `circuit-breakers/<name>.toml`: immutable bounds and initial pause/heartbeat settings;
- `oracles/<name>.toml`: oracle inputs; standalone deployment uses the configured DAO Agent as proxy admin;
- `guardians/<group>.toml`: GuardianSignals guardian set, quorum, and suspect window; proxy admin and
  `DEFAULT_ADMIN_ROLE` are fixed by the market factory's immutable `ADMIN`;
- `vaults/<name>.toml` and `adapters/<name>.toml`: an external vault-v2 vault and its Morpho adapter;
- `bundlers/<name>.toml`: the WETH / wstETH the general adapter binds; the Bundler3 it dispatches through is deployed with it.

Set `RPC_URL`, the deployer signer, and `ETHERSCAN_API_KEY` in `.env`. The signer is `DEPLOYER_ACCOUNT` — an encrypted Foundry keystore created with `cast wallet import --interactive <name>`, for which forge prompts for the password — plus `DEPLOYER_SENDER`, its address, passed as `--sender` (forge derives no sender from a keystore). A raw private key is not accepted; a local unlocked node sets `DEPLOYER_SENDER` alone. Deployment targets broadcast and verify by default; use `VERIFY=false` only for networks without a verifier. `RUN` selects `deployed/<RUN>/`; all steps for one deployment must use the same `RUN`. Artifacts are immutable and are not overwritten.

Each artifact header records two deploy-config hashes. `config_hash` is the exact hash of the complete TOML and
is retained as provenance. `compatibility_hash` is canonical over the protocol identity that existing-protocol
steps depend on: network, chain id, Agent, EVMScriptExecutor, Reseal Manager, and CircuitBreaker artifact selector. Exit-book fields and the
test-only `[provision]` plan are excluded from compatibility. Consumers still require the same run name, chain,
compatibility hash, and governance actors, and `protocol.toml` must agree internally between its artifact header
and protocol section. Exact hashes may therefore differ between compatible sibling artifacts created before and
after a standalone configuration extension; that difference is preserved rather than rewritten.

The run directory contains:

```text
protocol.toml
markets/<market>.toml
circuit-breakers/<name>.toml
guardians/<group>.toml
oracles/<oracle>.toml
vaults/<name>.toml       # when a vault-v2 pair is deployed
adapters/<name>.toml     # when a vault-v2 pair is deployed
exit-books.toml          # when exit books are deployed
bundler.toml             # when the bundler stack is deployed
transactions/<step>.json
```

A market declares `market.role` — the part it plays, e.g. `weth-wsteth` — which is recorded in its artifact.
Roles are shared across networks while market names are not, so a consumer names the role it needs rather than
a network's market. `test/fork/` binds by role and skips a role the deployment has no market for.

The protocol artifact records the shared permissionless `IrmConfigFactory`, the Reseal Manager, and the single CircuitBreaker bound
to the core's market factory. Each market artifact contains its resolved addresses, market ID, initial supply cap,
immutable Adaptive Curve config, activation, settlement, and curve parameters. Current role holders are read directly
from the deployed enumerable AccessControl contracts; they are not copied into artifacts. Separate
CircuitBreaker, oracle, and GuardianSignals artifacts contain their resolved configuration.

Deploy the protocol's single CircuitBreaker before the protocol. The script
fixes the CircuitBreaker's `ADMIN = evm_script_executor`; the remaining immutable bounds and initial settings
come from the named `script/config/circuit-breakers/<circuit_breaker_artifact>.toml`. The resolved address is fixed in the market factory and receives
`PAUSER_ROLE` on every controller it deploys. The protocol-wide `reseal_manager` receives both `PAUSER_ROLE` and
`RESUMER_ROLE` on those controllers. There are no per-market controller-role arrays: one CircuitBreaker and one
Reseal Manager serve the core/factory and all of its markets.

Zero `market.oracle` resolves `oracle_artifact`. A zero `market.guardian_signals` resolves the already-recorded
`guardian_group`; run `deploy-guardian` first. Guardian registries are separate resources, so several markets
can reference the same group without `deploy-protocol` or `deploy-market` creating it as a side effect.

Every market is routed through the protocol's Adaptive Curve IRM singleton. Its market config carries `[curve]`
parameters; `deploy-market` resolves or deploys the matching immutable config through `IrmConfigFactory` and
records that address as `market.irm_config`. There is no separate IRM artifact or per-market model selector.

## Deploy

Deploy the required CircuitBreaker and oracle, then the protocol:

```sh
make deploy-circuit-breaker CONFIG=mainnet RUN=mainnet-weth-wsteth
make deploy-oracle CONFIG=mainnet RUN=mainnet-weth-wsteth ORACLE=weth-wsteth
make deploy-protocol CONFIG=mainnet RUN=mainnet-weth-wsteth
```

`deploy-protocol` includes exit books when `exit_books = true`. Use `deploy-oracle-usdy` for USDY or
`deploy-run` for the canonical single-CircuitBreaker, single-WstETH-oracle flow.

`deploy-oracle-nav` deploys a NAV oracle: it builds the adapter its config's `kind` names (`nav-usdy`,
`nav-centrifuge`) from the config's constructor arguments, puts it behind an `OssifiableProxy` with
the DAO Agent as admin, and initializes it from the live source with the config's `max_price_above_anchor`,
`max_price_below_anchor`, `max_anchor_rise_per_year`, `max_anchor_fall_per_year`, `max_anchor_below_mark`, `max_anchor_above_mark`,
`reanchor_delay` and `reanchor_window`. The deployer initializes as the temporary `DEFAULT_ADMIN_ROLE` holder, grants `MANAGER_ROLE` to
the EVMScriptExecutor and the Agent, and `PRICE_ACCEPTOR_ROLE` and `DEFAULT_ADMIN_ROLE` to the Agent, and renounces
in the same broadcast. The artifact under `deployed/<RUN>/oracles/` records the kind, the constructor arguments and
the eight parameters. `deploy-market`'s preflight refuses the oracle unless the live source already prices inside the
bounds and the parameters pass the two sizing rules for the market's LLTV, with the parameters as fractions:
`(1 − max_anchor_below_mark)(1 − max_price_below_anchor) ≥ LLTV × LIF × (1 + max_anchor_above_mark)(1 + max_price_above_anchor)`,
and
`reanchor_delay × max_anchor_fall_per_year ≤ max_price_below_anchor × 365 days`.

`deploy-protocol` deploys the backbone and, when `exit_books = true`, the exit books. Markets are not part of
it: each is its own `deploy-market` run against that backbone, so a run's market set is the sequence of those
runs and is recorded in `deployed/<RUN>/markets/`.

Every artifact a market references is deployed before the market, each by its own step: its oracle and the
`GuardianSignals` registry of its guardian group. The protocol-wide CircuitBreaker is deployed once before the backbone. The registry
belongs to a committee rather than to a market — several markets under one committee share one — so it is a
step, not a side effect of the first market that needs it. It comes after the backbone, which records the
factory it is created through:

```sh
make deploy-guardian CONFIG=mainnet RUN=mainnet-weth-wsteth GUARDIAN_GROUP=weth-wsteth
make deploy-market CONFIG=mainnet RUN=mainnet-weth-wsteth MARKET=weth-wsteth
```

The full order is CircuitBreaker, oracles, the protocol, the guardian registries, the
markets, then anything optional (`deploy-vault-v2`, `deploy-bundler`, `deploy-exit-books`).

The checked-in `mainnet` profile is deliberately blocked before value-bearing deployment: governance has not
yet supplied `exit_book_pauser`, and `guardians/weth-wsteth.toml` still has an empty production committee.
Unrelated resource scripts can read the profile, but `deploy-protocol` fails on the missing exit-book pauser and
`deploy-guardian` rejects a quorum larger than the configured committee. Replace both placeholders only with
reviewed production inputs.

Integrated and standalone deployment assign both books' sole initial `PAUSER_ROLE` to the configured protocol-wide Risk Steward Committee. `RESUMER_ROLE` starts empty. After a pause, the Lido DAO Agent must grant an explicit governance resumer before either book can resume. A per-market pauser must not receive this global authority implicitly.

Exit Books are direct, non-upgradeable deployments. Incompatible `Request` layouts require new book deployments; never reinterpret existing request storage.

If broadcast or verification is interrupted, immediately repeat the same target and arguments with `RESUME=true`. Do not send another transaction from the deployer first: Foundry resumes the saved nonce sequence.

Deploy a shared GuardianSignals instance for an existing run when needed:

```sh
make deploy-guardian CONFIG=mainnet RUN=mainnet-weth-wsteth GUARDIAN_GROUP=shared-group
```

Optional standalone deployments:

```sh
make deploy-vault-v2 CONFIG=mainnet RUN=mainnet-weth-wsteth VAULT=weth-wsteth ADAPTER=weth-wsteth
make deploy-bundler CONFIG=mainnet RUN=mainnet-weth-wsteth BUNDLER=mainnet
make deploy-exit-books CONFIG=mainnet RUN=mainnet-weth-wsteth
```

`deploy-vault-v2` needs an existing run: the adapter's Morpho and IRM-router immutables come from its
`protocol.toml`, and the vault is the adapter's own constructor immutable, so both are created in one broadcast.
Both are left unconfigured — curator, adapter registration and caps are the vault owner's calls.
`deploy-bundler` needs an existing run too: it deploys this run's own bundler stack — the stock `Bundler3`
dispatcher, the vendored `EthereumGeneralAdapter1` bound to the run's core, and the `LidoLendVaultAdapter`, both
adapters bound to that dispatcher — from the tokens `bundlers/<name>.toml` names, and records it as
`bundler.toml`. The protocol does not share Morpho's dispatcher: a bundle running through it would carry
whatever adapters Morpho registers there. Neither adapter holds any protocol role: they act for the bundle's
initiator and nothing else.
`deploy-exit-books` writes `exit-books.toml` without modifying the protocol artifact.

For a deliberately standalone Exit Book rollout, deploy the backbone with `exit_books = false`. The pauser and
maximum request lifetime may be omitted initially. Once reviewed, add those two fields while leaving
`exit_books = false`, then run `deploy-exit-books` against the same `RUN`. These fields are parsed even in false
mode, the nonzero pauser is subject to the same actor-separation checks, and the unchanged compatibility hash
allows the immutable protocol artifact to be reused. Changing a protocol-identity field requires a new run.

## Activate

Activation inputs are runtime EasyTrack motion choices, not deployment artifacts. No separate activation
artifact is generated or required. EasyTrack acceptance reads reviewed values and resolved addresses from
`deployed/<RUN>/markets/<market-name>.toml`. Deployment creates or reuses an immutable config for the recorded
curve parameters. After confirmation, activation applies that config to Adaptive Curve, routes it,
creates the market through `LidoLendOwner`, and registers the pauser committee on the protocol
CircuitBreaker — `pauser_committee` from the network config, recorded in `protocol.toml`; the Agent stands in
when the config sets none. Settlement enablement remains a runtime input.

The EasyTrack factory implementation and its registration are outside this repository; this repository deploys
the lending stack, records the immutable inputs, and verifies the result. A production rollout cannot be activated
until its governance proposal identifies the reviewed external factory/version and supplies the two runtime inputs
to acceptance independently of live contract state:

```sh
ACCEPTANCE_ENABLE_SETTLEMENT=true \
ACCEPTANCE_PAUSER_COMMITTEE=0x... \
make acceptance-run RUN=mainnet-weth-wsteth MARKET=weth-wsteth
```

Exit-book allow-listing is a separate governance action after market activation because `setMarketAllowed` rejects an uncreated market. Run activated-state acceptance only after allow-listing completes.

On a fork or devnet there is no EasyTrack, so `make activate-markets RUN=<run>` replays the motion for every
market recorded in the run, as the impersonated `EVMScriptExecutor` (read from the run's `protocol.toml`). Before
the first broadcast it parses every market artifact and checks every already-completed step for conflicts. A rerun
then resumes at the first missing IRM, market, CircuitBreaker, or exit-book action. It is never a substitute for
the motion on a real network.

## Verify

```sh
ACCEPTANCE_ENABLE_SETTLEMENT=true ACCEPTANCE_PAUSER_COMMITTEE=0x... \
  make acceptance-run RUN=mainnet-weth-wsteth MARKET=weth-wsteth
ACCEPTANCE_ENABLE_SETTLEMENT=true \
  make acceptance-run-multi RUN=mainnet-weth-wsteth MARKET_A=market-a MARKET_B=market-b
```

The multi-market simulation supplies disposable test pausers itself, so only its settlement choice is external.
The conventional local `deployed/fork` run uses the activation replay's fixed values when these inputs are unset.

Acceptance audits the exact initial-launch role topology. It is not a general audit of a deployment after later
governance grants; such a run needs a separately reviewed expected-role input before this suite can support it.

The read-only fork suites bind to a run the same way, reading `deployed/<RUN>/` directly:

```sh
make fork-run RUN=mainnet-weth-wsteth
```

## Fork provisioning

`test/fork/` needs a deployment to drive before any real network is live, so provisioning stands one up on a
local anvil fork of a real network. `FORK_CONFIG` defaults to `fork-<CONFIG>`: the fork config records test-only
role holders such as the Anvil Exit Book pauser without putting them in the production config. It still names
the real network in `network`, so fork tests resolve external addresses from that network's config. The
`fork-*` markets differ from production only where a test needs them to — for example a higher LLTV — and go
through the same scripts, artifact layout and activation as everything above. Its `[provision]` section is the
test-only deploy plan: it lists markets and standalone vault-v2 resources; oracle and guardian dependencies are
derived from those market configs.

```sh
make provision-fork RPC_URL=<archive-rpc>            # starts anvil; CONFIG=mainnet -> fork-mainnet
make provision-fork                                  # reuses a compatible anvil already on :8545
make test-fork-live                                 # the suites against it; re-runnable without re-provisioning
make provision-stop
```

`RPC_URL` is required only when provisioning must start anvil. A node already listening on `:8545` is reused only
if its chain id matches and it supports Anvil balance and account-impersonation RPCs. `PIN_BLOCK=<n>` pins the
upstream block for a newly started node and is rejected on reuse, where the requested origin cannot be proved.
The driver serializes provisioning runs and restores the previous `deployed/fork` if deployment fails. The
rollback state is either the prior run directory or a file recording that no prior run existed. The artifact
commit first atomically moves that state into committed trash, then removes the trash; an interruption during
removal therefore preserves the accepted new run, and the next invocation only finishes the cleanup. Anvil
ownership is matched by PID, process start time, a per-start ownership token, command, and port.

`deploy-vault-v2` verifies its pair through `verify-vault-v2`, a separate target because the pair is created
with `vm.deployCode` and `forge script --verify` cannot name those creations. A retry first validates the protocol,
vault and adapter metadata and their immutable cross-links, then submits either address to the explorer.

`make test-fork-provision RPC_URL=<archive-rpc>` chains provisioning and the fork suite. A private per-invocation
result handshake records whether that exact call started or reused Anvil; cleanup stops only a returned
PID/start-time/token identity. This remains correct across signals and concurrent calls. A compatible external
node or a still-running node from an earlier `provision-fork` is reused and left running.

The driver runs the `deploy-*` targets in the order this document describes — CircuitBreaker, oracles, the
backbone, the guardian registries, the markets, the vault-v2 pair, then `activate-markets` — and finishes with
`acceptance-run` per market, so provisioning reports success only once the deployed stack verifies against the
artifacts it wrote.
