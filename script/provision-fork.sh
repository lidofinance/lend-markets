#!/usr/bin/env bash
# Stands up a complete, activated protocol on a local anvil fork of mainnet, so the read-only fork suites
# (test/fork/) have a deployment to bind to before any real network is live. Draft, not production-ready.
#
# It is a thin driver over the ordinary deploy targets — no fork-only deploy mechanism of its own. Every step is
# the same `make deploy-*` a real run uses, with the `fork` config (script/config/fork.toml) and the run
# directory `deployed/fork/`, producing the same immutable artifacts. The one step a real network does NOT run
# this way is the last: activation is an EasyTrack motion there, replayed here by
# script/ActivateMarkets.s.sol as the impersonated EVMScriptExecutor.
#
# Pipeline (order is load-bearing):
#   1. anvil, forking the upstream mainnet RPC, chain-id 1, auto-impersonate
#   2. fund the impersonated governance accounts so their transactions pay gas
#   3. CircuitBreaker            — every market's roles.pausers[0]; DeployProtocol requires it to exist
#   4. oracles (3)               — resolved by the market configs; DeployProtocol runs OraclePreflight on them
#   5. LinearKinkIrm             — fork-weth-wsteth-kinked names it, and MarketConfigFile checks it resolves
#   6. protocol                  — backbone + exit books + the three inert markets
#   7. vault-v2 + adapter        — needs the run's core and IRM router from protocol.toml
#   8. acceptance (inert)        — every market verified ready for the motion, and the motion simulated
#   9. activation                — the motion replay, as the executor
#  10. acceptance (live)         — every market verified activated and fully wired
#
# Usage:
#   bash script/provision-fork.sh [upstream-rpc]   # provision; leaves anvil running
#   bash script/provision-fork.sh stop             # kill the anvil a previous run started
#
# The upstream RPC to fork FROM comes from the argument or `RPC_URL`, and must be a real archive node — never
# the local anvil, which would make it fork itself. Every deploy step is then pointed at the local anvil on the
# command line, so `.env`'s RPC_URL keeps its one meaning: the real network.
#
# anvil, cast, forge and make must be on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG_NAME="fork"
RUN_NAME="fork"
RPC_LOCAL="http://127.0.0.1:8545"
RUN_DIR="deployed/${RUN_NAME}"
PID_FILE="deployed/${RUN_NAME}-anvil.pid"
LOG_FILE="deployed/${RUN_NAME}-anvil.log"
CONFIG_TOML="script/config/${CONFIG_NAME}.toml"

# anvil's first well-known dev account — the provisioning deployer. It holds no protocol role afterwards, which
# is what `DeployConfigFile.requireActorSeparation` enforces against the config's agent/executor.
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
TEN_ETHER_HEX="0x8AC7230489E80000"

# Resources this profile deploys, as named by script/config/fork.toml and the market configs it lists.
CIRCUIT_BREAKER="lido-lend"
ORACLES_WSTETH=("weth-wsteth" "fork-weth-wsteth-kinked")
ORACLE_USDY="fork-usdy-usdt"
IRM_NAME="linear-kink"
VAULT_NAME="fork-weth-wsteth"

log() { echo "[provision] $*"; }
die() { echo "[provision] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage:
  bash script/provision-fork.sh [upstream-rpc]   # provision; leaves anvil running
  bash script/provision-fork.sh stop             # kill the anvil a previous run started
EOF
}

# --- stop subcommand ------------------------------------------------------------------------------------------
if [ "${1:-}" = "stop" ]; then
  if [ -f "$PID_FILE" ]; then
    PID="$(cat "$PID_FILE")"
    if kill -0 "$PID" 2>/dev/null; then kill "$PID" && log "stopped anvil (pid $PID)"; else log "no live anvil at pid $PID"; fi
    rm -f "$PID_FILE"
  else
    log "no pid file at $PID_FILE (anvil was reused or never started by this script)"
  fi
  exit 0
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then usage; exit 0; fi

