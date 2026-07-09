#!/usr/bin/env node
// Headless replay of a dashboard scenario JSON against a throwaway anvil — the same steps the browser `script`
// tab runs, but in node, so a scenario can be validated end-to-end (it halts on the first failing step exactly
// like the UI). Deploy steps shell out to the same `script/Devnet.s.sol` the server uses; every other step is a
// direct ethers call mirroring the browser ACTIONS.
//
// Usage: node dev-dashboard/tools/run-scenario.js [scenario.json] [--rpc http://127.0.0.1:8546] [--keep]
//   spawns its own anvil on :8546 unless --rpc points at a running node.

const fs = require("fs");
const path = require("path");
const { spawn, spawnSync } = require("child_process");
const { ethers } = require(path.join(__dirname, "..", "node_modules", "ethers"));

const REPO = path.join(__dirname, "..", "..");
const SCRIPT = "script/Devnet.s.sol";
const argv = process.argv.slice(2);
function flag(n) { return argv.includes("--" + n); }
function opt(n, d) { const i = argv.indexOf("--" + n); return i >= 0 ? argv[i + 1] : d; }
const FILE = argv.find(a => !a.startsWith("--") && a.endsWith(".json")) || path.join(__dirname, "..", "scenarios", "dense-6mo.json");
const RPC = opt("rpc", "http://127.0.0.1:8546");
const PORT = new URL(RPC).port || "8546";
const ADMIN_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0
const ADMIN = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

// ── ABIs (subset used by the scenario) ──
const MP = "(address,address,address,address,uint256)";
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function decimals() view returns (uint8)", "function approve(address,uint256) returns (bool)", "function allowance(address,address) view returns (uint256)"];
const VAULT = ["function deposit(uint256,address) returns (uint256)", "function withdraw(uint256,address,address) returns (uint256)", "function redeem(uint256,address,address) returns (uint256)", "function maxWithdraw(address) view returns (uint256)", "function balanceOf(address) view returns (uint256)", "function totalAssets() view returns (uint256)", "function totalSupply() view returns (uint256)", "function convertToAssets(uint256) view returns (uint256)", "function fallbackExit(uint256,address,address,uint256)", "function settle(uint256,address[],address,address)"];
const CORE = ["function supply(" + MP + ",uint256,uint256,address,bytes) returns (uint256,uint256)", "function withdraw(" + MP + ",uint256,uint256,address,address) returns (uint256,uint256)", "function supplyCollateral(" + MP + ",uint256,address,bytes)", "function borrow(" + MP + ",uint256,uint256,address,address) returns (uint256,uint256)", "function repay(" + MP + ",uint256,uint256,address,bytes) returns (uint256,uint256)", "function withdrawCollateral(" + MP + ",uint256,address,address)", "function liquidate(" + MP + ",address,uint256,uint256,bytes) returns (uint256,uint256)", "function position(bytes32,address) view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral)", "function market(bytes32) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee)"];
const CTLCFG = ["function setSupplyCap(uint256)", "function grantInstantActivation(address)", "function setSettlementLtv(uint256)", "function pauseFor(uint256)", "function resume()"];
const ADAPTIVE = ["function setMarketCurveParams(" + MP + ",(int256,int256,int256,int256,int256,int256,uint256))"];
const ORACLE = ["function price() view returns (uint256)", "function setPrice(uint256)"];
const GUARDIAN = ["function flag(bytes32,address[],(bytes32,uint40,uint40))", "function unflag(bytes32,address[],(bytes32,uint40,uint40))", "function suspect(bytes32,address[],(bytes32,uint40,uint40))", "function unsuspect(bytes32,address[],(bytes32,uint40,uint40))", "function ban(bytes32,address)", "function unban(bytes32,address)", "function addGuardian(address)", "function setQuorum(uint256)", "function setSuspectWindow(uint256)", "function getOpinion(bytes32,address) view returns (bool banned, uint256 strikeCount, uint256 suspectCount, uint256 suspectExpiryTimestamp, uint256 quorumFrontierTimestamp)"];

