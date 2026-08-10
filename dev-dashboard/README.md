# Lido Lend · dev console

A local dashboard for developing UI against the protocol: start a throwaway node, deploy the whole
stack with mock tokens, seed addresses, crank the oracle price, and fast-forward time — all from a
browser page. Everything is against a local **anvil** (never a real network); it signs with anvil's
well-known dev keys.

## Prerequisites

The backend shells out to `forge` and `anvil`, so the parent repo must be able to build:

```sh
# Foundry (provides forge + anvil)
curl -L https://foundry.paradigm.xyz | bash && foundryup
forge --version                       # must be on PATH

# submodules (recursive — lib/lido-lend-irm has its own nested submodules)
git submodule update --init --recursive
forge build                           # must succeed before the dashboard can deploy
```

If `deploy core` fails, run `forge build` at the repo root and read its error — a missing `forge`
on PATH or uninitialised submodules is the usual cause (the log now shows the real forge output).

## Run

```sh
cd dev-dashboard
npm install          # express + ethers (vendored to public/ethers.min.js on first copy)
npm start            # serves http://127.0.0.1:8899
```

The page is organized into global tabs (header, active-market bar, and log stay visible across all of
them): **network** (node, snapshot, seed, time & blocks), **protocol** (deploy core / mock tokens /
create market / bundler), **market** (overview, actions, participants, state, oracle, control, guardian,
controller config, IRM), **script** (scenario input + history), and **txs** (transaction inspector).
Typical flow moves left to right: network → protocol → market.

**Bundler.** `deploy bundler` puts up Bundler3, the vendored general adapter and the Lido vault adapter
against the current core, straight from the forge artifacts — the two upstream contracts pin solc
0.8.28, so the 0.8.35 devnet script cannot deploy them. Leaving the token fields empty also deploys the
WETH / stETH / wstETH trio the general adapter's constructor requires (it reads `stETH()` off the wstETH
address, which a plain mock token does not have); create the market on those addresses to bundle against
it. Frontend usage — how to shape a bundle, and worked recipes including the two Lido-specific adapter
actions — is in [docs/integration/bundler.md](../docs/integration/bundler.md).

Reverts are decoded: a failed action logs the protocol error name (e.g. `InsufficientActiveCollateral()`,
`SupplyCapExceeded(…)`) or the core's string reason, instead of raw selector bytes. Every sent tx also
prints a clickable hash line in the page log (click → the txs tab, details for that tx).

**Transactions tab (txs).** The node's **whole tx history** (block walk, newest first); known txs are
labelled — deploy steps (`deployCore`/`deployToken`/`createMarket`, whose hashes the server reads from
the forge broadcast) and your own actions — the rest show `·`. Or paste **any** hash to inspect it. A tx
view shows status, block, from/to (with the contract's Solidity name if we deployed it, e.g.
`LidoLendERC4626`), value, gas & fee, the **decoded call** (`name(args)` from the artifact function ABIs;
deploys show "contract creation"), the raw calldata, and the **decoded events**. Event/function ABIs come
from the forge artifacts (`GET /api/events-abi`, `GET /api/functions-abi`), so struct-typed events (e.g.
`CollateralDrained`) decode too; anything still unknown is shown in full (topic0, indexed topics, data as
32-byte words).

**Scenario tab (script + history).** Split in two:

- **history** (read-only) — the chronological log of every executed action, one JSON step
  (`{"a":"deposit","amount":"1000","from":"0x…"}`). It is **persisted on the server**, so it survives a
  page reload. On node stop/start the history is **archived** (not deleted) — the last few sessions are
  kept alongside and can be loaded back into the input. Each on-chain step carries a `from` — the acting
  account; node/cheat/deploy steps have none (deploys always use the account-dropdown key).
- **script input** (editable) — paste or write a JSON array of steps and hit **run script**. Each step
  executes (impersonating its `from`) **and is appended to history** — running a script is just another
  way to drive the protocol. `selectMarket` switches the active market mid-scenario. Run stops (and
  reports) on the first failing step. `history → input` copies the current history in to edit and re-run.

Open <http://127.0.0.1:8899>, then:

0. **impersonate** (header) — type any address + `as` to send every subsequent action from it
   (auto-funded 100 ETH via `anvil_impersonateAccount`); `use key` switches back to a dev key.
1. **node** — `start local anvil` (fresh chain) or `start fork` with a mainnet RPC URL. The page
   auto-connects and lists the dev accounts as signers. (You can also point `rpc` at an anvil you
   started yourself and skip these buttons.) `snapshot` / `revert` save and restore chain state.
2. **protocol** — three tabs, since a core is a singleton that hosts many markets:
   - **deploy core** — the singleton `LidoLend` core **and** the project-level guardian registry
     (one `GuardianSignals`, keyed by market Id, shared by every market — not one per market).
   - **mock tokens** — deploy standalone mock ERC-20s (reusable across markets).
   - **create market** — pick the loan/collateral (from the deployed mocks, or a custom address),
     set oracle price (human "loan per 1 collateral"), LLTV (0–1), and min-activation (whole
     tokens) — all converted to chain units under the hood (the oracle scale accounts for token
     decimals). Repeat for more markets; each appears in the **active market** selector at the top.
3. **seed** — give any address a token balance. Pick a deployed mock (or type **any** ERC-20
   address, incl. a real fork token), then either `mint` (mock only) or `set balance` — the latter
   writes the `balanceOf` slot directly (deal), so it works on tokens with no public mint. The slot
   is auto-probed; override it if a token lays out balances unusually. Also sets ETH balances.
4. **time & blocks** — advance time + mine, mine N blocks, set the next block timestamp, or
   **freeze** the chain (automine off — txs sit pending, time stops) / set interval mining.
