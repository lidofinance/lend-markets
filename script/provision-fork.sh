#!/usr/bin/env bash
# Deploys and activates the `fork` profile on a local anvil fork of mainnet. Driver over the `make deploy-*`
# targets; see script/DEPLOYMENT.md.
#
#   bash script/provision-fork.sh [upstream-rpc]   # provision; leaves anvil running
#   bash script/provision-fork.sh stop             # stop the anvil a previous run started
#
# The upstream to fork comes from the argument or RPC_URL and must be an archive node, not the local anvil.
# Deploy steps receive the local anvil URL on the command line, so RPC_URL keeps one meaning.
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

# anvil's first dev account. Holds no protocol role; requireActorSeparation enforces that against the config.
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

# Probed before anvil starts: an unreachable upstream reports the node's own error instead of a 60s timeout.
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

# The artifact writers refuse to replace a record, so a re-run needs a clean directory.
rm -rf "$RUN_DIR"
log "cleared run dir $RUN_DIR"

# VERIFY is off: a local node has no verifier.
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

# Precedes the protocol: MarketConfigFile rejects a market whose irm_artifact does not resolve.
log "deploying LinearKinkIrm ($IRM_NAME)"
deploy deploy-linear-kink-irm IRM="$IRM_NAME"

log "deploying protocol (config=$CONFIG_NAME, run dir=$RUN_DIR)"
deploy deploy-protocol

log "deploying vault-v2 vault + adapter ($VAULT_NAME)"
deploy deploy-vault-v2 VAULT="$VAULT_NAME" ADAPTER="$VAULT_NAME"

# Read from the config so that adding a market cannot skip its verification.
read -r -a MARKETS <<<"$(sed -n 's/^markets *= *\[\(.*\)\]/\1/p' "$CONFIG_TOML" | tr -d ' "' | tr ',' ' ')"
[ "${#MARKETS[@]}" -gt 0 ] || die "could not read the market list from $CONFIG_TOML"

# Verification uses the same acceptance suite as a real deployment, against the artifacts this run wrote. Each
# acceptance test forks the node itself, so its state changes do not reach the anvil. While the markets are
# inert MarketMotionReadiness runs and MarketActivated self-skips.
for market in "${MARKETS[@]}"; do
  log "verifying $market is ready for the motion (acceptance)"
  make acceptance-run RUN="$RUN_NAME" MARKET="$market" RPC_URL="$RPC_LOCAL"
done

# The two-market simulation performs the motion itself, covering the activation write path (including a kinked
# market's params) and cross-market singleton state. The first two markets are the adaptive/kinked pair.
if [ "${#MARKETS[@]}" -ge 2 ]; then
  log "simulating the activation motion over ${MARKETS[0]} + ${MARKETS[1]} (acceptance)"
  make acceptance-run-multi RUN="$RUN_NAME" MARKET_A="${MARKETS[0]}" MARKET_B="${MARKETS[1]}" RPC_URL="$RPC_LOCAL"
fi

log "activating markets (motion replay as the executor)"
deploy activate-markets

# After activation the halves swap: MarketActivated runs, MarketMotionReadiness self-skips.
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