// error interface (decode custom-error selectors to names) — built from the forge artifacts
function buildErrIface() {
  const frags = [], seen = new Set();
  const files = ["out/LidoLendMarketController.sol/LidoLendMarketController.json", "out/LidoLend.sol/LidoLend.json", "out/LidoLendERC4626.sol/LidoLendERC4626.json", "out/GuardianSignals.sol/GuardianSignals.json", "out/IrmRouter.sol/IrmRouter.json", "out/AdaptiveCurveIrm.sol/AdaptiveCurveIrm.json"];
  for (const f of files) { try { const j = JSON.parse(fs.readFileSync(path.join(REPO, f), "utf8")); for (const e of j.abi) if (e.type === "error") { const k = e.name + (e.inputs || []).length; if (!seen.has(k)) { seen.add(k); frags.push(e); } } } catch {} }
  try { return new ethers.Interface(frags); } catch { return null; }
}
const EI = buildErrIface();
function decodeErr(data) { if (typeof data !== "string" || !/^0x[0-9a-fA-F]{8}/.test(data)) return null; try { const d = EI.parseError(data); return d.name + "(" + d.args.map(String).join(",") + ")"; } catch { return "selector " + data.slice(0, 10); } }

// ── state ──
let provider, anvilProc;
const state = { core: null, guardian: null, tokens: [], markets: [] };
let cur = -1;
const dec = {}; // token address -> decimals

const sleep = (ms) => new Promise(r => setTimeout(r, ms));
function log(s) { process.stdout.write(s + "\n"); }
function tokBySymbol(s) { return state.tokens.find(t => t.symbol.toLowerCase() === String(s).toLowerCase()); }
function m() { if (cur < 0 || !state.markets[cur]) throw new Error("no active market"); return state.markets[cur]; }
function mp(mk) { return [mk.loanToken, mk.collateralToken, mk.oracle, mk.irm, BigInt(mk.lltv)]; }
async function decimals(addr) { if (dec[addr] === undefined) { try { dec[addr] = Number(await new ethers.Contract(addr, ERC20, provider).decimals()); } catch { dec[addr] = 18; } } return dec[addr]; }
async function oracleScale(mk) { return 36 + await decimals(mk.loanToken) - await decimals(mk.collateralToken); }

// impersonated signer for `from` (fund with gas)
const signers = {};
async function signerFor(addr) {
  const a = ethers.getAddress(addr);
  if (!signers[a]) {
    await provider.send("anvil_impersonateAccount", [a]); await provider.send("anvil_setBalance", [a, "0x" + ethers.parseEther("1000").toString(16)]);
    const s = await provider.getSigner(a); const orig = s.sendTransaction.bind(s);
    // Force a generous fixed gas limit on every tx. anvil auto-mines with a wall-clock timestamp, so a hook's gas
    // (activation / settlement-queue sync) varies run-to-run; a tight estimate then OOGs non-deterministically.
    s.sendTransaction = (tx) => orig(tx.gasLimit ? tx : { ...tx, gasLimit: 15000000n });
    signers[a] = s;
  }
  return signers[a];
}
async function ensureApprove(token, owner, spender) {
  const t = new ethers.Contract(token, ERC20, await signerFor(owner));
  const cur = await t.allowance(owner, spender);
  if (cur < ethers.MaxUint256 / 2n) await (await t.approve(spender, ethers.MaxUint256)).wait();
}
// write an ERC20 balance by probing the balances mapping slot (mirrors the dashboard's deal)
async function deal(token, holder, amount) {
  const t = new ethers.Contract(token, ERC20, provider);
  const enc = (i) => ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [holder, i]));
  const val = ethers.toBeHex(amount, 32);
  for (let i = 0; i < 40; i++) {
    const slot = enc(i);
    const prev = await provider.send("eth_getStorageAt", [token, slot, "latest"]);
    await provider.send("anvil_setStorageAt", [token, slot, val]);
    if ((await t.balanceOf(holder)) === amount) return;
    await provider.send("anvil_setStorageAt", [token, slot, prev]); // restore, wrong slot
  }
  throw new Error("could not locate balances slot for " + token);
}
async function lastScanned() {
  const latest = await provider.send("eth_getBlockByNumber", ["latest", false]);
  let n = parseInt(latest.number, 16) - 1; if (n < 0) n = 0;
  const blk = await provider.send("eth_getBlockByNumber", ["0x" + n.toString(16), false]);
  return [blk.hash, n, parseInt(blk.timestamp, 16)];
}