5. **oracle** — shows the current price and lets you set it (human units), bump it ±n%, or crash −50%.
6. **market control** — freeze/unfreeze and pause/resume the active market via its controller
   (the admin signer holds the FREEZER/UNFREEZER/PAUSER/RESUMER roles); shows frozen/paused status.
7. **guardian** — flag/unflag, suspect/unsuspect, ban/unban an account on the active market, and
   run committee ops (add/remove guardian, set quorum, set suspect window). flag/suspect submit a
   proof-of-scan block (latest−1 + its real hash); a flag quorum latches a ban. Shows banned/strikes.
8. **state** — the active market's addresses (marketId, core, vault, controller, oracle, irm,
   adaptive, guardian, tokens — click to copy) plus its vault/market totals and share price;
   `export deploy (json)` downloads all addresses (core, guardian, tokens, markets) for a frontend
   app to consume.
9. **protocol actions** — drive the market as the current signer (or any address via `act as`):
   - **lender** — via the vault (deposit / withdraw / redeem / fallback-exit) **and** directly to the
     core (Morpho supply / withdraw / withdraw-all), since a lender can hold supply either way.
   - **borrower** — supply-collateral / borrow / repay (by amount or all) / withdraw-collateral.
   - **keeper** — liquidate.
   Approvals are automatic. Collateral must mature before borrow — warp past the activation delay or
   grant instant activation (below).
10. **controller config** — supply cap, instant-activation grants, your settlement LTV, and the
    settlement / collateral-activation config structs as separate labelled fields (`Ne18` shorthand).
11. **IRM curve** — retune the active market's adaptive curve params (separate fields);
    `adjustmentSpeed=0` freezes rate adaptation.
12. **market overview** (top of the market tab) — parameters and live counters computed via a JS port
    of `expectedMarketBalances` (interest accrued): market supply/borrow assets & shares, utilization,
    borrow/supply APR, plus the ERC-4626 **vault totals** (totalAssets, totalSupply, share price).
13. **participants** — a table of watched addresses (dev accounts by default; add your own) showing
    ETH, token balances, **vault shares & assets** (supply via the vault), **supply shares & assets**
    (supply held directly in the core), collateral, debt and LTV (red at/over the market LLTV) — via
    `core.position` + `controller.positionOf`. Auto-refreshes while the market tab is open.

Each of core / token / market is a separate `forge script script/Devnet.s.sol --sig …` call the
backend runs against the node.

## How it works

- **Backend** (`server.js`, Express): manages the `anvil` process and runs the forge deploy against
  it, parsing the labeled addresses from the script's log. It does **not** re-implement the deploy —
  it reuses `script/Devnet.s.sol` (`deployCore` / `deployToken` / `createMarket`). It also persists the
  scenario **history** (append + archive on node stop/start) so it survives page reloads, records every
  sent **tx hash** (`GET /api/txlog`), and serves the project's **event ABIs** from the forge artifacts
  (`GET /api/events-abi`) for the txs-tab event decoder.
- **Frontend** (`public/index.html`, ethers): talks to the node directly over JSON-RPC for seeding
  (`mint`, `anvil_setStorageAt` deal, `anvil_setBalance`), time-travel (`evm_increaseTime`/`evm_mine`/
  `anvil_mine`/`evm_setNextBlockTimestamp`), chain freeze (`evm_setAutomine`/`evm_setIntervalMining`),
  snapshots (`evm_snapshot`/`evm_revert`), impersonation (`anvil_impersonateAccount`), and all protocol
  / guardian / controller / IRM calls (oracle `setPrice`, vault ERC4626, core borrow/repay/liquidate,
  guardian flag/ban, controller freeze/pause/config). Human amounts convert to chain units on the way in.

Fork mode boots an `--fork-url` anvil so real Lido tokens exist; seed those with `set balance` —
it probes the token's `balanceOf` storage slot and writes it via `anvil_setStorageAt`, so no mint
is required.

## Scenarios

The `script` tab replays a JSON array of steps (`{"a":<action>, …params, "from":<actor>}`); it runs each
step (impersonating its `from`) and **halts on the first failure**.

`tools/gen-scenario.js` generates a big, self-contained one — two markets driven densely over ~6 months:

```
node dev-dashboard/tools/gen-scenario.js [--months 6] [--seed 42] [--out dev-dashboard/scenarios/dense-6mo.json]
```

Load the output into the `script` tab and run it against a **fresh local node** (it deploys core + 4 mock
tokens + 2 markets itself, so start from an empty anvil). It exercises:

- dense ordinary flow on both markets, via the vault (deposit/withdraw) **and** the core (supply/borrow/repay);
- smooth price growth on both markets, then one −10% crash on ETH that tips a maxed borrower into **bad debt**,
  realized by a full-seizure `liquidateMax` (residual debt socialized);
- once-each set-pieces: `settle` (lender self-liquidation via the queue) and `fallbackExit` (illiquid exit);
- a guardian episode: suspect flags, a quorum ban that stays, and a ban that is later lifted;
- governance: a pause/resume and a supply-cap change.

Time is spread across each day (not a strict 1-day step); connected cascades (crash → liquidate → fallback)
run tightly but still with gaps. The generator keeps every emitted step valid against its own state model
(entries pre-funded, exits self-sizing), so the run does not halt midway. Re-run with a different `--seed`
for a different mix, or `--months 12` for a full year.

Actions the scenarios rely on beyond the panel buttons: `fund {side,to,amount}` (deal the active market's
loan/collateral to an actor), `settle {shares,borrowers}`, `liquidateMax {borrower}`, `watch {addresses}`
(register a cast into the participants table), and token **symbols** (e.g. `"WETH"`) in place of addresses
in `createMarket`. Every address a step touches is auto-added to the participants watch-list.

Not production tooling — a draft dev aid.
