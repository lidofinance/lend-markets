#!/usr/bin/env python3
"""Prepare every configured/recorded market on an owned fork of an external post-vote RPC, then test."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen

try:
    import tomllib
except ImportError:
    import tomli as tomllib

ROOT = Path(__file__).resolve().parents[1]


def name(value):
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*", value):
        raise ValueError(f"Invalid deployment/resource name: {value!r}")
    return value


def read_toml(path):
    with path.open("rb") as stream:
        return tomllib.load(stream)


def rpc(url, method, params=None):
    request = Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                                      "params": params or []}).encode(),
                      {"Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=60) as response:
            result = json.load(response)
    except Exception as error:
        # The upstream URL may contain credentials. Do not include urllib's exception text.
        raise RuntimeError(f"RPC {method} failed ({type(error).__name__})") from None
    if "error" in result:
        raise RuntimeError(f"RPC {method} returned an error")
    return result["result"]


def discover_markets(root, config, run):
    config_dir = root / "script/config" / name(config)
    run_dir = root / "deployed" / name(run)
    declared = read_toml(config_dir / "protocol.toml").get("provision", {}).get("markets", [])
    if not isinstance(declared, list) or any(not isinstance(item, str) for item in declared):
        raise ValueError("provision.markets must be a list of resource names")
    recorded = [path.stem for path in (run_dir / "markets").glob("*.toml")]
    markets = sorted({name(item) for item in declared + recorded})
    if not markets:
        raise ValueError("No configured or recorded markets; refusing an empty regression run")
    for market in markets:
        if not (run_dir / "markets" / f"{market}.toml").exists():
            read_toml(config_dir / "markets" / f"{market}.toml")
    return markets


def prepare_markets(markets, exists, deploy, active, activate):
    """Apply the deployment lifecycle independently; existing active markets are never repaired."""
    initial = {}
    pending = []
    for market in markets:
        if not exists(market):
            initial[market] = "missing"
            deploy(market)
        else:
            initial[market] = "active" if active(market) else "inert"
        if initial[market] != "active":
            # A deploy target must leave the market inert; a new onchain market under the same ID is a conflict.
            if initial[market] == "missing" and active(market):
                raise RuntimeError(f"{market}: newly deployed components unexpectedly bind an existing core market")
            pending.append(market)
    if pending:
        activate()
    for market in markets:
        if not active(market):
            raise RuntimeError(f"{market}: activation did not create the core market")
    return initial


def copy_workspace(source, target, run):
    # The run identity stays unchanged; production files are copied, never rewritten or renamed in place.
    for relative in ("Makefile", "foundry.toml", "foundry.lock", "remappings.txt", ".foundryref",
                     "src", "script", "test", "tools", "out", "cache"):
        item = source / relative
        if item.is_dir():
            shutil.copytree(item, target / item.name, ignore=shutil.ignore_patterns("__pycache__"))
        elif item.is_file():
            shutil.copy2(item, target / item.name)
    (target / "lib").symlink_to(source / "lib", target_is_directory=True)
    shutil.copytree(source / "deployed" / run, target / "deployed" / run)


@contextmanager
def fork(upstream, chain_id, log_path):
    block = rpc(upstream, "eth_getBlockByNumber", ["latest", False])
    if int(rpc(upstream, "eth_chainId"), 16) != chain_id:
        raise RuntimeError("Upstream chain ID differs from the deployment artifact")
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    local = f"http://127.0.0.1:{port}"
    with log_path.open("w") as log:
        process = subprocess.Popen([
            "anvil", "--fork-url", upstream, "--fork-block-number", str(int(block["number"], 16)),
            "--chain-id", str(chain_id), "--host", "127.0.0.1", "--port", str(port),
            "--auto-impersonate", "--silent",
        ], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 90
            while True:
                if process.poll() is not None:
                    raise RuntimeError("Anvil exited before becoming ready")
                try:
                    if int(rpc(local, "eth_chainId"), 16) == chain_id:
                        break
                except RuntimeError:
                    pass
                if time.monotonic() >= deadline:
                    raise RuntimeError("Anvil did not become ready")
                time.sleep(0.5)
            yield local, {"number": int(block["number"], 16), "hash": block["hash"]}
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


class Deployment:
    def __init__(self, root, config, run, local):
        self.root, self.config, self.run, self.local = root, config, run, local
        self.run_dir = root / "deployed" / run
        self.record = read_toml(self.run_dir / "protocol.toml")
        self.protocol = self.record["protocol"]
        self.config_values = read_toml(root / "script/config" / config / "protocol.toml")
        self.env = dict(os.environ, RPC_URL=local, ACCEPTANCE_RPC_URL=local, ARTIFACTS_CONFIG=config)
        # A block before synthetic deployment would hide it from the fork suites.
        self.env.pop("FORK_BLOCK", None)
        self.env.pop("ARTIFACTS_DIR", None)
        self.require_code(self.protocol["core"])

    def require_code(self, address):
        if rpc(self.local, "eth_getCode", [address, "latest"]) in ("0x", "0x0"):
            raise RuntimeError(f"Artifact address has no code: {address}")

    def make(self, target, *args):
        subprocess.run(["make", target, f"RUN={self.run}", f"CONFIG={self.config}",
                        f"RPC_URL={self.local}", *args], cwd=self.root, env=self.env, check=True)

    def exists(self, market):
        return (self.run_dir / "markets" / f"{market}.toml").is_file()

    def active(self, market):
        artifact = read_toml(self.run_dir / "markets" / f"{market}.toml")
        meta, expected = artifact["artifact"], self.record["artifact"]
        for key in ("deployment", "chain_id", "compatibility_hash"):
            if meta[key] != expected[key]:
                raise RuntimeError(f"{market}: incompatible artifact {key}")
        value = artifact["market"]
        for key in ("controller", "vault", "oracle", "guardian_signals", "irm_config"):
            self.require_code(value[key])
        raw = self.call(self.protocol["core"], "market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)", value["id"])
        if int(raw[4]) == 0:
            return False
        controller = self.call(self.protocol["core"], "marketController(bytes32)(address)", value["id"])
        if controller.lower() != value["controller"].lower():
            raise RuntimeError(f"{market}: core points to a different controller")
        return True

    def call(self, address, signature, *args):
        result = subprocess.run(["cast", "call", address, signature, *args, "--rpc-url", self.local, "--json"],
                                check=True, capture_output=True, text=True)
        values = json.loads(result.stdout)
        return values[0] if len(values) == 1 else values

    def deploy(self, market):
        value = read_toml(self.root / "script/config" / self.config / "markets" / f"{market}.toml")["market"]
        args = [f"MARKET={market}", f"ORACLE={name(value['oracle_artifact'])}",
                f"GUARDIAN_GROUP={name(value['guardian_group'])}", "DEPLOYER_ACCOUNT=", "DEPLOYER_SENDER="]
        guardians = os.environ.get("GUARDIANS") or self.config_values.get("risk_steward", "")
        if guardians:
            args.append(f"GUARDIANS={guardians}")
        self.make("provision-market", *args)

    def activate(self):
        self.make("fork-activate", "ACTIVATION_ENTRYPOINT=runPending()")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=name)
    parser.add_argument("--run", required=True, type=name)
    args = parser.parse_args()
    upstream = os.environ.get("RPC_URL")
    if not upstream:
        parser.error("RPC_URL is required (the caller's prepared post-vote fork)")
    markets = discover_markets(ROOT, args.config, args.run)
    protocol = read_toml(ROOT / "deployed" / args.run / "protocol.toml")["protocol"]
    with tempfile.TemporaryDirectory(prefix="lend-external-") as directory:
        workspace = Path(directory) / "workspace"
        workspace.mkdir()
        copy_workspace(ROOT, workspace, args.run)
        with fork(upstream, protocol["chain_id"], Path(directory) / "anvil.log") as (local, block):
            deployment = Deployment(workspace, args.config, args.run, local)
            initial = prepare_markets(markets, deployment.exists, deployment.deploy, deployment.active, deployment.activate)
            print(json.dumps({"fork": block, "markets": initial}, indent=2), flush=True)
            deployment.make("fork-run")


if __name__ == "__main__":
    main()
