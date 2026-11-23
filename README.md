# Lido Lend Markets

Lido Lend is a family of isolated lending markets for established looping trades, built on the [`lend`](https://github.com/lidofinance/lend) Morpho Blue fork. Each market is narrow by design, with several exit paths and controls that limit how quickly new collateral becomes borrowable.

The Morpho-style market accounting lives in that core, with the interest-rate model in [`lend-irm`](https://github.com/lidofinance/lend-irm). This repository — Lido Lend Markets — holds everything built on top: the per-market policy and contracts, the specifications, the deployment scripts, and the deployed-address registry.

## Setup

Install the Foundry version recorded in `.foundryref`, then fetch pinned dependencies.

```sh
git submodule update --init --recursive
```

Build:

```sh
forge build --force
```

Run the local test suite (everything except the fork and deployment suites):

```sh
forge test --no-match-path 'test/{fork,deployment}/**'
```

The fork suites run once per market, each in its own Forge run; the deploy scripts deploy what the block lacks, and
the market is created by its Easy Track activation motion. No Anvil or shell provisioning is required.

```sh
make -k test-fork                                    # the fork suites on every market
make test-fork-mainnet-weth-wsteth                   # one market
make test-deployment RPC_URL=<mainnet-archive-rpc>   # deployment-state scenarios
```

A network's markets need its RPC variable (`RPC_URL` for mainnet, `HOODI_RPC_URL` for Hoodi) and fail without it;
they run at `FORK_BLOCK` and `HOODI_FORK_BLOCK` when set, else at the latest block. To exercise a deployment's recorded markets at
the RPC's latest block without preparing them:

```sh
make test-fork RUN=<run> PREPARE=false RPC_URL=<network-rpc>
```

Deployment parameters and dependency addresses live in Solidity files under `script/deployment/<network>/`.
Run `forge script <recipe.s.sol> --rpc-url <rpc>` to simulate; add `--broadcast` to deploy. Results and State Mate
configurations are maintained manually. See [deployment instructions](script/DEPLOYMENT.md) for signer inputs,
Solidity deployment descriptions and State Mate checks.

Format Solidity:

```sh
forge fmt src/LidoLendERC4626.sol src/GuardianSignals.sol src/adapters src/controllers src/interfaces src/oracle src/libs src/periphery src/utils script test
```

## Repository Tooling

Most everyday commands are wrapped in a `Makefile`:

```sh
make help            # list available targets
make build           # forge build
make test            # every suite on the default fork target (mainnet weth-wsteth); RPC_URL required
make test-local      # local suites only (excludes test/fork, test/deployment); no RPC
make test-fork       # the fork suites once per market; run as make -k to go on past a failing market
make fmt-check       # forge fmt --check on tracked paths (local only; CI does not fail on style)
make lint            # forge lint
make coverage        # coverage of the whole suite; fork suites revert without the fork setup
make snapshot        # gas snapshot of the whole suite
make snapshot-diff   # fresh run diffed against .gas-snapshot
make slither         # static analysis (requires `slither` in PATH)
make solhint         # stylistic/security checks (requires `solhint` in PATH)
make ci              # everything CI runs on PRs: build + lint + local tests
make test-deployment # missing/inert/active deployment-state scenarios on a mainnet fork
make test-fork RUN=mainnet # the recorded mainnet markets on a fork of the caller's RPC; an inert one is created
```

Environment variables are documented in `.env.example`. Copy it to `.env` and set `RPC_URL` (and `HOODI_RPC_URL`
for the Hoodi markets). Explicit `make test-fork RUN=<run>` binds the recorded markets of an existing deployment and
creates an inert one; add `PREPARE=false` to test them without preparation. `RUN` selects only when passed on the
Make command line; a value from `.env` or the environment does not. For other inputs, command-line assignments take
precedence over exported environment values, then `.env`, then Makefile defaults.

CI pins Foundry via `.foundryref` (read by `.github/actions/repo-setup`); install that version locally. `make test-mutation` is local only. Workflows under `.github/workflows/` cover build/lint/local tests and the fork suites on every market (`ci.yml`), coverage (`coverage.yml`) and deep fuzz/invariants (`fuzz.yml`).
Additional workflows check action configuration and compiled contract bytecode sizes.

To run the local pre-commit solhint check, point Git at the bundled hook:

```sh
git config core.hooksPath .githooks
```

## Source Layout

```text
src/
├── LidoLendERC4626.sol              # single-market ERC-4626 vault with settlement exits
├── GuardianSignals.sol              # guardian-signal registry (address bans and activation strikes)
├── adapters/
│   ├── LidoLendVaultAdapter.sol     # Bundler3 adapter for vault fallback exits
│   └── EthereumGeneralAdapter1.sol  # Ethereum Bundler3 adapter without the MORPHO-token surface
├── controllers/
│   └── LidoLendMarketController.sol # Lido policy: hooks, collateral activation, freeze/pause, gating, settlement queue
├── interfaces/                      # local interfaces and hook payload structs
├── libs/
│   ├── CollateralActivationLib.sol  # active / activating / dust collateral accounting
│   ├── SettlementQueueLib.sol       # risk-ordered settlement queue and slice sizing
│   ├── MaxHeapLib.sol               # max-heap primitive backing the queue
│   ├── ExitBookLib.sol
│   └── Constants.sol
├── oracle/
│   ├── WstEthRateOracle.sol         # wstETH/ETH accounting-rate adapter
│   └── UsdyStableOracle.sol         # USDY to stablecoin oracle
├── periphery/
│   ├── LidoLendOwner.sol            # role-gated governance facade over the core and market policy
│   ├── LidoLendMarketFactory.sol    # stateless component deployment and role-wiring factory
│   ├── RiskStewardDashboard.sol     # bounded per-market risk levers
│   ├── ExitBookBase.sol             # filler-served exit registry base
│   ├── Erc4626ExitBook.sol
│   └── MorphoExitBook.sol
├── types/                           # shared value types (activation, settlement, guardian, exit-book)
├── proxy/
│   └── OssifiableProxy.sol          # vendored Lido upgradeable proxy
└── utils/
    ├── AssetRecoverer.sol
    └── PausableUntil.sol
```

## Architecture

Start with the [system architecture](docs/specs/architecture.md). It contains the runtime and governance maps and links to the controller, guardian, lender-settlement, and Exit Book mechanism specifications.

The vendored core (`lib/lend`, contract `LidoLend`) is the Morpho-compatible market.

- Upgradeable behind `OssifiableProxy`, with owner-gated market creation.
- Preserves upstream `MarketParams`, `Position`, `Market`, and market id derivation.
- Preserves the standard Morpho action signatures, plus a borrow-share-anchored `settle` that cancels borrower debt against an authorized supplier position.
- Binds an optional controller and settlement availability once at market creation, and calls controller hooks for controller-enabled markets.

`LidoLendMarketController` owns Lido policy for a market.

- Collateral activation: active, activating, and dust buckets with a maturation timer and an inflow throttle.
- Active-only borrow capacity and a minimum-position floor.
- Freeze and pause controls, plus guardian-signal address gating.
- The settlement queue: risk-ordered borrowers, a per-borrower settlement LTV, and the policy-sized cut.

`LidoLendERC4626` is the single-market ERC-4626 lender wrapper. It offers targeted settlement and a fallback exit that uses free liquidity first, then settlement when ordinary withdrawal liquidity is short.

Supporting pieces: `GuardianSignals` (shared address bans and activation strikes), `RiskStewardDashboard` (bounded tighten-only risk levers), the exit-book periphery (`ExitBookBase` and its adapters), and the `WstEthRateOracle` / `UsdyStableOracle` adapters.

## Fork Notes

The Morpho Blue fork is the vendored `lib/lend` dependency. See `FORK_NOTES.md`, which points to `lib/lend/FORK_NOTES.md` for the fork point and core-level changes.

## License

Repository source files use SPDX headers. They are GPL-2.0-or-later, except `src/proxy/OssifiableProxy.sol`, imported Lido source under [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html). The Morpho Blue fork point is pinned in the `lib/lend` dependency to upstream `main` commit `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a`, where `src/Morpho.sol` is marked `GPL-2.0-or-later`. See `LICENSE` and `lib/lend/FORK_NOTES.md`.
