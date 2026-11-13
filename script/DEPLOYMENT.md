# Deployment

Deployment inputs live in concrete Solidity scripts under `script/deployment/<network>/`. Each runnable script controls its own broadcast boundary and calls
shared deployment functions with typed parameters. Markets are deployed inert; activation remains a separate
Easy Track motion. This repository does not deploy Easy Track or its executor.

## Scripts and shared operations

- `ProtocolDeployment` / `ProtocolDeployer`: protocol backbone and a new or reused CircuitBreaker.
- `MarketDeployment`: market creation, price-feed proxy deployment/validation and address output.
- `WethWstethMarket` at the start of `mainnet/DeployWethWsteth.s.sol`: shared WETH/wstETH parameters and price-feed functions.
- `ProtocolDeployer._deployExitBooks`: independent exit-book deployment.
- `PeripheryDeployment`: bundler and Vault V2 helpers.

The concrete `.s.sol` files inherit `Script` and the shared operations they use. Only these entrypoints contain
`run()` and `startBroadcast`/`stopBroadcast`. Fork fixtures inherit the shared recipe class; only the runnable class inherits `Script` and exposes `run()`.
`mainnet/artifacts/Protocol.sol` supplies recorded protocol addresses. New protocol parameters are defined
at the start of `mainnet/DeployProtocol.s.sol`.
`mainnet/DeployExitBooks.s.sol` defines the exit-book parameters directly; shared types live in `DeploymentTypes.sol`.

These operations are also used by fork fixtures. Production contracts under `src/` and pinned dependencies are
unchanged. The old TOML-driven deployment entrypoints and `deploy-all` shell driver have been removed.

`mainnet/DeployWethWsteth.s.sol` uses the WETH/wstETH launch parameters and the Risk Steward as its sole guardian.
The three APR-dependent rates still need the approved launch snapshot. Guardian membership, quorum, tokens, price feed,
activation/settlement parameters and IRM curve are Solidity values; no config file is read to construct them.

A new market needs a reusable recipe inheriting `MarketDeployment`, with typed parameters and implementations of
`_deployPriceFeedImplementation` and `_checkPriceFeed`, and a small runnable class in the same `.s.sol` file that supplies protocol addresses and
calls `_deployMarket` inside its broadcast boundary. Tests use the reusable recipe directly.
`parameters.name` identifies the market and its integration-test role. Set `parameters.market.oracle` or
`parameters.market.guardianSignals` to reuse a reviewed deployment; zero creates that resource. Reused contracts are
validated before market deployment. Set `ProtocolParameters.circuitBreaker` to reuse a CircuitBreaker.

## Simulate and broadcast

`make deploy` builds and runs one concrete script. It simulates unless `BROADCAST=true` is passed explicitly
on the Make command line; environment and `.env` values cannot enable broadcasting.

```sh
make deploy SCRIPT=script/deployment/mainnet/DeployWethWsteth.s.sol \
  RPC_URL=<rpc> DEPLOYER_SENDER=<deployer>
make deploy SCRIPT=script/deployment/mainnet/DeployWethWsteth.s.sol \
  RPC_URL=<rpc> DEPLOYER_SENDER=<deployer> BROADCAST=true DEPLOYER_ACCOUNT=<keystore>
```

The recipe controls its parameters and output paths. For additional Forge options, call the script directly.

Run the concrete recipe directly with Forge. Build first: the shared deployment helpers use compiled artifacts
for dependencies with a different Solidity version.

```sh
forge build
forge script script/deployment/mainnet/DeployProtocol.s.sol --rpc-url <rpc> --sender <deployer> -vv
forge script script/deployment/mainnet/DeployWethWsteth.s.sol --rpc-url <rpc> --sender <deployer> -vv
forge script script/deployment/mainnet/DeployExitBooks.s.sol --rpc-url <rpc> --sender <deployer> -vv
```

Without `--broadcast`, Forge simulates. Each script returns its typed deployment result and Forge keeps its
native transaction report under `broadcast/`.

For a reviewed deployment, import a keystore with `cast wallet import --interactive <name>` and run:

