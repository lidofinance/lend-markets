#!/usr/bin/env python3
"""Generate State Mate drafts using the same recorded-deployment reader as Forge tests.

Required: RUN, MARKET, RPC_URL. Optional STATE_MATE_ACTIVATION supplies reviewed
motion parameters as JSON. Without it, the selected market is expected to be inert.
OUT_DIR defaults to deployed/<RUN>/state-mate/generated; ABI_DIR defaults to out/.
GUARDIAN_DELEGATES accepts guardian=delegate pairs separated by commas.
Coverage is partial; preserve additional expectations in manually maintained configs.
"""
import re
import gzip
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
ABI_DIR = os.environ.get("ABI_DIR", os.path.join(ROOT, "out"))
RUN = os.environ.get("RUN")
MARKET = os.environ.get("MARKET")
OUT_DIR = os.environ.get("OUT_DIR") or (os.path.join(ROOT, "deployed", RUN, "state-mate", "generated") if RUN else None)
RPC = os.environ.get("RPC_URL")

ZERO = "0x0000000000000000000000000000000000000000"
Z32 = "0x" + "0" * 64
SHARE_DECIMALS = 18

R = {
    "MANAGER_ROLE": "0x241ecf16d79d0f8dbfb92cbc07fe17840425976cf0667f022fe9877caa831b08",
    "PAUSER_ROLE": "0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a",
    "RESUMER_ROLE": "0xf7f4a11bd0d206dbf09149f977ee978cf87879c93f7d8d7b725d222bdd3aa5e3",
    "FREEZER_ROLE": "0x92de27771f92d6942691d73358b3a4673e4880de8356f8f2cf452be87e02d363",
    "UNFREEZER_ROLE": "0x3e02eaefb22229c9fa4ecb927d4a3b0bd2d30b1af650a970c5a95ba1f96906ea",
    "ACCESS_LIMITER_ROLE": "0xfc5f5b5f0f3f8995740cf969e82c673b6edb5075d8813046f28c6058bdd58de0",
    "ACCESS_RESTORER_ROLE": "0x2185faf57ed59187a53d561a36691febce26676457b65b4553aa732fd2c9d195",
}

# Struct fields in ABI order, with the config key each one is read from.
ACTIVATION_FIELDS = [
    ("minActivationDelay", "min_activation_delay"),
    ("maxActivationDelay", "max_activation_delay"),
    ("maxDelayInflow", "max_delay_inflow"),
    ("minDepositAmount", "min_deposit_amount"),
    ("activatingLockDuration", "activating_lock_duration"),
    ("minActivationAmount", "min_activation_amount"),
    ("maxGuardiansQuorumDelay", "max_guardians_quorum_delay"),
    ("delayPerStrike", "delay_per_strike"),
    ("delayPerSuspect", "delay_per_suspect"),
]
SETTLEMENT_FIELDS = [
    ("sliceFloorBps", "slice_floor_bps"),
    ("sliceFloorAssets", "slice_floor_assets"),
    ("fullCutBelowCollateral", "full_cut_below_collateral"),
    ("ltvStepBps", "ltv_step_bps"),
]


def s(value):
    """Uint expectation: state-mate compares large numbers as strings."""
    return str(value)


def die(message):
    sys.exit("gen_state_mate.py: " + message)


def snake_fields(value):
    return {re.sub(r"(?<!^)(?=[A-Z])", "_", key).lower(): item for key, item in value.items()}


def read_inputs():
    if not RUN or not MARKET or not RPC:
        die("set RUN, MARKET and RPC_URL")
    command = ["forge", "script", "script/deployment/ExportDeployment.s.sol", "--sig", "run(string)",
               RUN, "--rpc-url", RPC, "--json"]
    if os.environ.get("FORK_BLOCK"):
        command += ["--fork-block-number", os.environ["FORK_BLOCK"]]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        die("deployment export failed: " + result.stderr.replace(RPC, "<RPC_URL>"))
    output = json.loads(result.stdout)
    if not output["success"]:
        die("deployment export reverted")
    # Decode the ABI string return; Forge's formatted `returns` field escapes JSON for terminal display.
    encoded = bytes.fromhex(output["returned"].removeprefix("0x"))
    offset = int.from_bytes(encoded[:32], "big")
    length = int.from_bytes(encoded[offset:offset + 32], "big")
    snapshot = json.loads(encoded[offset + 32:offset + 32 + length])
    return snapshot_inputs(snapshot)


