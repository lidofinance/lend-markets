# Formal verification handover

This directory contains AlexZoid's Certora formal verification work from the
Cyfrin Lido Lend engagement, imported into the public `lend-markets` repository.

## Start here

- [Formal verification report and reproduction instructions](./README.md)
- [Verification methodology](../certora_docs/README.md)
- [Initial engagement report, September 1, 2026](./reports/2026-09-01-cyfrin-lido-lend-FV.pdf)
- [Follow-up report, September 15, 2026](./2026-09-15-cyfrin-lido-lend-FV.pdf)

The PDFs are unchanged copies of the original deliverables. Their dates,
repository names, commit identifiers, and results describe the historical
engagement. The September 1 report accompanies the handover as a historical
record; the executable specifications in this directory are the later,
post-remediation suite, rather than the earlier report's source snapshot.

## Contents

- `confs/`: 76 Certora configurations, including the shared base configuration.
- `specs/`: 122 CVL specifications and setup models.
- `helpers/`: five Solidity harnesses and helpers.
- `mutations/`: 1,197 deliberately faulted source variants, their documentation,
  and the mutation runner.
- `assets/`: the diagrams used by the follow-up report.
- `../certora_docs/`: the methodology guide and its illustration.

The suite covers the core, guardian signals, market controller, lender vault,
exit books, interest-rate models, and linked-contract scenes. Read each scene's
assumptions, bounds, and narrowed configurations alongside its results.

## Public repository layout

The engagement used the names `lido-lend-markets`, `lido-lend`, and
`lido-lend-irm`. The public repositories are now
[`lend-markets`](https://github.com/lidofinance/lend-markets),
[`lend`](https://github.com/lidofinance/lend), and
[`lend-irm`](https://github.com/lidofinance/lend-irm).

Run commands from the `lend-markets` repository root. Initialize the pinned
dependencies first:

```sh
git -c 'url.https://github.com/.insteadOf=git@github.com:' \
  submodule update --init --recursive
```

References to the old physical dependency paths have been adapted to
`lib/lend/` and `lib/lend-irm/`, including config inputs, mutation targets, and
documentation links. The `@lido-lend/` and `@lido-lend-irm/` import aliases
remain the aliases defined by the public repository's `remappings.txt`.

The command above uses HTTPS for nested SSH URLs for that invocation only.

The pinned IRM dependency still names its own nested core dependency
`lib/lido-lend/`. The round-trip factory scene retains that nested name at
`lib/lend-irm/lib/lido-lend/`; only the top-level dependency paths are renamed.

## Results and compatibility

The September 15 report records 1,200 properties: 1,161 proved and 39 timed out.
A timeout is an undecided result. These are historical results, not a new proof
of the current public source tree.

This handover was prepared against public `main` at
`23416c43c4038ea3c00a13d6203949c8f88905cc`. Protocol sources have changed since
the verification work. Compilation or specification compatibility may therefore
need further adaptation by the maintainers. The import preserves the original
verification rules, models, compiler and EVM settings, solver budgets, and
historical results; only repository paths and handover documentation are adapted.

The recorded toolchain is Certora Prover/CLI 8.16.2 and Solidity 0.8.36, targeting
Prague in the prover configuration. This differs from the public Foundry
configuration's Cancun target. The original verification settings are retained
for provenance; they have not been silently aligned to the Foundry build.

No production contracts, dependency pins, or Foundry settings are changed by
this import. See the PR's validation notes for the checks performed on the
handover and any observed compatibility failures.

### Observed compatibility drift

Local compilation and typechecking with `--compilation_steps_only` were run on
13 representative configurations, covering all 12 scene directories and the
factory round-trip scene. Twelve passed. The GuardianSignals valid-state scene
failed in `GuardianSignals_base.spec:50`: the historical selector is
`heartbeat(address, BlockInfoWithHash)`, while the public contract now exposes
`heartbeat(address, BlockInfoWithHash, bytes)`.

The original specification is retained for the maintainers to adapt. Passing
compilation and typechecking is not a proof result, and these sample checks do
not establish compatibility of every configuration. No verification request
was submitted and no historical verdict was updated.

## Historical evidence

The raw prover-run archives and earlier source snapshots are not included in
this import. The separate post-remediation archive indexes 1,205 checks because
it includes five additional reachability checks without rows in the report;
its 1,166 verified / 39 timeout totals should not be substituted for the
report's 1,161 / 39 totals. The report's mutation column counts properties with
mutation coverage, whereas the corpus contains 1,197 mutant source files.

## Import provenance

The suite and methodology come from the final follow-up verification snapshot
`a199e2584009da72939b83dec60990c064c32848`. The initial PDF comes from snapshot
`f6faabdf095d0576389dc8ce72821ec71bdbabec`.

The historical audit revisions remain recorded in the reports. Those commit
identifiers predate the repository history rewrite and may not resolve in the
public repositories. They have not been replaced with newer commits that would
change the meaning of the recorded results.