```sh
forge script <network-recipe.s.sol> --rpc-url <rpc> \
  --sender <deployer> --account <keystore> --broadcast -vv
```

Add `--verify` with `ETHERSCAN_API_KEY` configured for explorer verification. Contracts created through
`vm.deployCode` may need a separate `forge verify-contract` with their constructor arguments. Use `--resume`
only for the same pending broadcast, script, chain and sender. An unlocked local node uses `--unlocked`
instead of `--account`.

## Results and dependency addresses

Maintain dependency addresses in `script/deployment/<network>/artifacts/Protocol.sol` by hand after checking the
successful Forge receipts and deployed code. `ExitBooks.sol` and `Bundler.sol` in the same folder hold their
recorded addresses. New deployment inputs stay in the scripts; recorded expectations stay in `artifacts/`.

`script/deployment/<run>/artifacts/Deployment.sol` provides `snapshot()`, returning a `DeploymentSnapshot`:
protocol addresses, expected parameters, optional books/bundler/vaults and the recorded markets. Mainnet and
Hoodi descriptions are checked in. Add a market's actual addresses and deployment block after deployment;
keep its approved parameters in its Solidity recipe. Each market carries its price-feed sources and optional
collateral blocklist; token addresses belong to its market parameters. Do not infer expected values from the contracts being tested.

With `--broadcast`, the four entrypoints write flat address lists under `deployed/<network>/`:
`protocol.toml`, `markets/<market>.toml`, `exit-books.toml` or `bundler.toml`. Market output also includes its ID.
Existing files are not overwritten; dry runs and tests do not write these lists. For another run, set the output
directory explicitly in its concrete recipe.

Forge executes `run()` before sending transactions. The address list is therefore written before broadcast
confirmation and can exist even if submission fails. Check the native Forge receipts and deployed code before
copying addresses into the Solidity description. Existing TOML files remain unchanged; deployment and test inputs
are Solidity only. Output uses standard `serializeAddress` / `writeToml`, without schemas or config hashes.

For an external CI run, supply the same `Deployment.sol` under `script/deployment/<run>/artifacts/`, with the actual
addresses and expected parameters of the caller's prepared state. Then run `make test-fork RUN=<run>` against
its RPC. Register the run in `RecordedDeployment.load` with an import and a call to its `snapshot()` function.
The description is a Solidity library, compiled with the tests. Unknown runs, the wrong chain and missing core code fail.
The caller must supply Solidity; a directory of TOML artifacts is no longer a test input.

## Fork and acceptance checks

```sh
make test-fork RPC_URL=<mainnet-archive-rpc>
make test-fork RUN=<run> RPC_URL=<deployment-rpc>
make test-fork RUN=<run> PREPARE=false RPC_URL=<deployment-rpc>
make test-deployment RPC_URL=<mainnet-archive-rpc>
```

Without command-line `RUN`, `test-fork` creates a fresh protocol, two WETH/wstETH markets, books, bundler and
Vault V2 inside each suite's Forge fork. No Anvil, artifact directory or shell provisioning is required.
With `RUN`, it reads the Solidity description, prepares missing/inert markets, and tests the resulting private state.
With `PREPARE=false`, it tests existing state without preparing it. `RUN` and `PREPARE` from `.env` or the
shell environment do not select the mode. Make sets `DEPLOYMENT_RUN` and `PREPARE_MARKETS` internally.
`FORK_BLOCK=<block>` optionally pins the source state. The fresh and preparation recipes currently support
mainnet WETH/wstETH; USDY is omitted from the fresh fixture. Other chains/pairs need a concrete fixture recipe.

| Recorded state | Preparation inside the Forge fork |
| --- | --- |
| Protocol only | Deploy the required missing market, activate and preseed |
| Inert market | Validate identity, initial roles and parameters, then activate and preseed |
| Active market | Validate identity and seed/route/pauser setup; preserve live parameters and balances |
| Missing code at a recorded address | Fail without replacing the deployment |

