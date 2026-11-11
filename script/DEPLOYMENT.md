# Deployment

Deployment inputs live in concrete Solidity scripts under `script/deployment/<network>/`. Each runnable script controls its own broadcast boundary and calls
shared deployment functions with typed parameters. Markets are deployed inert; activation remains a separate
Easy Track motion. This repository does not deploy Easy Track or its executor.

## Scripts and shared operations

- `ProtocolDeployment` / `ProtocolDeployer`: protocol backbone and a new or reused CircuitBreaker.
- `MarketDeployment`: market creation and dependency validation.
- `mainnet/WethWstethMarket.sol`: WETH/wstETH parameters and price-feed deployment/validation, shared with tests.
- `ProtocolDeployer._deployExitBooks`: independent exit-book deployment.
- `PeripheryDeployment`: bundler and Vault V2 helpers.

The concrete `.s.sol` files inherit `Script` and the shared operations they use. Only these entrypoints contain
`run()` and `startBroadcast`/`stopBroadcast`. Fork fixtures inherit shared operations, not runnable scripts.
`mainnet/Protocol.sol` supplies protocol addresses and deployment parameters; `mainnet/ExitBookPlan.sol` supplies
exit-book parameters. These libraries contain data functions and require no inheritance.

These operations are also used by fork fixtures. Production contracts under `src/` and pinned dependencies are
unchanged. The old TOML-driven deployment entrypoints and `deploy-all` shell driver have been removed.

`mainnet/DeployWethWsteth.s.sol` uses the WETH/wstETH launch parameters and the Risk Steward as its sole guardian.
The three APR-dependent rates still need the approved launch snapshot. Guardian membership, quorum, tokens, price feed,
activation/settlement parameters and IRM curve are Solidity values; no config file is read to construct them.

A new market needs a reusable recipe inheriting `MarketDeployment`, with a typed plan and implementations of
`_deployPriceFeed` and `_checkPriceFeed`, plus a small `.s.sol` entrypoint that supplies protocol addresses and
calls `_deployMarket` inside its broadcast boundary. Tests use the reusable recipe directly.
`plan.name` identifies the market and its integration-test role. Set `plan.market.oracle` or
`plan.market.guardianSignals` to reuse a reviewed deployment; zero creates that resource. Reused contracts are
validated before market deployment. Set `ProtocolPlan.circuitBreaker` to reuse a CircuitBreaker.

## Simulate and broadcast

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

Maintain dependency addresses in `script/deployment/<network>/Protocol.sol` by hand after verifying the native
Forge receipts and deployed addresses. The Mainnet recipes use the existing Mainnet protocol addresses.
Historical Hoodi addresses remain in its recorded artifacts. A new deployment needs its own reviewed provider before
it is reused by markets or periphery. No generator or deployment config parser runs in the deployment path.

The scripts do not write or export application artifacts. Preserve the successful Forge broadcast report,
check chain, receipt status, block hashes and deployed code, then record the addresses and reviewed parameters
in `deployed/<run>/` manually when artifact-backed tests are needed. Do not replace existing deployment history.

The readers accept historical TOML and the typed records defined in `DeploymentRecord.sol`. The typed layout is:

```text
protocol.toml                  # protocol addresses and plan
markets/<name>.toml             # market addresses, plan and committee
exit-books.toml                # optional books and their plan
bundler.toml                   # optional bundler and its token inputs
vaults/<name>.toml              # optional Vault V2 and adapter
transactions/<kind>-<name>.json # reviewed native Forge report
```

Typed records include a versioned header with run, kind, name, chain, sender and block number. Use a block no
later than the deployment transactions for event scans. Copy parameters from the reviewed recipe and addresses
from successful receipts; acceptance tests verify them against the chain. Fresh fork tests use the shared
Solidity deployment functions directly and do not require these files.

## Fork and acceptance checks

```sh
make test-fork RPC_URL=<mainnet-archive-rpc>
make test-fork RUN=<run> RPC_URL=<deployment-rpc>
make test-fork RUN=<run> PREPARE=false RPC_URL=<deployment-rpc>
make test-deployment RPC_URL=<mainnet-archive-rpc>
```

Without command-line `RUN`, `test-fork` creates a fresh protocol, two WETH/wstETH markets, books, bundler and
Vault V2 inside each suite's Forge fork. No Anvil, artifact directory or shell provisioning is required.
With `RUN`, it reads recorded results, prepares missing/inert markets, and tests the resulting private state.
With `PREPARE=false`, it tests existing state without preparing it. `RUN` and `PREPARE` from `.env` or the
shell environment do not select the mode. Make sets `ARTIFACTS_DIR` and `PREPARE_MARKETS` internally.
`FORK_BLOCK=<block>` optionally pins the source state. The fresh and preparation recipes currently support
mainnet WETH/wstETH; USDY is omitted from the fresh fixture. Other chains/pairs need a concrete fixture recipe.

| Recorded state | Preparation inside the Forge fork |
| --- | --- |
| Protocol only | Deploy the required missing market, activate and preseed |
| Inert market | Validate identity, initial roles and plan, then activate and preseed |
| Active market | Validate identity and seed/route/pauser setup; preserve live parameters and balances |
| Missing code at a recorded address | Fail without replacing the deployment |

Several markets share one protocol. Extend the typed required-market list when another market is reviewed.
Preparation impersonates the executor inside Forge. Real Easy Track factory, preseed and motion flows remain
integration tests of the Easy Track repository. The external regression action calls `make test-fork RUN="$RUN"`
against its caller's post-vote RPC; it never changes that source node.

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

## Historical compatibility

`script/legacy/` holds the readers and verification helpers for existing artifacts. Historical configs under
`script/config/` are retained for those readers and pending-governance rehearsals, not for new
Solidity deployment. New-format market results can be added to an existing historical protocol run.

For integration tests use `make test-fork RUN=<run>`; preparation happens inside the private Forge fork.
Production activation remains the reviewed Easy Track motion.

`apply-pending`, `pending-stop` and `test-pending` retain the separate local-Anvil workflow for rehearsing a
pending governance transaction. `test-pending` passes `PREPARE=false` to verify exactly the post-action state.

## State Mate

Maintain protocol and per-market State Mate configurations by hand under `deployed/<run>/state-mate/`.
Keep market-specific checks in `markets/<market>.yaml` and shared protocol checks in the protocol configuration.
Review addresses, proxy implementations, Safe membership and thresholds, initial roles and approved motion
parameters before running State Mate. Each market configuration must reflect that market's activation state.

## Audit checksums

Run `make audit-checksums` or `make audit-checksums REF=<git-ref>` to compare audited source digests.
