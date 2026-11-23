# Repository Guidelines

## Project Structure

- `src/`: Lido-specific extensions over the Morpho Blue fork — controller, vault, registry, oracle, libraries.
- `lib/lend`: the Morpho Blue fork (core `src/LidoLend.sol`), pinned as a submodule and imported via the `@lido-lend/` remapping. Fork point and core-change record live in `lib/lend/FORK_NOTES.md`.
- `lib/bundler3`: stock Morpho bundler3, pinned as a submodule and imported via the `@bundler3/` remapping — the one-transaction bundling dispatcher, deployed per run rather than shared with Morpho's, and its adapter base contracts.
  The Lido bundler code is `src/adapters/LidoLendVaultAdapter.sol` (the vault's `fallbackExit`) and `src/adapters/EthereumGeneralAdapter1.sol` (upstream's general adapter vendored without the MORPHO token surface).
- `lib/circuit-breaker`: pinned upstream emergency-pause manager, imported via the `@circuit-breaker/` remapping and deployed as a reusable per-run dependency.
- `src/controllers/`: the Lido-specific market controller and its hook policy.
- `src/GuardianSignals.sol`: guardian-signal registry (one per guardian group; markets may share one).
- `src/interfaces/`: local interfaces and hook payload structs.
- `src/oracle/`: local oracle adapters.
- `src/libs/`: pure libraries (math, data structures). Internal — they inline into call sites.
- `src/proxy/OssifiableProxy.sol`: imported Lido proxy source. Do not reformat it.
- `test/scenario/`: end-to-end flows on **freshly deployed** core / controller / vault, on the local
  EVM with mock tokens. Driven through shared helpers; happy path first, then revert and
  edge cases. Pure-library fuzz tests live under `test/unit/`.
- `test/fork/`: integrations on `vm.createSelectFork`, one market per run: the market of the deploy script that
  `FORK_DEPLOY_SCRIPT` names, by default mainnet `weth-wsteth`, at its network's `FORK_BLOCK` or `HOODI_FORK_BLOCK`,
  else at the latest block. The scripts get or deploy what the block lacks. A market the core lacks is created by its
  Easy Track activation motion, the one in flight or a new one, where Easy Track registers the network's activation
  factory, and otherwise by its script's `activationScript()` sent to the EVMScriptExecutor as Easy Track. Base suites
  in `test/fork/` run on every market, on one market per kind or on the WETH/wstETH markets, as their `setUp` says;
  `test/fork/markets/<vendor>/` (`lido`, `ondo`, `centrifuge`, `circle`) on the markets of
  that vendor's oracle or token and skips the others. `make test-fork-<network>-<market>` runs `test/fork` on one
  market and `make test-fork` on every market; a market whose network's RPC variable (`RPC_URL`, `HOODI_RPC_URL`) is
  unset fails. The legacy `make test-fork RUN=<network>` binds each recorded market of the network at the latest block and
  creates an inert one; `PREPARE=false` leaves them as they are and skips an inert one. Only a Make command-line
  `RUN` selects it; Make sets `FORK_DEPLOY_SCRIPT`, `FORK_RUN` and `FORK_RUN_PREPARE` internally. No source-node
  transactions or artifact writes.
- `test/deployment/`: Solidity deployment scenarios run by CI, selected by the `deployment` Foundry profile.
  Runs on mainnet `weth-wsteth` at `FORK_BLOCK`, else at the latest block, through the deploy scripts;
  never writes to the source RPC and is excluded from default/local/recorded-deployment fork suites.
