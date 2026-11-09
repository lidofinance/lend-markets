# Deployment

Deployment inputs live in concrete Solidity scripts under `script/deployment/<network>/`. A script inherits a
shared deployment base and supplies typed parameters. Markets are deployed inert; activation remains a separate
Easy Track motion. This repository does not deploy Easy Track or its executor.

## Scripts and shared operations

- `DeployProtocolBase` / `ProtocolDeployment`: protocol backbone and a new or reused CircuitBreaker.
- `DeployMarketBase` / `MarketDeployment`: one market, with a new or reused price feed and guardian registry.
  Several market scripts can inherit the same generated protocol address provider.
- `DeployExitBooksBase`: exit books, independently of protocol and market deployment.
- `DeployBundlerBase` and `DeployVaultV2Base` / `PeripheryDeployment`: optional periphery.

These operations are also used by fork fixtures. Production contracts under `src/` and pinned dependencies are
unchanged. The old TOML-driven deployment entrypoints and `deploy-all` shell driver have been removed.

`mainnet/DeployWethWsteth.s.sol` still has an empty production committee and draft economic parameters. Supply
reviewed values in the concrete script before deploying. Guardian membership, quorum, tokens, price feed,
activation/settlement parameters and IRM curve are Solidity values; no config file is read to construct them.

A new market needs one concrete `.s.sol` file inheriting `DeployMarketBase`, implementing `_deploymentProtocol`,
`_deploymentPlan`, `_deployPriceFeed` and `_checkPriceFeed`. The WETH/wstETH script demonstrates these hooks.
`plan.name` names both its artifact and its integration-test role. Set `plan.market.oracle` or
`plan.market.guardianSignals` to reuse a reviewed deployment; zero creates that resource. Reused contracts are
validated before market deployment. Set `ProtocolPlan.circuitBreaker` to reuse a CircuitBreaker.

## Simulate, broadcast, record

```sh
make deploy-script SCRIPT=script/deployment/mainnet/DeployProtocol.s.sol RPC_URL=<rpc>
```

This simulates only. `DEPLOYER_SENDER=<address>` can select the simulation sender. No deployment artifact is
published by a simulation. Forge keeps its normal dry-run transaction report under `broadcast/`.

Broadcast is enabled only by an explicit Make command-line argument:

```sh
make deploy-script SCRIPT=script/deployment/mainnet/DeployProtocol.s.sol \
  RUN=<run> RPC_URL=<rpc> BROADCAST=true \
  DEPLOYER_SENDER=<address> DEPLOYER_ACCOUNT=<encrypted-keystore>
```

Import a keystore using `cast wallet import --interactive <name>`. Forge prompts for its password. An unlocked
local node can use `DEPLOYER_SENDER` with an empty `DEPLOYER_ACCOUNT`. Raw private keys are not Make inputs.
`VERIFY=true` enables Forge explorer verification and requires `ETHERSCAN_API_KEY`. Contracts created through
`vm.deployCode` may require explicit `forge verify-contract` with their Solidity constructor arguments; the
record contains the addresses and inputs. `RESUME=true` resumes Forge's pending broadcast without rerunning the
simulation. Resume the same script, run, chain and sender; do not start another broadcast of that script while
one is pending.

After a successful broadcast, Make invokes `record-deployment`. It checks the native Forge report's chain,
run identity, transaction count, successful receipts and canonical receipt blocks against the RPC, rejects failed/pending transactions, and checks
that the recorded contracts have code. Only then does it archive the report and write the result. If recording
was interrupted after the broadcast completed, retry it without sending transactions:

```sh
make record-deployment SCRIPT=<same-script.s.sol> RUN=<same-run> RPC_URL=<rpc>
```

An existing deployment result is never overwritten. Keep the native broadcast report for retries. The recording
check establishes transaction completion; run acceptance tests separately for full wiring, bytecode, parameters
and role-topology verification.

