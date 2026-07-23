# Deployment

Deployment scripts create an inert protocol; market activation is a separate EasyTrack motion.
Role ownership is documented in `docs/specs/roles.md`.

## Inputs and artifacts

Configuration lives under `script/config/`:

- `<config>.toml`: network, governance addresses, optional exit books, and market names;
- `markets/<market>.toml`: market parameters, roles, and artifact references;
- `oracles/<name>.toml`: oracle deployment;
- `guardians/<group>.toml`: GuardianSignals deployment.

`RUN` selects `deployed/<RUN>/`. Reuse the same `CONFIG` and `RUN` for every step. The directory contains
the manifest, input snapshots, transaction records, address registry, and activation plans. Existing
artifacts are never overwritten.

Set `RPC_URL` and `DEPLOYER_PRIVATE_KEY` in `.env`. Make deployment targets always broadcast.

### Address resolution

- `market.oracle = 0`: resolve `oracle_artifact` from `oracle-<name>.toml`.
- `market.guardian_signals = 0`: resolve `guardian_group` if already deployed; otherwise deploy it.
- Non-zero values pin existing addresses.
- `roles.pausers` contains the market's CircuitBreaker. One breaker may serve several markets.

## Deploy a protocol

1. Deploy the required CircuitBreakers externally with `ADMIN = evm_script_executor`, then set one under
   each market's `roles.pausers`.
2. Fill the protocol, market, oracle, and guardian configs.
3. Deploy each oracle:

   ```sh
   make deploy-oracle CONFIG=mainnet RUN=mainnet-weth-wsteth ORACLE=weth-wsteth
   ```

   Use `deploy-oracle-usdy` for `DeployUsdyOracle`.

4. Deploy the backbone and configured markets:

   ```sh
   make deploy-protocol CONFIG=mainnet RUN=mainnet-weth-wsteth
   ```

For the current single-WstETH-oracle flow, steps 3–4 can be combined:

```sh
make deploy-run CONFIG=mainnet RUN=mainnet-weth-wsteth ORACLE=weth-wsteth
```

The resulting registry is `deployed/<RUN>/registry.toml`.

## Add a market

Deploy its oracle first. If several markets share one GuardianSignals registry, deploy it once:

```sh
make deploy-guardian CONFIG=mainnet RUN=mainnet-weth-wsteth GUARDIAN_GROUP=shared-group
```

Then deploy the market:

```sh
make deploy-market CONFIG=mainnet RUN=mainnet-weth-wsteth MARKET=weth-wsteth
```

The market is appended to `registry.toml`; its activation inputs are written to
`activation-<market>.toml`.

## Activate a market

`LidoLendActivateMarket` executes atomically through the EVMScriptExecutor:

1. `AdaptiveCurveIrm.setMarketCurveParams`;
2. `IrmRouter.setMarketIrm`;
3. `LidoLendOwner.createMarket`;
4. `CircuitBreaker.registerPauser`.

The generated activation plan contains the deploy-known inputs. Fill its `pauser_committee` and
`enable_settlement` before assembling the motion.

Exit-book allow-listing is a separate `LidoLendSetMarketExitBookAllowed` motion.

## Verify

```sh
ACCEPTANCE_PAUSER_COMMITTEE=0x… \
  make acceptance-run CONFIG=mainnet RUN=mainnet-weth-wsteth MARKET=weth-wsteth
```

The acceptance suite checks deployment wiring, proxy admins, exact role holders, configured parameters,
inert state, and simulated activation.
