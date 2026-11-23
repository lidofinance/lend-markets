# Deployment

Deployment inputs live in concrete Solidity scripts under `script/deployment/<network>/`. Each runnable script controls its own broadcast boundary and calls
shared deployment functions with typed parameters. Markets are deployed inert; activation remains a separate
Easy Track motion. This repository does not deploy Easy Track or its executor.

## Scripts and shared operations

- `DeployCoreBase`: the base of each network's core script (`mainnet/DeployCoreMainnet.s.sol`,
  `hoodi/DeployCoreHoodi.s.sol`): the protocol backbone and a new or reused CircuitBreaker, through
  `ProtocolDeployer` (`script/lib/`), which the exit-book scripts also use.
- `DeployExitBooksBase`: the base of each network's exit-book script, over the network's recorded protocol.
- `DeployMarketBase`: the base of each market script under `<network>/markets/`: market creation, and the protocol
  and price-feed checks.
- `DeployTrailingAnchorMarketBase`: the base of a market script over a trailing anchor oracle, which deploys the
  oracle and hands it to the Agent.
- `script/lib/`: `ProtocolDeployer` (protocol and exit-book deployment) and `RecordedProtocol` (the records of the chain
  in use: its protocol, read from its core script, and its Easy Track activation factory, from its
  `EasyTrack<Network>.sol`).

A script is named `Deploy<Component><Network>` and its base `Deploy<Component>Base`. The concrete `.s.sol` files inherit `Script` and the shared operations they use. Only these entrypoints contain
`run()` and `startBroadcast`/`stopBroadcast`. Fork tests call the scripts' `getOrDeploy()` without a broadcast.
Each script overrides `getConfig()`, its deploy inputs, and `getDeployment()`, its recorded addresses; `run()` refuses a
component that `getDeployment()` records. Each type lives in the script or library that owns it.

These operations are also used by fork fixtures. Production contracts under `src/` and pinned dependencies are
unchanged. The old TOML-driven deployment entrypoints and `deploy-all` shell driver have been removed.

`mainnet/markets/DeployWethWstethMainnet.s.sol` uses the WETH/wstETH launch parameters and the Risk Steward as its sole guardian.
The three APR-dependent rates still need the approved launch snapshot. Guardian membership, quorum, tokens, price feed,
activation/settlement parameters and IRM curve are Solidity values; no config file is read to construct them.

A new market is one script under `script/deployment/<network>/markets/` that inherits `DeployMarketBase` and overrides
`getDeployConfig()` (its parameters), `getActivationMotionConfig()` (its activation choices),
`getOrDeployPriceOracle()` and, once the market is deployed, `getDeployment()` (its addresses and block).
`test/fork/helpers/ForkNetworks.sol` imports it, and the Makefile runs its fork suites as
`test-fork-<network>-<market>`. Tests call the script's `getOrDeploy` and `deploy` without a broadcast.
Set `parameters.market.oracle` or
`parameters.market.guardianSignals` to reuse a reviewed deployment; zero creates that resource. Reused contracts are
validated before market deployment. Record a CircuitBreaker in the core script's `getDeployment()`, without a core, to
reuse it.

A market over a trailing anchor oracle, such as `DeployUsdcUsdyMainnet`, deploys its adapter with
`_deployTrailingAnchorOracle` behind a proxy, initialized in the proxy's constructor with the deployer as its first
admin, the launch parameters and a seed range; a source price outside the seed range stops the run. The reviewer
checks that the seed range is narrow around the live source price, since the seed price becomes the anchor and the
base price. The deployer then grants `DEFAULT_ADMIN_ROLE`, `MANAGER_ROLE` and `PRICE_ACCEPTOR_ROLE` to the Agent and
renounces its admin role.
A reused oracle must be an Agent-administered proxy over an implementation with the code of a new build from the
script.

## Simulate and broadcast

`make deploy` builds and runs one concrete script. It simulates unless `BROADCAST=true` is passed explicitly
on the Make command line; environment and `.env` values cannot enable broadcasting.

```sh
make deploy SCRIPT=script/deployment/mainnet/markets/DeployWethWstethMainnet.s.sol \
  RPC_URL=<rpc> DEPLOYER_SENDER=<deployer>
make deploy SCRIPT=script/deployment/mainnet/markets/DeployWethWstethMainnet.s.sol \
  RPC_URL=<rpc> DEPLOYER_SENDER=<deployer> BROADCAST=true DEPLOYER_ACCOUNT=<keystore>
```

The recipe controls its parameters and output paths. For additional Forge options, call the script directly.

Run the concrete recipe directly with Forge. Build first: the shared deployment helpers use compiled artifacts
for dependencies with a different Solidity version.

