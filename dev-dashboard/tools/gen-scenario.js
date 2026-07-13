#!/usr/bin/env node
// Generate a big, self-contained dev-dashboard scenario: two markets driven densely over ~6 months.
//
// Output is a JSON array of steps in the dashboard's `script` vocabulary ({"a":<action>, ...params, "from":..}).
// Load it into the dashboard's `script` tab and hit "run". The runner halts on the FIRST failing step, so this
// generator only ever emits steps its own lightweight state-model proves valid: entries are pre-funded, exits use
// the self-sizing actions (withdrawMax / coreWithdrawAll / repayAll / liquidateMax), borrows stay well inside LTV
// and market liquidity, and collateral withdrawals happen only after the debt is fully repaid.
//
// What it exercises:
//   - self-bootstrap: deploy core + 4 mock tokens + 2 markets (ETH: WETH/wstETH 0.86 LLTV; USD: USDC/USDY 0.98).
//   - dense ordinary flow on BOTH markets, via the vault (deposit/withdraw) AND the core (supply/borrow/repay).
//   - smooth price growth on both markets (no drawdowns) + one -10% crash on ETH that tips a maxed borrower into
//     bad debt, realized by a full-seizure liquidation (liquidateMax) — the residual debt is socialized.
//   - rare set-pieces, once each: settle (lender self-liquidation via the queue), fallbackExit (illiquid exit).
//   - guardian episode: suspect flags (lengthen activation), a quorum ban that STAYS, and a ban that is later lifted.
//   - governance: a pause/resume and a supply-cap change.
//   - time is not a strict 1-day step: actions are spread across each day, and connected cascades run tightly but
//     still with small gaps.
//
// Usage: node dev-dashboard/tools/gen-scenario.js [--months 6] [--seed 42] [--winddown] [--out dev-dashboard/scenarios/dense-6mo.json]
//   --winddown  unwind all positions at the end (markets end empty). Default: end in a rich, live state.

const fs = require("fs");
const path = require("path");
const { ethers } = require(path.join(__dirname, "..", "node_modules", "ethers"));

// ── args ──
const argv = process.argv.slice(2);
function arg(name, def) { const i = argv.indexOf("--" + name); return i >= 0 && argv[i + 1] ? argv[i + 1] : def; }
const MONTHS = Number(arg("months", "6"));
const SEED = Number(arg("seed", "42"));
const WINDDOWN = argv.includes("--winddown"); // if set, unwind everything at the end (markets end empty)
let OUT = arg("out", path.join(__dirname, "..", "scenarios", "dense-6mo.json"));
if (WINDDOWN) OUT = OUT.replace(/\.json$/, ".winddown.json"); // keep the wound-down variant under its own name
const DAYS = Math.round(MONTHS * 30);

// ── deterministic PRNG (mulberry32) — no Date/Math.random, so the same seed reproduces the same scenario ──
let _s = SEED >>> 0;
function rnd() { _s |= 0; _s = (_s + 0x6d2b79f5) | 0; let t = Math.imul(_s ^ (_s >>> 15), 1 | _s); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }
function pick(arr) { return arr[Math.floor(rnd() * arr.length)]; }
function ri(lo, hi) { return lo + Math.floor(rnd() * (hi - lo + 1)); }

// deterministic checksummed address from a label
function addrOf(label) { return ethers.getAddress(ethers.dataSlice(ethers.id(label), 0, 20)); }

