#!/usr/bin/env bash
# Deploys one market stack of a deployment — its oracle, its guardian registry and the inert market — onto a
# local anvil that already holds the run, for the market rehearsal of a production run. The production guardians
# config has no committee until governance supplies one; the rehearsal fills it from anvil's default accounts
# in a throw-away copy of the config, so nothing under script/config/<config>/ changes and no test address can
# reach a production deploy. The steps are the ordinary deploy targets, resumable through deploy-step.sh.
#
#   bash script/provision-market.sh <config> <run> <market> [oracle] [guardian-group]
#
# Env: RPC_URL — the local anvil (default http://127.0.0.1:8545); must answer the anvil RPCs.
#      DEPLOYER_SENDER — the unlocked sender (default: anvil's first account), funded here.
#      GUARDIANS — comma-separated committee for an empty guardians config (default: anvil's second account).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ $# -ge 3 ] || { echo "usage: provision-market.sh <config> <run> <market> [oracle] [guardian-group]" >&2; exit 2; }
CONFIG_NAME="$1"
RUN_NAME="$2"
MARKET="$3"
ORACLE="${4:-$MARKET}"
GUARDIAN_GROUP="${5:-$MARKET}"
RPC="${RPC_URL:-http://127.0.0.1:8545}"
DEPLOYER="${DEPLOYER_SENDER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
DEFAULT_GUARDIANS="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
GUARDIANS="${GUARDIANS:-$DEFAULT_GUARDIANS}"
TEN_ETHER_HEX="0x8AC7230489E80000"

CONFIG_DIR="script/config/${CONFIG_NAME}"
OVERLAY_NAME=".provision-${CONFIG_NAME}"
OVERLAY_DIR="script/config/${OVERLAY_NAME}"
RUN_DIR="deployed/${RUN_NAME}"

log() { echo "[provision-market] $*"; }
die() { echo "[provision-market] ERROR: $*" >&2; exit 1; }

toml_str() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
toml_num() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$1" | head -1; }

for name in "$CONFIG_NAME" "$RUN_NAME" "$MARKET" "$ORACLE" "$GUARDIAN_GROUP"; do
  case "$name" in *[!A-Za-z0-9._-]*|"") die "invalid name '$name'" ;; esac
done
[ -f "${CONFIG_DIR}/protocol.toml" ] || die "${CONFIG_DIR}/protocol.toml is missing"
for f in "oracles/${ORACLE}.toml" "guardians/${GUARDIAN_GROUP}.toml" "markets/${MARKET}.toml"; do
  [ -f "${CONFIG_DIR}/${f}" ] || die "${CONFIG_DIR}/${f} is missing"
done
[ -f "${RUN_DIR}/protocol.toml" ] || die "${RUN_DIR}/protocol.toml is missing: deploy the run first"

cast rpc anvil_setBalance "$DEPLOYER" "$TEN_ETHER_HEX" --rpc-url "$RPC" >/dev/null 2>&1 \
  || die "$RPC is not an anvil node (anvil_setBalance failed); the rehearsal never targets a live network"
expected_chain="$(toml_num "${CONFIG_DIR}/protocol.toml" chain_id)"
actual_chain="$(cast chain-id --rpc-url "$RPC")"
[ "$actual_chain" = "$expected_chain" ] || die "chain id $actual_chain at $RPC, config expects $expected_chain"
core="$(toml_str "${RUN_DIR}/protocol.toml" core)"
[ -n "$core" ] || die "${RUN_DIR}/protocol.toml records no core"
[ "$(cast code "$core" --rpc-url "$RPC")" != "0x" ] || die "run '$RUN_NAME' is not deployed on $RPC: no code at core $core"

cleanup() { rm -rf "$OVERLAY_DIR"; }
trap cleanup EXIT
rm -rf "$OVERLAY_DIR"
mkdir -p "${OVERLAY_DIR}/oracles" "${OVERLAY_DIR}/guardians" "${OVERLAY_DIR}/markets"
cp "${CONFIG_DIR}/protocol.toml" "${OVERLAY_DIR}/protocol.toml"
cp "${CONFIG_DIR}/oracles/${ORACLE}.toml" "${OVERLAY_DIR}/oracles/"
cp "${CONFIG_DIR}/guardians/${GUARDIAN_GROUP}.toml" "${OVERLAY_DIR}/guardians/"
cp "${CONFIG_DIR}/markets/${MARKET}.toml" "${OVERLAY_DIR}/markets/"

guardians_file="${OVERLAY_DIR}/guardians/${GUARDIAN_GROUP}.toml"
if grep -qE '^[[:space:]]*guardians[[:space:]]*=[[:space:]]*\[[[:space:]]*\]' "$guardians_file"; then
  list=""
  IFS=',' read -r -a addresses <<< "$GUARDIANS"
  for a in "${addresses[@]}"; do
    a="$(printf '%s' "$a" | tr -d '[:space:]')"
    [[ "$a" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "GUARDIANS: '$a' is not an address"
    list="${list:+$list, }\"$a\""
  done
  sed -i.bak -E "s/^([[:space:]]*guardians[[:space:]]*=[[:space:]]*)\[[[:space:]]*\].*/\1[${list}]/" "$guardians_file"
  rm -f "${guardians_file}.bak"
  log "guardians/${GUARDIAN_GROUP}.toml has no committee; the rehearsal uses [${list}]"
else
  log "guardians/${GUARDIAN_GROUP}.toml names a committee; used as configured"
fi

oracle_kind="$(toml_str "${OVERLAY_DIR}/oracles/${ORACLE}.toml" kind)"
case "$oracle_kind" in
  wsteth) oracle_target=deploy-oracle ;;
  usdy) oracle_target=deploy-oracle-usdy ;;
  *) die "unknown oracle kind '$oracle_kind' in oracles/${ORACLE}.toml" ;;
esac

STEP=script/deploy-step.sh
STEP_VARS=(CONFIG="$OVERLAY_NAME" RUN="$RUN_NAME" DEPLOYER_ACCOUNT= DEPLOYER_SENDER="$DEPLOYER" VERIFY=false RESUME=false)
log "run $RUN_NAME on $RPC, deployer $DEPLOYER, config $CONFIG_NAME"
"$STEP" "${RUN_DIR}/oracles/${ORACLE}.toml" address "$RPC" "$oracle_target" "${STEP_VARS[@]}" ORACLE="$ORACLE"
"$STEP" "${RUN_DIR}/guardians/${GUARDIAN_GROUP}.toml" address "$RPC" deploy-guardian "${STEP_VARS[@]}" GUARDIAN_GROUP="$GUARDIAN_GROUP"
"$STEP" "${RUN_DIR}/markets/${MARKET}.toml" controller "$RPC" deploy-market "${STEP_VARS[@]}" MARKET="$MARKET"

log "market stack of '$MARKET' recorded under ${RUN_DIR}/ (fork only: not for commit)"