def snapshot_inputs(d):
    protocol = snake_fields(d["protocol"])
    protocol["risk_steward_dashboard"] = protocol.pop("dashboard")
    protocol["evm_script_executor"] = protocol.pop("executor")
    markets, guardians, oracles = [], {}, {}
    selected = [entry for entry in d["markets"] if entry["plan"]["name"] == MARKET]
    if len(selected) != 1:
        die("MARKET must select exactly one recorded market")
    for entry in selected:
        plan, contracts = entry["plan"], entry["contracts"]
        params = snake_fields(plan["market"])
        activation = snake_fields(params.pop("activation_config"))
        settlement = snake_fields(params.pop("settlement_config"))
        artifact = dict(params, id=contracts["id"], controller=contracts["controller"], vault=contracts["vault"],
                        irm=contracts["params"]["irm"], irm_config=contracts["irmConfig"], role=entry["role"],
                        vault_name=plan["wrapper"]["name"], vault_symbol=plan["wrapper"]["symbol"])
        markets.append({"name": plan["name"], "artifact": artifact,
                        "config": {"market": params, "activation": activation, "settlement": settlement}})
        registry = contracts["guardianSignals"]
        guardian = {"name": plan["name"], "artifact": {"address": registry}, "config": snake_fields(plan["committee"])}
        if registry in guardians and guardians[registry]["config"] != guardian["config"]:
            die("conflicting recorded guardian parameters: " + registry)
        guardians[registry] = guardian
        feed = entry["priceFeed"]
        config = {"kind": entry["priceFeedKind"], "wsteth": feed["wstEth"], "usdy_oracle": feed["usdySource"],
                  "feed": feed["feed"], "min_price": feed["minPrice"], "max_price": feed["maxPrice"]}
        address = contracts["params"]["oracle"]
        if address in oracles and oracles[address]["config"] != config:
            die("conflicting recorded price-feed parameters: " + address)
        oracles[address] = {"name": plan["name"], "artifact": {"address": address}, "config": config}
    motions = None
    if os.environ.get("STATE_MATE_ACTIVATION"):
        with open(os.environ["STATE_MATE_ACTIVATION"]) as handle:
            motions = json.load(handle)
        if not isinstance(motions, dict) or MARKET not in motions:
            die("STATE_MATE_ACTIVATION must contain the selected market")
        for market in markets:
            motion = motions[market["name"]]
            if set(motion) != {"fee", "pauser", "steward", "enableSettlement", "allowExitBooks"}:
                die("each motion requires fee, pauser, steward, enableSettlement and allowExitBooks")
            for key in ("pauser", "steward"):
                if not isinstance(motion[key], str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", motion[key]):
                    die("invalid motion " + key)
            if motion["pauser"].lower() == ZERO or type(motion["fee"]) not in (str, int):
                die("invalid motion pauser or fee")
            if not str(motion["fee"]).isdigit() or not 0 <= int(motion["fee"]) <= 10**18:
                die("fee must be an integer WAD ratio")
            if any(type(motion[key]) is not bool for key in ("enableSettlement", "allowExitBooks")):
                die("motion switches must be JSON booleans")
            market["motion"] = motion
    return {"protocol": protocol, "markets": markets,
            "guardians": list(guardians.values()), "oracles": list(oracles.values()),
            "exit_books": d["books"] if d["books"]["morpho"].lower() != ZERO else None,
            "motions": motions}


def cast_call(address, signature):
    command = ["cast", "call", address, signature, "--rpc-url", RPC]
    if os.environ.get("FORK_BLOCK"):
        command += ["--block", os.environ["FORK_BLOCK"]]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        die("cast call %s %s failed: %s" % (address, signature, result.stderr.strip().replace(RPC, "<RPC_URL>")))
    return result.stdout.strip()


def implementation(proxy):
    return cast_call(proxy, "proxy__getImplementation()(address)")


# ---------------------------------------------------------------------------------------------------------------
# ABIs
# ---------------------------------------------------------------------------------------------------------------
def load_abi(name):
    candidates = [os.path.join(ABI_DIR, name + ".sol", name + ".json"), os.path.join(ABI_DIR, name + ".json")]
    for path in candidates:
        if os.path.isfile(path):
            loaded = json.load(open(path))
            return loaded["abi"] if isinstance(loaded, dict) else loaded
    die("no ABI for %s under %s (run `forge build` or set ABI_DIR)" % (name, ABI_DIR))


def views(name):
    abi = load_abi(name)
    names = sorted({f["name"] for f in abi
                    if f.get("type") == "function" and f.get("stateMutability") in ("view", "pure")})
    return names, abi


def yval(v, ind):
    pad = " " * ind
    if v is None:
        return " null"
    if isinstance(v, bool):
        return " " + ("true" if v else "false")
    if isinstance(v, int):
        return " %d" % v
    if isinstance(v, str):
        return " " + json.dumps(v)
    if isinstance(v, list) and v and isinstance(v[0], dict):
        out = "\n"
        for e in v:
            out += "%s- args: [%s]\n" % (pad, ", ".join(json.dumps(a) for a in e["args"]))
            if isinstance(e["result"], list):
                out += "%s  result: %s\n" % (pad, json.dumps(e["result"]))
            else:
                out += "%s  result:%s\n" % (pad, yval(e["result"], ind + 4))
        return out.rstrip("\n")
    if isinstance(v, list):
        return " " + json.dumps(v)
    if isinstance(v, dict):
        # A struct result: named fields, `null` for the ones left unchecked (state-mate skips them).
        out = "\n"
        for key, value in v.items():
            out += "%s%s:%s\n" % (pad, key, yval(value, ind + 2))
        return out.rstrip("\n")
    raise ValueError(v)


def mk(pairs):
    # No recorded markets means there are no arguments to check, not a zero-argument call.
    return [{"args": a, "result": r} for a, r in pairs] or None


def camel(text):
    return "".join(part.capitalize() for part in text.replace("_", "-").split("-"))


# ---------------------------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------------------------
def build(inputs, impls, mode):
    """Check the selected market and its bindings on shared contracts."""
    live = mode == "live"
    protocol = inputs["protocol"]
    agent, reseal = protocol["agent"], protocol["reseal_manager"]
    core, facade, router = protocol["core"], protocol["owner_facade"], protocol["irm_router"]
    adaptive, dashboard, cb = protocol["adaptive_curve_irm"], protocol["risk_steward_dashboard"], protocol["circuit_breaker"]
    markets = inputs["markets"]
    ids = [m["artifact"]["id"] for m in markets]
    controllers = [m["artifact"]["controller"] for m in markets]

    contracts = []

    def add(alias, abi_name, address, checks, ozacl=None, impl=None):
        names, _ = views(abi_name)
        unknown = set(checks) - set(names)
        if unknown:
            die("%s: unknown methods %s" % (alias, sorted(unknown)))
        contracts.append((alias, abi_name, address, impl, {n: checks.get(n) for n in names}, ozacl))

    def market_params(m):
        """`idToMarketParams(id)`: the recorded params once the market is created, zeros before."""
        a = m["artifact"]
        if not live:
            return {"loanToken": ZERO, "collateralToken": ZERO, "oracle": ZERO, "irm": ZERO, "lltv": "0"}
        return {"loanToken": a["loan_token"], "collateralToken": a["collateral_token"], "oracle": a["oracle"],
                "irm": a["irm"], "lltv": s(a["lltv"])}

    def market_state(market):
        return {"totalSupplyAssets": None if live else "0", "totalSupplyShares": None if live else "0",
                "totalBorrowAssets": None if live else "0", "totalBorrowShares": None if live else "0",
                "lastUpdate": None if live else "0", "fee": s(market["motion"]["fee"]) if live else "0"}

    add("core", "LidoLend", core, {
        "isSettlementEnabled": mk([([m["artifact"]["id"]], m["motion"]["enableSettlement"] if live else False) for m in markets]),
        "marketController": mk([([ids[i]], controllers[i] if live else ZERO) for i in range(len(ids))]),
        "idToMarketParams": mk([([m["artifact"]["id"]], market_params(m)) for m in markets]),
        "market": mk([([m["artifact"]["id"]], market_state(m)) for m in markets]),
    }, impl=impls[core])

    delegates = {}
    for pair in filter(None, os.environ.get("GUARDIAN_DELEGATES", "").split(",")):
        guardian, delegate = pair.split("=")
        delegates[guardian.strip()] = delegate.strip()
    for group in inputs["guardians"]:
        registry, config = group["artifact"]["address"], group["config"]
        checks = {
            "getGuardianCount": len(config["guardians"]), "getQuorum": config["quorum"],
            "getSuspectWindow": config["suspect_window"],
            "DEFAULT_ADMIN_ROLE": Z32, "MANAGER_ROLE": R["MANAGER_ROLE"],
            "ACCESS_LIMITER_ROLE": R["ACCESS_LIMITER_ROLE"], "ACCESS_RESTORER_ROLE": R["ACCESS_RESTORER_ROLE"],
            "isGuardian": mk([([g], True) for g in config["guardians"]]),
        }
        pinned = [(g, delegates[g]) for g in config["guardians"] if g in delegates]
        if pinned:
            checks["getDelegate"] = mk([([g], d) for g, d in pinned])
        add("guardianSignals" + camel(group["name"]), "GuardianSignals", registry, checks,
            {Z32: [agent], R["MANAGER_ROLE"]: [facade], R["ACCESS_RESTORER_ROLE"]: [facade],
             R["ACCESS_LIMITER_ROLE"]: []}, impl=impls[registry])

    add("circuitBreaker", "CircuitBreaker", cb, {
        "getPauser": mk([([m["artifact"]["controller"]], m["motion"]["pauser"] if live else ZERO) for m in markets]),
        "isPauserLive": mk([([m["motion"]["pauser"]], True) for m in markets]) if live else None,
    })

    add("riskStewardDashboard", "RiskStewardDashboard", dashboard, {
        "marketStewards": mk([
            ([m["artifact"]["id"]], [m["motion"]["steward"]]
             if live and m["motion"]["steward"].lower() != ZERO else []) for m in markets]),
    })

    for market in markets:
        artifact, config, label = market["artifact"], market["config"], camel(market["artifact"]["role"])
        activation = [s(config["activation"][key]) for _, key in ACTIVATION_FIELDS]
        settlement = [s(config["settlement"][key]) for _, key in SETTLEMENT_FIELDS]
        add("controller" + label, "LidoLendMarketController", artifact["controller"], {
            "LIDO_LEND": core, "marketId": artifact["id"], "supplyCap": s(config["market"]["supply_cap"]),
            "guardianSignals": artifact["guardian_signals"],
            "collateralActivationConfig": activation, "settlementConfig": settlement,
            "isFrozen": False, "isPaused": False, "hasBadDebt": False,
            "DEFAULT_ADMIN_ROLE": Z32, "MANAGER_ROLE": R["MANAGER_ROLE"], "PAUSER_ROLE": R["PAUSER_ROLE"],
            "RESUMER_ROLE": R["RESUMER_ROLE"], "FREEZER_ROLE": R["FREEZER_ROLE"],
            "UNFREEZER_ROLE": R["UNFREEZER_ROLE"],
        }, {Z32: [agent], R["PAUSER_ROLE"]: [cb, reseal], R["RESUMER_ROLE"]: [reseal],
            R["MANAGER_ROLE"]: [facade, dashboard], R["FREEZER_ROLE"]: [dashboard],
            R["UNFREEZER_ROLE"]: [facade]}, impl=impls[artifact["controller"]])
        add("vault" + label, "LidoLendERC4626", artifact["vault"], {
            "asset": artifact["loan_token"], "controller": artifact["controller"], "LIDO_LEND": core,
            "marketId": artifact["id"], "name": artifact["vault_name"], "symbol": artifact["vault_symbol"],
            "decimals": SHARE_DECIMALS,
        }, impl=impls[artifact["vault"]])

    books = inputs["exit_books"]
    if books:
        add("morphoExitBook", "MorphoExitBook", books["morpho"], {
            "isMarketAllowed": mk([([m["artifact"]["id"]], m["motion"]["allowExitBooks"] if live else False) for m in markets]),
        })
        add("erc4626ExitBook", "Erc4626ExitBook", books["erc4626"], {
            "isVaultAllowed": mk([([m["artifact"]["vault"]], m["motion"]["allowExitBooks"] if live else False) for m in markets]),
        })

    add("irmRouter", "IrmRouter", router, {
        "marketIrm": mk([([i], adaptive if live else ZERO) for i in ids]),
    }, impl=impls[router])
    add("adaptiveCurveIrm", "AdaptiveCurveIrm", adaptive, {
        "marketCurveConfig": mk([([m["artifact"]["id"]], m["artifact"]["irm_config"] if live else ZERO)
                                 for m in markets]),
    })

    for oracle in inputs["oracles"]:
        artifact, config = oracle["artifact"], oracle["config"]
        if config["kind"] == "wsteth-rate":
            add("oracle" + camel(oracle["name"]), "WstEthRateOracle", artifact["address"],
                {"WSTETH": config["wsteth"]}, impl=impls[artifact["address"]])
        elif config["kind"] == "usdy-stable":
            add("oracle" + camel(oracle["name"]), "UsdyStableOracle", artifact["address"],
                {"USDY_ORACLE": config["usdy_oracle"], "stableUsdFeed": config["feed"],
                 "MIN_PRICE": s(config["min_price"]), "MAX_PRICE": s(config["max_price"])},
                impl=impls[artifact["address"]])
        else:
            die("oracle %s: unknown kind %r" % (oracle["name"], config["kind"]))
    return contracts


# ---------------------------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------------------------
def emit(name, header, contracts, proxy_admin, chain, rpc_env):
    lines = ["# " + line for line in header] + [""]
    lines.append("parameters:")
    lines.append('  - &proxyAdmin "%s"' % proxy_admin)
    lines.append("")
    lines.append("deployed:")
    lines.append("  l1:")
    seen = []
    for _, _, addr, impl, _, _ in contracts:
        for a in (addr, impl):
            if a and a not in seen:
                seen.append(a)
    for a in seen:
        lines.append('    - "%s"' % a)
    lines.append("")
    lines.append("l1:")
    lines.append("  rpcUrl: %s" % rpc_env)
    lines.append("  chainId: %d" % chain)
    lines.append("  contracts:")
    for alias, abi_name, addr, impl, checks, ozacl in contracts:
        lines.append("    %s:" % alias)
        lines.append("      name: %s" % abi_name)
        lines.append('      address: "%s"' % addr)
        if impl:
            lines.append("      proxyName: OssifiableProxy")
            lines.append('      implementation: "%s"' % impl)
            lines.append("      proxyAdmin: *proxyAdmin")
        lines.append("      checks:")
        for method, value in checks.items():
            lines.append("        %s:%s" % (method, yval(value, 10)))
        if ozacl:
            lines.append("      ozAcl:")
            for role, holders in ozacl.items():
                lines.append('        "%s": [%s]' % (role, ", ".join('"%s"' % h for h in holders)))
    path = os.path.join(OUT_DIR, name)
    if os.path.exists(path) and not generated_draft(path):
        die("refusing to overwrite a manually maintained config: " + path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=os.path.dirname(path), delete=False) as handle:
        handle.write("\n".join(lines) + "\n")
        temporary = handle.name
    os.replace(temporary, path)
    return path


def generated_draft(path):
    with open(path) as handle:
        first_line = handle.readline()
    return first_line.startswith(("# State Mate draft from ", "# state-mate config generated from "))


def main():
    inputs = read_inputs()
    protocol = inputs["protocol"]
    chain = int(protocol["chain_id"])
    proxies = [protocol["core"], protocol["irm_router"]]
    proxies += [g["artifact"]["address"] for g in inputs["guardians"]]
    proxies += [o["artifact"]["address"] for o in inputs["oracles"]]
    for market in inputs["markets"]:
        proxies += [market["artifact"]["controller"], market["artifact"]["vault"]]
    impls = {proxy: implementation(proxy) for proxy in proxies}

    store_path = os.path.join(OUT_DIR, "abis.json.gz")
    store = json.load(gzip.open(store_path, "rt")) if os.path.isfile(store_path) else {}

    header = [
        "State Mate draft from deployed/%s, chain %d, using RecordedDeployment." % (RUN, chain),
        "Expected deployment parameters come from recorded artifacts; motion choices come from STATE_MATE_ACTIVATION.",
        "Proxy implementation addresses come from RPC at generation time; review them against audited deployments.",
        "Coverage is partial. Merge with the reviewed configuration; do not overwrite manual checks.",
    ]
    mode = "live" if inputs["motions"] is not None else "post-deploy"
    note = "Selected market activated with reviewed motion inputs." if mode == "live" else "Selected market inert."
    contracts = build(inputs, impls, mode)
    for _, abi_name, addr, impl, _, _ in contracts:
        store["%d:%s" % (chain, (impl or addr).lower())] = {"name": abi_name, "abi": load_abi(abi_name)}
    path = emit(os.path.join("markets", MARKET + ".yaml"), header + [note], contracts,
                inputs["protocol"]["agent"], chain, "RPC_URL")
    with gzip.open(store_path, "wt") as handle:
        json.dump(store, handle)
    # Retire only outputs owned by the old generator. Other markets and reviewed configs stay intact.
    for name in ("post-deploy.yaml", "live.yaml", "post-activation-fork.yaml"):
        old = os.path.join(OUT_DIR, name)
        if os.path.isfile(old) and generated_draft(old):
            os.unlink(old)
    print("emitted %s (%s); ABI store entries: %d" % (path, mode, len(store)))


if __name__ == "__main__":
    main()
