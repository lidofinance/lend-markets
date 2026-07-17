# Lido Lend Markets

Lido Lend is a family of isolated lending markets for established, low-risk looping trades, built on the [`lido-lend`](https://github.com/lidofinance/lido-lend) Morpho Blue fork. Each market is narrow by design, with strong exit paths and conservative controls that limit how quickly new collateral becomes borrowable.

The Morpho-style market accounting lives in that core, with the interest-rate model in [`lido-lend-irm`](https://github.com/lidofinance/lido-lend-irm). This repository — Lido Lend Markets — holds everything built on top: the per-market policy and contracts, the specifications, the deployment scripts, and the deployed-address registry.

## Setup

Install Foundry, then fetch pinned dependencies. Current setup was checked with `forge 1.5.1-stable`.

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

Run the fork tests against a real network. The suites under `test/fork/` require `ETH_RPC_URL` and a path to that network's address map `DEPLOYMENT` — they revert if either is unset or the map file is missing (a plain `forge test` runs local and fork suites together):

```sh
ETH_RPC_URL=<rpc-url> DEPLOYMENT=deployments/deployed-mainnet.json forge test --match-path 'test/fork/**'
ETH_RPC_URL=<rpc-url> DEPLOYMENT=deployments/deployed-<network>.json forge test --match-path 'test/fork/**'  # needs that network's map (see deployments/README.md)
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
make test            # all tests, local + fork; fork suites revert without the fork setup (ETH_RPC_URL + DEPLOYMENT)
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
```

Environment variables are documented in `.env.example`. Copy it to `.env` and set `ETH_RPC_URL` + `DEPLOYMENT` to enable fork tests locally.

CI pins Foundry via `.foundryref` (read by `.github/actions/repo-setup`). Locally `forge 1.5.1-stable` is the reference. Workflows live under `.github/workflows/`: `ci.yml` (a `local` job — build/lint/local tests, no RPC — plus a `fork` job that runs `test/fork/` with `ETH_RPC_URL` from the `MAINNET_RPC_URL` secret), `static.yml` (Slither + Solhint), `coverage.yml` (whole-suite coverage, fork suites included via the same secret), `gas-diff.yml` (whole-suite gas snapshot diff at one pinned block, posted as a PR comment), and `fuzz.yml` (deep fuzz/invariant, local suites only).

To run the local pre-commit fmt check, point Git at the bundled hook:

```sh
git config core.hooksPath .githooks
```

## Source Layout

```text
src/
├── LidoLendERC4626.sol              # single-market ERC-4626 vault (the lender layer) with settle exit
├── LidoLendOwner.sol                # owner/admin entrypoint for deployed markets
├── GuardianSignals.sol              # guardian-signal registry (address bans and activation strikes)
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
│   ├── RiskStewardDashboard.sol     # bounded per-market risk levers
│   ├── ExitBookBase.sol             # lender exit queue (base) and adapters
│   ├── Erc4626ExitBook.sol
│   └── MorphoExitBook.sol
├── types/                           # shared value types (activation, settlement, guardian, exit-book)
├── proxy/
│   └── OssifiableProxy.sol          # vendored Lido upgradeable proxy
└── utils/
    └── PausableUntil.sol
```

## Architecture

The vendored core (`lib/lido-lend`, contract `LidoLend`) is the Morpho-compatible market.

- Upgradeable behind `OssifiableProxy`, with owner-gated market creation.
- Preserves upstream `MarketParams`, `Position`, `Market`, and market id derivation.
- Preserves the standard Morpho action signatures, plus a two-anchor `settle` for the lender exit.
- Binds an optional controller and settlement availability once at market creation, and calls controller hooks for controller-enabled markets.

`LidoLendMarketController` owns Lido policy for a market.

- Collateral activation: active, activating, and dust buckets with a maturation timer and an inflow throttle.
- Active-only borrow capacity and a minimum-position floor.
- Freeze and pause controls, plus guardian-signal address gating.
- The settlement queue: risk-ordered borrowers, a per-borrower settlement LTV, and the policy-sized cut.

`LidoLendERC4626` is the single-market ERC-4626 vault, the sole lender, with a fallback settle exit when ordinary liquidity is short.

Supporting pieces: `GuardianSignals` (shared address bans and activation strikes), `RiskStewardDashboard` (bounded tighten-only risk levers), the exit-book periphery (`ExitBookBase` and its adapters), and the `WstEthRateOracle` / `UsdyStableOracle` adapters.

## Fork Notes

The Morpho Blue fork is the vendored `lib/lido-lend` dependency. See `FORK_NOTES.md`, which points to `lib/lido-lend/FORK_NOTES.md` for the fork point and core-level changes.

## License

Repository source files use SPDX headers. The Morpho Blue fork point is pinned in the `lib/lido-lend` dependency to upstream `main` commit `1478e9cfe1b4d514f80682b3b60e4e12ff3ee45a`, where `src/Morpho.sol` is marked `GPL-2.0-or-later`. See `LICENSE` and `lib/lido-lend/FORK_NOTES.md`.