- `script/deployment/<network>/`: concrete Solidity deployment entrypoints and reusable recipes. Only the `.s.sol`
  entrypoints own broadcast boundaries; the fork tests call the scripts' `getOrDeploy()`, `activationParams()` (the
  activation motion's calldata) and `activationScript()`.
  Run one entrypoint with `make deploy SCRIPT=<path> RPC_URL=<rpc> DEPLOYER_SENDER=<sender>` or `forge script`.
  Make simulates by default; only command-line `BROADCAST=true` with `DEPLOYER_ACCOUNT=<keystore>` sends transactions.
  A run's addresses are in Forge's `broadcast/<script>/<chainId>/run-latest.json`, with the receipts to verify.
  Each component is one script, `Deploy<Component><Network>`: the core (protocol and CircuitBreaker), the exit books,
  the bundler, and each market in `markets/`. Its `getConfig()` (a market's `getDeployConfig()` and
  `getActivationMotionConfig()`) holds the inputs and its `getDeployment()` the manually maintained recorded
  addresses; `getOrDeploy()` returns the record, which must have code, else deploys without a broadcast. Components on
  several networks share a base, `Deploy<Component>Base`. `EasyTrack<Network>.sol` records the network's Easy Track
  activation factory by hand, zero until it is deployed; `script/lib/RecordedProtocol.sol` gives the records of the
  chain in use.
- `test/fork/helpers/`: `ForkNetworks.sol` forks a network at its block with its RPC variable and imports every market
  script, so that forge builds it; `ForkCollateralIssuer<Issuer>.sol`, one per collateral issuer, deals the collateral,
  adds an account to its allowlist and moves the price through the oracle's source; `ForkStack.sol` is the base of
  every fork suite.
- `script/config/`: historical files. Deployment and test code read none of them.
- `deployed/<network>/`: per package (`protocol/`, `easy-track/`, `markets/<market>/`), Forge transaction records
  (`*.broadcast.json`), Diffyscan configs and a State Mate config (`state-mate.yaml`, the package's expected current
  state, with its `abis.json.gz`). Record new addresses and approved parameters manually in Solidity after checking
  successful receipts, canonical RPC blocks and deployed code, and update `state-mate.yaml` with each change of state.
- `lib/`: pinned git submodules. Treat as vendored dependencies.
- `docs/specs/`: per-contract specifications (see Specifications section).
- `STYLE_GUIDE.md`: Solidity style guide (naming, structure, comments, fork conventions).
  Read it before writing or reviewing new contracts.
- `CLAUDE.md`: thin pointer (`@AGENTS.md`) so Claude Code picks up the same guidelines as Codex (which reads `AGENTS.md` natively). `AGENTS.md` is the source of truth — update it, not the pointer. Add similar stubs for other agents (Cursor, Copilot, Cline, ...) when those tools are actually used on the project.

## Build, Test, And Formatting Commands

- Build: `forge build --force`.
- All tests (local + fork): `make test` requires `RPC_URL`; it runs every suite on mainnet `weth-wsteth`.
- Fork suites: `make -k test-fork` runs them once per market and goes on past a failing one; a market whose network's
  RPC variable is unset fails. One market: `make test-fork-<network>-<market>`, or
  `FORK_DEPLOY_SCRIPT=<script path> forge test --match-path 'test/fork/**'`. `FORK_BLOCK` and `HOODI_FORK_BLOCK` set
  the blocks. No Anvil, shell provisioning or test TOML configs.
- Existing run, without preparation: `make test-fork RUN=<network> PREPARE=false RPC_URL=<rpc>`. Missing recorded
  contracts fail rather than trigger redeployment.
- External regressions: the `.github/actions/regression-tests` action forks the caller's RPC with Anvil, runs
  `make test-fork RUN=<network>` against it, which creates the network's inert recorded markets, and then State Mate
  on each `deployed/<network>/**/state-mate.yaml`. Easy Track and its executor are never deployed here.
- Local suites: `forge test --no-match-path 'test/{fork,deployment}/**'`, or `make test-local` — the RPC-free path.
- Solidity deployment scenarios: `make test-deployment RPC_URL=<mainnet-rpc>` runs deployment-state tests
  on mainnet `weth-wsteth` inside Forge; CI invokes this target too.
  `FORK_BLOCK` optionally pins the input state. No `CONFIG`, `RUN`, artifacts overlay or Anvil is required.
  The suite does not deploy Easy Track or its executor; activation is replayed as the protocol's existing executor.
