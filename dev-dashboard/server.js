// SPDX-License-Identifier: GPL-2.0-or-later
// Dev-UI backend: manages a local anvil node and runs the split forge devnet actions against it
// (deploy core · deploy mock token · create market). Everything else (seeding, time-travel, oracle,
// state) the browser does directly over JSON-RPC.
"use strict";

const express = require("express");
const path = require("path");
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

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

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
  });
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
  res.json({ running: true, mode, rpc: DEFAULT_RPC, accounts: ANVIL_ACCOUNTS });
});

app.post("/api/node/stop", (_req, res) => {
  if (anvil) { anvil.proc._intentional = true; try { anvil.proc.kill(); } catch {} }
  anvil = null;
  state = { core: null, guardianSignals: null, tokens: [], markets: [] };
  res.json({ running: false });
});

// ── forge runner ──
function runForge(extraArgs, req) {
  const rpc = req.body?.rpc || anvil?.rpc || DEFAULT_RPC;
  const privateKey = req.body?.privateKey || ANVIL_ACCOUNTS[0].key;
  const args = ["script", SCRIPT, "--rpc-url", rpc, "--broadcast", "--private-key", privateKey, ...extraArgs];
  return new Promise((resolve) => {
    const forge = spawn("forge", args, { cwd: REPO_ROOT, env: process.env });
    let out = "", err = "";
    forge.stdout.on("data", (d) => (out += d.toString()));
    forge.stderr.on("data", (d) => (err += d.toString()));
    forge.on("close", (code) => resolve({ code, out, err }));
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

// ── 2a · deploy core (singleton) ──
app.post("/api/deploy/core", async (req, res) => {
  const r = await runForge(["--sig", "deployCore()"], req);
  if (r.code !== 0) return res.status(500).json({ error: "deployCore failed", log: (r.err || r.out).slice(-4000) });
  const d = parseLabels(r.out);
  if (!d.core || !d.guardianSignals) return res.status(500).json({ error: "could not parse core/guardian", log: r.out.slice(-4000) });
  state.core = d.core;
  state.guardianSignals = d.guardianSignals; // project-level singleton, shared by every market
  res.json({ core: d.core, guardianSignals: d.guardianSignals });
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
  res.json({ token: entry });
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
  res.json({ market });
});

app.listen(PORT, () => {
  console.log(`Lido Lend dev-UI on http://127.0.0.1:${PORT}  (repo: ${REPO_ROOT})`);
});
