// SPDX-License-Identifier: GPL-2.0-or-later
// Dev-UI backend: manages a local anvil node and runs the split forge devnet actions against it
// (deploy core · deploy mock token · create market). Everything else (seeding, time-travel, oracle,
// state) the browser does directly over JSON-RPC.
"use strict";

const express = require("express");
const path = require("path");
const fs = require("fs");
const { spawn } = require("child_process");

const REPO_ROOT = path.resolve(__dirname, "..");
const PORT = Number(process.env.DEVUI_PORT || 8899);
const DEFAULT_RPC = "http://127.0.0.1:8545";
const SCRIPT = "script/Devnet.s.sol";

// The deterministic accounts of anvil's default mnemonic. A dev tool signing with well-known keys against a
// throwaway node — never use these anywhere real.
const ANVIL_ACCOUNTS = [
  { address: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", key: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" },
  { address: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", key: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" },
  { address: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", key: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a" },
  { address: "0x90F79bf6EB2c4f870365E785982E1f101E93b906", key: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6" },
  { address: "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65", key: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a" },
];

let anvil = null; // { proc, mode, rpc, forkUrl }
let state = { core: null, guardianSignals: null, tokens: [], markets: [] };

// Scenario history: the chronological log of executed actions, persisted server-side so it survives a
// page reload. Archived (not deleted) on node stop/start — the last few sessions are kept alongside.
let history = [];
let historyArchive = [];
let txLog = []; // { hash, label } of txs the browser has sent this session (reset on node start/stop)
function archiveHistory(reason) {
  if (history.length) { historyArchive.unshift({ reason, steps: history }); historyArchive = historyArchive.slice(0, 3); }
  history = [];
  txLog = []; // hashes belong to the old chain
}

const app = express();
app.use(express.json({ limit: "64mb" })); // a picked scenario file is POSTed as content (can be a few MB)
app.use(express.static(path.join(__dirname, "public")));
app.use("/scenarios", express.static(path.join(REPO_ROOT, "dev-dashboard", "scenarios"))); // serve scenario files so the UI can load one into the input

function rpcReady(url) {
  return fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] }),
  }).then((r) => r.ok).catch(() => false);
}
async function waitForRpc(url, tries = 40) {
  for (let i = 0; i < tries; i++) {
    if (await rpcReady(url)) return true;
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
}

// ── node lifecycle ──
app.get("/api/node/status", (_req, res) => {
  res.json({
    running: !!anvil,
    mode: anvil?.mode || null,
    rpc: anvil?.rpc || DEFAULT_RPC,
    forkUrl: anvil?.forkUrl || null,
    accounts: ANVIL_ACCOUNTS,
    state,
    history,
    archive: historyArchive,
  });
});

// ── transaction hashes: the browser reports each sent tx so it lands in the server log and can be
//    looked up later (eth_getTransactionReceipt → .logs for the emitted events) ──
app.post("/api/txlog", (req, res) => {
  const { hash, label } = req.body || {};
  if (!hash) return res.status(400).json({ error: "hash required" });
  txLog.push({ hash, label: label || null });
  txLog = txLog.slice(-1000);
  res.json({ ok: true });
});
app.get("/api/txlog", (_req, res) => res.json({ txLog }));

// ── event ABIs from forge artifacts, so the browser can decode any emitted event (incl. struct-typed
//    ones the hand-written list can't express). Collected once from out/ and cached. ──
let abiCache = null;
function collectAbis() {
  const outDir = path.join(REPO_ROOT, "out");
  if (!fs.existsSync(outDir)) return { events: [], functions: [] };
  const seenE = new Set(), seenF = new Set(), events = [], functions = [];
  const walk = (dir) => {
    for (const f of fs.readdirSync(dir)) {
      const p = path.join(dir, f);
      let st; try { st = fs.statSync(p); } catch { continue; }
      if (st.isDirectory()) walk(p);
      else if (f.endsWith(".json")) {
        let j; try { j = JSON.parse(fs.readFileSync(p, "utf8")); } catch { continue; }
        if (!Array.isArray(j.abi)) continue;
        for (const e of j.abi) {
          const key = e.name + JSON.stringify(e.inputs || []);
          if (e.type === "event" && !seenE.has(key)) { seenE.add(key); events.push(e); }
          else if (e.type === "function" && !seenF.has(key)) { seenF.add(key); functions.push(e); }
        }
      }
    }
  };
  try { walk(outDir); } catch {}
  return { events, functions };
}
app.get("/api/events-abi", (_req, res) => { abiCache = abiCache || collectAbis(); res.json({ events: abiCache.events }); });
app.get("/api/functions-abi", (_req, res) => { abiCache = abiCache || collectAbis(); res.json({ functions: abiCache.functions }); });

// ── scenario history (persisted, archived on node lifecycle) ──
app.get("/api/history", (_req, res) => res.json({ history, archive: historyArchive }));
app.post("/api/history", (req, res) => {
  const step = req.body?.step;
  if (!step || typeof step !== "object") return res.status(400).json({ error: "step object required" });
  history.push(step);
  res.json({ history });
});
app.post("/api/history/clear", (_req, res) => {
  archiveHistory("manual clear");
  res.json({ history, archive: historyArchive });
});

app.post("/api/node/start", async (req, res) => {
  const { mode = "local", forkUrl } = req.body || {};
  if (mode === "fork" && !forkUrl) return res.status(400).json({ error: "forkUrl required for fork mode" });

  // Restart cleanly: drop our previous node, and if something else already holds 8545, refuse (don't deploy
  // onto an unknown chain the user may not expect).
  if (anvil) { anvil.proc._intentional = true; try { anvil.proc.kill("SIGKILL"); } catch {} anvil = null; await new Promise((r) => setTimeout(r, 400)); }
  if (await rpcReady(DEFAULT_RPC)) {
    return res.status(409).json({ error: "something is already listening on 127.0.0.1:8545 — stop it, or point `rpc` at it and skip start" });
  }

  const args = ["--host", "127.0.0.1", "--port", "8545"];
  if (mode === "fork") args.push("--fork-url", forkUrl);
  const proc = spawn("anvil", args, { cwd: REPO_ROOT, stdio: "ignore", detached: false });
  let exited = false;
  proc.on("error", (e) => { exited = true; console.error("anvil spawn error:", e.message); });
  proc.on("exit", (c, s) => {
    exited = true;
    // A restart/stop kills the prior node on purpose — log that calmly; only surface a real crash as an error.
    if (proc._intentional) console.log("anvil stopped (restart)");
    else console.error(`anvil exited unexpectedly (code=${c} signal=${s})`);
  });

  let up = false;
  for (let i = 0; i < 40 && !exited; i++) {
    if (await rpcReady(DEFAULT_RPC)) { up = true; break; }
    await new Promise((r) => setTimeout(r, 250));
  }
  if (!up) {
    try { proc.kill("SIGKILL"); } catch {}
    return res.status(500).json({ error: exited ? "anvil exited immediately (port busy, or not on PATH)" : "anvil did not come up in time" });
  }
  anvil = { proc, mode, rpc: DEFAULT_RPC, forkUrl: forkUrl || null };
  state = { core: null, guardianSignals: null, tokens: [], markets: [] };
  archiveHistory("node start"); // fresh chain → fresh history, prior session kept in the archive
  res.json({ running: true, mode, rpc: DEFAULT_RPC, accounts: ANVIL_ACCOUNTS });
});

app.post("/api/node/stop", (_req, res) => {
  if (anvil) { anvil.proc._intentional = true; try { anvil.proc.kill(); } catch {} }
  anvil = null;
  state = { core: null, guardianSignals: null, tokens: [], markets: [] };
  archiveHistory("node stop");
  res.json({ running: false });
});

// ── forge runner ──
function runForge(extraArgs, req) {
  const rpc = req.body?.rpc || anvil?.rpc || DEFAULT_RPC;
  const privateKey = req.body?.privateKey || ANVIL_ACCOUNTS[0].key;
  const args = ["script", SCRIPT, "--rpc-url", rpc, "--broadcast", "--private-key", privateKey, ...extraArgs];
  return new Promise((resolve) => {
    const forge = spawn("forge", args, { cwd: REPO_ROOT, env: process.env });
    let out = "", err = "", done = false;
    const finish = (code) => { if (!done) { done = true; resolve({ code, out, err }); } };
    // surface a missing/broken toolchain instead of resolving with an empty log
    forge.on("error", (e) => {
      err += `[spawn error] ${e.message}`
        + (e.code === "ENOENT" ? " — `forge` not found on PATH. Install Foundry (https://getfoundry.sh) and reopen the terminal." : "");
      finish(127);
    });
    forge.stdout.on("data", (d) => (out += d.toString()));
    forge.stderr.on("data", (d) => (err += d.toString()));
    forge.on("close", (code) => finish(code));
  });
}

function parseLabels(stdout) {
  const d = {};
  const addr = /^\s*(\w+)\s+:\s+(0x[0-9a-fA-F]{40})\s*$/;
  const id = /^\s*(0x[0-9a-fA-F]{64})\s*$/;
  for (const line of stdout.split("\n")) {
    const m = line.match(addr);
    if (m) { d[m[1]] = m[2]; continue; }
    const mi = line.match(id);
    if (mi) d.marketId = mi[1];
  }
  return d;
}

// Pull the tx hashes forge just broadcast (from the run's saved transactions file named in stdout) and
// record them in txLog with a label, so server-side deploy txs also appear in the node tx history.
function recordForgeTxs(stdout, label) {
  const m = stdout.match(/Transactions saved to:\s*(\S+\.json)/);
  if (!m) return [];
  let j; try { j = JSON.parse(fs.readFileSync(m[1], "utf8")); } catch { return []; }
  const hashes = (j.transactions || []).map((t) => t.hash).filter(Boolean);
  for (const hash of hashes) txLog.push({ hash, label });
  txLog = txLog.slice(-1000);
  return hashes;
}

// ── 2a · deploy core (singleton) ──
app.post("/api/deploy/core", async (req, res) => {
  const r = await runForge(["--sig", "deployCore()"], req);
  if (r.code !== 0) return res.status(500).json({ error: "deployCore failed", log: (r.err || r.out).slice(-4000) });
  const d = parseLabels(r.out);
  if (!d.core || !d.guardianSignals) return res.status(500).json({ error: "could not parse core/guardian", log: r.out.slice(-4000) });
  state.core = d.core;
  state.guardianSignals = d.guardianSignals; // project-level singleton, shared by every market
  const txHashes = recordForgeTxs(r.out, "deployCore");
  res.json({ core: d.core, guardianSignals: d.guardianSignals, txHashes });
});

// ── 2b · deploy a mock token ──
app.post("/api/deploy/token", async (req, res) => {
  const { symbol = "TOK", decimals = 18 } = req.body || {};
  const r = await runForge(["--sig", "deployToken(string,uint8)", String(symbol), String(decimals)], req);
  if (r.code !== 0) return res.status(500).json({ error: "deployToken failed", log: (r.err || r.out).slice(-4000) });
  const token = parseLabels(r.out).token;
  if (!token) return res.status(500).json({ error: "could not parse token", log: r.out.slice(-4000) });
  const entry = { address: token, symbol: String(symbol), decimals: Number(decimals) };
  state.tokens.push(entry);
  const txHashes = recordForgeTxs(r.out, "deployToken");
  res.json({ token: entry, txHashes });
});

// ── 2c · create market on an existing core with chosen tokens ──
app.post("/api/market/create", async (req, res) => {
  const p = req.body || {};
  const core = p.core || state.core;
  const guardian = state.guardianSignals;
  if (!core || !guardian) return res.status(400).json({ error: "no core; deploy core first" });
  if (!p.loanToken || !p.collateralToken) return res.status(400).json({ error: "loanToken and collateralToken required" });

  const args = [
    "--sig", "createMarket(address,address,address,address,uint256,uint256,uint128)",
    core, guardian, p.loanToken, p.collateralToken,
    String(p.oraclePrice ?? "2000000000000000000000000000000000000"),
    String(p.lltv ?? "800000000000000000"),
    String(p.minActivation ?? "10000000000000000000"),
  ];
  const r = await runForge(args, req);
  if (r.code !== 0) return res.status(500).json({ error: "createMarket failed", log: (r.err || r.out).slice(-4000) });
  const d = parseLabels(r.out);
  if (!d.vault) return res.status(500).json({ error: "could not parse market", log: r.out.slice(-4000) });
  const market = {
    core, loanToken: p.loanToken, collateralToken: p.collateralToken,
    lltv: String(p.lltv ?? "800000000000000000"),
    oracle: d.oracle, guardianSignals: guardian, irm: d.irm, adaptive: d.adaptive,
    controller: d.controller, vault: d.vault, marketId: d.marketId,
  };
  state.markets.push(market);
  const txHashes = recordForgeTxs(r.out, "createMarket");
  res.json({ market, txHashes });
});

// ── run the headless activity runner (tools/run-scenario.js) against the current node, driven from the UI so the
//    heavy activity does not crawl through the browser (per-step slot-probing + history POSTs). It attaches to the
//    running node and reads the deployed addresses from this server, so run a *.bootstrap.json in the UI first. ──
let scenarioProc = null;
let scenarioLog = [];
let scenarioFile = null;
function scenPush(chunk) { for (const line of String(chunk).split(/\r?\n/)) if (line.trim()) scenarioLog.push(line); scenarioLog = scenarioLog.slice(-400); }
// Once the node runner finishes, fold the steps it actually executed into the scenario history — so the split
// (node) run populates the same history panel as an in-UI run. `deal`/probe overhead stays out of the run: we
// append here, not per step. The count is parsed from the runner's own summary (all vs halted-after-N).
function appendScenarioHistory() {
  try {
    const log = scenarioLog.join("\n");
    const mAll = log.match(/ALL (\d+)\//), mHalt = log.match(/HALTED after (\d+)\b/);
    const n = mAll ? Number(mAll[1]) : mHalt ? Number(mHalt[1]) : 0;
    if (n > 0 && scenarioFile) { for (const s of JSON.parse(fs.readFileSync(scenarioFile, "utf8")).slice(0, n)) history.push(s); scenPush("— appended " + n + " executed step(s) to history"); }
  } catch (e) { scenPush("— history append failed: " + e.message); }
}

app.post("/api/scenario/run", (req, res) => {
  if (scenarioProc) return res.status(409).json({ error: "a scenario run is already in progress" });
  if (!anvil) return res.status(400).json({ error: "start a node first" });
  if (!state.markets || !state.markets.length) return res.status(400).json({ error: "no markets deployed — run a *.bootstrap.json in the script tab first" });
  const body = req.body || {};
  let abs;
  if (body.content != null) {
    // a file picked in the browser is sent as content — validate it and stage it under scenarios/ to run
    let steps; try { steps = JSON.parse(body.content); } catch { return res.status(400).json({ error: "picked file is not valid JSON" }); }
    if (!Array.isArray(steps)) return res.status(400).json({ error: "picked file must be a JSON array of steps" });
    abs = path.join(REPO_ROOT, "dev-dashboard", "scenarios", "_uploaded.activity.json");
    fs.writeFileSync(abs, JSON.stringify(steps));
  } else {
    let file = body.file || "dev-dashboard/scenarios/dense-6mo.activity.json";
    if (!path.isAbsolute(file) && !file.includes("/")) file = path.join("dev-dashboard", "scenarios", file);
    abs = path.resolve(REPO_ROOT, file);
    if (!abs.startsWith(REPO_ROOT) || !fs.existsSync(abs)) return res.status(400).json({ error: "scenario file not found: " + file });
  }
  const runner = path.join(__dirname, "tools", "run-scenario.js");
  scenarioLog = [];
  scenarioFile = abs;
  scenPush("$ node tools/run-scenario.js " + path.basename(abs) + " --from-server");
  const proc = spawn(process.execPath, [runner, abs, "--from-server", "http://127.0.0.1:" + PORT, "--rpc", anvil.rpc], { cwd: REPO_ROOT, env: process.env });
  scenarioProc = proc;
  proc.stdout.on("data", (d) => scenPush(d));
  proc.stderr.on("data", (d) => scenPush(d));
  proc.on("error", (e) => scenPush("[spawn error] " + e.message));
  proc.on("close", (code) => { scenPush("— runner exited (code " + code + ")"); appendScenarioHistory(); if (scenarioProc === proc) scenarioProc = null; });
  res.json({ started: true, file: path.basename(abs) });
});
// list the scenario files (the browser can't point a file dialog at a folder, so the UI picks from this list)
app.get("/api/scenarios", (_req, res) => {
  const dir = path.join(REPO_ROOT, "dev-dashboard", "scenarios");
  let files = [];
  try { files = fs.readdirSync(dir).filter(f => f.endsWith(".json") && !f.startsWith("_")).sort(); } catch {}
  res.json({ dir: "dev-dashboard/scenarios", files });
});
app.get("/api/scenario/status", (_req, res) => res.json({ running: !!scenarioProc, log: scenarioLog.join("\n") }));
app.post("/api/scenario/stop", (_req, res) => { if (scenarioProc) { try { scenarioProc.kill("SIGKILL"); } catch {} scenarioProc = null; scenPush("— stopped by user"); } res.json({ stopped: true }); });

app.listen(PORT, () => {
  console.log(`Lido Lend dev-UI on http://127.0.0.1:${PORT}  (repo: ${REPO_ROOT})`);
});
