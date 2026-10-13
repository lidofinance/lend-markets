# Lido Lend Markets

Lido Lend is a family of isolated lending markets for established, low-risk looping trades, built on the [`lido-lend`](https://github.com/lidofinance/lido-lend) Morpho Blue fork. Each market is narrow by design, with strong exit paths and conservative controls that limit how quickly new collateral becomes borrowable.

The Morpho-style market accounting lives in that core, with the interest-rate model in [`lido-lend-irm`](https://github.com/lidofinance/lido-lend-irm). This repository — Lido Lend Markets — holds everything built on top: the per-market policy and contracts, the specifications, the deployment scripts, and the deployed-address registry.

## Setup

Install the Foundry version recorded in `.foundryref`, then fetch pinned dependencies.

```sh
git submodule update --init --recursive
```

Build:

```sh
forge build --force
```

Run the local test suite (everything except `test/fork/`):

```sh
forge test --no-match-path 'test/fork/**'
```

The suites under `test/fork/` drive an already-deployed protocol, so they need one: `RPC_URL` is the node to
fork — the node that HOLDS the deployment — and `ARTIFACTS_DIR` names the deploy run whose artifacts under
`deployed/<run>/` they read. They revert if either is unset, the run is absent, or its recorded chain id does
not match the forked chain. No registry is composed and no preparation step is needed.

Locally, `make provision-fork` deploys and activates the fork markets onto a local anvil fork of the network
`CONFIG` names (mainnet by default), using the test-only `FORK_CONFIG=fork-<CONFIG>`, and leaves it running;
`make test-fork-provision` chains provision -> test and stops Anvil only when that invocation started it:

```sh
make test-fork-provision RPC_URL=<mainnet-archive-rpc>     # one shot
make provision-fork RPC_URL=<archive-rpc>                  # or keep the anvil for repeated runs
make provision-fork                                        # reuses a compatible anvil already on :8545
make test-fork-live                                       # re-run the suites against it, no re-provisioning
make provision-stop
```

Against a real deploy run, point them at that network instead:

```sh
make fork-run RUN=<run>       # RPC_URL from .env is the network the run lives on
```

Format Solidity:

```sh
forge fmt src/LidoLendERC4626.sol src/GuardianSignals.sol src/controllers src/interfaces src/oracle src/libs src/periphery src/utils script test
```

## Repository Tooling

Most everyday commands are wrapped in a `Makefile`:

```sh
make help            # list available targets
make build           # forge build
make test            # all tests, local + fork; fork suites require RPC_URL + ARTIFACTS_DIR
make test-local      # local suites only (excludes test/fork/); no RPC
make test-fork       # test/fork/ only; the suites revert without the fork setup (copy .env.example to .env)
make fmt-check       # forge fmt --check on tracked paths (local only; CI does not fail on style)
make lint            # forge lint
make coverage        # coverage of the whole suite; fork suites revert without the fork setup
make snapshot        # gas snapshot of the whole suite
make snapshot-diff   # fresh run diffed against .gas-snapshot
make slither         # static analysis (requires `slither` in PATH)
make solhint         # stylistic/security checks (requires `solhint` in PATH)
make ci              # everything CI runs on PRs: build + lint + local tests
make provision-fork  # deploy + activate the fork markets on a local anvil fork of CONFIG's network
make provision-stop  # stop the anvil provision-fork started
make test-fork-live  # fork suites against an already-provisioned anvil (the iterative path)
make test-fork-provision  # provision -> test-fork against it -> teardown
```

Environment variables are documented in `.env.example`. Copy it to `.env` and set `RPC_URL`; fork tests
additionally need `ARTIFACTS_DIR`, which the provisioning targets above pass for you. For every documented
input, command-line assignments take precedence over exported environment values, which take precedence over
`.env` and then Makefile defaults.

CI pins Foundry via `.foundryref` (read by `.github/actions/repo-setup`); install that same version locally. `make test-mutation` is the one target that needs a newer forge than the pin and is therefore never run in CI. Workflows live under `.github/workflows/`: `ci.yml` (a `local` job — build/lint/local tests, no RPC — plus a `fork` job that provisions a deployment onto a local anvil fork from the `RPC_URL` secret and runs `test/fork/` against it), `static.yml` (Slither + Solhint), `coverage.yml` (whole-suite coverage, fork suites included via the same provisioned anvil), `gas-diff.yml` (whole-suite gas snapshot diff at one pinned block, posted as a PR comment), and `fuzz.yml` (deep fuzz/invariant, local suites only).
Additional workflows check action configuration and compiled contract bytecode sizes.

To run the local pre-commit fmt check, point Git at the bundled hook:

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

The vendored core (`lib/lido-lend`, contract `LidoLend`) is the Morpho-compatible market.

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

The Morpho Blue fork is the vendored `lib/lido-lend` dependency. See `FORK_NOTES.md`, which points to `lib/lido-lend/FORK_NOTES.md` for the fork point and core-level changes.

## License

Repository source files use SPDX headers. The Morpho Blue fork point is pinned in the `lib/lido-lend` dependency to upstream `main` commit `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a`, where `src/Morpho.sol` is marked `GPL-2.0-or-later`. See `LICENSE` and `lib/lido-lend/FORK_NOTES.md`.
