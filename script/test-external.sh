#!/usr/bin/env bash
# Rehearse the caller's deployment on an owned fork, then run the system's Forge fork suites.
# All deployment writes and artifacts stay in a temporary workspace; RPC_URL is read-only upstream.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_NAME="${1:?config required}"
RUN_NAME="${2:?run required}"
UPSTREAM="${RPC_URL:?RPC_URL must name the prepared fork}"
log() { echo "[test-external] $*"; }
die() { echo "[test-external] ERROR: $*" >&2; exit 1; }
name() { [[ "$1" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] || die "invalid resource name '$1'"; }

# Configs and artifacts use one-line scalars/arrays, as in the existing provisioning scripts.
value() {
  awk -v section="$2" -v key="$3" '
    /^[[:space:]]*\[/ { current=$0; gsub(/[[:space:]\[\]]/, "", current); next }
    current == section {
      lhs=$0; sub(/=.*/, "", lhs); gsub(/[[:space:]]/, "", lhs)
      if (lhs != key) next
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit
    }
  ' "$1"
}
scalar() {
  local result
  result="$(value "$@")"
  [ -n "$result" ] || die "$1: missing $2.$3"
  printf '%s\n' "$result" | tr -d '"'
}

name "$CONFIG_NAME"
name "$RUN_NAME"
cd "$ROOT"
CONFIG_FILE="script/config/$CONFIG_NAME/protocol.toml"
PROTOCOL="deployed/$RUN_NAME/protocol.toml"
[ -f "$CONFIG_FILE" ] && [ -f "$PROTOCOL" ] || die "config or protocol artifact is missing"
for command in anvil cast forge jq; do command -v "$command" >/dev/null || die "$command is required"; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lend-external.XXXXXX")"
ANVIL_PID=""
cleanup() {
  if [ -n "$ANVIL_PID" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

declared="$(value "$CONFIG_FILE" provision markets)"
printf '%s\n' "${declared:-[]}" | jq -r 'if type == "array" and all(.[]; type == "string") then .[] else error("invalid markets") end' > "$WORK/markets" \
  || die "invalid provision.markets"
for artifact in "deployed/$RUN_NAME/markets/"*.toml; do
  [ -f "$artifact" ] || continue
  basename "$artifact" .toml >> "$WORK/markets"
done
sort -u "$WORK/markets" > "$WORK/selected"
[ -s "$WORK/selected" ] || die "no configured or recorded markets"
while IFS= read -r market; do
  name "$market"
  [ -f "deployed/$RUN_NAME/markets/$market.toml" ] || [ -f "script/config/$CONFIG_NAME/markets/$market.toml" ] \
    || die "$market: missing market config"
done < "$WORK/selected"

mkdir -p "$WORK/workspace/deployed"
for item in Makefile foundry.toml foundry.lock remappings.txt .foundryref src script test tools out cache; do
  [ ! -e "$item" ] || cp -R "$item" "$WORK/workspace/"
done
ln -s "$ROOT/lib" "$WORK/workspace/lib"
cp -R "deployed/$RUN_NAME" "$WORK/workspace/deployed/"
cd "$WORK/workspace"

chain="$(scalar "$PROTOCOL" protocol chain_id)"
[ "$(cast chain-id --rpc-url "$UPSTREAM" 2>/dev/null)" = "$chain" ] || die "upstream chain differs from artifact or is unreachable"
block="$(cast block latest --json --rpc-url "$UPSTREAM" 2>/dev/null)" || die "cannot read upstream block"
block_number="$(cast to-dec "$(printf '%s' "$block" | jq -er .number)")"
log "upstream block $block_number ($(printf '%s' "$block" | jq -er .hash))"
# Port zero lets the OS allocate a free port. Never print Anvil's log: it includes development keys.
NO_COLOR=1 anvil --fork-url "$UPSTREAM" --fork-block-number "$block_number" --chain-id "$chain" \
  --host 127.0.0.1 --port 0 --auto-impersonate > "$WORK/anvil.log" 2>&1 &
ANVIL_PID=$!
local_rpc=""
for ((attempt=0; attempt<180; attempt++)); do
  kill -0 "$ANVIL_PID" 2>/dev/null || die "Anvil exited during startup"
  port="$(sed -n 's/^Listening on 127\.0\.0\.1:\([0-9]*\).*/\1/p' "$WORK/anvil.log" | head -1)"
  if [ -n "$port" ]; then
    local_rpc="http://127.0.0.1:$port"
    [ "$(cast chain-id --rpc-url "$local_rpc" 2>/dev/null || true)" != "$chain" ] || break
  fi
  sleep 0.5
done
[ -n "$local_rpc" ] && [ "$(cast chain-id --rpc-url "$local_rpc" 2>/dev/null)" = "$chain" ] || die "Anvil did not become ready"

# Do not inherit the caller's pinned pre-deployment block or Make command-line RPC into child targets.
unset FORK_BLOCK ARTIFACTS_DIR MAKEFLAGS MFLAGS MAKEOVERRIDES EXECUTOR CHAIN_ID
export RPC_URL="$local_rpc" ACCEPTANCE_RPC_URL="$local_rpc" ARTIFACTS_CONFIG="$CONFIG_NAME"
make_step() { make "$@" CONFIG="$CONFIG_NAME" RUN="$RUN_NAME" RPC_URL="$local_rpc"; }
require_code() {
  local code
  code="$(cast code "$1" --rpc-url "$local_rpc")"
  [ "$code" != 0x ] && [ "$code" != 0x0 ] || die "no code at artifact address $1"
}
core="$(scalar "$PROTOCOL" protocol core)"
require_code "$core"
market_state() {
  local artifact="deployed/$RUN_NAME/markets/$1.toml" key id controller current
  for key in deployment chain_id compatibility_hash; do
    [ "$(scalar "$artifact" artifact "$key")" = "$(scalar "$PROTOCOL" artifact "$key")" ] \
      || die "$1: incompatible artifact $key"
  done
  for key in controller vault oracle guardian_signals irm_config; do
    require_code "$(scalar "$artifact" market "$key")"
  done
  id="$(scalar "$artifact" market id)"
  current="$(cast call "$core" 'market(bytes32)(uint128,uint128,uint128,uint128,uint128,uint128)' "$id" --rpc-url "$local_rpc" --json)"
  STATE=inert
  if [ "$(printf '%s' "$current" | jq -er '.[4] | tostring')" != 0 ]; then
    controller="$(cast call "$core" 'marketController(bytes32)(address)' "$id" --rpc-url "$local_rpc")"
    [ "$(printf '%s' "$controller" | tr '[:upper:]' '[:lower:]')" = "$(scalar "$artifact" market controller | tr '[:upper:]' '[:lower:]')" ] \
      || die "$1: core points to a different controller"
    STATE=active
  fi
}

pending=false
while IFS= read -r market; do
  if [ ! -f "deployed/$RUN_NAME/markets/$market.toml" ]; then
    log "$market: missing; deploy market stack"
    market_config="script/config/$CONFIG_NAME/markets/$market.toml"
    oracle="$(scalar "$market_config" market oracle_artifact)"
    guardian="$(scalar "$market_config" market guardian_group)"
    name "$oracle"
    name "$guardian"
    committee="${GUARDIANS:-$(value "$CONFIG_FILE" '' risk_steward | tr -d '"')}"
    make_step provision-market MARKET="$market" ORACLE="$oracle" GUARDIAN_GROUP="$guardian" \
      DEPLOYER_ACCOUNT= DEPLOYER_SENDER= GUARDIANS="$committee"
    market_state "$market"
    [ "$STATE" = inert ] || die "$market: new stack unexpectedly binds an existing core market"
  else
    market_state "$market"
    log "$market: $STATE"
  fi
  [ "$STATE" = active ] || pending=true
done < "$WORK/selected"
if [ "$pending" = true ]; then make_step fork-activate 'ACTIVATION_ENTRYPOINT=runPending()'; fi
while IFS= read -r market; do
  market_state "$market"
  [ "$STATE" = active ] || die "$market: activation did not create the core market"
done < "$WORK/selected"
make_step fork-run