```sh
forge build
forge script script/deployment/mainnet/DeployCoreMainnet.s.sol --rpc-url <rpc> --sender <deployer> -vv
forge script script/deployment/mainnet/markets/DeployWethWstethMainnet.s.sol --rpc-url <rpc> --sender <deployer> -vv
forge script script/deployment/mainnet/DeployExitBooksMainnet.s.sol --rpc-url <rpc> --sender <deployer> -vv
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

Maintain each component's recorded addresses in its script's `getDeployment()` by hand after checking the successful
Forge receipts and deployed code. Deployment inputs stay in the scripts' `getConfig()` and `getDeployConfig()`.

The fork suites take each script's record through its `getOrDeploy()`, which returns the record, failing where its
contracts have no code at the fork's block, and deploys what is not recorded without a broadcast. Add a market's
actual addresses and deployment block to its script's `getDeployment()` after deployment. `activationParams()` is the
activation motion's calldata, and `activationScript()` the EVMScript of the motion's calls without the preseed; their
approved choices stay in the script's `getActivationMotionConfig()`.

A run's addresses are its `run()` result, which Forge prints and keeps with the transactions and receipts in
`broadcast/<script>/<chainId>/run-latest.json`. Check those receipts and the deployed code before copying the
addresses into a script's `getDeployment()`, and keep the file as the package's `*.broadcast.json` under
`deployed/<network>/`.

An external CI run names a network, `mainnet` or `hoodi`, and runs `make test-fork RUN=<network>` against its RPC.
Unknown networks, the wrong chain and missing core code fail.

## Fork checks

```sh
make -k test-fork
make test-fork-<network>-<market>
make test-fork RUN=<network> RPC_URL=<deployment-rpc>
make test-fork RUN=<network> PREPARE=false RPC_URL=<deployment-rpc>
make test-deployment RPC_URL=<mainnet-archive-rpc>
```

`test-fork` runs the fork suites once per market, each in its own Forge run; `-k` goes on past a failing market. A
network's markets need its RPC variable (`RPC_URL` for mainnet, `HOODI_RPC_URL` for Hoodi) and fail without it; they
run at `FORK_BLOCK` or `HOODI_FORK_BLOCK` when set, else at the latest block; a market not deployed at the block is deployed by its script
over the network's protocol. No Anvil, artifact directory or shell provisioning is required.
With `RUN`, it binds each recorded market of the network at the RPC's latest block and creates an inert one; with
`PREPARE=false`, it tests existing state without preparing it and skips an inert market. Only a command-line `RUN`
selects; Make sets `FORK_DEPLOY_SCRIPT`, `FORK_RUN` and `FORK_RUN_PREPARE` internally.

| Recorded state | Preparation inside the Forge fork |
| --- | --- |
| Inert market | Activate and preseed |
| Active market | Use as it is |
| Missing code at a recorded address | Fail without replacing the deployment |

A market the core lacks is created by its activation motion where Easy Track registers the network's activation
factory, recorded in `EasyTrack<Network>.sol`: the motion in flight whose calldata is the script's
`activationParams()`, else a new one from the factory's trusted caller, enacted once its duration has passed; its
preseed seeds the market. Where the factory is missing or not registered, as on mainnet until the vote, Easy Track is
impersonated to send the script's `activationScript()` to the EVMScriptExecutor, and a test account seeds the market.
Either way the executor then allows the market on the exit books. External callers run `make test-fork RUN="$RUN"`
against their post-vote RPC after recording the deployment in the scripts' `getDeployment()`; this never changes that
source node.
The regression action starts Anvil at the caller's post-vote block with `--fork-state-by-number` for Hardhat
compatibility, runs the Forge suites and then State Mate on each `deployed/<network>/**/state-mate.yaml` against
Anvil, and stops it on exit. The mainnet configs need the caller's `etherscan_token`.
Callers using the old TOML export must migrate before using this branch.

## Activation

```sh
make activation-safe-tx MARKET=<network>/markets/<DeployScript>
```

prints the Safe transaction that creates a recorded market's activation motion: a Transaction Builder batch to
import into the factory's trusted caller, and its safeTxHash at the Safe's current nonce, for the signers to match on
their hardware wallets. It refuses a market with no recorded deployment and a network whose activation factory Easy
Track does not register.

## State Mate

Each package under `deployed/<network>/` (`protocol/`, `markets/<market>/`) has one `state-mate.yaml`, written by hand:
the package's expected current state, with its contracts' ABIs in `abis.json.gz` beside it. Update it in the change
that moves that state: a deployment, an activation or a vote. Review addresses, proxy implementations, Safe membership
and thresholds, roles and approved motion parameters against their sources, not against the chain. Run a config with
`yarn start <config>` from a State Mate checkout at the commit the regression action pins, with `MAINNET_RPC_URL` or
`HOODI_RPC_URL`, the variable the config names, and for mainnet `ETHERSCAN_TOKEN` and `ETHERSCAN_EXPLORER_TOKEN`.
The Diffyscan configs sit beside the State Mate config of their package.

## Audit checksums

Run `make audit-checksums` or `make audit-checksums REF=<git-ref>` to compare audited source digests.
