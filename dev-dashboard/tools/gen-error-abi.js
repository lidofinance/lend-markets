#!/usr/bin/env node
// Regenerate the PROTOCOL_ERRORS list in public/index.html from the forge artifacts (out/).
//
//   forge build                       # produce out/ first
//   node dev-dashboard/tools/gen-error-abi.js
//
// PROTOCOL_ERRORS is the static dictionary the dashboard uses to decode reverts (custom-error selectors
// → names). Run this after adding/changing custom errors so the decoder stays in sync with the contracts.
"use strict";
const fs = require("fs");
const path = require("path");
const E = require("ethers"); // resolved from dev-dashboard/node_modules

const REPO_ROOT = path.resolve(__dirname, "..", "..");
const OUT = path.join(REPO_ROOT, "out");
const INDEX = path.resolve(__dirname, "..", "public", "index.html");

if (!fs.existsSync(OUT)) {
  console.error("no out/ — run `forge build` at the repo root first");
  process.exit(1);
}

function walk(dir) {
  let files = [];
  for (const f of fs.readdirSync(dir)) {
    const p = path.join(dir, f);
    let st; try { st = fs.statSync(p); } catch { continue; }
    if (st.isDirectory()) files = files.concat(walk(p));
    else if (f.endsWith(".json")) files.push(p);
  }
  return files;
}

const bySelector = new Map();
for (const file of walk(OUT)) {
  let j; try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch { continue; }
  if (!Array.isArray(j.abi)) continue;
  for (const e of j.abi) {
    if (e.type !== "error") continue;
    let frag; try { frag = E.ErrorFragment.from(e); } catch { continue; }
    if (bySelector.has(frag.selector)) continue;
    let s = frag.format("full");
    if (!s.startsWith("error ")) s = "error " + s;
    bySelector.set(frag.selector, s);
  }
}

const list = [...bySelector.values()].sort();
console.log(`collected ${list.length} unique custom errors from ${OUT}`);

const block = "const PROTOCOL_ERRORS = [\n" + list.map((s) => "  " + JSON.stringify(s)).join(",\n") + "\n];";
const re = /const PROTOCOL_ERRORS = \[[\s\S]*?\n\];/;

let html = fs.readFileSync(INDEX, "utf8");
if (!re.test(html)) {
  console.error("could not find the PROTOCOL_ERRORS block in", INDEX);
  process.exit(1);
}
html = html.replace(re, block);
fs.writeFileSync(INDEX, html);
console.log("updated", path.relative(REPO_ROOT, INDEX));
