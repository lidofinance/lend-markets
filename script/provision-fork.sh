#!/usr/bin/env bash
# Deploys and activates the protocol on a local anvil fork of a real network. Driver over the `make deploy-*`
# targets; see script/DEPLOYMENT.md.
#
#   bash script/provision-fork.sh [upstream-rpc] [config] [block]   # provision; leaves anvil running
#   bash script/provision-fork.sh check                             # is the run live on the local anvil?
#   bash script/provision-fork.sh stop                              # stop the anvil a previous run started
#
# `config` is an ordinary deploy config and selects the network to fork: its chain_id is
# what the upstream must report and what anvil is started with. `block` pins the upstream block anvil forks
# from; without it anvil forks the tip and a run is not reproducible. The upstream comes from the argument or
# RPC_URL and must be an archive node, not the local anvil. Deploy steps receive the local anvil URL on the
# command line, so RPC_URL keeps one meaning.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG_NAME="${2:-mainnet}"
PIN_BLOCK="${3:-}"
case "$PIN_BLOCK" in ""|*[!0-9]*) [ -z "$PIN_BLOCK" ] || { echo "[provision] ERROR: PIN_BLOCK must be a number" >&2; exit 1; } ;; esac
# One run directory regardless of network: a provisioning run is cleared and rebuilt, never kept alongside
# another, and every consumer refers to it as ARTIFACTS_DIR=fork.
RUN_NAME="fork"
RPC_LOCAL="http://127.0.0.1:8545"
RUN_DIR="deployed/${RUN_NAME}"
PID_FILE="deployed/${RUN_NAME}-anvil.pid"
LOG_FILE="deployed/${RUN_NAME}-anvil.log"
CONFIG_TOML="script/config/${CONFIG_NAME}.toml"

# anvil's first dev account. Holds no protocol role; requireActorSeparation enforces that against the config.
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
TEN_ETHER_HEX="0x8AC7230489E80000"

# The vault-v2 pair is standalone: no market config references it, so it cannot be derived like the resources
# below.
VAULT_NAME="fork-weth-wsteth"

log() { echo "[provision] $*"; }
die() { echo "[provision] ERROR: $*" >&2; exit 1; }

# Quoted scalar from a TOML file. Matches the first line whose key is $2, so it reads keys unique within the
# file and does not distinguish sections. Empty when the key is absent; use toml_req where absence is an error.
toml_str() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }

toml_req() {
  local value
  value="$(toml_str "$1" "$2")"
  [ -n "$value" ] || die "$1 is missing key '$2'"
  printf '%s' "$value"
}

# Appends $2 to the space-separated list $1 unless already present.
add_unique() {
  case " $1 " in *" $2 "*) printf '%s' "$1" ;; *) printf '%s' "${1:+$1 }$2" ;; esac
}

usage() {
  cat <<EOF
Usage:
  bash script/provision-fork.sh [upstream-rpc] [config] [block]   # provision; leaves anvil running
  bash script/provision-fork.sh check                             # is the run live on the local anvil?
  bash script/provision-fork.sh stop                              # stop the anvil a previous run started
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

# --- check subcommand -----------------------------------------------------------------------------------------
# Exits 0 when the local anvil hosts the deployment recorded in $RUN_DIR. Says nothing about whether that
# deployment matches the current sources — it answers "can the fork suites run", not "is it up to date".
if [ "${1:-}" = "check" ]; then
  [ -f "$RUN_DIR/protocol.toml" ] || die "no run at $RUN_DIR; run: make provision-fork"
  cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1 || die "no node on $RPC_LOCAL; run: make provision-fork"
  CORE="$(toml_req "$RUN_DIR/protocol.toml" core)"
  CODE="$(cast code "$CORE" --rpc-url "$RPC_LOCAL" 2>/dev/null || true)"
  case "$CODE" in
    ""|0x) die "$RUN_DIR does not match the node on $RPC_LOCAL (core $CORE has no code); run: make provision-fork" ;;
  esac
  log "run $RUN_DIR is live on $RPC_LOCAL"
  exit 0
fi

# --- 1. upstream RPC + anvil ----------------------------------------------------------------------------------
# shellcheck disable=SC1091
[ -f .env ] && source .env || true
UPSTREAM="${1:-${RPC_URL:-}}"
case "$UPSTREAM" in
  "") die "pass an upstream archive RPC as the first argument, or set RPC_URL in .env" ;;
  *127.0.0.1*|*localhost*) die "upstream RPC must be a real archive node, not the local anvil ($UPSTREAM)" ;;
esac

[ -f "$CONFIG_TOML" ] || die "deploy config not found: $CONFIG_TOML"
# Bare integer, so it needs its own reader. Deliberately the config's chain id, not the run's: the Makefile
# resolves the RUN's chain id from its protocol.toml, which at this point may still be the previous network's.
CHAIN_ID="$(sed -n 's/^[[:space:]]*chain_id[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$CONFIG_TOML" | head -1)"
[ -n "$CHAIN_ID" ] || die "$CONFIG_TOML is missing key 'chain_id'"

# The fork market set per network. An unknown config fails here rather than provisioning an empty run.
case "$CONFIG_NAME" in
  mainnet) MARKETS=(fork-weth-wsteth fork-weth-wsteth-kinked fork-usdy-usdt) ;;
  *) die "no fork market set defined for config '$CONFIG_NAME'" ;;
esac

# Probed before anvil starts: an unreachable upstream reports the node's own error instead of a 60s timeout.
UPSTREAM_CHAIN_ID="$(cast chain-id --rpc-url "$UPSTREAM" 2>&1)" \
  || die "upstream RPC is not answering: $UPSTREAM_CHAIN_ID"