## Results and dependency addresses

`deployed/<run>/` contains results, not deployment inputs:

```text
protocol.toml                 # typed addresses and protocol plan
markets/<name>.toml            # typed addresses, market plan and committee
exit-books.toml                # independent books and their plan, when deployed
bundler.toml                   # optional bundler and its token inputs
vaults/<name>.toml             # optional Vault V2 + adapter and their inputs
transactions/<kind>-<name>.json # native Forge broadcast report, including receipts
```

Each TOML has a versioned header with run, chain, sender, resource identity and the simulation's starting block.
There are no config hashes, config inheritance or resource-name lookups. Foundry serializes typed structs and
reads them back with a named ABI schema. The starting block bounds historical event scans; actual transaction
blocks and hashes are in the archived receipts.

Generate the inheritable protocol provider after recording the protocol:

```sh
make export-deployment SCRIPT=script/deployment/GenerateProtocol.s.sol RUN=<run>
```

It writes `script/deployment/generated/<run>/Protocol.sol`. Import this provider in the concrete market, book
or periphery script. It contains addresses as Solidity values; deployment does not parse TOML to resolve them.
The selected run's recorded core/chain are checked before a dependent broadcast to prevent writing results
under an unrelated protocol. Books may also be recorded independently in their own run.

```sh
make deploy-script SCRIPT=<network-market.s.sol> RUN=<run> RPC_URL=<rpc> \
  BROADCAST=true DEPLOYER_SENDER=<address> DEPLOYER_ACCOUNT=<keystore>
make deploy-script SCRIPT=<network-exit-books.s.sol> RUN=<run> RPC_URL=<rpc> \
  BROADCAST=true DEPLOYER_SENDER=<address> DEPLOYER_ACCOUNT=<keystore>
make export-deployment SCRIPT=script/deployment/GenerateExitBooks.s.sol RUN=<run>
```

Both exporters also read historical TOML artifacts. Neither exporter silently selects mainnet. Update the
concrete script's import when using a different run; a preceding simulation does not change dependency addresses.

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

## State Mate drafts

`make state-mate-config RUN=<run> MARKET=<market> RPC_URL=<rpc>` generates one draft:
`deployed/<run>/state-mate/generated/markets/<market>.yaml`, plus the generated ABI cache.
It checks the selected market and its bindings on shared contracts. Other markets and shared pauser counts
are outside its scope. The reviewed per-market config lives at `deployed/<run>/state-mate/markets/<market>.yaml`;
the common protocol config remains separate.

The Solidity `RecordedDeployment` reader supplies addresses and parameters for both historical and typed
artifacts. No market-config overlay is read. `OUT_DIR` changes the draft root.

Without `STATE_MATE_ACTIVATION`, the selected market is expected to be inert. To generate its activated state,
pass `STATE_MATE_ACTIVATION=<reviewed.json>` containing its motion values:

```json
{
  "<market-name>": {
    "fee": "100000000000000000",
    "pauser": "<reviewed-pauser-address>",
    "steward": "<reviewed-steward-address-or-zero-address>",
    "enableSettlement": true,
    "allowExitBooks": true
  }
}
```

`fee` is an integer WAD ratio; the example means 10%. Entries for other markets do not affect the selected
market. Generate each market separately: one can be live while another remains inert.
Regeneration replaces only that market's draft. The old generator's `post-deploy.yaml`, `live.yaml` and
`post-activation-fork.yaml` outputs under `OUT_DIR` are removed only when their generated-file header is present.
Manually maintained files are not overwritten or removed.

Review and merge the draft into the maintained market configuration, including the separately reviewed Safe
checks. Proxy implementation addresses come from RPC for ABI lookup; validate them against the audited
deployment. `FORK_BLOCK` pins both the export and implementation reads.

## Audit checksums

Run `make audit-checksums` or `make audit-checksums REF=<git-ref>` to compare audited source digests.
