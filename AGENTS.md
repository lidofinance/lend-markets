# Repository Guidelines

## Project structure

- `src/`: Solidity contracts for the Morpho Blue fork draft and Lido-specific extensions.
- `src/MorphoBlueFork.sol`: the Morpho Blue fork. Keep changes narrow and easy to compare with upstream.
- `src/controllers/`: controller and access-registry contracts. All Lido-specific extension logic lives here.
- `src/interfaces/`: local interfaces and hook payload structs.
- `src/oracle/`: local oracle adapters.
- `src/libs/`: pure libraries (math, data structures). Internal — they inline into call sites.
- `src/proxy/OssifiableProxy.sol`: imported Lido proxy source. Do not reformat it.
- `test/unit/`: per-library, per-function unit and fuzz tests with explicit per-branch assertions.
- `test/integration/`: end-to-end flows on a fresh test deployment; driven through shared helpers.
- `test/regression/`: helper-driven flows against the **deployed** contracts on a live fork.
  Coverage target is every flow on every contract — see Regression tests in Testing guidelines.
- `script/`: deployment scripts.
- `deployed-<network>.toml`: registry of deployed addresses per network (TOML so the file can
  carry inline `#` comments — deploy date, governance handover, audit refs). Source of truth
  for the regression base test; updated on every deploy/upgrade.
- `lib/`: pinned git submodules. Treat as vendored dependencies.
- `docs/specs/`: per-contract specifications (see Specifications section).

## Build, test, and formatting commands

- Build: `forge build --force`.
- Test: `forge test`.
- Format check for local Solidity files:
  `forge fmt --check src/MorphoBlueFork.sol src/controllers src/interfaces src/oracle src/libs test`.
- Do not include `src/proxy/OssifiableProxy.sol` in formatting commands.
- Mainnet-fork tests skip when no mainnet fork context is available; guard with
  `vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required")`.
- The mainnet RPC for fork tests comes from `MAINNET_RPC_URL` (see `.env.example`). Each developer
  uses their own endpoint; do not hardcode addresses in the repo.

## Dependency policy

- Foundry dependencies are pinned as git submodules under `lib/`.
- Do not edit files inside `lib/` unless the task is explicitly about dependency patching.
- When dependency pins change, stage and commit the relevant `.gitmodules`, `foundry.lock`,
  and `lib/<dependency>` gitlink updates together.
- `git ls-files --stage lib/<dependency>` should show mode `160000` for submodules.

## Morpho fork policy

- `src/MorphoBlueFork.sol` is a near-verbatim copy of Morpho Blue. Minimum changes only.
- **Do not touch the core accounting**: positions, supply/borrow shares, interest accrual, market
  creation primitive, liquidate path. These stay byte-identical to upstream where practical.
- All extension logic — Lido policy, controller hooks, deleverage flavours, watermark, batch
  orchestration, lender auth — lives in the controller (`src/controllers/LidoMarketController.sol`),
  not in core.
- New core storage is appended after upstream state, never mixed in.
- Fork-added errors and events live in dedicated library blocks at the top of the core file
  (`MorphoBlueForkErrorsLib`, `MorphoBlueForkEventsLib`) so the upstream diff stays visible.
- Update `FORK_NOTES.md` when the fork point or material fork delta changes.

## Solidity style

- **Compile target: `via_ir = false`.** When stack-too-deep arises, refactor: extract helpers,
  pack arguments into memory structs, scope locals in `{ }` blocks. Do not flip on `via_ir`.
- Core (`MorphoBlueFork.sol`) keeps upstream Morpho conventions: `require(..., "string")` reverts
  via library constants, library blocks for fork additions.
- New contracts (controllers, libs, vaults) prefer custom errors and explicit visibility
  (`external` / `internal` / `private`).
- Use struct hook payloads (e.g. `IMarketController.*HookData`) over positional
  `abi.encode` / `abi.decode` tuples.
- Named struct initialisation (`Foo({a: 1, b: 2})`); no positional struct literals in new code.
- Magic numbers go in named constants; document the source (oracle scale, WAD, etc.).
- NatSpec explains WHY (invariants, non-obvious behaviour, fork-specific deviations) — not WHAT.
- Keep NatSpec concise; do not reference ADR numbers from contract NatSpec. Cite ADRs from `docs/`.
- Comments focused on non-obvious behaviour, invariants, or fork-specific deviations.
- Do not add Solhint, Slither, pre-commit, CI, or deployment tooling unless the task explicitly
  covers repository tooling.

## Specifications

Every non-trivial contract gets a spec at `docs/specs/<ContractName>.md`. The spec captures what a
reviewer needs before reading code, not what the code already says.

- Sections: Purpose · State · Invariants · Externally visible
  behaviour (one subsection per external/public function) · Threat model · Open questions ·
  Change log.
