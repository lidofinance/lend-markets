# Lido Lend · dev console

A local dashboard for developing UI against the protocol: start a throwaway node, deploy the whole
stack with mock tokens, seed addresses, crank the oracle price, and fast-forward time — all from a
browser page. Everything is against a local **anvil** (never a real network); it signs with anvil's
well-known dev keys.

## Run

```sh
cd devui
npm install          # express + ethers (vendored to public/ethers.min.js on first copy)
npm start            # serves http://127.0.0.1:8899
```

The page is organized into three global tabs (header, active-market bar, and log stay visible across
all of them): **network** (node, snapshot, seed, time & blocks), **protocol** (deploy core / mock
tokens / create market), and **market** (oracle, control, guardian, actions, controller config, IRM,
state). Typical flow moves left to right: network → protocol → market.

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
5. **oracle** — set the active market's mock price (human units) directly, or crash it −50%.
6. **market control** — freeze/unfreeze and pause/resume the active market via its controller
   (the admin signer holds the FREEZER/UNFREEZER/PAUSER/RESUMER roles); shows frozen/paused status.
7. **guardian** — flag/unflag, suspect/unsuspect, ban/unban an account on the active market, and
   run committee ops (add/remove guardian, set quorum, set suspect window). flag/suspect submit a
   proof-of-scan block (latest−1 + its real hash); a flag quorum latches a ban. Shows banned/strikes.
8. **state** — the active market's addresses (marketId, core, vault, controller, oracle, irm,
   adaptive, guardian, tokens — click to copy) plus its vault/market totals and share price;
   `export deploy (json)` downloads all addresses (core, guardian, tokens, markets) for a frontend
   app to consume.
9. **protocol actions** — drive the market as the current signer: lender deposit/redeem/withdraw,
   borrower supply-collateral/borrow/repay/withdraw-collateral, keeper liquidate. Approvals are
   automatic. Collateral must mature before borrow — warp past the activation delay or grant instant
   activation (below).
10. **controller config** — supply cap, instant-activation grants, your settlement LTV, and the raw
    settlement / collateral-activation config structs (comma-separated, `Ne18` shorthand supported).
11. **IRM curve** — retune the active market's adaptive curve params; `adjustmentSpeed=0` freezes
    rate adaptation.

Each of core / token / market is a separate `forge script script/Devnet.s.sol --sig …` call the
backend runs against the node.

## How it works

- **Backend** (`server.js`, Express): manages the `anvil` process and runs the forge deploy against
  it, parsing the labeled addresses from the script's log. It does **not** re-implement the deploy —
  it reuses the Solidity `DeployLocalDevnet` script.
- **Frontend** (`public/index.html`, ethers): talks to the node directly over JSON-RPC for seeding
  (`mint`, `anvil_setStorageAt` deal, `anvil_setBalance`), time-travel (`evm_increaseTime`/`evm_mine`/
  `anvil_mine`/`evm_setNextBlockTimestamp`), chain freeze (`evm_setAutomine`/`evm_setIntervalMining`),
  snapshots (`evm_snapshot`/`evm_revert`), impersonation (`anvil_impersonateAccount`), and all protocol
  / guardian / controller / IRM calls (oracle `setPrice`, vault ERC4626, core borrow/repay/liquidate,
  guardian flag/ban, controller freeze/pause/config). Human amounts convert to chain units on the way in.

Fork mode boots an `--fork-url` anvil so real Lido tokens exist; seed those with `set balance` —
it probes the token's `balanceOf` storage slot and writes it via `anvil_setStorageAt`, so no mint
is required.

Not production tooling — a draft dev aid.
