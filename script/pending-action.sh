#!/usr/bin/env bash
# Applies the pending multisig action on a local anvil fork of the live network and leaves the
# fork running, so the fork suites and state-mate can validate the change before anyone signs it.
#
#   bash script/pending-action.sh apply <config> [block]   # fork + apply; leaves anvil on :8545
#   bash script/pending-action.sh stop                     # stop the anvil a previous apply started
#
# `config` names both the network config (script/config/<config>.toml — its chain_id is checked
# against the upstream) and the pending file (script/config/pending/<config>.toml). The upstream
# comes from RPC_URL and must hold the live deployment. `block` pins the fork block; without it
# anvil forks the tip. Each [[transaction]] is applied by impersonating `from`; a revert aborts.
# A transaction that creates an EasyTrack motion carries `motion_calldata` (the factory calldata
# inside `data`): once it is mined the motion's objection window is skipped on the fork and the
# motion is enacted with that calldata, so the state the suites see is the motion's outcome.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ACTION="${1:-apply}"
CONFIG_NAME="${2:-hoodi}"
PIN_BLOCK="${3:-}"

RPC_LOCAL="http://127.0.0.1:8545"
PID_FILE="deployed/pending-anvil.pid"
LOG_FILE="deployed/pending-anvil.log"
NETWORK_TOML="script/config/${CONFIG_NAME}.toml"
PENDING_TOML="script/config/pending/${CONFIG_NAME}.toml"

log() { echo "[pending] $*"; }
die() { echo "[pending] ERROR: $*" >&2; exit 1; }

if [ "$ACTION" = "stop" ]; then
  [ -f "$PID_FILE" ] || { log "no pid file; nothing to stop"; exit 0; }
  PID="$(cat "$PID_FILE")"
  kill "$PID" 2>/dev/null && log "stopped anvil pid $PID" || log "anvil pid $PID was not running"
  rm -f "$PID_FILE"
  exit 0
fi
[ "$ACTION" = "apply" ] || die "unknown action '$ACTION' (apply|stop)"

[ -f "$NETWORK_TOML" ] || die "missing network config $NETWORK_TOML"
[ -f "$PENDING_TOML" ] || die "missing pending config $PENDING_TOML"
[ -n "${RPC_URL:-}" ] || die "set RPC_URL to the live network's RPC"

EXPECTED_CHAIN_ID="$(awk -F'= *' '/^chain_id/ {print $2; exit}' "$NETWORK_TOML" | tr -d ' ')"
[ -n "$EXPECTED_CHAIN_ID" ] || die "no chain_id in $NETWORK_TOML"
UPSTREAM_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$UPSTREAM_CHAIN_ID" = "$EXPECTED_CHAIN_ID" ] || die "upstream chain id $UPSTREAM_CHAIN_ID != expected $EXPECTED_CHAIN_ID"

if cast chain-id --rpc-url "$RPC_LOCAL" >/dev/null 2>&1; then
  die "something already answers on $RPC_LOCAL; stop it first (make pending-stop / provision-stop)"
fi

FORK_ARGS=(--fork-url "$RPC_URL" --chain-id "$EXPECTED_CHAIN_ID" --port 8545 --auto-impersonate)
[ -n "$PIN_BLOCK" ] && FORK_ARGS+=(--fork-block-number "$PIN_BLOCK")
anvil "${FORK_ARGS[@]}" >"$LOG_FILE" 2>&1 &
ANVIL_PID=$!
echo "$ANVIL_PID" > "$PID_FILE"
for _ in $(seq 1 60); do
  cast chain-id --rpc-url "$RPC_LOCAL" >/dev/null 2>&1 && break
  kill -0 "$ANVIL_PID" 2>/dev/null || die "anvil exited early; see $LOG_FILE"
  sleep 0.5
done
cast chain-id --rpc-url "$RPC_LOCAL" >/dev/null 2>&1 || die "anvil did not come up; see $LOG_FILE"
log "anvil forked $CONFIG_NAME (chain $EXPECTED_CHAIN_ID) at block $(cast block-number --rpc-url "$RPC_LOCAL"), pid $ANVIL_PID"