[ "$UPSTREAM_CHAIN_ID" = "$CHAIN_ID" ] \
  || die "upstream chain id $UPSTREAM_CHAIN_ID does not match $CONFIG_TOML ($CHAIN_ID)"
log "upstream chain $CHAIN_ID, block $(cast block-number --rpc-url "$UPSTREAM")"

if cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1; then
  REUSED_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_LOCAL")"
  [ "$REUSED_CHAIN_ID" = "$CHAIN_ID" ] \
    || die "anvil on :8545 reports chain id $REUSED_CHAIN_ID, not $CHAIN_ID; stop it or free the port"
  log "reusing the anvil already listening on $RPC_LOCAL"
else
  # Unquoted on purpose: PIN_BLOCK is validated as digits, and an empty array cannot be expanded under
  # `set -u` in bash 3.2.
  PIN_ARG=""
  [ -z "$PIN_BLOCK" ] || PIN_ARG="--fork-block-number $PIN_BLOCK"
  log "starting anvil (fork of the upstream, chain-id $CHAIN_ID, block ${PIN_BLOCK:-tip}) -> $LOG_FILE"
  mkdir -p deployed
  : >"$LOG_FILE" # so a failure never reports a previous run's log
  anvil --fork-url "$UPSTREAM" --port 8545 --chain-id "$CHAIN_ID" --auto-impersonate $PIN_ARG >"$LOG_FILE" 2>&1 &
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
AGENT="$(toml_req "$CONFIG_TOML" agent)"
EXECUTOR="$(toml_req "$CONFIG_TOML" evm_script_executor)"
cast rpc anvil_setBalance "$AGENT" "$TEN_ETHER_HEX" --rpc-url "$RPC_LOCAL" >/dev/null
cast rpc anvil_setBalance "$EXECUTOR" "$TEN_ETHER_HEX" --rpc-url "$RPC_LOCAL" >/dev/null
log "agent $AGENT and executor $EXECUTOR funded with 10 ETH each"

# The artifact writers refuse to replace a record, so a re-run needs a clean directory.
rm -rf "$RUN_DIR"
log "cleared run dir $RUN_DIR"

# Every resource below is derived from the market configs selected above, so the deploy order cannot fall out
# of step with what they reference.

BREAKERS="" ORACLES="" IRMS="" GROUPS=""
for market in "${MARKETS[@]}"; do
  mcfg="script/config/markets/${market}.toml"
  [ -f "$mcfg" ] || die "market config not found: $mcfg"
  BREAKERS="$(add_unique "$BREAKERS" "$(toml_req "$mcfg" circuit_breaker_artifact)")"
  ORACLES="$(add_unique "$ORACLES" "$(toml_req "$mcfg" oracle_artifact)")"
  GROUPS="$(add_unique "$GROUPS" "$(toml_req "$mcfg" guardian_group)")"
  # An absent irm_artifact means the backbone adaptive curve, which the protocol deploy already brings.
  irm="$(toml_str "$mcfg" irm_artifact)"
  [ -z "$irm" ] || [ "$irm" = "adaptive-curve" ] || IRMS="$(add_unique "$IRMS" "$irm")"
done
log "markets: ${MARKETS[*]}"
log "breakers: ${BREAKERS:-none}  oracles: ${ORACLES:-none}  irms: ${IRMS:-none}  guardians: ${GROUPS:-none}"

# VERIFY is off: a local node has no verifier.
deploy() {
  make "$@" CONFIG="$CONFIG_NAME" RUN="$RUN_NAME" RPC_URL="$RPC_LOCAL" \
    DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY" VERIFY=false
}

# --- 4..8. the deploy pipeline --------------------------------------------------------------------------------
for breaker in $BREAKERS; do
  log "deploying CircuitBreaker ($breaker)"
  deploy deploy-circuit-breaker CIRCUIT_BREAKER="$breaker"
done

# The oracle config's own keys select the implementation, as OraclePreflight discriminates them.
for oracle in $ORACLES; do
  ocfg="script/config/oracles/${oracle}.toml"
  [ -f "$ocfg" ] || die "oracle config not found: $ocfg"
  if grep -qE '^[[:space:]]*wsteth[[:space:]]*=' "$ocfg"; then
    log "deploying wstETH rate oracle ($oracle)"
    deploy deploy-oracle ORACLE="$oracle"
  elif grep -qE '^[[:space:]]*usdy_oracle[[:space:]]*=' "$ocfg"; then
    log "deploying USDY stable oracle ($oracle)"
    deploy deploy-oracle-usdy ORACLE="$oracle"
  else
    die "cannot tell which oracle implementation $ocfg configures"
  fi
done

# Precedes the protocol: MarketConfigFile rejects a market whose irm_artifact does not resolve.
for irm in $IRMS; do
  log "deploying LinearKinkIrm ($irm)"
  deploy deploy-linear-kink-irm IRM="$irm"
done

log "deploying protocol backbone (config=$CONFIG_NAME, run dir=$RUN_DIR)"
deploy deploy-protocol

# After the protocol (the registry builder is recorded there) and before the markets, which require the
# registry of the group they name. One per group, so markets sharing a committee share its registry.
for group in $GROUPS; do
  log "deploying GuardianSignals ($group)"
  deploy deploy-guardian GUARDIAN_GROUP="$group"
done

for market in "${MARKETS[@]}"; do
  log "deploying market ($market)"
  deploy deploy-market MARKET="$market"
done

log "deploying vault-v2 vault + adapter ($VAULT_NAME)"
deploy deploy-vault-v2 VAULT="$VAULT_NAME" ADAPTER="$VAULT_NAME"

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