// ── forge deploy (same script the server uses) ──
function forge(sigArgs) {
  const args = ["script", SCRIPT, "--rpc-url", RPC, "--broadcast", "--private-key", ADMIN_KEY, ...sigArgs];
  const r = spawnSync("forge", args, { cwd: REPO, encoding: "utf8" });
  if (r.status !== 0) throw new Error("forge failed:\n" + (r.stderr || r.stdout || "").slice(-2000));
  const d = {};
  for (const line of (r.stdout || "").split("\n")) {
    const ma = line.match(/^\s*(\w+)\s+:\s+(0x[0-9a-fA-F]{40})\s*$/); if (ma) { d[ma[1]] = ma[2]; continue; }
    const mi = line.match(/^\s*(0x[0-9a-fA-F]{64})\s*$/); if (mi) d.marketId = mi[1];
  }
  return d;
}

// ── action handlers (mirror public/index.html ACTIONS) ──
const A = {
  deployCore: async () => { const d = forge(["--sig", "deployCore()"]); state.core = d.core; state.guardian = d.guardianSignals; },
  deployToken: async (p) => { const d = forge(["--sig", "deployToken(string,uint8)", String(p.symbol), String(p.decimals)]); state.tokens.push({ address: d.token, symbol: String(p.symbol), decimals: Number(p.decimals) }); },
  createMarket: async (p) => {
    const loan = tokBySymbol(p.loan)?.address || p.loan, coll = tokBySymbol(p.collateral)?.address || p.collateral;
    const ld = await decimals(loan), cd = await decimals(coll);
    const price = ethers.parseUnits(String(p.price), 36 + ld - cd), lltv = ethers.parseUnits(String(p.lltv), 18), minA = ethers.parseUnits(String(p.minActivation), cd);
    const d = forge(["--sig", "createMarket(address,address,address,address,uint256,uint256,uint128)", state.core, state.guardian, loan, coll, price.toString(), lltv.toString(), minA.toString()]);
    state.markets.push({ core: state.core, loanToken: loan, collateralToken: coll, lltv: lltv.toString(), oracle: d.oracle, guardianSignals: state.guardian, irm: d.irm, adaptive: d.adaptive, controller: d.controller, vault: d.vault, marketId: d.marketId });
    cur = state.markets.length - 1;
  },
  selectMarket: async (p) => { cur = Number(p.index); },
  watch: async () => {},
  fund: async (p) => { const mk = m(); const token = String(p.side).toLowerCase() === "collateral" ? mk.collateralToken : mk.loanToken; await deal(token, ethers.getAddress(p.to), ethers.parseUnits(String(p.amount), await decimals(token))); },
  warp: async (p) => { await provider.send("evm_increaseTime", [Math.max(1, Number(p.seconds))]); await provider.send("evm_mine", []); },
  setPrice: async (p) => { const mk = m(); await (await new ethers.Contract(mk.oracle, ORACLE, await signerFor(p.from || ADMIN)).setPrice(ethers.parseUnits(String(p.price), await oracleScale(mk)))).wait(); },
  bumpPrice: async (p) => { const mk = m(); const o = new ethers.Contract(mk.oracle, ORACLE, await signerFor(p.from || ADMIN)); const cur2 = await o.price(); const bps = BigInt(Math.round(Number(p.pct) * 100)); await (await o.setPrice(cur2 * (10000n + bps) / 10000n)).wait(); },
  crashPrice: async (p) => { await A.bumpPrice({ pct: (p && p.pct !== undefined) ? p.pct : -50, from: p.from }); },
  setCurveParams: async (p) => { const mk = m(); await (await new ethers.Contract(mk.adaptive, ADAPTIVE, await signerFor(p.from || ADMIN)).setMarketCurveParams(mp(mk), p.values.map(v => BigInt(String(v).includes("e") ? Number(v) : v)))).wait(); },
  setSupplyCap: async (p) => { const mk = m(); const d2 = await decimals(mk.loanToken); const cap = Number(p.cap) === 0 ? 0n : ethers.parseUnits(String(p.cap), d2); await (await new ethers.Contract(mk.controller, CTLCFG, await signerFor(p.from || ADMIN)).setSupplyCap(cap)).wait(); },
  grantInstantActivation: async (p) => { const mk = m(); await (await new ethers.Contract(mk.controller, CTLCFG, await signerFor(p.from || ADMIN)).grantInstantActivation(ethers.getAddress(p.caller))).wait(); },
  setSettlementLtv: async (p) => { const mk = m(); await (await new ethers.Contract(mk.controller, CTLCFG, await signerFor(p.from)).setSettlementLtv(ethers.parseUnits(String(p.ltv), 18))).wait(); },
  marketPause: async (p) => { const mk = m(); await (await new ethers.Contract(mk.controller, CTLCFG, await signerFor(p.from || ADMIN)).pauseFor(BigInt(p.seconds))).wait(); },
  marketResume: async (p) => { const mk = m(); await (await new ethers.Contract(mk.controller, CTLCFG, await signerFor(p.from || ADMIN)).resume()).wait(); },
  deposit: async (p) => { const mk = m(); const d2 = await decimals(mk.loanToken); const assets = ethers.parseUnits(String(p.amount), d2); await ensureApprove(mk.loanToken, p.from, mk.vault); await (await new ethers.Contract(mk.vault, VAULT, await signerFor(p.from)).deposit(assets, p.from)).wait(); },
  withdrawMax: async (p) => { const mk = m(); const v = new ethers.Contract(mk.vault, VAULT, await signerFor(p.from)); const max = await v.maxWithdraw(p.from); if (max === 0n) return; await (await v.withdraw(max, p.from, p.from)).wait(); },
  fallbackExit: async (p) => { const mk = m(); await (await new ethers.Contract(mk.vault, VAULT, await signerFor(p.from)).fallbackExit(ethers.parseUnits(String(p.shares), 18), p.from, p.from, BigInt(p.maxIterations || 10))).wait(); },
  settle: async (p) => { const mk = m(); const bs = (p.borrowers || []).map(a => ethers.getAddress(a)); await (await new ethers.Contract(mk.vault, VAULT, await signerFor(p.from)).settle(ethers.parseUnits(String(p.shares), 18), bs, p.from, p.from)).wait(); },
  coreSupply: async (p) => { const mk = m(); const d2 = await decimals(mk.loanToken); const assets = ethers.parseUnits(String(p.amount), d2); await ensureApprove(mk.loanToken, p.from, mk.core); await (await new ethers.Contract(mk.core, CORE, await signerFor(p.from)).supply(mp(mk), assets, 0n, p.from, "0x")).wait(); },
  coreWithdrawAll: async (p) => { const mk = m(); const c = new ethers.Contract(mk.core, CORE, await signerFor(p.from)); const pos = await c.position(mk.marketId, p.from); if (pos.supplyShares === 0n) return; await (await c.withdraw(mp(mk), 0n, pos.supplyShares, p.from, p.from)).wait(); },
  supplyCollateral: async (p) => { const mk = m(); const d2 = await decimals(mk.collateralToken); const amt = ethers.parseUnits(String(p.amount), d2); await ensureApprove(mk.collateralToken, p.from, mk.core); await (await new ethers.Contract(mk.core, CORE, await signerFor(p.from)).supplyCollateral(mp(mk), amt, p.from, "0x")).wait(); },
  borrow: async (p) => { const mk = m(); const d2 = await decimals(mk.loanToken); await (await new ethers.Contract(mk.core, CORE, await signerFor(p.from)).borrow(mp(mk), ethers.parseUnits(String(p.amount), d2), 0n, p.from, p.from)).wait(); },
  repayAll: async (p) => { const mk = m(); const c = new ethers.Contract(mk.core, CORE, await signerFor(p.from)); const pos = await c.position(mk.marketId, p.from); if (pos.borrowShares === 0n) return; await ensureApprove(mk.loanToken, p.from, mk.core); await (await c.repay(mp(mk), 0n, pos.borrowShares, p.from, "0x")).wait(); },
  withdrawCollateral: async (p) => { const mk = m(); const d2 = await decimals(mk.collateralToken); await (await new ethers.Contract(mk.core, CORE, await signerFor(p.from)).withdrawCollateral(mp(mk), ethers.parseUnits(String(p.amount), d2), p.from, p.from)).wait(); },
  liquidateMax: async (p) => { const mk = m(); const c = new ethers.Contract(mk.core, CORE, await signerFor(p.from)); const v = new ethers.Contract(mk.vault, VAULT, provider); const b = ethers.getAddress(p.borrower); const pos = await c.position(mk.marketId, b); if (pos.collateral === 0n) throw new Error("no collateral to seize"); const before = await c.market(mk.marketId); const ppsB = await v.convertToAssets(ethers.parseUnits("1", 18)); await ensureApprove(mk.loanToken, p.from, mk.core); await (await c.liquidate(mp(mk), b, pos.collateral, 0n, "0x")).wait(); const after = await c.market(mk.marketId); const pz = await c.position(mk.marketId, b); const ppsA = await v.convertToAssets(ethers.parseUnits("1", 18)); log(`  BAD-DEBT: seized all collateral of ${b.slice(0, 10)}; residual borrowShares ${pos.borrowShares}->${pz.borrowShares} (written off), totalBorrowAssets -${ethers.formatEther(before.totalBorrowAssets - after.totalBorrowAssets)} WETH, vault pps ${ethers.formatEther(ppsB)}->${ethers.formatEther(ppsA)}`); },
  addGuardian: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from || ADMIN)).addGuardian(ethers.getAddress(p.address))).wait(); },
  setQuorum: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from || ADMIN)).setQuorum(BigInt(p.n))).wait(); },
  setSuspectWindow: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from || ADMIN)).setSuspectWindow(BigInt(p.n))).wait(); },
  flag: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from)).flag(mk.marketId, [ethers.getAddress(p.account)], await lastScanned())).wait(); },
  unflag: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from)).unflag(mk.marketId, [ethers.getAddress(p.account)], await lastScanned())).wait(); },
  suspect: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from)).suspect(mk.marketId, [ethers.getAddress(p.account)], await lastScanned())).wait(); },
  unsuspect: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from)).unsuspect(mk.marketId, [ethers.getAddress(p.account)], await lastScanned())).wait(); },
  ban: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from || ADMIN)).ban(mk.marketId, ethers.getAddress(p.account))).wait(); },
  unban: async (p) => { const mk = m(); await (await new ethers.Contract(mk.guardianSignals, GUARDIAN, await signerFor(p.from || ADMIN)).unban(mk.marketId, ethers.getAddress(p.account))).wait(); },
};