- Invariants are **testable**: each one maps to a unit or integration assertion in `test/`.
- Behaviour subsections list preconditions, state mutations, events, reverts. Match the order in
  the source file.
- Threat model lists the actors (lender, borrower, liquidator, controller admin, oracle, IRM) and
  what each is trusted not to do.
- New contracts: spec lands in the same PR as the contract. Behaviour-changing PRs update the
  existing spec under the same commit.
- Reference the spec from contract-level NatSpec: `@dev See docs/specs/Foo.md`.

## Testing guidelines

### Layout

- `test/unit/<Module>.t.sol`: one file per library or single-purpose contract. Explicit
  assertions on every branch. Include fuzz tests for pure math (`testFuzz_<invariant>`).
- `test/integration/<Flow>.t.sol`: end-to-end flows on a fresh test deployment, driven via
  shared helpers. Cover the happy path first, then revert and edge cases.
- `test/regression/<Flow>.t.sol`: same flows run against **deployed contracts on a fork at
  the latest mainnet state** (not a fresh deployment). See Regression tests below.

### Helper pattern (integration and regression)

Every user-visible action has a helper on the base test contract. The helper does the action and
checks everything around it — call sites don't repeat assertion blocks. Each helper:

1. Captures pre-state for the actors involved (`position[id][addr]`, `market[id]`, ERC-20 balances).
2. Sets up `vm.expectEmit` for every event the action should fire.
3. Performs the call (`vm.prank` + invocation); returns the recorded outputs.
4. **Recomputes the expected post-state from inputs independently** — do not trust the contract's
   own return value. Re-derive shares↔assets, slice sizing, oracle conversions etc. using the
   formula in the spec.
5. Asserts state deltas match the recomputation, all expected events fired with exact args,
   token balances moved by the right amount.

Integration tests compose helpers. If a test needs a one-off check that doesn't fit the helper,
extend the helper or add a sibling — don't sprinkle ad-hoc assertions across tests.

### Unit tests

Drive the smallest possible surface (one function, one library). Explicit per-branch asserts, no
helper indirection. Fuzz any property with a closed-form invariant (`testFuzz_<property>`).

### Math recomputation

Where contracts compute amounts (shares↔assets, slice sizing, oracle conversions, watermark LTV),
tests re-derive the expected number from inputs using the same formula. This catches drift in
either the contract or the test setup.

### Regression tests

Live in `test/regression/`. Their job: prove that the protocol still behaves correctly **as the
deployed system evolves**. Unlike integration tests, regression tests do not deploy fresh — they
fork mainnet at the latest block and drive the **real, deployed contracts** with whatever state
those contracts currently hold (live positions, accrued interest, real oracle prices, real lender
balances).

Rules:

- Address registry: deployed addresses live in `deployed-<network>.toml` (one file per network),
  read by the regression base test via `vm.parseToml`. No address strings inline in tests. Each
  entry carries `#` comments with provenance — deploy commit, audit ref, governance handover date.
- Fork target: latest block at run time (`forge test --fork-url $MAINNET_RPC_URL`), not a pinned
  block — the point is to follow live state.
- Reuse the integration helpers. The helper's pre-state snapshot already handles arbitrary
  starting state, so the same helper that powers integration tests also powers regression. No
  helper duplication.
- Coverage target: **every external/public function on every contract**, every documented flow,
  every reachable revert path. The matrix is the spec's "Externally visible behaviour" section
  cross-product with realistic actor states (matured, dust, frozen, paused, heap head, heap tail,
  bad-debt, healthy-but-unhealthy, etc.).
- Scenarios that mutate state (supply, borrow, deleverage, etc.) seed their own actors via
  `deal` / impersonation so the regression run leaves the fork state as it found it
  (`vm.snapshot` + `vm.revertTo` between independent flows).

A regression test that fails on a previously-passing flow is the strongest possible signal that
the protocol just regressed. Treat it accordingly.

### Naming

- `test_<scenario>_<expectation>` for single-shot tests.
- `testFuzz_<property>` for fuzz.
- `invariant_<property>` for invariant runs.
- `testRevert_<reason>` for explicit failure-path coverage.
- `testRegression_<flow>_<expectation>` for regression suite entries.

### Discipline

- Tests land with the change. Separate "tests follow-up" PRs are not accepted for new functionality.
- After source changes, run at least `forge build --force` and `forge test`.

## Pull request notes

PR description includes:

- Test commands actually run. If contract surface changed, confirm `forge build --force` passes
  with `via_ir = false` (the default for this repo).
- Storage layout impact for struct, mapping, or proxy/controller storage changes (which slot
  moved, whether append-only).
- Updated specification (`docs/specs/<Contract>.md`) for behaviour-changing PRs.
- For changes to `src/MorphoBlueFork.sol`: explicit upstream-diff note (e.g. "touches accounting"
  / "controller-only addition" / "fork-additions library only").
