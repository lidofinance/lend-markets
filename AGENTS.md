# Repository Guidelines

## Project Structure

- `src/`: Solidity contracts for the Morpho Blue fork draft and Lido-specific extensions.
- `src/MorphoBlueFork.sol`: the Morpho Blue fork. Keep changes narrow and easy to compare with upstream.
- `src/controllers/`: controller and access-registry contracts.
- `src/interfaces/`: local interfaces and hook payload structs.
- `src/oracle/`: local oracle adapters.
- `src/proxy/OssifiableProxy.sol`: imported Lido proxy source. Do not reformat it.
- `test/integration/`: happy-path integration and mainnet-fork tests.
- `lib/`: pinned git submodules. Treat as vendored dependencies.

## Build, Test, And Formatting Commands

- Build: `forge build --force --offline`.
- Test: `forge test --offline`.
- Format check for local Solidity files:
  `forge fmt --check src/MorphoBlueFork.sol src/controllers src/interfaces src/oracle test`.
- Do not include `src/proxy/OssifiableProxy.sol` in formatting commands.
- Mainnet-fork tests should skip when no mainnet fork context is available.

## Dependency Policy

- Foundry dependencies are pinned as git submodules under `lib/`.
- Do not edit files inside `lib/` unless the task is explicitly about dependency patching.
- When dependency pins change, stage and commit the relevant `.gitmodules`, `foundry.lock`,
  and `lib/<dependency>` gitlink updates together.
- `git ls-files --stage lib/<dependency>` should show mode `160000` for submodules.

## Morpho Fork Policy

- Keep `src/MorphoBlueFork.sol` as close to upstream Morpho Blue as practical.
- New storage added to the fork should be placed after the upstream-style state, not mixed into
  the original state block.
- Prefer upstream Morpho dependencies, libraries, errors, events, and style where they already fit.
- Define fork-specific errors and events locally in `src/MorphoBlueFork.sol` unless there is a clear
  reason to move them elsewhere.
- Update `FORK_NOTES.md` when the fork point or material fork delta changes.

## Solidity Style

- Prefer custom errors over revert strings in new local contracts.
- Keep NatSpec concise and do not reference ADR numbers from contract NatSpec.
- Keep comments focused on non-obvious behavior, invariants, or fork-specific deviations.
- For controller hook payloads, prefer structs in `IMarketController` over positional
  `abi.encode` / `abi.decode` tuples.
- Do not add Solhint, Slither, pre-commit, CI, or deployment tooling unless the task explicitly
  covers repository tooling.

## Testing Guidelines

- This repository currently keeps only happy-path integration and fork tests.
- Add broader unit, invariant, or upstream-compatibility tests only when the task explicitly asks
  for that expansion.
- Order scenario tests with the happy path first; add revert or edge-case tests after the main flow.
- After source changes, run at least `forge build --force --offline` or `forge test --offline`.

## Pull Request Notes

- Include test commands that were run.
- Mention storage layout impact when changing structs, mappings, or proxy/controller storage.