async function startAnvil() {
  anvilProc = spawn("anvil", ["--host", "127.0.0.1", "--port", PORT], { cwd: REPO, stdio: "ignore" });
  for (let i = 0; i < 60; i++) { try { await new ethers.JsonRpcProvider(RPC, undefined, { staticNetwork: true }).getBlockNumber(); return; } catch { await sleep(250); } }
  throw new Error("anvil did not come up");
}

(async () => {
  const steps = JSON.parse(fs.readFileSync(FILE, "utf8"));
  log(`scenario: ${FILE} (${steps.length} steps)`);
  const externalRpc = argv.includes("--rpc");
  if (!externalRpc) { log("starting anvil on :" + PORT + " …"); await startAnvil(); }
  provider = new ethers.JsonRpcProvider(RPC, undefined, { cacheTimeout: -1, staticNetwork: true });

  let ok = 0;
  const t0 = Date.now();
  for (let i = 0; i < steps.length; i++) {
    const s = steps[i], fn = A[s.a];
    if (!fn) { log(`✗ step ${i + 1}/${steps.length}: unknown action "${s.a}"`); break; }
    try { await fn(s); ok++; if (ok % 250 === 0) log(`… ${ok}/${steps.length} ok (${((Date.now() - t0) / 1000).toFixed(0)}s)`); }
    catch (e) { const data = e?.data || e?.info?.error?.data || e?.revert?.data || (typeof e?.error?.data === "string" ? e.error.data : null); const named = decodeErr(data); log(`✗ step ${i + 1}/${steps.length} (${s.a}${s.from ? " from " + s.from.slice(0, 10) : ""}): ${named || e.shortMessage || e.message}`); log("  params: " + JSON.stringify(s));
      try { if (s.from && cur >= 0) { const mk = state.markets[cur]; const who = ethers.getAddress(s.from); const lb = await new ethers.Contract(mk.loanToken, ERC20, provider).balanceOf(who); const al = await new ethers.Contract(mk.loanToken, ERC20, provider).allowance(who, mk.core); const cc = new ethers.Contract(mk.core, CORE, provider); const pz = await cc.position(mk.marketId, who); const mkt = await cc.market(mk.marketId); const owed = mkt.totalBorrowShares === 0n ? 0n : (pz.borrowShares * mkt.totalBorrowAssets + mkt.totalBorrowShares - 1n) / mkt.totalBorrowShares; const ld = await decimals(mk.loanToken); log(`  diag mk#${cur}: loanBal=${ethers.formatUnits(lb, ld)} owed=${ethers.formatUnits(owed, ld)} allowanceToCore=${al === ethers.MaxUint256 ? "max" : al.toString()} borrowShares=${pz.borrowShares} collateral=${pz.collateral} | mkt tBA=${ethers.formatUnits(mkt.totalBorrowAssets, ld)} tBS=${mkt.totalBorrowShares}`); } } catch (d) { log("  diag failed: " + d.message); }
      break; }
  }
  log(`\n${ok === steps.length ? "✓ ALL" : "✗ HALTED after"} ${ok}/${steps.length} steps in ${((Date.now() - t0) / 1000).toFixed(0)}s`);

  // report bad-debt realization on the ETH market (market #0): totalBorrowAssets>0 with no backing collateral shows
  // socialization; also print the vault share price, which drops when bad debt is realized.
  try {
    if (state.markets[0]) {
      const mk = state.markets[0]; const c = new ethers.Contract(mk.core, CORE, provider); const v = new ethers.Contract(mk.vault, VAULT, provider);
      const mkt = await c.market(mk.marketId); const pps = await v.convertToAssets(ethers.parseUnits("1", 18));
      log(`ETH market: totalSupplyAssets=${ethers.formatEther(mkt.totalSupplyAssets)} totalBorrowAssets=${ethers.formatEther(mkt.totalBorrowAssets)} | vault pps=${ethers.formatEther(pps)}`);
    }
  } catch (e) { log("state read failed: " + e.message); }

  if (anvilProc && !flag("keep")) { try { anvilProc.kill("SIGKILL"); } catch {} }
  process.exit(ok === steps.length ? 0 : 1);
})();