// ── cast ──
// admin is anvil account #0 (the forge deploy key); governance/guardian-admin/oracle steps act from it.
const ADMIN = ethers.getAddress("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
const guardians = [ADMIN, addrOf("guardian:1"), addrOf("guardian:2"), addrOf("guardian:3"), addrOf("guardian:4")];
const lenders = Array.from({ length: 10 }, (_, i) => addrOf("lender:" + i));
const keeper = addrOf("keeper:0");
// borrowers: split by risk profile; VICTIM is the maxed ETH borrower that the crash tips into bad debt.
const victim = addrOf("borrower:victim");
const suspected = addrOf("borrower:suspected"); // gets suspect flags -> lengthened activation
const banStays = addrOf("borrower:ban-stays"); // quorum-banned, never unbanned
const banLifted = addrOf("borrower:ban-lifted"); // banned then unbanned
const borrowers = [victim, suspected, banStays, banLifted, addrOf("borrower:a"), addrOf("borrower:b"), addrOf("borrower:c"), addrOf("borrower:d")];
const CAST = [...new Set([...guardians, ...lenders, keeper, ...borrowers])];
// two lenders keep a permanent vault stake (never fully withdrawn) so the vault never drains to dust — that keeps
// the ERC-4626 share price near 1, which our asset≈share model (and the shares-based set-pieces) rely on.
const permanent = new Set([lenders[0], lenders[1]]);

// ── markets (index 0 = ETH, 1 = USD) ──
const ETH = 0, USD = 1;
const M = {
  // apr = conservative modelled borrow rate (a LOWER bound: on-chain we pin the ETH curve higher and hold util near
  // target, so real accrual >= model). setpoint = utilization the daily mix steers toward.
  // ETH LLTV is high (LST collateral): a maxed borrow sits near 0.91 LTV, so a -10% crash lands it near 0.99 —
  // comfortably past 1/LIF (~0.975), which makes the bad-debt set-piece fire regardless of interest/utilization.
  // apr = a conservative modelled borrow rate, only used to keep repay funding ample; the on-chain rate is the
  // default adaptive curve (gentle, ~4%/yr at target) so APR moves smoothly.
  [ETH]: { loan: "WETH", coll: "wstETH", loanDec: 18, collDec: 18, price: 1.15, growth: 0.025, apr: 0.03, lltv: 0.915, cap: 8000, priceFmt: 6, setpoint: 0.85 },
  [USD]: { loan: "USDC", coll: "USDY", loanDec: 6, collDec: 18, price: 1.02, growth: 0.04, apr: 0.03, lltv: 0.98, cap: 8000000, priceFmt: 6, setpoint: 0.80 },
};
const LIF = 1 / (0.3 * M[ETH].lltv + 0.7); // Morpho liquidation incentive factor at this LLTV (~1.044)

// ── state model (only what we need to keep every emitted step valid) ──
const st = {
  [ETH]: { price: M[ETH].price, supply: 0, borrow: 0 },
  [USD]: { price: M[USD].price, supply: 0, borrow: 0 },
};
const pos = {}; // pos[market][actor] = { vault, core, coll, debt, unlock, active }
for (const mk of [ETH, USD]) { pos[mk] = {}; for (const a of CAST) pos[mk][a] = { vault: 0, core: 0, coll: 0, debt: 0, unlock: 0, active: false }; }

// ── step emission + a model clock (chain-time elapsed) so collateral activation is time-based ──
const steps = [];
let curMarket = -1, clock = 0;
function push(s) { steps.push(s); }
function selectMarket(mk) { if (curMarket !== mk) { push({ a: "selectMarket", index: mk }); curMarket = mk; } }
const HOUR = 3600, DAY = 86400;
// how long to wait for collateral to activate: the controller's base delay is <= maxActivationDelay (2h); leave
// slack for the inflow throttle and rounding. Activation is time-based, never instant.
const ACT_DELAY = 4 * HOUR;
// advance the clock by `seconds`; every warp moves chain time, which is what matures activating collateral
function warp(seconds) { const s = Math.max(1, Math.round(seconds)); clock += s; push({ a: "warp", seconds: s }); }

// numeric formatting for human-amount params
function amt(x, dec) { return Number(x).toFixed(Math.min(dec, 6)); }
function px(mk) { return st[mk].price.toFixed(M[mk].priceFmt); }

// ── actions (update the model, then emit the step) ──
function fund(mk, side, to, amount) { push({ a: "fund", side, to, amount: amt(amount, side === "collateral" ? M[mk].collDec : M[mk].loanDec) }); }
function setPrice(mk) { selectMarket(mk); push({ a: "setPrice", price: px(mk), from: ADMIN }); }

// keep modelled supply a margin below the cap: the on-chain total is supply principal PLUS accrued interest, and
// the cap is enforced on that post-accrue total, so leave 10% headroom to avoid SupplyCapExceeded.
function capRoom(mk) { return 0.9 * M[mk].cap - st[mk].supply; }
function deposit(mk, who, amount) { amount = Math.min(amount, capRoom(mk)); if (amount < (mk === USD ? 100 : 0.1)) return; selectMarket(mk); fund(mk, "loan", who, amount * 1.01); push({ a: "deposit", amount: amt(amount, M[mk].loanDec), from: who }); pos[mk][who].vault += amount; st[mk].supply += amount; }
function withdrawMax(mk, who) { const p = pos[mk][who]; if (p.vault <= 0) return; selectMarket(mk); push({ a: "withdrawMax", from: who }); st[mk].supply -= p.vault; p.vault = 0; }
function coreSupply(mk, who, amount) { amount = Math.min(amount, capRoom(mk)); if (amount < (mk === USD ? 100 : 0.1)) return; selectMarket(mk); fund(mk, "loan", who, amount * 1.01); push({ a: "coreSupply", amount: amt(amount, M[mk].loanDec), from: who }); pos[mk][who].core += amount; st[mk].supply += amount; }
function coreWithdrawAll(mk, who) { const p = pos[mk][who]; if (p.core <= 0) return; selectMarket(mk); push({ a: "coreWithdrawAll", from: who }); st[mk].supply -= p.core; p.core = 0; }

// supply collateral; it becomes borrowable only after the activation delay elapses (time-based, not instant) — a
// non-blocking wait, so other actors keep acting meanwhile and the borrow comes a tick/day later.
function supplyCollateral(mk, who, amount) { selectMarket(mk); fund(mk, "collateral", who, amount); push({ a: "supplyCollateral", amount: amt(amount, M[mk].collDec), from: who }); const p = pos[mk][who]; p.coll += amount; p.unlock = clock + ACT_DELAY; p.active = false; }
// mark collateral active once its activation delay has elapsed (call after time has advanced)
function activate(mk) { for (const a of CAST) { const p = pos[mk][a]; if (p.coll > 0 && !p.active && clock >= p.unlock) p.active = true; } }
function collValue(mk, who) { return pos[mk][who].coll * st[mk].price; }
// borrow a fraction of the remaining LTV room, capped by market liquidity, with margin so it can't revert even
// though real debt/borrow run a touch above the model (accrual): leave headroom on both LTV and idle liquidity.
// Only active (matured) collateral is borrowable.
function borrow(mk, who, ltvFrac) { const p = pos[mk][who]; if (!p.active) return; const maxDebt = collValue(mk, who) * M[mk].lltv; const room = maxDebt * ltvFrac - p.debt; const liq = (st[mk].supply - st[mk].borrow * 1.06) * 0.6; const a = Math.min(room, liq); if (a < (mk === USD ? 1 : 0.01)) return; selectMarket(mk); push({ a: "borrow", amount: amt(a, M[mk].loanDec), from: who }); p.debt += a; st[mk].borrow += a; }
// repay everything; over-fund the loan generously (deal is free) so on-chain owed — always a bit above the model
// debt after accrual — is comfortably covered.
function repayAll(mk, who) { const p = pos[mk][who]; if (p.debt <= 0) return; selectMarket(mk); fund(mk, "loan", who, p.debt * 3 + 10); push({ a: "repayAll", from: who }); st[mk].borrow -= p.debt; p.debt = 0; }
function withdrawCollateralAll(mk, who) { const p = pos[mk][who]; if (p.coll <= 0 || p.debt > 0) return; selectMarket(mk); push({ a: "withdrawCollateral", amount: amt(p.coll, M[mk].collDec), from: who }); p.coll = 0; p.active = false; }
// open a borrower by supplying collateral only — it is borrowed against a tick/day later, once activation matures
function openBorrow(mk) { const b = pick(borrowers.filter(x => x !== victim && x !== banStays && pos[mk][x].coll === 0)); if (!b) return; supplyCollateral(mk, b, mk === ETH ? ri(80, 150) : ri(120000, 280000)); }

function util(mk) { return st[mk].supply > 0 ? st[mk].borrow / st[mk].supply : 0; }

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// 1) bootstrap: deploy, configure an example guardian committee, register the cast in participants
// ═══════════════════════════════════════════════════════════════════════════════════════════════
push({ a: "deployCore" });
push({ a: "deployToken", symbol: "WETH", decimals: 18 });
push({ a: "deployToken", symbol: "wstETH", decimals: 18 });
push({ a: "deployToken", symbol: "USDC", decimals: 6 });
push({ a: "deployToken", symbol: "USDY", decimals: 18 });
push({ a: "createMarket", loan: "WETH", collateral: "wstETH", price: px(ETH), lltv: "0.915", minActivation: "0.01" });
push({ a: "createMarket", loan: "USDC", collateral: "USDY", price: px(USD), lltv: "0.98", minActivation: "1" });
push({ a: "watch", addresses: CAST });

// guardian committee (shared registry): add 4 more guardians (each with a distinct operator key), example
// quorum 3-of-5, 7-day suspect window.
for (const g of guardians.slice(1)) {
  const operator = "0x" + (BigInt(g) ^ 1n).toString(16).padStart(40, "0");
  push({ a: "addGuardian", address: g, operator, from: ADMIN });
}
push({ a: "setQuorum", n: 3, from: ADMIN });
push({ a: "setSuspectWindow", n: 7 * DAY, from: ADMIN });
// example supply caps. The IRM keeps its default adaptive curve (gentle ~4%/yr at target) so the borrow APR
// moves smoothly; the bad-debt set-piece does not rely on a high rate (it is driven by LLTV + the price crash).
for (const mk of [ETH, USD]) { selectMarket(mk); push({ a: "setSupplyCap", cap: String(M[mk].cap), from: ADMIN }); }

// Split point: everything above is deploy + guardian config + caps + watch — cheap, run it in the UI so the
// server learns the addresses and the participants panel is populated. Everything below is the heavy activity —
// run it in node against the same node (much faster than the browser, which slot-probes on every fund).
const BOOTSTRAP_LEN = steps.length;

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// 2) seed initial liquidity + open positions (incl. the maxed VICTIM on ETH held to the crash)
// ═══════════════════════════════════════════════════════════════════════════════════════════════
// lenders seed both markets (mix of vault deposits and direct core supply)
for (let i = 0; i < lenders.length; i++) {
  const who = lenders[i];
  if (i % 2 === 0) { deposit(ETH, who, ri(200, 600)); coreSupply(USD, who, ri(200000, 600000)); }
  else { coreSupply(ETH, who, ri(200, 600)); deposit(USD, who, ri(200000, 600000)); }
  warp(ri(1, 4) * HOUR);
}
// ordinary borrowers supply collateral on both markets; the borrow lands the next day, once activation matures.
for (const b of borrowers) {
  if (b === victim || b === banStays || b === banLifted || b === suspected) continue; // handled separately
  supplyCollateral(ETH, b, ri(80, 160)); warp(ri(1, 3) * HOUR);
  supplyCollateral(USD, b, ri(150000, 300000)); warp(ri(1, 3) * HOUR);
}
warp(DAY); activate(ETH); activate(USD); // collateral matures overnight
for (const b of borrowers) {
  if (b === banStays || b === banLifted || b === suspected) continue;
  borrow(ETH, b, 0.6); warp(ri(2, 6) * HOUR);
  borrow(USD, b, 0.7); warp(ri(2, 6) * HOUR);
}
// VICTIM: supply, let it activate overnight, then max out ETH LTV and hold — the -10% crash later tips it past 1/LIF.
supplyCollateral(ETH, victim, 120); warp(DAY); activate(ETH); borrow(ETH, victim, 0.99); // ~0.905 LTV, held to the crash
warp(DAY);

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// 3) main timeline — dense ordinary activity, smooth price growth, utilization drift; set-pieces spliced in
// ═══════════════════════════════════════════════════════════════════════════════════════════════
const dayGrowth = { [ETH]: Math.pow(1 + M[ETH].growth, 1 / 365) - 1, [USD]: Math.pow(1 + M[USD].growth, 1 / 365) - 1 };
// utilization setpoint slowly oscillates around each market's base (smooth adaptive-APR response), never pinned
function setpoint(day, mk) { return M[mk].setpoint + 0.04 * Math.sin((day / DAYS) * Math.PI * 3); }

const sched = {
  [Math.round(DAYS * 0.30)]: "guardian",
  [Math.round(DAYS * 0.45)]: "governance",
  [Math.round(DAYS * 0.62)]: "settle",
  [Math.round(DAYS * 0.80)]: "crash", // crash -> bad-debt liquidation cascade
  [Math.round(DAYS * 0.88)]: "fallback",
};

for (let day = 0; day < DAYS; day++) {
  // model daily interest accrual on all debt (conservative vs on-chain), recompute totals from positions to stay
  // consistent, then grow both prices a touch (no drawdowns). Refresh the oracle every few days.
  for (const mk of [ETH, USD]) {
    const ad = Math.pow(1 + M[mk].apr, 1 / 365) - 1;
    let b = 0, s = 0; for (const a of CAST) { const p = pos[mk][a]; if (p.debt > 0) p.debt *= (1 + ad); b += p.debt; s += p.vault + p.core; }
    st[mk].borrow = b; st[mk].supply = s; st[mk].price *= (1 + dayGrowth[mk]);
  }
  if (day % 3 === 0) { setPrice(ETH); setPrice(USD); }

  // mature any collateral whose delay has elapsed, then borrow against some freshly-active positions — not
  // necessarily the day they matured (spread across days, as in practice).
  activate(ETH); activate(USD);
  for (const mk of [ETH, USD]) {
    const ready = borrowers.filter(x => x !== victim && x !== banStays && pos[mk][x].active && pos[mk][x].coll > 0 && (collValue(mk, x) * M[mk].lltv * 0.7 - pos[mk][x].debt) > (mk === USD ? 100 : 0.5));
    for (const b of ready) if (rnd() < 0.6) { borrow(mk, b, ri(6, 8) / 10); warp(ri(1, 4) * HOUR); }
  }

  // many ordinary actions spread across the day. Build the set of actions that are VALID right now (an eligible
  // actor exists), bias it toward raising or lowering utilization, then always execute one — so every iteration
  // is a real tx, never a skipped no-op. A fresh deposit/supply is always valid, so the list is never empty.
  const nActs = ri(4, 8);
  for (let k = 0; k < nActs; k++) {
    const mk = pick([ETH, USD]);
    const addSupply = () => { const l = pick(lenders); if (mk === ETH) deposit(mk, l, ri(150, 400)); else coreSupply(mk, l, ri(150000, 400000)); };
    const opts = [addSupply]; // always available
    const room = borrowers.filter(x => x !== banStays && x !== victim && pos[mk][x].active && pos[mk][x].coll > 0 && (collValue(mk, x) * M[mk].lltv * 0.8 - pos[mk][x].debt) > (mk === USD ? 100 : 0.5));
    const withVault = lenders.filter(x => pos[mk][x].vault > 0 && !permanent.has(x));
    const withDebt = borrowers.filter(x => x !== victim && pos[mk][x].debt > 0);
    const idle = borrowers.filter(x => x !== victim && x !== banStays && pos[mk][x].coll === 0);
    const raise = util(mk) < setpoint(day, mk);
    // weight the pool: when raising utilization, favour borrow/withdraw; when lowering, favour supply/repay
    if (room.length) { opts.push(() => borrow(mk, pick(room), 0.8)); if (raise) opts.push(() => borrow(mk, pick(room), 0.8)); }
    if (withVault.length && raise) opts.push(() => withdrawMax(mk, pick(withVault)));
    if (withDebt.length) { const rep = () => { const b = pick(withDebt); repayAll(mk, b); withdrawCollateralAll(mk, b); }; opts.push(rep); if (!raise) opts.push(rep); }
    if (idle.length) opts.push(() => openBorrow(mk));
    if (!raise) opts.push(addSupply);
    pick(opts)();
    warp(ri(2, 5) * HOUR);
  }

  // splice a scheduled set-piece at this day boundary
  const piece = sched[day];
  if (piece === "guardian") emitGuardianEpisode();
  else if (piece === "governance") emitGovernance();
  else if (piece === "settle") emitSettle();
  else if (piece === "crash") emitCrashBadDebt();
  else if (piece === "fallback") emitFallbackExit();

  warp(ri(1, 6) * HOUR); // pad out to ~a day
}

// ═══════════════════════════════════════════════════════════════════════════════════════════════
// set-pieces
// ═══════════════════════════════════════════════════════════════════════════════════════════════
function emitGuardianEpisode() {
  selectMarket(ETH);
  // suspect flags: a guardian suspects `suspected`, lengthening its activation delay; another confirms, then clear.
  push({ a: "suspect", account: suspected, from: guardians[1] }); warp(2 * HOUR);
  push({ a: "suspect", account: suspected, from: guardians[2] }); warp(6 * HOUR);
  push({ a: "unsuspect", account: suspected, from: guardians[1] }); warp(DAY);
  // quorum ban that STAYS: 3 distinct guardians flag `banStays` -> ban latches at quorum and is never lifted.
  push({ a: "flag", account: banStays, from: guardians[1] }); warp(HOUR);
  push({ a: "flag", account: banStays, from: guardians[2] }); warp(HOUR);
  push({ a: "flag", account: banStays, from: guardians[3] }); warp(6 * HOUR);
  // ban then UNBAN: `banLifted` is banned by the admin, then later lifted.
  push({ a: "ban", account: banLifted, from: ADMIN }); warp(2 * DAY);
  push({ a: "unban", account: banLifted, from: ADMIN }); warp(HOUR);
  // banLifted re-enters normally after the ban is lifted: supply, mature overnight, then borrow
  supplyCollateral(ETH, banLifted, 100); warp(DAY); activate(ETH); borrow(ETH, banLifted, 0.5);
}

function emitGovernance() {
  selectMarket(USD);
  push({ a: "marketPause", seconds: 3 * HOUR, from: ADMIN }); warp(HOUR);
  push({ a: "marketResume", from: ADMIN }); warp(HOUR); // resume while still paused (before the 3h window expires)
  // raise the ETH supply cap (risk-steward loosening)
  selectMarket(ETH); push({ a: "setSupplyCap", cap: String(M[ETH].cap + 4000), from: ADMIN }); M[ETH].cap += 4000; warp(HOUR);
}

// settle: a lender self-liquidates an eligible borrower through the settlement queue once liquidity is thin.
function emitSettle() {
  const mk = USD; selectMarket(mk);
  // pick a solvent borrower with debt to be the settle target; a lender with vault shares settles a small slice.
  const target = pick(borrowers.filter(x => pos[mk][x].debt > 0 && x !== victim)) || borrowers[4];
  const lender = pick(lenders.filter(x => pos[mk][x].vault > 0)) || lenders[1];
  if (pos[mk][lender].vault <= 0) deposit(mk, lender, 300000);
  push({ a: "setSettlementLtv", ltv: "0.9", from: target }); warp(2 * HOUR);
  const shares = Math.max(1, Math.floor(pos[mk][lender].vault * 0.1));
  push({ a: "settle", shares: String(shares), borrowers: [target], from: lender }); warp(6 * HOUR);
}

// crash + bad-debt liquidation: -10% on ETH tips the maxed VICTIM past 1/LIF; a full-seizure liquidation
// zeroes its collateral while debt remains, so the core socializes the residual as bad debt.
function emitCrashBadDebt() {
  selectMarket(ETH);
  st[ETH].price *= 0.90; setPrice(ETH); warp(30 * 60); // the drop, then a short gap
  // sanity: after the crash the victim's LTV must exceed 1/LIF for the full seizure to leave residual debt
  const ltvAfter = pos[ETH][victim].debt / collValue(ETH, victim);
  if (ltvAfter <= 1 / LIF) throw new Error("crash did not push victim into bad-debt range: LTV=" + ltvAfter.toFixed(4) + " need>" + (1 / LIF).toFixed(4));
  // the keeper repays the seized debt out of its own loan balance — fund it generously first
  fund(ETH, "loan", keeper, pos[ETH][victim].debt * 2 + 100);
  push({ a: "liquidateMax", borrower: victim, from: keeper }); warp(2 * HOUR);
  st[ETH].borrow -= pos[ETH][victim].debt; pos[ETH][victim] = { vault: 0, core: 0, coll: 0, debt: 0, unlock: 0, active: false };
}

// fallbackExit: drive ETH utilization high so idle liquidity is thin, then a lender exits via redeem+settle.
function emitFallbackExit() {
  const mk = ETH; selectMarket(mk);
  const lender = pick(lenders.filter(x => pos[mk][x].vault > 0)) || lenders[0];
  if (pos[mk][lender].vault <= 0) deposit(mk, lender, 400);
  // push utilization up so a plain withdraw can't be fully served
  for (const b of borrowers.filter(x => pos[mk][x].coll > 0 && x !== banStays)) { borrow(mk, b, 0.78); warp(HOUR); }
  const shares = Math.max(1, Math.floor(pos[mk][lender].vault * 0.5));
  const targets = borrowers.filter(x => pos[mk][x].debt > 0 && x !== victim).slice(0, 5);
  push({ a: "fallbackExit", shares: String(shares), maxIterations: 10, from: lender }); warp(4 * HOUR);
  pos[mk][lender].vault = Math.max(0, pos[mk][lender].vault - shares);
}

// Wind-down (optional, --winddown): repay every debt and withdraw all supply so the markets end empty. Off by
// default — the scenario deliberately ends in a rich, live state (open positions, accrued interest, the realized-
// bad-debt aftermath, latched guardian bans) so the dashboard has something to explore rather than emptied markets.
if (WINDDOWN) {
  for (const mk of [ETH, USD]) {
    for (const b of borrowers) { repayAll(mk, b); withdrawCollateralAll(mk, b); }
    for (const l of lenders) { withdrawMax(mk, l); coreWithdrawAll(mk, l); }
    warp(HOUR);
  }
}

// ── write ──
// coalesce runs of adjacent warps into a single warp — same elapsed time, fewer steps
function coalesce(arr) {
  const out = [];
  for (const s of arr) {
    const last = out[out.length - 1];
    if (s.a === "warp" && last && last.a === "warp") last.seconds += s.seconds;
    else out.push(s.a === "warp" ? { a: "warp", seconds: s.seconds } : s);
  }
  return out;
}
const combined = coalesce(steps);
const bootstrap = coalesce(steps.slice(0, BOOTSTRAP_LEN));
const activity = coalesce(steps.slice(BOOTSTRAP_LEN));
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(combined, null, 1));
const bootOut = OUT.replace(/\.json$/, ".bootstrap.json");
const actOut = OUT.replace(/\.json$/, ".activity.json");
fs.writeFileSync(bootOut, JSON.stringify(bootstrap, null, 1));
fs.writeFileSync(actOut, JSON.stringify(activity, null, 1));
const counts = combined.reduce((m, s) => ((m[s.a] = (m[s.a] || 0) + 1), m), {});
console.log("months=" + MONTHS + " days=" + DAYS + " seed=" + SEED + " cast=" + CAST.length + " (" + (steps.length - combined.length) + " warps coalesced)");
console.log("combined  " + combined.length + " steps -> " + OUT + "  (load whole thing in the UI)");
console.log("bootstrap " + bootstrap.length + " steps -> " + bootOut + "  (load in UI script tab)");
console.log("activity  " + activity.length + " steps -> " + actOut + "  (node dev-dashboard/tools/run-scenario.js " + path.basename(actOut) + " --from-server)");
console.log("action counts:", JSON.stringify(counts));