- Year-long solvency simulations: `make test-simulation` sets `RUN_SOLVENCY_SIMULATION=true` over
  `test/simulation/`. The 30-day variants of the same suites already run inside `make test-local`; without that
  variable the year-long tests skip. The gas limit they need is set in `foundry.toml`.
- Mutation testing: `make test-mutation` scores `src/` against the 30-day simulations. Requires forge >= 1.8.0;
  it never runs in CI. The score counts only evaluated mutants.
- Gas snapshots: `make snapshot` runs the whole suite into `.gas-snapshot`. The
  fork suites are included — they revert without the fork setup — on mainnet `weth-wsteth` at `FORK_BLOCK`, else
  at the latest block. `TEST_SEED` comes from the env when set; otherwise foundry picks
  one random seed per run and the suites log it (fork suites also log their block), so a run is always
  replayable by exporting the logged `TEST_SEED`/`FORK_BLOCK`. `make snapshot-diff` diffs a fresh run
  against `.gas-snapshot` — run both at the same `TEST_SEED`, or the diff picks up seed noise on top of the
  code change (CI pins `TEST_SEED=1`).
- Format check for local Solidity files:
  `forge fmt --check src/LidoLendERC4626.sol src/GuardianSignals.sol src/adapters src/controllers src/interfaces src/oracle src/libs src/periphery src/utils script test`.
- Do not include `src/proxy/OssifiableProxy.sol` in formatting commands.
- Writing a fork test: a protocol test is `test/fork/<Flow>.t.sol` extending `helpers/ForkStack.sol`; a test of one
  vendor's oracle or token goes into `test/fork/markets/<vendor>/` and skips other markets in `setUp`. Call
  `_setUpTarget()` in `setUp` and drive `market` with the ForkStack helpers and MarketActions: `_freshActor`,
  `collateralIssuer.dealCollateral`, `_setOraclePrice` and `_setPriceForLtv` work on every market. A suite that needs
  a second market deploys it with `script.deploy` and creates it with `_createMarket`. A suite of the network's
  shared contracts calls `_onlyOnWethWsteth()` first in `setUp`, and one that depends only on the market's kind
  `_onlyOnOneMarketPerKind()`. Protocol and dependency
  addresses are fields of `ForkStack` (`protocol`, `books`, `bundler`).
- Adding a market: its deploy script, an import in `ForkNetworks.sol`, its `test-fork-<network>-<market>` target in the
  Makefile and in `FORK_TARGETS`, and its `deployed/<network>/markets/<market>/` once deployed; no test code, except
  that a market of a new kind (oracle, decimals pair, collateral restriction or loan token) joins the list of
  `_onlyOnOneMarketPerKind` in `ForkStack.sol`. A new
  collateral issuer is a `ForkCollateralIssuer<Issuer>` contract.

## Dependency Policy

- Foundry dependencies are pinned as git submodules under `lib/`.
- Do not edit files inside `lib/` unless the task is explicitly about dependency patching.
- When dependency pins change, stage and commit the relevant `.gitmodules`, `foundry.lock`, and `lib/<dependency>` gitlink updates together.
- `git ls-files --stage lib/<dependency>` should show mode `160000` for submodules.

## Morpho Fork Policy

- The Morpho Blue fork is the vendored `lib/lend` dependency (core `src/LidoLend.sol`), pinned as a submodule. Its fork point, core-change record, and editing rules live in `lib/lend/FORK_NOTES.md`.
- The forked core accounting (positions, supply/borrow shares, interest accrual, market creation, liquidate, settle) changes only through a `lib/lend` pin bump.
- Lido-layer policy and orchestration live in this repository: the per-market policy entry point is `src/controllers/LidoLendMarketController.sol`, while guardian state, vault settlement orchestration, and optional periphery remain in their own contracts under `src/`.

## Solidity Style

See `STYLE_GUIDE.md` for naming, structure, comments, error/event placement and fork conventions.
Read before writing or reviewing contracts.

## Specifications

Specs live in `docs/specs/` in two layers (see `docs/specs/README.md`). They capture what a reviewer needs before reading code, not what the code already says.

