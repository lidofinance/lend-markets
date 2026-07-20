# Deployment runbook

Scripts compose the shared engine (`script/lib/ProtocolDeployer.sol`). Deploying gets you to an **inert**
stack; **activation** (binding a market on the core) is a governance EasyTrack motion, not a script. Role
split and CircuitBreaker wiring: `docs/specs/roles.md`.

There is **one protocol deployment**: one `LidoLend` core hosting every market as a storage entry, one
backbone of singletons around it. The `CONFIG` selector just picks the TOML describing
that deployment (`script/config/<name>.toml`), nothing more. (A second fully independent instance
would remain deployable from a second config by construction, but none is planned.)

## Scripts

Config files live under `script/config/`.

| Script | Deploys | Selector → config |
|---|---|---|
| `DeployProtocol.s.sol` | The whole protocol from scratch: backbone (core, `LidoLendOwner` facade, `IrmRouter`, `LidoLendMarketFactory` + `LidoLendMarketBuilder`, `RiskStewardDashboard`), optional exit books, and per-market guardian registry + inert components. | `CONFIG` → `<name>.toml` (+ the files it names) |
| `AddMarket.s.sol` | One market onto the live protocol: its guardian registry (via `LidoLendMarketBuilder.buildGuardianSignals`, its own transaction, when the config leaves it zero) + inert components (via `buildMarketContracts`). | `MARKET` → `markets/`, `guardians/<name>.toml`; `REGISTRY` → the deployed-address registry (optional — only for appending the result) |
| `DeployWstEthOracle.s.sol` / `DeployUsdyOracle.s.sol` | One standalone oracle behind a proxy; prints its address and records it to `deployed/oracle-<name>.toml`. | `ORACLE` → `oracles/<name>.toml` |
| `DeployGuardianSignals.s.sol` | One standalone `GuardianSignals` registry (for a guardian committee shared by a market group), via the same `buildGuardianSignals` entry point; prints its address and records it to `deployed/guardian-<name>.toml`. | `GUARDIANS` → `guardians/<name>.toml` (which also names the builder, `.builder`, pasted in after the protocol deploy) |
| `Devnet.s.sol` | Local devnet bring-up. | — |

A market's oracle is a **pre-deployed address**: deploy it first with its script, which records the address
to `deployed/oracle-<name>.toml`. With `markets/<name>.toml → [market].oracle` left zero, the market deploy
resolves it from that record automatically; a non-zero value pins an explicit address instead.

A market's guardian registry is likewise a **pre-deployed address** by the time the market itself deploys —
`LidoLendMarketBuilder.buildMarketContracts` only ever takes one in, never deploys or reuses on its own
initiative. Deploying (or reusing) it is a SEPARATE transaction, always before `buildMarketContracts`,
through the one path a registry is ever deployed: `LidoLendMarketBuilder.buildGuardianSignals`. It defaults
to **fresh per market**: `guardian_signals = 0` makes the orchestrator (`DeployProtocol` / `AddMarket`) call
`buildGuardianSignals` from `guardians/<name>.toml`, at the shared `GuardianSignals`
implementation. For a group of markets under one committee, deploy the registry once with
`DeployGuardianSignals` (same entry point) — its recorded address (`deployed/guardian-<name>.toml`) is then
picked up automatically by any market whose `guardian_signals` is left zero, mirroring the oracle resolver;
no manual paste needed. Sharing is always an explicit or auto-resolved address (bans stay separated by
market id).

## Deploy the protocol

1. Deploy the CircuitBreaker (external circuit-breaker repo, `admin = evm_script_executor`) — one instance for
   all markets. It is needed at deploy time to grant each controller's `PAUSER_ROLE`.
2. Fill `<name>.toml` (governance addresses, the `circuit_breaker` from step 1, `exit_books` flag, market
   list) and the per-market files it names (`markets/`, `guardians/`).
3. Deploy each market's oracle (the address is recorded and picked up by the market deploy automatically):
   ```sh
   ORACLE=weth-wsteth forge script script/DeployWstEthOracle.s.sol --rpc-url "$RPC_URL" --broadcast
   ```
4. Deploy the protocol (backbone + configured markets):
   ```sh
   # dry run
   CONFIG=mainnet forge script script/DeployProtocol.s.sol --fork-url "$MAINNET_RPC_URL" --sender "$DEPLOYER" -vvv
   # broadcast
   CONFIG=mainnet forge script script/DeployProtocol.s.sol --rpc-url "$RPC_URL" --broadcast --verify
   ```
   Addresses are logged; the registry is written to a dated `deployed/<name>-<unix-ms>.toml` (one per run —
   no auto-overwritten "current" alias, since the freshest deploy is not necessarily the relevant one; pass
   the file you mean explicitly). The deployer holds no role afterward.
5. External to this repo: whitelist the EasyTrack activation factory (DAO Voting).

## Add a market later

1. Deploy its oracle (step 2 above).
2. Optional: if it shares a guardian committee with other markets, deploy that registry once, up front:
   ```sh
   GUARDIANS=usdy forge script script/DeployGuardianSignals.s.sol --rpc-url "$RPC_URL" --broadcast
   ```
   Skip this when the market wants its own fresh registry — `guardian_signals` stays `0` and step 3 deploys
   one for it.
