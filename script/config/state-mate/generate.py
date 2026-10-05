#!/usr/bin/env python3
"""Generate the state-mate configs for a deploy run.

Addresses come from the run's artifacts under deployed/<RUN>/, expected values from the reviewed configs under
script/config/, and proxy implementations from the node the run lives on. Every contract gets every view of its
ABI listed; the ones without an expectation stay `null`.

    RUN=hoodi-testnet-fork HOODI_RPC_URL=http://127.0.0.1:8545 python3 script/config/state-mate/generate.py

Emits, next to this file:
  hoodi-post-deploy.yaml           right after deploy-all — markets inert: no controller bound, no IRM routed,
                                   no pauser or steward, allowlists empty; roles, parameters and proxies checked;
  hoodi-testnet.yaml               the live expectation after the pending motions — markets live, IRM routed,
                                   settlement on, the pauser committee registered and live, the risk steward
                                   (`risk_steward` in the network config) appointed on every market, exit-book
                                   allowlists still empty; the pending-action workflow checks it against the
                                   fork with script/config/pending/hoodi.toml applied;
  hoodi-post-activation-fork.yaml  the same run checked on the fork, where the activation replay
                                   (ActivateMarkets.s.sol) allowlists the exit books and appoints no steward;
  abis.json.gz                     ABIs from forge's out/, keyed chainId:address, so the unverified contracts
                                   need no explorer. Existing entries are kept.

A fork rehearsal run as the live deployer from its live nonce records the addresses the live run will get, so
the config generated from it is ready before the live deploy.

Env: RUN and HOODI_RPC_URL (required), GUARDIAN_DELEGATES ("guardian=delegate,..." pins the delegates),
OUT_DIR (default: this directory), ABI_DIR (default: forge out/).
"""
import glob
import gzip
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
OUT_DIR = os.environ.get("OUT_DIR", HERE)
ABI_DIR = os.environ.get("ABI_DIR", os.path.join(ROOT, "out"))
RUN = os.environ.get("RUN")
RPC = os.environ.get("HOODI_RPC_URL")

ZERO = "0x0000000000000000000000000000000000000000"
Z32 = "0x" + "0" * 64
SHARE_DECIMALS = 18