TEN_ETHER_HEX="0x8AC7230489E80000"
MOTION_CREATED_TOPIC="$(cast sig-event 'MotionCreated(uint256,address,address,bytes,bytes)')"
APPLIED=0
# Parse [[transaction]] blocks: key = "value" lines between block headers.
while IFS=$'\t' read -r FROM TO VALUE DATA MOTION DESC; do
  [ -n "$FROM" ] || continue
  [ -n "$TO" ] && [ -n "$DATA" ] || die "transaction with missing to/data in $PENDING_TOML"
  log "applying: ${DESC:-<no description>}"
  cast rpc --rpc-url "$RPC_LOCAL" anvil_setBalance "$FROM" "$TEN_ETHER_HEX" >/dev/null
  if ! TX_JSON="$(cast send "$TO" "$DATA" --value "${VALUE:-0}" --from "$FROM" --unlocked --rpc-url "$RPC_LOCAL" --json)"; then
    die "transaction failed to send (likely reverts on estimation) — the pending action is broken; fork left up for inspection"
  fi
  STATUS="$(echo "$TX_JSON" | jq -r .status)"
  HASH="$(echo "$TX_JSON" | jq -r .transactionHash)"
  case "$STATUS" in
    0x1|1) log "  ok $HASH" ;;
    *) die "transaction reverted ($STATUS) $HASH — the pending action is broken; fork left up for inspection" ;;
  esac
  if [ -n "$MOTION" ]; then
    MOTION_ID="$(echo "$TX_JSON" | jq -r --arg t "$MOTION_CREATED_TOPIC" '[.logs[] | select(.topics[0] == $t)] | .[0].topics[1] // empty')"
    [ -n "$MOTION_ID" ] || die "no MotionCreated event in $HASH — motion_calldata set on a transaction that creates no motion"
    MOTION_ID="$(cast to-dec "$MOTION_ID")"
    DURATION="$(cast call "$TO" 'motionDuration()(uint256)' --rpc-url "$RPC_LOCAL")"
    cast rpc --rpc-url "$RPC_LOCAL" evm_increaseTime "$((DURATION + 1))" >/dev/null
    cast rpc --rpc-url "$RPC_LOCAL" evm_mine >/dev/null
    if ! ENACT_JSON="$(cast send "$TO" 'enactMotion(uint256,bytes)' "$MOTION_ID" "$MOTION" --from "$FROM" --unlocked --rpc-url "$RPC_LOCAL" --json)"; then
      die "motion $MOTION_ID failed to enact (likely reverts on estimation) — the pending action is broken; fork left up for inspection"
    fi
    case "$(echo "$ENACT_JSON" | jq -r .status)" in
      0x1|1) log "  motion $MOTION_ID enacted after ${DURATION}s $(echo "$ENACT_JSON" | jq -r .transactionHash)" ;;
      *) die "motion $MOTION_ID reverted on enact — the pending action is broken; fork left up for inspection" ;;
    esac
  fi
  APPLIED=$((APPLIED + 1))
done < <(awk '
  /^\[\[transaction\]\]/ { if (seen) print from "\t" to "\t" value "\t" data "\t" motion "\t" desc; seen=1; from=to=value=data=motion=desc="" ; next }
  seen && /^from *=/  { gsub(/.*= *"|"$/,""); from=$0 }
  seen && /^to *=/    { gsub(/.*= *"|"$/,""); to=$0 }
  seen && /^value *=/ { gsub(/.*= *"|"$/,""); value=$0 }
  seen && /^data *=/  { gsub(/.*= *"|"$/,""); data=$0 }
  seen && /^motion_calldata *=/ { gsub(/.*= *"|"$/,""); motion=$0 }
  seen && /^description *=/ { gsub(/.*= *"|"$/,""); desc=$0 }
  END { if (seen) print from "\t" to "\t" value "\t" data "\t" motion "\t" desc }
' "$PENDING_TOML")

if [ "$APPLIED" -eq 0 ]; then
  log "no pending transactions in $PENDING_TOML — clean fork left up"
else
  log "$APPLIED transaction(s) applied — fork with the pending state is up on $RPC_LOCAL"
fi
log "next: make test-fork RPC_URL=$RPC_LOCAL ARTIFACTS_DIR=<run> FORK_BLOCK= ; stop with: make pending-stop"
