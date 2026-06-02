# Solidity Style Guide

Rules for writing and reviewing contracts in this repository. AGENTS.md links here; this file
is the source of truth for style decisions. Update it when conventions change; do not duplicate
them back into AGENTS.md.

## Compile Target

- **`via_ir = false`** is the canonical compile pipeline. Legacy Solc must build the codebase.
- When stack-too-deep arises: extract helpers, pack arguments into memory structs, scope locals
  in `{ }` blocks. **Never** flip `via_ir = true` to silence the error.
- `optimizer_runs` is tuned for deploy size, not call gas. Keep contracts under the EIP-170 24KB
  limit on every change.

## File Structure

Order inside a contract file, top to bottom:

1. SPDX header and `pragma`.
2. Imports (grouped: external first, then `@morpho-blue/*`, then `@openzeppelin/*`, then local
   `./`-relative).
3. Local interfaces (only those needed by the file).
4. Fork-added libraries (errors, events) — see `MorphoBlueForkErrorsLib` /
   `MorphoBlueForkEventsLib` in `src/MorphoBlueFork.sol` for the pattern.
5. Contract body.

Inside a contract, order top to bottom:

1. `using` directives.
2. Constants and immutables.
3. Custom errors.
4. Events.
5. Storage variables (or storage struct + namespaced slot for upgradeable contracts).
6. Modifiers.
7. Constructor / `initialize`.
8. External functions.
9. Public functions.
10. Internal functions.
11. Private functions.

## Naming

- **Contracts**: `PascalCase`. Match the file name.
- **Interfaces**: prefixed with `I` (`IMarketController`, `IMorphoBase`).
- **Libraries**: suffixed with `Lib` (`MaxHeapLib`, `DeleverageSliceLib`).
- **Functions / variables / parameters**: `camelCase`.
- **Internal / private** helpers: leading underscore (`_validateDeleverage`, `_storage`).
- **Constants and immutables**: `SCREAMING_SNAKE_CASE`.
- **Events**: past tense or noun (`Deleverage`, `MarketControllerSet`, `BorrowerWatermarkSet`).
- **Errors**: noun phrase, no `Error` suffix (`Unauthorized`, `WatermarkOutOfRange`).
- **Test functions**: see Testing Guidelines in AGENTS.md.

## Errors And Reverts

- **Core (`src/MorphoBlueFork.sol`)** keeps upstream Morpho conventions: `require(..., "string")`
  with constants in a dedicated library block (`MorphoBlueForkErrorsLib`). Preserves diff against
  upstream.
- **New contracts** (controllers, libs, vaults, adapters) use custom errors. Declare them at the
  top of the contract, near other state declarations.
- Custom errors include parameters where useful (`InsufficientCollateralOut(received, minimum)`),
  no parameters when the name alone is enough (`Unauthorized`).

## Visibility

- Always declare explicit visibility (`external` / `public` / `internal` / `private`). No
  implicit defaults.
- Default to the most restrictive that compiles: `private` > `internal` > `public` > `external`.
- Public state variables get auto-generated getters; prefer explicit `external view` getters when
  the ABI needs to be stable and human-readable.

## Functions

- One responsibility per function. If a function does two things, factor.
- Function parameters that come from external input must be validated explicitly at the function
  entry (`require` / custom error). Internal-only helpers can trust their callers.
- Return named values (`returns (uint256 sharesBurned, ...)`); document them in NatSpec.

## Struct And Tuple Hygiene

- **Named struct initialisation** (`Foo({a: 1, b: 2})`). No positional struct literals in new
  code.
- Use struct hook payloads (`IMarketController.*HookData`) over positional `abi.encode` /
  `abi.decode` tuples — keeps the payload schema obvious and refactor-safe.
- Pack storage structs deliberately; document the slot layout in a comment when packing is
  non-trivial.

## Constants

- Magic numbers go in named constants; document the source (oracle scale, WAD, `KEY_SCALE`,
  etc.).
- Re-use upstream constants (`WAD`, `ORACLE_PRICE_SCALE`) instead of re-declaring local ones with
  the same value.

## Comments And NatSpec

- NatSpec explains **WHY** — invariants, non-obvious behaviour, fork-specific deviations. Not
  WHAT (well-named identifiers cover that).
- Keep NatSpec concise. One line per parameter when it adds something; skip when it would just
  restate the type.
- Do not reference ADR numbers from contract NatSpec. Cite ADRs from `docs/` or the spec at
  `docs/specs/<Contract>.md`.
- Body comments focus on non-obvious behaviour, invariants, or fork-specific deviations. Never
  restate code.
- Avoid comments that pin to specific tasks/PRs/issues — they rot. Cite stable artefacts (ADRs,
  specs) only.

## Fork Conventions

- `src/MorphoBlueFork.sol` is a near-verbatim copy of Morpho Blue. Style choices favour matching
  upstream over local preference.
- Fork-added errors and events live in dedicated library blocks at the top of the core file
  (`MorphoBlueForkErrorsLib`, `MorphoBlueForkEventsLib`) so the upstream diff is visible at a
  glance.
- Do not reformat upstream Morpho code unless the upstream patch itself changes.
- `src/proxy/OssifiableProxy.sol` is imported Lido source — never reformat.

## Tooling

- Do not add Solhint, Slither, pre-commit, CI, or deployment tooling unless the task explicitly
  covers repository tooling.

## When This Guide Doesn't Cover It

Default to the convention already used in the file. If there is no convention, match upstream
Morpho or OpenZeppelin contracts of the same shape. If still ambiguous, ask before introducing a
new style.
