# Repository Guidelines

## Project Structure

- `src/`: Lido-specific extensions over the Morpho Blue fork — controller, vault, registry, oracle,
  libraries.
- `lib/lido-lend`: the Morpho Blue fork (core `src/LidoLend.sol`), pinned as a submodule and imported
  via the `@lido-lend/` remapping. Fork point and core-change record live in `lib/lido-lend/FORK_NOTES.md`.
- `lib/bundler3`: stock Morpho bundler3, pinned as a submodule and imported via
  the `@bundler3/` remapping — the one-transaction bundling dispatcher and its adapter base contracts.
  The Lido bundler code is `src/adapters/LidoLendVaultAdapter.sol` (the vault's `fallbackExit`) and
  `src/adapters/EthereumGeneralAdapter1.sol` (upstream's general adapter vendored without the MORPHO
  token surface).
- `lib/circuit-breaker`: pinned upstream emergency-pause manager, imported via the
  `@circuit-breaker/` remapping and deployed as a reusable per-run dependency.
- `src/controllers/`: the Lido-specific market controller and its hook policy.
- `src/GuardianSignals.sol`: guardian-signal registry (one per guardian group; markets may share one).
- `src/interfaces/`: local interfaces and hook payload structs.
- `src/oracle/`: local oracle adapters.
- `src/libs/`: pure libraries (math, data structures). Internal — they inline into call sites.
- `src/proxy/OssifiableProxy.sol`: imported Lido proxy source. Do not reformat it.
- `test/scenario/`: end-to-end flows on **freshly deployed** core / controller / vault, on the local
  EVM with mock tokens. Driven through shared helpers; happy path first, then revert and
  edge cases. Pure-library fuzz tests live here too.
- `test/fork/`: test suite that runs against a forked network, binding to an **already-deployed** protocol —
  fork suites never deploy what they test. `RPC_URL` is the node to fork and `ARTIFACTS_DIR` names the deploy
  run under `deployed/<run>/` whose artifacts they read; the run records its own network and chain id, so
  there is no network selector.
- `test/acceptance/`: verification of an **already-deployed** protocol on a mainnet fork — asserts the
  deployed stack is correctly wired, has the exact initial-launch role topology (direct enumerable-role checks),
  and is either ready for the activation motion or live after it. Expected deployment values and addresses come
  from immutable artifacts under `deployed/<run>/`; reviewed runtime motion choices come from
  `ACCEPTANCE_PAUSER_COMMITTEE` and `ACCEPTANCE_ENABLE_SETTLEMENT`. The suite skips unless
  `ACCEPTANCE_REGISTRY` points at its `protocol.toml`.
- `script/`: deployment scripts.
- `deployed/<run>/`: immutable per-run artifacts: `protocol.toml`, `markets/`, `circuit-breakers/`,
  `guardians/`, `oracles/`, `vaults/`, `adapters/`, optional `exit-books.toml`, and archived
  transaction records. Read directly by both `test/fork/` (`ARTIFACTS_DIR`) and `test/acceptance/`
  (`ACCEPTANCE_REGISTRY` -> `protocol.toml`); nothing is composed or prepared in between.
- `lib/`: pinned git submodules. Treat as vendored dependencies.
- `docs/specs/`: per-contract specifications (see Specifications section).
- `STYLE_GUIDE.md`: Solidity style guide (naming, structure, comments, fork conventions).
  Read it before writing or reviewing new contracts.
- `CLAUDE.md`: thin pointer (`@AGENTS.md`) so Claude Code picks up the same guidelines as Codex
  (which reads `AGENTS.md` natively). `AGENTS.md` is the source of truth — update it, not the
  pointer. Add similar stubs for other agents (Cursor, Copilot, Cline, ...) when those tools are
  actually used on the project.

## Build, Test, And Formatting Commands

- Build: `forge build --force`.
- All tests (local + fork): `make test`. The fork suites require a working fork setup — `RPC_URL` pointing at
  the node that HOLDS the deployment and `ARTIFACTS_DIR` naming its run on disk — and revert without it;
  a fork suite runs or it fails, it never skips.
- Local fork setup: `make provision-fork RPC_URL=<archive-rpc>` deploys and activates the `fork-*` markets on a
  local anvil fork of `CONFIG`'s network (mainnet by default), using `FORK_CONFIG=fork-<CONFIG>` for test-only
  role holders, into `deployed/fork/` and leaves anvil running; a compatible node already on `:8545` is reused
  without requiring the archive RPC;
  `make provision-stop` tears it down; `make test-fork-provision` does provision -> test-fork and stops the
  node only when that invocation started it (a reused node is left running). Against a real deploy run,
  `make fork-run RUN=<run>` is the equivalent.
- Local suites: `forge test --no-match-path 'test/fork/**'`, or `make test-local` — the RPC-free path.
- Fork tests only: `forge test --match-path 'test/fork/**'`, or `make test-fork`.
- Gas snapshots: `make snapshot` runs the whole suite into `.gas-snapshot`. The
  fork suites are included — they revert without the fork setup — forking the latest block unless
  `FORK_BLOCK` pins one. `TEST_SEED` comes from the env when set; otherwise foundry picks
  one random seed per run and the suites log it (fork suites also log their block), so a run is always
  replayable by exporting the logged `TEST_SEED`/`FORK_BLOCK`. `make snapshot-diff` diffs a fresh run
  against `.gas-snapshot` — run both at the same `TEST_SEED`, or the diff picks up seed noise on top of the
  code change (CI pins `TEST_SEED=1`).
- Format check for local Solidity files:
  `forge fmt --check src/LidoLendERC4626.sol src/GuardianSignals.sol src/adapters src/controllers src/interfaces src/oracle src/libs src/periphery src/utils script test`.
- Do not include `src/proxy/OssifiableProxy.sol` in formatting commands.
- Writing a fork test: put it under `test/fork/`, extend `helpers/ForkStack.sol` (which extends `ForkTest`),
  call `_fork()` first in `setUp`, bind the market with `_marketForRole("<role>")` + `_bindMarket`, and read external addresses
  via `_ext("wstEth")`. `_fork()` forks `RPC_URL` at latest and binds the run named by `ARTIFACTS_DIR`,
  reverting when either is unset, the run has no `protocol.toml`, the network config it names is missing, or
  its recorded chain id differs from the forked chain. A role the deployment has no market for skips the
  suite; everything else reverts. Protocol addresses come from `_protocol("core")`,
  `_market(name, "controller")`, `_marketId(name)`, or `_artifactAddr("vaults/weth-wsteth.toml", "vault.address")`
  for the per-resource artifacts; each reverts on a key the run does not define. `FORK_BLOCK` pins a block for
  replay.

## Dependency Policy

- Foundry dependencies are pinned as git submodules under `lib/`.
- Do not edit files inside `lib/` unless the task is explicitly about dependency patching.
- When dependency pins change, stage and commit the relevant `.gitmodules`, `foundry.lock`,
  and `lib/<dependency>` gitlink updates together.
- `git ls-files --stage lib/<dependency>` should show mode `160000` for submodules.

## Morpho Fork Policy

- The Morpho Blue fork is the vendored `lib/lido-lend` dependency (core `src/LidoLend.sol`), pinned
  as a submodule. Its fork point, core-change record, and editing rules live in
  `lib/lido-lend/FORK_NOTES.md`.
- The forked core accounting (positions, supply/borrow shares, interest accrual, market creation,
  liquidate, settle) changes only through a `lib/lido-lend` pin bump.
- All Lido extension logic — policy, controller hooks, settlement flavours, watermark, batch
  orchestration, lender auth — lives in the controller (`src/controllers/WethWstEthController.sol`).

## Solidity Style

See `STYLE_GUIDE.md` for naming, structure, comments, error/event placement and fork conventions.
Read before writing or reviewing contracts.

## Specifications

Specs live in `docs/specs/` in two layers (see `docs/specs/README.md`). They capture what a reviewer
needs before reading code, not what the code already says.

- **Conceptual specs** (hand-written): the architecture, the access-control matrix, per-market
  parameters, and the invariants and threat model the code cannot state itself. `architecture.md` is the
  system and controller-subsystem reference, `roles.md` maps every privilege to its role and holder,
  `markets/<market>.md` is per market.
- **API reference** (`docs/specs/api/`, generated): the per-contract surface — functions, structs, state
  variables — rendered from the Solidity NatSpec by `tools/gen_api_from_artifacts.py` (`make doc`). It is
  the single source for per-member behaviour, so never hand-write or hand-edit it: keep the NatSpec
  accurate and regenerate. The forked Morpho core is documented under `lib/lido-lend/`.
- Invariants are **testable**: each one maps to a scenario, fork, or acceptance assertion in `test/`.
- Threat model lists the actors (lender, borrower, liquidator, controller admin, guardian, oracle, IRM)
  and what each is trusted not to do.
- Behaviour-changing PRs update the NatSpec (which regenerates the API reference) and any conceptual spec
  the change affects, under the same commit.
- Specs reference the code; contract NatSpec never references specs, ADRs, tests, or docs
  (see `STYLE_GUIDE.md`).

## Testing Guidelines

### Layout

```
test/
├── setup/        # shared infra — deploy + action helpers + mocks + types (no tests of its own)
├── unit/         # L0+L1 — one file per contract / pure library, method-by-method
├── scenario/     # L2 — end-to-end flows on a freshly deployed stack (local EVM, mock tokens)
├── invariant/    # L4 — handler-based stateful properties
├── fork/         # fork tests vs the deployed protocol, bound from deployed/<ARTIFACTS_DIR>/
└── acceptance/   # L3 — mainnet fork vs immutable artifacts under deployed/<run>/
```

- `unit/<Contract>.t.sol` — single contract or pure library in isolation; **flat, one file per
  contract** (no per-contract subfolders), pure-library harnesses + fuzz alongside. Drives one
  contract's methods through every branch.
- `scenario/<Flow>.t.sol` — full cross-contract flows on a **freshly deployed** protocol (built via
  `setup/`), on the local EVM with mock tokens.
- `invariant/<Area>.invariant.t.sol` — handler-based stateful properties (actors, ghosts, bounded
  actions). Handlers under `invariant/handlers/`.
- `fork/<Flow>.t.sol` — integration tests against the deployed protocol. `make test-fork` to run.
- `acceptance/<Flow>.t.sol` — verification of the **already-deployed** protocol on a mainnet fork; live
  addresses and deployment values from `deployed/<run>/` (`ACCEPTANCE_REGISTRY` points to `protocol.toml`).
  Activated/readiness runs also require independent reviewed `ACCEPTANCE_PAUSER_COMMITTEE` and
  `ACCEPTANCE_ENABLE_SETTLEMENT` motion inputs. Run with `ACCEPTANCE_RPC_URL=$RPC_URL` (or `--fork-url`);
  skips without an artifact. It audits launch state, not role changes made by later governance. See
  `script/DEPLOYMENT.md`.

### Setup Infra (`test/setup/`)

Every suite builds on `LidoLendSetup` (abstract base) — do not re-implement deployment:

- **Deploys with `new`, not `vm.getCode`** (the fork core and IRM are 0.8.35-compatible). One
  `LidoLend` core and one guardian registry are **singletons**; a core hosts **many markets**.
  `Protocol { config, core, guardianSignals, Market[] markets }`; each `Market` carries its
  per-market contracts (controller/vault/oracle/irm), its own config, and a handle on the core.
- `_deployProtocol(cfg)` / `_addMarket(cfg)` deploy a market; `_defaultConfig(...)` is the starting
  point; `irmKind` selects the IRM (Adaptive / Fixed); `_fund(token, to, amt)` and `_actor(name)`
  set up actors.
- **Oracle price is seeded, never `1e36` parity** (see Solidity-style / values rule below): the
  seed is logged at deploy; reproduce a failure by exporting `TEST_SEED`.
- Each proxied contract exposes two handles — the typed impl (`market.vault`) and the proxy admin
  (`market.vaultProxy` / `IOssifiableProxy`) — at the same address.

### Helper Pattern (`MarketActions`)

Every user-visible action is a helper in the `MarketActions` library over `Market`
(`using MarketActions for Market` → `market.borrow(bob, 10 ether)`). The helper does the action AND
asserts everything around it — call sites never repeat assertion blocks. Each helper:

1. Captures pre-state for the actors involved (position, market totals, ERC-20 balances, shares).
2. Sets up `vm.expectEmit` for the events the action should fire (where args are static).
3. Performs the call (`vm.prank` + invocation); returns the recorded outputs.
4. **Recomputes expected values independently** — do not trust the call's return. Re-derive
   shares↔assets, slice sizing, oracle conversions etc. with the spec formula.
5. Asserts state deltas, events, and token movements match.

Actors must be **funded first** (`_fund` on the base — `deal` is StdCheats, not a `vm` cheatcode, so
it cannot live in the library). Coverage spans lender (deposit/mint/withdraw/redeem/settle/
fallbackExit), borrower (supplyCollateral/activate/borrow/repay/withdrawCollateral/setSettlementLtv),
keeper (`liquidate` asserts **no** bad debt, `liquidateBadDebt` asserts bad debt **is** realized),
and interest utilities. Extend `MarketActions` rather than sprinkling ad-hoc assertions in tests.

### Black-box, Model-first

Tests are derived from **requirements** (specs), **never from the implementation** — a test
read off the code inherits its bugs. Model each method independently (requirements · revert
conditions · parameter boundaries · all branches) and recompute expected numbers from the spec
formula. Fuzz and invariants are mandatory for state-mutating methods, not just example tests.
Coverage is necessary hygiene but not the goal — completeness is the closed branch checklist;
mutation score is the honest measure of test strength.

### Math Recomputation

Where contracts compute amounts (shares↔assets, slice sizing, oracle conversions, settlement LTV),
re-derive the expected number from inputs using the same formula. This catches drift in either the
contract or the test setup.

### Naming

- `test_<scenario>_<expectation>` for single-shot tests.
- `testFuzz_<property>` for fuzz.
- `invariant_<property>` for invariant runs.
- `testRevert_<reason>` for explicit failure-path coverage.

### Discipline

- Tests land with the change. Separate "tests follow-up" PRs are not accepted for new functionality.
- After source changes, run at least `forge build --force` and `make test-local` (`make test` when a fork
  setup is configured).

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/): the subject starts with a type
prefix, an optional scope, and a short imperative summary.

```
<type>(<optional scope>): <summary>
```

- Allowed types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`, `ci`, `perf`, `style`.
- Scope is optional and names the area touched, e.g. `feat(controller):`, `fix(vault):`,
  `test(scenario):`, `chore(deps):`.
- Summary is imperative and lower-case, no trailing period; keep it under ~72 characters and put
  detail in the body.
- Breaking changes: add `!` after the type/scope (`refactor!:`) and explain the break in the body.

## Pull Request Notes

PR description includes:

- Test commands actually run. If contract surface changed, confirm `forge build --force` passes
  with `via_ir = false` (the default for this repo).
- Storage layout impact for struct, mapping, or proxy/controller storage changes (which slot
  moved, whether append-only).
- Updated specification (`docs/specs/<Contract>.md`) for behaviour-changing PRs.
- For a `lib/lido-lend` pin bump: note what moved in the fork (accounting, ABI, storage layout) and
  that `.gitmodules`, `foundry.lock`, and the gitlink are staged together.
