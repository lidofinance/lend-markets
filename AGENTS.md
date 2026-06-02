# Repository Guidelines

## Project Structure

- `src/`: Solidity contracts for the Morpho Blue fork draft and Lido-specific extensions.
- `src/MorphoBlueFork.sol`: the Morpho Blue fork. Keep changes narrow and easy to compare with upstream.
- `src/controllers/`: controller and access-registry contracts. All Lido-specific extension logic lives here.
- `src/interfaces/`: local interfaces and hook payload structs.
- `src/oracle/`: local oracle adapters.
- `src/libs/`: pure libraries (math, data structures). Internal — they inline into call sites.
- `src/proxy/OssifiableProxy.sol`: imported Lido proxy source. Do not reformat it.
- `test/scenario/`: end-to-end flows on **freshly deployed** core / controller / vault. May
  run on a mainnet fork to reach real Lido stETH / wstETH contracts, but the protocol under test
  is deployed inside the test. Driven through shared helpers; happy path first, then revert and
  edge cases. Pure-library fuzz tests live here too.
- `test/integration/`: same flows on a mainnet fork against the **already-deployed** protocol —
  addresses come from `deployed-<network>.toml`. Verifies the live system still behaves correctly
  as its state evolves.
- `script/`: deployment scripts.
- `deployed-<network>.toml`: registry of deployed addresses per network (TOML so the file can
  carry inline `#` comments — deploy date, governance handover, audit refs). Source of truth
  for the integration tests; updated on every deploy/upgrade.
- `lib/`: pinned git submodules. Treat as vendored dependencies.
- `docs/specs/`: per-contract specifications (see Specifications section).
- `STYLE_GUIDE.md`: Solidity style guide (naming, structure, comments, fork conventions).
  Read it before writing or reviewing new contracts.

## Build, Test, And Formatting Commands

- Build: `forge build --force`.
- Test: `forge test`.
- Format check for local Solidity files:
  `forge fmt --check src/MorphoBlueFork.sol src/controllers src/interfaces src/oracle src/libs test`.
- Do not include `src/proxy/OssifiableProxy.sol` in formatting commands.
- Mainnet-fork tests skip when no mainnet fork context is available; guard with
  `vm.skip(!_hasMainnetLidoContracts(), "mainnet fork with Lido contracts required")`.
- The mainnet RPC for fork tests comes from `MAINNET_RPC_URL` (see `.env.example`). Each developer
  uses their own endpoint; do not hardcode addresses in the repo.

## Dependency Policy

- Foundry dependencies are pinned as git submodules under `lib/`.
- Do not edit files inside `lib/` unless the task is explicitly about dependency patching.
- When dependency pins change, stage and commit the relevant `.gitmodules`, `foundry.lock`,
  and `lib/<dependency>` gitlink updates together.
- `git ls-files --stage lib/<dependency>` should show mode `160000` for submodules.

## Morpho Fork Policy

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

## Solidity Style

See `STYLE_GUIDE.md` for naming, structure, comments, error/event placement and fork conventions.
Read before writing or reviewing contracts.

## Specifications

Every non-trivial contract gets a spec at `docs/specs/<ContractName>.md`. The spec captures what a
reviewer needs before reading code, not what the code already says.

- Sections: Purpose · State · Invariants · Externally Visible
  Behaviour (one subsection per external/public function) · Threat Model · Open Questions ·
  Change Log.
- Invariants are **testable**: each one maps to a scenario or integration assertion in `test/`.
- Behaviour subsections list preconditions, state mutations, events, reverts. Match the order in
  the source file.
- Threat model lists the actors (lender, borrower, liquidator, controller admin, oracle, IRM) and
  what each is trusted not to do.
- New contracts: spec lands in the same PR as the contract. Behaviour-changing PRs update the
  existing spec under the same commit.
- Reference the spec from contract-level NatSpec: `@dev See docs/specs/Foo.md`.

## Testing Guidelines

### Layout

Two suites, no overlap:

- `test/scenario/<Flow>.t.sol` — full flows against a **freshly deployed** protocol. The test
  deploys core / controller / vault from scratch, then drives helpers end-to-end. May still use
  a mainnet fork to reach real Lido stETH / wstETH (no usable local mock for those), but the
  protocol under test is constructed inside the test. Pure-library fuzz tests live alongside as
  `testFuzz_<property>`.
- `test/integration/<Flow>.t.sol` — same flows on a mainnet fork against the **already-deployed**
  protocol. Addresses come from `deployed-<network>.toml`; the test treats our system as a live
  third party and verifies it still works under current state (live positions, accrued interest,
  real oracle prices). Run with `forge test --fork-url $MAINNET_RPC_URL`.

### Helper Pattern (Scenario And Integration)

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

Tests compose helpers. If a test needs a one-off check that doesn't fit the helper, extend the
helper or add a sibling — don't sprinkle ad-hoc assertions across tests.

### Math Recomputation

Where contracts compute amounts (shares↔assets, slice sizing, oracle conversions, watermark LTV),
tests re-derive the expected number from inputs using the same formula. This catches drift in
either the contract or the test setup.

### Naming

- `test_<scenario>_<expectation>` for single-shot tests.
- `testFuzz_<property>` for fuzz.
- `invariant_<property>` for invariant runs.
- `testRevert_<reason>` for explicit failure-path coverage.

### Discipline

- Tests land with the change. Separate "tests follow-up" PRs are not accepted for new functionality.
- After source changes, run at least `forge build --force` and `forge test`.

## Pull Request Notes

PR description includes:

- Test commands actually run. If contract surface changed, confirm `forge build --force` passes
  with `via_ir = false` (the default for this repo).
- Storage layout impact for struct, mapping, or proxy/controller storage changes (which slot
  moved, whether append-only).
- Updated specification (`docs/specs/<Contract>.md`) for behaviour-changing PRs.
- For changes to `src/MorphoBlueFork.sol`: explicit upstream-diff note (e.g. "touches accounting"
  / "controller-only addition" / "fork-additions library only").