3. Build the market:
   ```sh
   MARKET=weth-wsteth REGISTRY=deployed/mainnet-<ts>.toml \
     forge script script/AddMarket.s.sol --rpc-url "$RPC_URL" --broadcast
   ```
   With `guardian_signals` left zero (and no record from step 2 under this market's name), this first calls
   `LidoLendMarketBuilder.buildGuardianSignals` — its own transaction — before `buildMarketContracts`.
4. Out come inert controller/vault + guardian registry at known addresses, recorded to `REGISTRY` (appended)
   or a standalone `deployed/market-<name>-<unix-ms>.toml` when `REGISTRY` is unset.

## Activation

Binding a deployed market is one atomic EasyTrack motion run by the `EVMScriptExecutor`, built by the
`LidoLendActivateMarket` factory (EasyTrack repo). Its calldata is
`(marketParams, curveParams, controller, pauserCommittee, enableSettlement)` — the market's curve params are
part of the reviewed motion, not the deploy — and it enacts, in this mandatory order:
`AdaptiveCurveIrm.setMarketCurveParams` → `IrmRouter.setMarketIrm` → `createMarket(params, controller,
enableSettlement)` → `CircuitBreaker.registerPauser`. (`createMarket`'s first `borrowRate` ping reverts while
the market is unrouted or its curve params are unset, so the factory hard-codes the order.)

Exit books are deliberately a SEPARATE motion (`LidoLendSetMarketExitBookAllowed`:
`morphoExitBook.setMarketAllowed(params)` + `erc4626ExitBook.setVaultAllowed(vault)`) — not every market gets
exit books.

## Verify

`test/acceptance/` is the only verify tool in this repo — there is no separate script, and nothing else
duplicates its checks. Point it at the node the deployment lives on and the registry the deploy produced:

```sh
ACCEPTANCE_RPC_URL="$RPC_URL" ACCEPTANCE_REGISTRY=deployed/mainnet-<ts>.toml \
  ACCEPTANCE_PAUSER_COMMITTEE=0x… MARKET=weth-wsteth \
  forge test --match-path "test/acceptance/*" -vvv
```

(`--fork-url` works instead of `ACCEPTANCE_RPC_URL` if you'd rather hand the fork to `forge test` directly.)
`ACCEPTANCE_REGISTRY` supplies the live deployed addresses; the expected values (governance holders, market
params, curve / activation / settlement config, guardian set) are read straight from the committed
`script/config/markets/<MARKET>.toml` and `guardians/<MARKET>.toml` — one source, no hand-maintained
duplicate. `ACCEPTANCE_PAUSER_COMMITTEE` is the activation-time pauser committee (only asserted post-motion).
Deploy addresses are never committed, so without `ACCEPTANCE_REGISTRY` (or a fork) the suite skips cleanly —
the event-completeness scan runs on `vm.eth_getLogs`, which only works against a real node.

Two tests, run at two different points in the lifecycle:

- **`MarketMotionReadiness`** — the gate BEFORE assembling the activation motion. Every component/role/config
  assertion, plus `_assertNotYetActivated()`. If this fails, the motion would have nothing sound to bind.
- **`MarketActivated`** — the check AFTER the motion executes. `setUp` replays `LidoLendActivateMarket` via the
  impersonated executor, then re-asserts the same component/role/config set, plus `_assertActivated()`.

Both share `AcceptanceBase`'s assertions:

1. **Backbone wiring** — cross-links the builder has no notion of (facade/router/dashboard/exit-book →
   core, builder's own immutables, controller/vault → core and loan token).
2. **`LidoLendMarketBuilder.validateMarketContracts` / `validateGuardianSignals`** — called directly, not
   re-implemented: impl codehashes, proxy admins, marketId/guardian bindings, every listed role holder
   present, and neither the builder nor the factory holding anything. A revert here fails the test outright.
3. **Event-based role-holder completeness** — `vm.eth_getLogs` from each record's `deployed_block` (a
   registry from `DeployProtocol` / `AddMarket` carries the real one; the fallback file uses `0`) reconstructs
   the CURRENT holder set of every `AccessControl` role on the controller, guardian registry, facade,
   dashboard, and both exit books, from `RoleGranted` / `RoleRevoked` logs, and asserts it against the
   expected set exactly — no extra holder, no missing one. Inside a `buildMarketContracts` /
   `buildGuardianSignals` call this is guaranteed by construction (see that contract's NatSpec); this scan is what closes the same
   guarantee for the window AFTER deploy and BEFORE activation, where a mutation is only possible from a
   `DEFAULT_ADMIN_ROLE` holder and always leaves a log.
4. **Activation state** — bound or not, per the test.

## Open items

- No `Upgrade.s.sol`; proxy upgrades are out of scope for this prototype.
- The `LidoLendActivateMarket` EasyTrack factory exists (EasyTrack repo) but is not whitelisted yet — that is
  a DAO Voting step outside this repo.
- `DeployProtocol` / `AddMarket` emit a per-market `deployed/activation-<name>-<unix-ms>.toml` with the
  deploy-known motion inputs (marketParams, curveParams, controller); `pauser_committee` and
  `enable_settlement` are activation-time governance decisions, left as flagged `# TODO` placeholders for the
  operator to fill before assembling the motion.