- **Conceptual specs** (hand-written): the architecture, cross-contract mechanisms, access-control matrix, per-market parameters, and the invariants and threat model the code cannot state itself. `architecture.md` is the system topology and runtime-boundary reference; `market-controller.md`, `guardian-signals.md`, `lender-settlement.md`, and `exit-books.md` own their respective state machines and formulas; `roles.md` maps every privilege to its role and holder; `markets/<market>.md` is per market.
- **API reference** (`docs/specs/api/`, generated): the per-contract surface — functions, structs, state variables — rendered from the Solidity NatSpec by `tools/gen_api_from_artifacts.py` (`make doc`). It is the single source for per-member behaviour, so never hand-write or hand-edit it: keep the NatSpec accurate and regenerate. The forked Morpho core is documented under `lib/lend/`.
- Invariants are **testable**: each one maps to a scenario or fork assertion in `test/`, or a State Mate check.
- Threat model lists the actors (lender, borrower, liquidator, controller admin, guardian, oracle, IRM) and what each is trusted not to do.
- Behaviour-changing PRs update the NatSpec (which regenerates the API reference) and any conceptual spec the change affects, under the same commit.
- Specs reference the code; contract NatSpec never references specs, ADRs, tests, or docs (see `STYLE_GUIDE.md`).

## Testing Guidelines

### Layout

```
test/
├── setup/        # shared infra — deploy + action helpers + mocks + types (no tests of its own)
├── unit/         # L0+L1 — one file per contract / pure library, method-by-method
├── scenario/     # L2 — end-to-end flows on a freshly deployed stack (local EVM, mock tokens)
├── invariant/    # L4 — handler-based stateful properties
├── simulation/   # seeded months-long solvency simulations on a fresh stack; 30-day variants run in test-local
├── fork/         # fork tests on one market per run; markets/<vendor>/ on that vendor's markets
└── deployment/   # typed deployment + preparation on a Forge fork (profile: deployment)
```

- `unit/<Contract>.t.sol` — single contract or pure library in isolation; **flat, one file per
  contract** (no per-contract subfolders), pure-library harnesses + fuzz alongside. Drives one
  contract's methods through every branch.
- `scenario/<Flow>.t.sol` — full cross-contract flows on a **freshly deployed** protocol (built via
  `setup/`), on the local EVM with mock tokens.
- `invariant/<Area>.invariant.t.sol` — handler-based stateful properties (actors, ghosts, bounded
  actions). Handlers under `invariant/handlers/`.
- `simulation/<Market>Solvency.t.sol` — seeded 30- and 365-day solvency simulations on a freshly deployed
  stack with the default market config. The driver draws everyday moves by odds and schedules each rare event
  once per run.
- `fork/<Flow>.t.sol` — integration tests on every market, one market per kind or the WETH/wstETH markets; `fork/markets/<vendor>/` on the markets of that vendor's
  oracle or token. `make test-fork` to run. The deployed state is checked by State Mate against
  `deployed/<network>/**/state-mate.yaml`; see `script/DEPLOYMENT.md`.

### Setup Infra (`test/setup/`)

Every suite builds on `LidoLendSetup` (abstract base) — do not re-implement deployment:

- **Deploys with `new`, not `vm.getCode`** (the fork core and IRM are 0.8.36-compatible). One `LidoLend` core and one guardian registry are **singletons**; a core hosts **many markets**.
  `Protocol { config, core, guardianSignals, Market[] markets }`; each `Market` carries its per-market contracts (controller/vault/oracle/irm), its own config, and a handle on the core.
- `_deployProtocol(cfg)` / `_addMarket(cfg)` deploy a market; `_defaultConfig(...)` is the starting point; `irmKind` selects the IRM (Adaptive / Fixed); `_fund(token, to, amt)` and `_actor(name)` set up actors.
- **Oracle price is seeded, never `1e36` parity**: the seed is logged at deploy; reproduce a failure by exporting `TEST_SEED`.
- Each proxied contract exposes two handles — the typed impl (`market.vault`) and the proxy admin (`market.vaultProxy` / `IOssifiableProxy`) — at the same address.