# --- 1. upstream RPC + anvil ----------------------------------------------------------------------------------
# shellcheck disable=SC1091
[ -f .env ] && source .env || true
UPSTREAM="${1:-${RPC_URL:-}}"
case "$UPSTREAM" in
  "") die "pass an upstream mainnet RPC as the first argument, or set RPC_URL in .env" ;;
  *127.0.0.1*|*localhost*) die "upstream RPC must be a real archive node, not the local anvil ($UPSTREAM)" ;;
esac

# Probe the upstream first: a bad URL or an expired key fails here in a second, with the node's own message,
# instead of surfacing as "anvil did not come up" a minute later.
UPSTREAM_CHAIN_ID="$(cast chain-id --rpc-url "$UPSTREAM" 2>&1)" \
  || die "upstream RPC is not answering: $UPSTREAM_CHAIN_ID"
[ "$UPSTREAM_CHAIN_ID" = "1" ] || die "upstream RPC is not mainnet (chain id $UPSTREAM_CHAIN_ID)"
log "upstream is mainnet, block $(cast block-number --rpc-url "$UPSTREAM")"

if cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1; then
  REUSED_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_LOCAL")"
  [ "$REUSED_CHAIN_ID" = "1" ] || die "anvil on :8545 is not a mainnet fork (chain id $REUSED_CHAIN_ID); stop it or free the port"
  log "reusing the anvil already listening on $RPC_LOCAL"
else
  log "starting anvil (fork of the upstream mainnet RPC, chain-id 1, auto-impersonate) -> $LOG_FILE"
  mkdir -p deployed
  anvil --fork-url "$UPSTREAM" --port 8545 --chain-id 1 --auto-impersonate >"$LOG_FILE" 2>&1 &
  echo "$!" >"$PID_FILE"
  for _ in $(seq 1 60); do
    cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1 && break
    sleep 1
  done
  if ! cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1; then
    rm -f "$PID_FILE"
    echo "[provision] --- last lines of $LOG_FILE ---" >&2
    tail -20 "$LOG_FILE" >&2
    die "anvil did not come up (see $LOG_FILE)"
  fi
  log "anvil up (pid $(cat "$PID_FILE")), block $(cast block-number --rpc-url "$RPC_LOCAL")"
fi

# --- 2. fund the impersonated governance accounts -------------------------------------------------------------
AGENT="$(grep -E '^\s*agent' "$CONFIG_TOML" | grep -oiE '0x[0-9a-f]{40}' | head -1)"
EXECUTOR="$(grep -E '^\s*evm_script_executor' "$CONFIG_TOML" | grep -oiE '0x[0-9a-f]{40}' | head -1)"
[ -n "$AGENT" ] && [ -n "$EXECUTOR" ] || die "could not read agent/evm_script_executor from $CONFIG_TOML"
cast rpc anvil_setBalance "$AGENT" "$TEN_ETHER_HEX" --rpc-url "$RPC_LOCAL" >/dev/null
cast rpc anvil_setBalance "$EXECUTOR" "$TEN_ETHER_HEX" --rpc-url "$RPC_LOCAL" >/dev/null
log "agent $AGENT and executor $EXECUTOR funded with 10 ETH each"

# --- 3. fresh run directory -----------------------------------------------------------------------------------
# The artifact writers are immutable and refuse to replace a record, so a re-run starts from a clean directory.
rm -rf "$RUN_DIR"
log "cleared run dir $RUN_DIR"

# Every step is an ordinary deploy target, pointed at the local anvil with the provisioning deployer. VERIFY is
# off: there is no verifier for a local node.
deploy() {
  make "$@" CONFIG="$CONFIG_NAME" RUN="$RUN_NAME" RPC_URL="$RPC_LOCAL" \
    DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY" VERIFY=false
}