R = {
    "MARKET_CREATOR_ROLE": "0xd3065a24ad9e7725d223007135762d2902038999e3e5829146654498a58d9795",
    "FEE_MANAGER_ROLE": "0x6c0757dc3e6b28b2580c03fd9e96c274acf4f99d91fbec9b418fa1d70604ff1c",
    "MARKET_MANAGER_ROLE": "0x959ec338079b71742207829b3534c23a2ddd8bcc180652a0ea6677af748b5fed",
    "GUARDIAN_MANAGER_ROLE": "0xb3afbb2c56b38273bac1b7b0b06fc410454e2570313eb67ef81dfaef813acd18",
    "MANAGER_ROLE": "0x241ecf16d79d0f8dbfb92cbc07fe17840425976cf0667f022fe9877caa831b08",
    "PAUSER_ROLE": "0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a",
    "RESUMER_ROLE": "0xf7f4a11bd0d206dbf09149f977ee978cf87879c93f7d8d7b725d222bdd3aa5e3",
    "FREEZER_ROLE": "0x92de27771f92d6942691d73358b3a4673e4880de8356f8f2cf452be87e02d363",
    "UNFREEZER_ROLE": "0x3e02eaefb22229c9fa4ecb927d4a3b0bd2d30b1af650a970c5a95ba1f96906ea",
    "STEWARD_ADMIN_ROLE": "0x4aadd87f245821b0ca19440acc61321fad3b1dd387bc52b706900941926fbce8",
    "ACCESS_LIMITER_ROLE": "0xfc5f5b5f0f3f8995740cf969e82c673b6edb5075d8813046f28c6058bdd58de0",
    "ACCESS_RESTORER_ROLE": "0x2185faf57ed59187a53d561a36691febce26676457b65b4553aa732fd2c9d195",
    "ALLOWLIST_MANAGER_ROLE": "0x8f951261ef278c1584c41b9b68518433e1baeac2a60d977f71ca9fe81511cc2f",
    "RECOVERER_ROLE": "0xb3e25b5404b87e5a838579cb5d7481d61ad96ee284d38ec1e97c07ba64e7f6fc",
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


# ---------------------------------------------------------------------------------------------------------------
# Minimal TOML reader — the artifacts and configs use sections, scalars and string arrays only.
# ---------------------------------------------------------------------------------------------------------------
def _strip_comment(line):
    out, quoted = [], False
    for ch in line:
        if ch == '"':
            quoted = not quoted
        elif ch == "#" and not quoted:
            break
        out.append(ch)
    return "".join(out)


def _scalar(text):
    text = text.strip()
    if text.startswith('"') and text.endswith('"'):
        return text[1:-1]
    if text in ("true", "false"):
        return text == "true"
    if text.lstrip("-").isdigit():
        return int(text)
    raise ValueError("unsupported TOML value: %r" % text)


def _split_array(body):
    items, current, quoted = [], [], False
    for ch in body:
        if ch == '"':
            quoted = not quoted
        if ch == "," and not quoted:
            items.append("".join(current))
            current = []
        else:
            current.append(ch)
    items.append("".join(current))
    return [_scalar(item) for item in items if item.strip()]


def toml_load(path):
    data, section, pending = {"": {}}, "", None
    for raw in open(path):
        line = _strip_comment(raw).strip()
        if pending is not None:
            pending += " " + line
            if "]" in line:
                key, body = pending.split("=", 1)
                data[section][key.strip()] = _split_array(body.strip()[1:-1])
                pending = None
            continue
        if not line:
            continue
        if line.startswith("["):
            section = line.strip("[]").strip()
            data.setdefault(section, {})
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if value.startswith("[") and not value.endswith("]"):
            pending = line
            continue
        if value.startswith("["):
            data[section][key.strip()] = _split_array(value[1:-1])
        else:
            data[section][key.strip()] = _scalar(value)
    return data


def s(value):
    """Uint expectation: state-mate compares large numbers as strings."""
    return str(value)


# ---------------------------------------------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------------------------------------------
def die(message):
    sys.exit("generate.py: " + message)


def run_path(*parts):
    return os.path.join(ROOT, "deployed", RUN, *parts)


def config_path(*parts):
    return os.path.join(ROOT, "script", "config", *parts)


def read_inputs():
    if not RUN:
        die("set RUN to the deploy run under deployed/")
    if not RPC:
        die("set HOODI_RPC_URL to the node the run's contracts live on")
    if not os.path.isfile(run_path("protocol.toml")):
        die("deployed/%s/protocol.toml is missing" % RUN)

    protocol = toml_load(run_path("protocol.toml"))["protocol"]
    network = toml_load(config_path(protocol["network"] + ".toml"))
    net, provision = network[""], network.get("provision", {})

    def by_provision(kind, key):
        names = provision.get(key) or sorted(
            os.path.basename(p)[:-5] for p in glob.glob(run_path(kind, "*.toml")))
        missing = [n for n in names if not os.path.isfile(run_path(kind, n + ".toml"))]
        if missing:
            die("deployed/%s/%s/ lacks %s" % (RUN, kind, ", ".join(missing)))
        return names

    markets = []
    for name in by_provision("markets", "markets"):
        artifact = toml_load(run_path("markets", name + ".toml"))
        config = toml_load(config_path("markets", name + ".toml"))
        markets.append({"name": name, "artifact": artifact["market"], "config": config})

    guardians = []
    for name in by_provision("guardians", "guardians"):
        artifact = toml_load(run_path("guardians", name + ".toml"))["guardian_signals"]
        config = toml_load(config_path("guardians", name + ".toml"))[""]
        guardians.append({"name": name, "artifact": artifact, "config": config})

    oracles = []
    for name in by_provision("oracles", "oracles"):
        artifact = toml_load(run_path("oracles", name + ".toml"))["oracle"]
        config = toml_load(config_path("oracles", name + ".toml"))[""]
        oracles.append({"name": name, "artifact": artifact, "config": config})

    cb_name = protocol["circuit_breaker_artifact"]
    circuit_breaker = {
        "artifact": toml_load(run_path("circuit-breakers", cb_name + ".toml"))["circuit_breaker"],
        "config": toml_load(config_path("circuit-breakers", cb_name + ".toml"))[""],
    }

    exit_books = None
    if os.path.isfile(run_path("exit-books.toml")):
        exit_books = toml_load(run_path("exit-books.toml"))["exit_books"]

    return {
        "protocol": protocol, "network": net, "markets": markets, "guardians": guardians,
        "oracles": oracles, "circuit_breaker": circuit_breaker, "exit_books": exit_books,
    }


def cast_call(address, signature):
    result = subprocess.run(["cast", "call", address, signature, "--rpc-url", RPC],
                            capture_output=True, text=True)
    if result.returncode != 0:
        die("cast call %s %s failed: %s" % (address, signature, result.stderr.strip()))
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
        return ' "%s"' % v
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
    raise ValueError(v)


def mk(pairs):
    return [{"args": a, "result": r} for a, r in pairs]


def camel(text):
    return "".join(part.capitalize() for part in text.replace("_", "-").split("-"))


# ---------------------------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------------------------
def build(inputs, impls, mode):
    """`mode`: "post-deploy" — markets inert; "live" — activated by the EasyTrack motions; "fork" — activated by
    the fork replay (ActivateMarkets.s.sol), which allowlists the exit books and appoints no market steward."""
    live = mode != "post-deploy"
    replay = mode == "fork"
    protocol, net = inputs["protocol"], inputs["network"]
    agent, executor, reseal = net["agent"], net["evm_script_executor"], net["reseal_manager"]
    committee = net.get("pauser_committee") or agent
    core, facade, router = protocol["core"], protocol["owner_facade"], protocol["irm_router"]
    adaptive, dashboard, cb = protocol["adaptive_curve_irm"], protocol["risk_steward_dashboard"], protocol["circuit_breaker"]
    markets = inputs["markets"]
    ids = [m["artifact"]["id"] for m in markets]
    controllers = [m["artifact"]["controller"] for m in markets]
    lltvs = sorted({s(m["config"]["market"]["lltv"]) for m in markets})

    contracts = []

    def add(alias, abi_name, address, checks, ozacl=None, impl=None):
        names, _ = views(abi_name)
        unknown = set(checks) - set(names)
        if unknown:
            die("%s: unknown methods %s" % (alias, sorted(unknown)))
        contracts.append((alias, abi_name, address, impl, {n: checks.get(n) for n in names}, ozacl))

    add("core", "LidoLend", core, {
        "owner": facade, "feeRecipient": agent, "isInitialized": True,
        "isSettlementEnabled": mk([([i], live) for i in ids]),
        "marketController": mk([([ids[i]], controllers[i] if live else ZERO) for i in range(len(ids))]),
        "isIrmEnabled": mk([([router], live)]),
        "isLltvEnabled": mk([([lltv], live) for lltv in lltvs]),
    }, impl=impls[core])

    add("ownerFacade", "LidoLendOwner", facade, {
        "LIDO_LEND": core, "DEFAULT_ADMIN_ROLE": Z32,
        "MARKET_CREATOR_ROLE": R["MARKET_CREATOR_ROLE"], "FEE_MANAGER_ROLE": R["FEE_MANAGER_ROLE"],
        "MARKET_MANAGER_ROLE": R["MARKET_MANAGER_ROLE"], "GUARDIAN_MANAGER_ROLE": R["GUARDIAN_MANAGER_ROLE"],
    }, {Z32: [agent], R["MARKET_CREATOR_ROLE"]: [executor], R["FEE_MANAGER_ROLE"]: [executor],
        R["MARKET_MANAGER_ROLE"]: [executor], R["GUARDIAN_MANAGER_ROLE"]: [executor]})

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

    cb_config = inputs["circuit_breaker"]["config"]
    add("circuitBreaker", "CircuitBreaker", cb, {
        "ADMIN": executor,
        "pauseDuration": s(cb_config["initial_pause_duration"]),
        "heartbeatInterval": s(cb_config["initial_heartbeat_interval"]),
        "MIN_PAUSE_DURATION": s(cb_config["min_pause_duration"]),
        "MAX_PAUSE_DURATION": s(cb_config["max_pause_duration"]),
        "MIN_HEARTBEAT_INTERVAL": s(cb_config["min_heartbeat_interval"]),
        "MAX_HEARTBEAT_INTERVAL": s(cb_config["max_heartbeat_interval"]),
        "getPauser": mk([([c], committee if live else ZERO) for c in controllers]),
        "getPausableCount": mk([([committee], len(controllers) if live else 0)]),
        "isPauserLive": mk([([committee], live)]),
    })

    dashboard_checks = {
        "LIDO_LEND": core, "DEFAULT_ADMIN_ROLE": Z32, "STEWARD_ADMIN_ROLE": R["STEWARD_ADMIN_ROLE"],
    }
    if mode == "live" and net.get("risk_steward"):
        dashboard_checks["marketStewards"] = mk([([i], [net["risk_steward"]]) for i in ids])
    elif mode == "post-deploy":
        dashboard_checks["marketStewards"] = mk([([i], []) for i in ids])
    add("riskStewardDashboard", "RiskStewardDashboard", dashboard, dashboard_checks,
        {Z32: [agent], R["STEWARD_ADMIN_ROLE"]: [executor]})

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
        allowlist_holders = sorted({agent, executor}, key=str.lower)
        book_acl = {Z32: [agent], R["ALLOWLIST_MANAGER_ROLE"]: allowlist_holders,
                    R["FEE_MANAGER_ROLE"]: [executor], R["RECOVERER_ROLE"]: [agent],
                    R["PAUSER_ROLE"]: [net["exit_book_pauser"]], R["RESUMER_ROLE"]: []}
        book_common = {"DEFAULT_ADMIN_ROLE": Z32, "ALLOWLIST_MANAGER_ROLE": R["ALLOWLIST_MANAGER_ROLE"],
                       "FEE_MANAGER_ROLE": R["FEE_MANAGER_ROLE"], "PAUSER_ROLE": R["PAUSER_ROLE"],
                       "RESUMER_ROLE": R["RESUMER_ROLE"], "RECOVERER_ROLE": R["RECOVERER_ROLE"],
                       "feeRecipient": ZERO, "serviceFee": "0", "paused": False,
                       "MAX_REQUEST_LIFETIME": s(net["exit_book_max_request_lifetime"])}
        add("morphoExitBook", "MorphoExitBook", books["morpho"],
            dict(book_common, MORPHO=core, isMarketAllowed=mk([([i], replay) for i in ids])), book_acl)
        add("erc4626ExitBook", "Erc4626ExitBook", books["erc4626"],
            dict(book_common, isVaultAllowed=mk([([m["artifact"]["vault"]], replay) for m in markets])), book_acl)

    add("irmRouter", "IrmRouter", router, {
        "owner": agent, "manager": executor, "MORPHO": core, "isInitialized": True,
        "marketIrm": mk([([i], adaptive if live else ZERO) for i in ids]),
    }, impl=impls[router])
    add("adaptiveCurveIrm", "AdaptiveCurveIrm", adaptive, {
        "owner": agent, "manager": executor, "ROUTER": router,
        "marketCurveConfig": mk([([m["artifact"]["id"]], m["artifact"]["irm_config"] if live else ZERO)
                                 for m in markets]),
    })

    for oracle in inputs["oracles"]:
        artifact, config = oracle["artifact"], oracle["config"]
        if config["kind"] == "wsteth":
            add("oracle" + camel(oracle["name"]), "WstEthRateOracle", artifact["address"],
                {"WSTETH": config["wsteth"]}, impl=impls[artifact["address"]])
        elif config["kind"] == "usdy":
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
def emit(name, header, contracts, proxy_admin, chain):
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
    lines.append("  rpcUrl: HOODI_RPC_URL")
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
    open(path, "w").write("\n".join(lines) + "\n")
    return path


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
        "state-mate config generated from deployed/%s (network %s, chain %d) by generate.py: addresses from"
        % (RUN, protocol["network"], chain),
        "the run's artifacts, expected values from script/config/, implementations from the node at generation",
        "time. Regenerate after any redeploy.",
    ]
    variants = [
        ("hoodi-post-deploy.yaml", "post-deploy",
         "Right after deploy-all: markets inert — no controller bound, no IRM routed, no pauser or steward."),
        ("hoodi-testnet.yaml", "live",
         "Live: activated by the pending motions — the risk steward on every market, exit-book allowlists empty."),
        ("hoodi-post-activation-fork.yaml", "fork",
         "Fork activation replay: exit-book allowlists filled, no market steward."),
    ]
    for name, mode, note in variants:
        contracts = build(inputs, impls, mode)
        for _, abi_name, addr, impl, _, _ in contracts:
            store["%d:%s" % (chain, (impl or addr).lower())] = {"name": abi_name, "abi": load_abi(abi_name)}
        emit(name, header + [note], contracts, inputs["network"]["agent"], chain)

    with gzip.open(store_path, "wt") as handle:
        json.dump(store, handle)
    print("emitted %d configs into %s; ABI store entries: %d" % (len(variants), OUT_DIR, len(store)))


if __name__ == "__main__":
    main()