Several markets share one protocol. Extend the typed required-market list when another market is reviewed.
Preparation impersonates the executor inside Forge. Real Easy Track factory, preseed and motion flows remain
integration tests of the Easy Track repository. External callers run `make test-fork RUN="$RUN"`
against their post-vote RPC after supplying and registering a Solidity description; this never changes that source node.
The regression action starts Anvil at the caller's post-vote block with `--fork-state-by-number` for Hardhat
compatibility, runs the Forge suites against Anvil, and stops it on exit.
Callers using the old TOML export must migrate before using this branch.

Verify an inert or activated deployment independently:

```sh
make acceptance-run RUN=<run> MARKET=<name> RPC_URL=<deployment-rpc> \
  ACCEPTANCE_PAUSER_COMMITTEE=<reviewed-address> ACCEPTANCE_ENABLE_SETTLEMENT=true \
  ACCEPTANCE_STEWARD=<reviewed-steward-or-zero-address> \
  ACCEPTANCE_FEE=<approved-fee-in-wad> \
  ACCEPTANCE_MIN_CORE_SEED_SHARES=<reviewed-core-share-threshold> \
  ACCEPTANCE_MIN_VAULT_SEED_SHARES=<reviewed-vault-share-threshold>
make acceptance-run-multi RUN=<run> MARKET_A=<first> MARKET_B=<second> RPC_URL=<deployment-rpc> \
  ACCEPTANCE_ENABLE_SETTLEMENT=true
```

Acceptance checks initial-launch wiring, exact role sets, bytecode and recorded parameters. It is not an audit
of later governance role changes. Activated checks require `ACCEPTANCE_STEWARD`; use the zero address only when the reviewed motion appoints no steward.
Activated checks also require `ACCEPTANCE_FEE` and positive `ACCEPTANCE_MIN_CORE_SEED_SHARES` /
`ACCEPTANCE_MIN_VAULT_SEED_SHARES`. Approve these values from the motion and preseed calculation before running;
they are not inferred from live balances. Fee is compared exactly; both seed balances at `0x000000000000000000000000000000000000dEaD`
must meet the reviewed share thresholds. These are share units, not loan-token amounts; the current Preseeder
requires at least `1000000000` locked shares in each position. Transaction-level funding amounts remain part
of the Easy Track motion replay and receipt checks.
Readiness and activated suites choose their applicable state; the two-market
suite rehearses sequential activation. It does not publish those transactions.

## Pending governance

`apply-pending`, `pending-stop` and `test-pending` retain the separate local-Anvil workflow for rehearsing a
pending governance transaction. `test-pending` passes `PREPARE=false` to verify exactly the post-action state.

## State Mate

Maintain protocol and per-market State Mate configurations by hand under `deployed/<run>/state-mate/`.
Keep market-specific checks in `markets/<market>.yaml` and shared protocol checks in the protocol configuration.
Review addresses, proxy implementations, Safe membership and thresholds, initial roles and approved motion
parameters before running State Mate. Each market configuration must reflect that market's activation state.

## Audit checksums

Run `make audit-checksums` or `make audit-checksums REF=<git-ref>` to compare audited source digests.

### Launch without Exit Book access

For a market that must remain outside both Exit Book allowlists, pass
`ACCEPTANCE_ALLOW_EXIT_BOOKS=false` to `make acceptance-run`. Activated acceptance then checks
that the market and vault are not allowed. The default remains `true`. The pauser test runs in
both modes; factory registration does not change a market allowlist.

The local activation helper is [`docs/deployment/test-activation.sh`](../docs/deployment/test-activation.sh).
It accepts only a loopback Anvil fork, registers the seven recorded factories when missing, and
replays the activation motion. This is not a test of the full prerequisite DAO vote.
Run `bash docs/deployment/test-activation.sh --help` for its inputs.

Market verification configs are in `deployed/mainnet/state-mate/markets/weth-wsteth.yaml` and
`deployed/mainnet/diffyscan/markets/weth-wsteth/`. Fill the deployment addresses and approved
expectations before use. See [State Mate on a fork](../docs/deployment/fork-state-mate.md).
