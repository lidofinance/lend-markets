# Testing Reference

The kinds of testing the protocol needs across its lifecycle: what each kind is, what it requires,
and when it runs. Authoring rules (black-box/model-first, helper patterns, naming) live in
[AGENTS.md](../AGENTS.md#testing-guidelines).

Each kind answers a different question; none substitutes for another. A change is gated by the
kinds its lifecycle stage requires (see the gate matrix at the end).

## 1. Unit tests

One contract or pure library in isolation, method by method: every branch, every revert path,
every parameter boundary; fuzz harnesses for pure code. Expected values are modeled from the
specification, never read off the implementation.

- **Requires:** nothing — local EVM, no network.
- **Runs:** on every change, locally and in CI (`make test-local` includes them).
- **Here:** `test/unit/`, one file per contract.

## 2. Integration (scenario) tests

Cross-contract flows on a freshly deployed stack with mock tokens: full lender / borrower / keeper
lifecycles, settlement, governance surfaces, bundled flows. Every user-visible action recomputes
its expected numbers independently and asserts state deltas, events, and token movements.

- **Requires:** nothing — local EVM; the stack is deployed by the test setup itself.
- **Runs:** on every change (`make test-local`).
- **Here:** `test/scenario/` on `test/setup/` + `MarketActions`.

## 3. Invariant (stateful fuzz) tests

Handler-driven properties over randomized bounded action sequences: solvency, activation-inflow
conservation, vault ERC-4626 conformance. Mandatory for state-mutating surfaces; a revert path
surfaced here gets pinned as an explicit deterministic test.

- **Requires:** nothing — local EVM. `TEST_SEED` fixes a run; unset seeds are logged for replay.
- **Runs:** on every change (`make test-local`); CI pins `TEST_SEED=1`.
- **Here:** `test/invariant/` + `invariant/handlers/`.

**Solvency simulations** (`test/simulation/`) drive one market for 30 or 365 simulated days. Lenders,
borrowers, keepers, governance and the vault-share exit book act at random, and a model of the
protocol state predicts every outcome, reverts included. The guardians follow a fixed routine: both
heartbeat every hour, and every ten days one ordinary borrower is suspected, flagged, banned and
unbanned. Rare events, such as governance changes, are scheduled once per run at a random time; the
price crash and the settlement scenarios also wait until they can succeed. Every 20 iterations the
books and the settlement queue are checked against the model. The run then unwinds and reconciles
every account. `test/setup/ActivationModel.sol` restates the collateral-activation rules from the spec.

The 30-day runs are part of `make test-local` and assert coverage floors; each floor's comment says why
it holds. `make test-simulation` runs the 365-day versions, and so does the fuzz workflow when dispatched.
`make test-mutation` runs the 30-day simulations against mutants of `src/`; it is local only and needs
forge >= 1.8.0.

Limitations:

- Moves run in a fixed order, one per hour; same-block and sub-hour cases are left to the unit suites.
- The simulated transaction is the whole run on the pinned forge 1.7.1 and one `iterate` call on 1.8.x,
  not one user call. `ActivationInflow.invariant.t.sol` covers the add-then-remove inflow rule.
- Activation config changes move only the activating lock and the guardian-quorum delay.
- `MorphoExitBook` and the guardian-signal admin surface are not driven; their own suites cover them.

## 4. Empty-fork deploy tests (scratch deploy on a fork)

The full deploy path exercised on a fork of the target network that is empty of the protocol but
has the real external world (real tokens, wstETH, governance contracts): deploy scripts run end to
end, artifacts are written, markets activate. This is what proves the *deploy tooling*, not the
contracts.

- **Requires:** an archive RPC of the target network; anvil.
- **Runs:** on deploy-script changes; as the pre-deploy rehearsal (full dry run of the deploy
  on a fork, under a scratch run id).
- **Here:** `make provision-fork` / `make test-fork-provision` (deploys + activates the `fork-*`
  markets, then runs the fork suites against them).

## 5. Live-deployment regression tests (fork against a real run)

Flow tests bound to an **already-deployed** protocol: fork the network that holds it, read the
run's immutable artifacts, and drive real flows against the live state. Never deploys what it
tests. This is the regression net for "the deployed protocol still behaves" — after code changes
or governance actions.

These suites check **functional correctness, not state values**: they take addresses from the
artifacts, read parameters off the chain, and assert *relative* behavior (read a value, act,
assert the delta) plus *relational* validity (`minActivationDelay < maxActivationDelay` and the
like), so a degenerate on-chain configuration still trips them. Absolute parameter assertions
belong to state-mate (kind 9) — baking state into these tests would mean rewriting them on every
parameter change. When authoring, mind the asymmetry: a false positive fails loudly and gets
fixed; a false negative accumulates silently and is the more dangerous of the two.

- **Requires:** `RPC_URL` holding the deployment + `ARTIFACTS_DIR` naming the run under
  `deployed/<run>/`; `FORK_BLOCK` to pin a block for replay. Reverts (never skips) when the setup
  is missing; only a role with no market in the run skips a suite.
- **Runs:** after every deploy; on protocol-touching changes.
- **Here:** `test/fork/` via `make test-fork` / `make fork-run RUN=<run>`.

## 6. Acceptance tests (deployment verification on a fork)

Assert the deployed stack is exactly what the plan intended: wiring, the full initial role
topology (direct enumerable-role checks), and its state relative to the activation motion —
**readiness** mode before the motion, **activated** mode after it, plus a multi-market activation
simulation. Expected addresses come from the immutable artifacts; the reviewed motion inputs
(pauser committee, settlement flag) come from the environment so a wrong artifact cannot vouch for
itself. Acceptance is a **post-deploy-only** gate: it also asserts the virgin state (no positions
taken, nothing borrowed yet), so it cannot be re-run meaningfully once the protocol is in use.
Audits launch state only — not later governance changes; the operational counterpart is state-mate
(kind 9).

- **Requires:** fork RPC + `deployed/<run>/protocol.toml` (`ACCEPTANCE_REGISTRY`) +
  `ACCEPTANCE_PAUSER_COMMITTEE` + `ACCEPTANCE_ENABLE_SETTLEMENT`.
- **Runs:** on deploy day — readiness before the activation motion (a gate on starting it),
  activated + multi after enactment; again for every added market.
- **Here:** `test/acceptance/` via `make acceptance-run RUN=<run> MARKET=<m>` /
  `make acceptance-run-multi RUN=<run> MARKET_A=<a> MARKET_B=<b>`.

## 7. Voting tests (governance simulation)

The Aragon vote that wires the protocol (adds EasyTrack factories, any Agent-forwarded items) is
itself code and gets tested: simulate the vote on a fork — start, pass, enact — then assert the
post-vote state (factories registered with exactly the intended permissions, nothing wider; DG
classification honored: Agent-forwarded items go through the Dual Governance proposal with its
timelock, plain items execute at enactment).

- **Requires:** fork of the network with its live governance (Voting, EasyTrack, DG); the vote
  script.
- **Runs:** before the vote is started for real; the enacted state is re-checked on-chain after.
- **Lives here:** the tests themselves (vote simulation + after-vote assertions) live in this
  repo's suite; the vote-script repo (`lidofinance/scripts`) carries only the trigger that invokes
  this run.

## 8. Motion tests (EasyTrack factories)

Each motion factory is a bounded governance action and gets its own fork tests: create a motion
via the factory as the trusted caller, wait out the objection period, enact, and assert the
on-chain effect equals the factory's bounded action — and that nothing outside its `(target,
selector)` permissions is reachable.

- **Requires:** fork with live EasyTrack + the deployed factories + this run's target contracts.
- **Runs:** before the factories are added to EasyTrack; the activation/fee motions are then
  re-verified on the live network by acceptance (kind 6).
- **Lives in:** the factories' repo (`easy-track`); this repo's
  `MultiMarketActivationSimulation` replays the motion item sequence as the executor.

## Parameter-change flow (how the test kinds compose around a motion)

Every market-parameter change (guardian roster, caps, activation/settlement config) runs through
one pipeline; the only exemption is an **unban motion**, which touches no market configuration and
needs only an address-presence check.

1. **PR first.** The change starts as a PR to this repo updating the market config, plus a forum
   post stating the intent and the safety rationale. The motion's parameters must equal the PR's
   exactly.
2. **Pre-motion tests.** Before the motion is created, the pending change is validated on a fork
   of the live deployment. Mechanics:
   - the **multisig-level calldata** goes into a small `pending_action` TOML next to the network's
     deploy config — encoded at the multisig boundary, not deeper;
   - an **apply-pending-action make command** forks the live network, applies the transaction, and
     leaves the fork running;
   - the fork-test setup **reuses that existing fork** (fork-URL passthrough) instead of spawning
     its own, and the regression suites (kind 5) run over it — they assert the mechanics still
     work, not the values;
   - **state-mate runs on the same fork** against the updated config — the value diff is reviewed
     there (for a simple change this is browser-only: edit the field in the state-mate config,
     open the PR, dispatch the `pending-action` workflow on its branch);
   - a **green `pending-action` run on the PR branch** gates the motion.
   Validation must complete **before** the motion starts.
3. **Post-enact.** State-mate re-run against the updated intended config (kind 9).

Role coverage follows the guinea-pig principle: every motion factory is exercised end to end on
**one** test market; the expected role set is hardcoded as the expectation for *any* market's
configuration (the factory wires every market identically), and each market is checked against
that same set. Deploy commands used by tests live next to the tests that use them, so a removed
test cannot orphan a forgotten deploy path.

## 9. Deploy verification (state-mate / diffyscan / artifact checks)

Non-forge verification layers on a live deployment:

- **artifact sanity** — files appeared, metadata records the chain id and deploy commit, every
  recorded address has bytecode;
- **state-mate** — on-chain state vs the intended configuration, from a reviewed YAML config.
  Unlike acceptance it works at **any operational moment**: run it over the
  critical state (ACLs and the like) after every governance action. The config is
  **self-healing**: state-mate can pull the current on-chain values back into the config, so
  maintenance is reviewing the diff, not hand-editing — and the config must be updated with every
  EasyTrack motion, since the parameters move with the protocol;
- **diffyscan** — deployed bytecode vs pinned source, via the explorer's verified source (only on
  runs where explorer verification is enabled).

- **Requires:** the run's artifacts; a state-mate config for the deployment; explorer verification
  for diffyscan.
- **Runs:** on deploy day after each stage; state-mate after every governance
  action.

## 10. On-chain drills (live-network rehearsals)

Exercises on the real (test)network that no fork can substitute, because they involve the real
actors, keys, and off-chain services: borrow lifecycle with a measured activation time under the
guardian quorum gate, settlement, liquidation via a mock price cut, supply-cap revert + raise
motion, circuit-breaker pause/resume through the real governance route, guardian/delegate
heartbeat and suspect flow.

- **Requires:** the live deployment, funded role holders, the off-chain services running.
- **Runs:** deploy day and after major operational changes.

## 11. Off-chain component tests

Each off-chain service carries its own suite in its repo: unit + integration against a
devnet/testnet deployment, plus end-to-end runs against a live devnet (a guardian service's
heartbeat/suspect signals landing on the real registry double as the guardian drill of kind 10).

- **Requires:** per-repo tooling; a devnet deployment to point at.
- **Runs:** per-repo CI; e2e against each fresh deployment.

## Gate matrix — which kinds gate which stage

| Stage | Gating kinds |
| --- | --- |
| Every change (local) | 1 unit · 2 integration · 3 invariant (`make test-local`) |
| PR / CI merge gate | 1–3 + 4 empty-fork (`test-fork-provision`) + fmt/lint |
| Dependency pin bump | 1–3 full + submodule gitlink check |
| Pre-deploy freeze | full `make test` + 4 as the deploy-plan rehearsal + 7 voting (here, triggered from `scripts`) + 8 motion (`easy-track`) |
| Deploy day | 6 acceptance readiness → (motions) → 6 activated + multi · 9 deploy verification · 10 drills |
| Post-deploy / operations | 5 regression against the live run · 9 state-mate after governance actions · 11 off-chain e2e |
| New market / upgrade | 4 on a fork first, then 5 + 6 + 9 for the new market |

## Reproducibility

Every randomized run is replayable: export the logged `TEST_SEED` (and `FORK_BLOCK` for fork
suites) and re-run the same command. Fork suites default to the latest block by design
and log the block they picked.