# --- 4..8. the deploy pipeline --------------------------------------------------------------------------------
log "deploying CircuitBreaker ($CIRCUIT_BREAKER)"
deploy deploy-circuit-breaker CIRCUIT_BREAKER="$CIRCUIT_BREAKER"

for oracle in "${ORACLES_WSTETH[@]}"; do
  log "deploying wstETH rate oracle ($oracle)"
  deploy deploy-oracle ORACLE="$oracle"
done
log "deploying USDY stable oracle ($ORACLE_USDY)"
deploy deploy-oracle-usdy ORACLE="$ORACLE_USDY"

# Before the protocol: a kinked market's config names this artifact, and MarketConfigFile refuses to read a
# market whose irm_artifact does not resolve.
log "deploying LinearKinkIrm ($IRM_NAME)"
deploy deploy-linear-kink-irm IRM="$IRM_NAME"

log "deploying protocol (config=$CONFIG_NAME, run dir=$RUN_DIR)"
deploy deploy-protocol

log "deploying vault-v2 vault + adapter ($VAULT_NAME)"
deploy deploy-vault-v2 VAULT="$VAULT_NAME" ADAPTER="$VAULT_NAME"

# The market list comes from the config, not from a second copy here: adding a market must not silently skip
# its verification.
read -r -a MARKETS <<<"$(sed -n 's/^markets *= *\[\(.*\)\]/\1/p' "$CONFIG_TOML" | tr -d ' "' | tr ',' ' ')"
[ "${#MARKETS[@]}" -gt 0 ] || die "could not read the market list from $CONFIG_TOML"

# Verification is split across the lifecycle exactly as a real deployment's is, and it is what makes the
# "production-shaped artifacts" claim checkable rather than asserted: test/acceptance/ is the same suite a real
# run is verified with, reading the immutable artifacts this run just wrote. Every acceptance test forks the node
# for itself, so nothing it does — pausing the controller, granting roles, simulating the motion — touches the
# live anvil.
#
# While the markets are still inert, `MarketMotionReadiness` asserts each one is fully prepared and NOT yet
# bound; `MarketActivated` self-skips. This is the only point at which that half of the suite can run.
for market in "${MARKETS[@]}"; do
  log "verifying $market is ready for the motion (acceptance)"
  make acceptance-run RUN="$RUN_NAME" MARKET="$market" RPC_URL="$RPC_LOCAL"
done

# The two-market simulation runs the motion itself against inert markets, so it is what exercises the activation
# WRITE path — including setting a kinked market's params — and proves activating one market does not disturb the
# other's shared singleton state. Uses the first two markets in the config; in this profile that is the
# adaptive-curve / kinked pair, so both routing paths are covered.
if [ "${#MARKETS[@]}" -ge 2 ]; then
  log "simulating the activation motion over ${MARKETS[0]} + ${MARKETS[1]} (acceptance)"
  make acceptance-run-multi RUN="$RUN_NAME" MARKET_A="${MARKETS[0]}" MARKET_B="${MARKETS[1]}" RPC_URL="$RPC_LOCAL"
fi

log "activating markets (motion replay as the executor)"
deploy activate-markets

# Now the mirror image: `MarketActivated` asserts each market is bound, configured and live — including the
# params of whichever model it is routed to — and `MarketMotionReadiness` self-skips.
for market in "${MARKETS[@]}"; do
  log "verifying $market is activated and fully wired (acceptance)"
  make acceptance-run RUN="$RUN_NAME" MARKET="$market" RPC_URL="$RPC_LOCAL"
done

log "done."
log "  run dir : $RUN_DIR"
log "anvil is left running on $RPC_LOCAL (stop it with: bash script/provision-fork.sh stop)"
echo
echo "Run the fork suites against it with:"
echo "  make test-fork RPC_URL=$RPC_LOCAL ARTIFACTS_DIR=$RUN_NAME"