### Helper Pattern (`MarketActions`)

Every user-visible action is a helper in the `MarketActions` library over `Market` (`using MarketActions for Market` → `market.borrow(bob, 10 ether)`). The helper does the action AND asserts everything around it — call sites never repeat assertion blocks. Each helper:

1. Captures pre-state for the actors involved (position, market totals, ERC-20 balances, shares).
2. Sets up `vm.expectEmit` for the events the action should fire (where args are static).
3. Performs the call (`vm.prank` + invocation); returns the recorded outputs.
4. **Recomputes expected values independently** — do not trust the call's return. Re-derive shares↔assets, slice sizing, oracle conversions etc. with the spec formula.
5. Asserts state deltas, events, and token movements match.

Actors must be **funded first** (`_fund` on the base — `deal` is StdCheats, not a `vm` cheatcode, so it cannot live in the library). Coverage spans lender (vaultDeposit/vaultMint/vaultWithdraw/vaultRedeem/settle/fallbackExit), borrower (supplyCollateral/activateCollateral/borrow/repay/withdrawCollateral/setSettlementLtv), keeper (`liquidate` asserts **no** bad debt, `liquidateBadDebt` asserts bad debt **is** realized), and interest utilities. Extend `MarketActions` rather than sprinkling ad-hoc assertions in tests.

### Black-box, Model-first

Tests are derived from **requirements** (specs), **never from the implementation** — a test read off the code inherits its bugs. Model each method independently (requirements · revert conditions · parameter boundaries · all branches) and recompute expected numbers from the spec formula. Fuzz and invariants are mandatory for state-mutating methods, not just example tests.
Coverage is necessary hygiene but not the goal — completeness is the closed branch checklist; mutation score is the honest measure of test strength.

### Math Recomputation

Where contracts compute amounts (shares↔assets, slice sizing, oracle conversions, settlement LTV), re-derive the expected number from inputs using the same formula. This catches drift in either the contract or the test setup.

### Naming

- `test_<scenario>_<expectation>` for single-shot tests.
- `testFuzz_<property>` for fuzz.
- `invariant_<property>` for invariant runs.
- `testRevert_<reason>` for explicit failure-path coverage.

### Discipline

- Tests land with the change. Separate "tests follow-up" PRs are not accepted for new functionality.
- Before writing a test, find its check in `TEST_PLAN.md`. A `[x]` line names the tests that already cover it: extend those, do not add a duplicate.
- A change that adds, renames or removes a test updates `TEST_PLAN.md` in the same change, in the line format its header gives: a new check gets a line, a `[ ]` line it covers becomes `[x]` with the test, and a removed test leaves no reference. Write test names and paths bare, in backticks: `make test-plan` adds the links.
- Any edit under `test/` or `src/` can move the line anchors in `TEST_PLAN.md`: run `make test-plan` after it. `make test-plan-check` must pass before the change is done.
- After source changes, run at least `forge build --force` and `make test-local` (`make test` when a fork setup is configured).

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/): the subject starts with a type prefix, an optional scope, and a short imperative summary.

```
<type>(<optional scope>): <summary>
```

- Allowed types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`, `ci`, `perf`, `style`.
- Scope is optional and names the area touched, e.g. `feat(controller):`, `fix(vault):`, `test(scenario):`, `chore(deps):`.
- Summary is imperative and lower-case, no trailing period; keep it under ~72 characters and put detail in the body.
- Breaking changes: add `!` after the type/scope (`refactor!:`) and explain the break in the body.

## Pull Request Notes

PR description includes:

- Test commands actually run. If contract surface changed, confirm `forge build --force` passes with `via_ir = false` (the default for this repo).
- Storage layout impact for struct, mapping, or proxy/controller storage changes (which slot moved, whether append-only).
- Updated specification for behaviour-changing PRs: the NatSpec (regenerated into `docs/specs/api/`) and any affected conceptual spec under `docs/specs/`.
- For a `lib/lend` pin bump: note what moved in the fork (accounting, ABI, storage layout) and that `.gitmodules`, `foundry.lock`, and the gitlink are staged together.
