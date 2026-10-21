#!/usr/bin/env bash
# Deploys and activates the protocol on a local anvil fork of a real network. Driver over the `make deploy-*`
# targets; see script/DEPLOYMENT.md.
#
#   bash script/provision-fork.sh [upstream-rpc] [config] [block]   # provision; leaves anvil running
#   bash script/provision-fork.sh check                             # is the run live on the local anvil?
#   bash script/provision-fork.sh stop                              # stop the anvil a previous run started
#
# `config` is the fork deploy config and selects the network to fork: its chain_id is what the upstream must
# report and what anvil is started with. `block` pins the upstream block anvil forks from; without it anvil
# forks the tip and a run is not reproducible. When no compatible anvil is already
# running, the upstream comes from the argument or RPC_URL and must be an archive node, not the local anvil.
# Deploy steps always receive the local anvil URL on the command line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ACTION="${1:-}"
STOP_EXPECTED_PID=""
STOP_EXPECTED_START=""
STOP_EXPECTED_TOKEN=""
if [ "$ACTION" = "stop-if-owned" ]; then
  # Internal one-shot cleanup command. The identity is kept separate from the normal positional deploy args.
  STOP_EXPECTED_PID="${2:-}"
  STOP_EXPECTED_START="${3:-}"
  STOP_EXPECTED_TOKEN="${4:-}"
  CONFIG_NAME="fork-mainnet"
  PIN_BLOCK=""
else
  CONFIG_NAME="${2:-fork-mainnet}"
  PIN_BLOCK="${3:-}"
  case "$PIN_BLOCK" in ""|*[!0-9]*) [ -z "$PIN_BLOCK" ] || { echo "[provision] ERROR: PIN_BLOCK must be a number" >&2; exit 1; } ;; esac
fi
# One published run directory regardless of network. Reprovision builds there under rollback protection, and
# every consumer refers to it as ARTIFACTS_DIR=fork.
RUN_NAME="fork"
RPC_LOCAL="http://127.0.0.1:8545"
RUN_DIR="deployed/${RUN_NAME}"
BACKUP_DIR="deployed/.${RUN_NAME}.previous"
TRASH_DIR="deployed/.${RUN_NAME}.previous.committed"
PID_FILE="deployed/${RUN_NAME}-anvil.pid"
LOG_FILE="deployed/${RUN_NAME}-anvil.log"
LOCK_DIR="deployed/.${RUN_NAME}-provision.lock"
CONFIG_TOML="script/config/${CONFIG_NAME}.toml"

# anvil's first dev account, impersonated rather than signed for: no key material anywhere in the deploy path.
# Holds no protocol role; requireActorSeparation enforces that against the config.
DEPLOYER_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
TEN_ETHER_HEX="0x8AC7230489E80000"
STARTED_ANVIL=0
RUN_IN_PROGRESS=0
LOCK_HELD=0
PENDING_SIGNAL=0
ANVIL_PID=""
ANVIL_START=""
ANVIL_TOKEN=""
PID_LAUNCH_TMP=""
RESULT_FILE="${PROVISION_RESULT_FILE:-}"
REQUEST_TOKEN="${PROVISION_REQUEST_TOKEN:-}"
RESULT_TMP=""

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

# One-line string array from a named TOML section. Provision resource names are deliberately whitespace-free.
toml_array() {
  local raw
  raw="$(awk -v wanted_section="$2" -v wanted_key="$3" '
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", section)
      next
    }
    section == wanted_section {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      equals = index(line, "=")
      if (!equals) next
      key = substr(line, 1, equals - 1)
      gsub(/[[:space:]]/, "", key)
      if (key != wanted_key) next
      value = substr(line, equals + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$1")"
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" | awk '
    !/^\[[[:space:]]*("[^"]+"[[:space:]]*(,[[:space:]]*"[^"]+"[[:space:]]*)*)?\]$/ { exit 2 }
    {
      sub(/^\[[[:space:]]*/, "")
      sub(/[[:space:]]*\]$/, "")
      if ($0 == "") exit
      count = split($0, values, ",")
      for (i = 1; i <= count; ++i) {
        value = values[i]
        gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", value)
        if (value !~ /^[A-Za-z0-9._-]+$/) exit 2
        print value
      }
    }
  '
}

process_start() {
  ps -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}'
}

queue_signal() {
  [ "$PENDING_SIGNAL" -ne 0 ] || PENDING_SIGNAL="$1"
}

arm_termination_traps() {
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

defer_termination() {
  PENDING_SIGNAL=0
  trap 'queue_signal 129' HUP
  trap 'queue_signal 130' INT
  trap 'queue_signal 143' TERM
}

resume_termination() {
  local pending="$PENDING_SIGNAL"
  PENDING_SIGNAL=0
  arm_termination_traps
  [ "$pending" -eq 0 ] || exit "$pending"
}

same_process() {
  local pid="$1" expected_start="$2" actual_start
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  actual_start="$(process_start "$pid")"
  [ -n "$actual_start" ] && [ "$actual_start" = "$expected_start" ]
}

direct_child() {
  local pid="$1" parent
  case "$pid" in ""|*[!0-9]*) return 1 ;; esac
  parent="$(ps -p "$pid" -o ppid= 2>/dev/null | awk '{$1=$1; print}')"
  [ "$parent" = "$$" ]
}

record_matches() {
  local expected_pid="$1" expected_start="$2" expected_token="$3"
  [ -f "$PID_FILE" ] || return 1
  [ "$(sed -n '1p' "$PID_FILE")" = "$expected_pid" ] \
    && [ "$(sed -n '2p' "$PID_FILE")" = "$expected_start" ] \
    && [ "$(sed -n '3p' "$PID_FILE")" = "$expected_token" ]
}

# PID file format: pid, process start time, per-start ownership token. Legacy/truncated records are deliberately
# treated as stale: they may be discarded, but never grant permission to signal a process.
owned_anvil() {
  local pid expected_start token command
  [ -f "$PID_FILE" ] || return 1
  pid="$(sed -n '1p' "$PID_FILE")"
  expected_start="$(sed -n '2p' "$PID_FILE")"
  token="$(sed -n '3p' "$PID_FILE")"
  [ -n "$token" ] || return 1
  same_process "$pid" "$expected_start" || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null)"
  case "$command" in anvil\ *|*/anvil\ *) ;; *) return 1 ;; esac
  case " $command " in *" --port 8545 "*) return 0 ;; *) return 1 ;; esac
}

stop_owned_anvil() {
  local pid
  if [ ! -f "$PID_FILE" ]; then
    log "no pid file at $PID_FILE (anvil was reused or never started by this script)"
    return 0
  fi
  pid="$(sed -n '1p' "$PID_FILE")"
  if ! owned_anvil; then
    if kill -0 "$pid" 2>/dev/null; then
      log "refusing to signal pid $pid: stale pid file does not identify this script's anvil"
    else
      log "no live owned anvil at pid ${pid:-unknown}"
    fi
    rm -f "$PID_FILE"
    return 0
  fi

  kill "$pid"
  for _ in $(seq 1 50); do
    same_process "$pid" "$(sed -n '2p' "$PID_FILE")" || break
    sleep 0.1
  done
  if owned_anvil; then
    log "ERROR: anvil pid $pid did not stop"
    return 1
  fi
  rm -f "$PID_FILE"
  log "stopped anvil (pid $pid)"
}

stop_owned_anvil_if_matches() {
  local expected_pid="$1" expected_start="$2" expected_token="$3" current_pid current_start current_token
  case "$expected_pid" in ""|*[!0-9]*) die "invalid expected anvil pid" ;; esac
  [ -n "$expected_start" ] || die "invalid expected anvil start time"
  [ -n "$expected_token" ] || die "invalid expected anvil ownership token"
  if [ ! -f "$PID_FILE" ]; then
    log "not stopping anvil: $PID_FILE no longer exists"
    return 0
  fi
  current_pid="$(sed -n '1p' "$PID_FILE")"
  current_start="$(sed -n '2p' "$PID_FILE")"
  current_token="$(sed -n '3p' "$PID_FILE")"
  if [ "$current_pid" != "$expected_pid" ] || [ "$current_start" != "$expected_start" ] \
    || [ "$current_token" != "$expected_token" ]; then
    log "not stopping anvil: its pid record changed after this invocation"
    return 0
  fi
  stop_owned_anvil
}

# Failure cleanup for the launcher critical section. The child writes its token before exec-ing anvil; wait for
# that record/exec transition, but fall back to the still-exact direct child if it failed before publishing.
stop_started_anvil() {
  local pid="$ANVIL_PID" token="$ANVIL_TOKEN" start="" current_pid current_token
  case "$pid" in ""|*[!0-9]*) return 0 ;; esac
  [ -n "$token" ] || return 0

  for _ in $(seq 1 50); do
    if [ -f "$PID_FILE" ]; then
      current_pid="$(sed -n '1p' "$PID_FILE")"
      current_token="$(sed -n '3p' "$PID_FILE")"
      if [ "$current_pid" = "$pid" ] && [ "$current_token" = "$token" ]; then
        start="$(sed -n '2p' "$PID_FILE")"
        [ -n "$start" ] && owned_anvil && break
        same_process "$pid" "$start" || break
      fi
    fi
    direct_child "$pid" || break
    sleep 0.02
  done

  if [ -n "$start" ] && record_matches "$pid" "$start" "$token" && same_process "$pid" "$start"; then
    kill "$pid" 2>/dev/null || true
    if direct_child "$pid"; then
      wait "$pid" 2>/dev/null || true
    else
      for _ in $(seq 1 50); do same_process "$pid" "$start" || break; sleep 0.1; done
    fi
  elif direct_child "$pid"; then
    # No complete record was published, but this is still the exact child returned by the launch operation.
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi

  if [ -f "$PID_FILE" ] && [ "$(sed -n '1p' "$PID_FILE")" = "$pid" ] \
    && [ "$(sed -n '3p' "$PID_FILE")" = "$token" ]; then
    rm -f "$PID_FILE"
  fi
  [ -z "$PID_LAUNCH_TMP" ] || rm -f "$PID_LAUNCH_TMP"
}

acquire_lock() {
  local owner_pid owner_start self_start
  mkdir -p deployed
  defer_termination
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    resume_termination
    owner_pid="$(sed -n '1p' "$LOCK_DIR/owner" 2>/dev/null || true)"
    owner_start="$(sed -n '2p' "$LOCK_DIR/owner" 2>/dev/null || true)"
    if same_process "$owner_pid" "$owner_start"; then
      die "another provision-fork is running (pid $owner_pid)"
    fi
    die "stale provision lock at $LOCK_DIR; verify no provision is running, then remove it"
  fi
  LOCK_HELD=1
  self_start="$(process_start "$$")"
  if [ -z "$self_start" ]; then
    resume_termination
    die "cannot identify the provision process"
  fi
  printf '%s\n%s\n' "$$" "$self_start" >"$LOCK_DIR/owner"
  resume_termination
}

release_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -f "$LOCK_DIR/owner" || return 1
  rmdir "$LOCK_DIR" || return 1
  LOCK_HELD=0
}

publish_result() {
  local mode="$1"
  [ -n "$RESULT_FILE" ] || return 0
  RESULT_TMP="${RESULT_FILE}.tmp.$$-$RANDOM"
  case "$mode" in
    reused)
      (umask 077; printf '%s\nreused\n' "$REQUEST_TOKEN") >"$RESULT_TMP"
      ;;
    started)
      owned_anvil || die "cannot publish ownership for an anvil that is not live"
      record_matches "$ANVIL_PID" "$ANVIL_START" "$ANVIL_TOKEN" \
        || die "anvil ownership record changed before result publication"
      (umask 077; printf '%s\nstarted\n%s\n%s\n%s\n' \
        "$REQUEST_TOKEN" "$ANVIL_PID" "$ANVIL_START" "$ANVIL_TOKEN") >"$RESULT_TMP"
      ;;
    *) die "invalid provision result '$mode'" ;;
  esac
  mv "$RESULT_TMP" "$RESULT_FILE"
  RESULT_TMP=""
}

restore_previous_run() {
  if [ ! -d "$BACKUP_DIR" ] && [ ! -f "$BACKUP_DIR" ]; then
    log "ERROR: invalid rollback state at $BACKUP_DIR"
    return 1
  fi
  if ! rm -rf "$RUN_DIR" || [ -e "$RUN_DIR" ]; then
    log "ERROR: could not remove the incomplete run at $RUN_DIR"
    return 1
  fi
  if [ -d "$BACKUP_DIR" ]; then
    if ! mv "$BACKUP_DIR" "$RUN_DIR"; then
      log "ERROR: could not restore $BACKUP_DIR to $RUN_DIR"
      return 1
    fi
    log "restored the previous run at $RUN_DIR"
  elif [ -f "$BACKUP_DIR" ]; then
    # A regular file is the durable transaction record for "there was no previous published run".
    if ! rm -f "$BACKUP_DIR"; then
      log "ERROR: could not clear the no-previous-run marker at $BACKUP_DIR"
      return 1
    fi
    log "removed the interrupted run; there was no previous run to restore"
  fi
}

recover_previous_run() {
  if [ -e "$BACKUP_DIR" ]; then
    log "recovering the last published state from $BACKUP_DIR"
    restore_previous_run
  fi
  if [ -e "$TRASH_DIR" ]; then
    # Trash is reachable only after the new RUN_DIR was accepted. It is never a rollback source.
    log "removing committed artifact trash at $TRASH_DIR"
    rm -rf "$TRASH_DIR"
  fi
}

prepare_run() {
  [ ! -e "$BACKUP_DIR" ] || die "rollback state already exists at $BACKUP_DIR"
  [ ! -e "$TRASH_DIR" ] || die "committed artifact trash still exists at $TRASH_DIR"
  RUN_IN_PROGRESS=1
  if [ -e "$RUN_DIR" ]; then
    mv "$RUN_DIR" "$BACKUP_DIR"
  else
    # Unlike a missing backup, this file explicitly records that rollback must leave RUN_DIR absent.
    : >"$BACKUP_DIR"
  fi
  log "building a fresh run at $RUN_DIR"
}

commit_run() {
  [ -e "$BACKUP_DIR" ] || die "cannot commit without rollback state at $BACKUP_DIR"
  [ ! -e "$TRASH_DIR" ] || die "cannot commit while $TRASH_DIR exists"
  # The same-filesystem rename is the commit marker. Once it lands, traps and future invocations preserve the
  # accepted RUN_DIR even if deletion of the obsolete state is interrupted.
  mv "$BACKUP_DIR" "$TRASH_DIR"
  RUN_IN_PROGRESS=0
  rm -rf "$TRASH_DIR"
}

rollback_run() {
  [ "$RUN_IN_PROGRESS" = 1 ] || return 0
  if [ -e "$BACKUP_DIR" ]; then
    restore_previous_run
  elif [ -e "$TRASH_DIR" ]; then
    # commit_run's rename already accepted RUN_DIR; never restore or delete a potentially partial trash tree.
    log "artifact commit already accepted; preserving $RUN_DIR"
  else
    # prepare_run may be interrupted before it creates rollback state. Preserving RUN_DIR is always the safe
    # choice: it is either the prior published run or no path at all.
    log "no artifact rollback state was created; preserving the published state"
  fi
  RUN_IN_PROGRESS=0
}

on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  [ -z "$RESULT_TMP" ] || rm -f "$RESULT_TMP"
  if [ "$status" -ne 0 ]; then
    rollback_run
    [ "$STARTED_ANVIL" = 0 ] || stop_started_anvil
  fi
  release_lock || { [ "$status" -ne 0 ] || status=1; }
  exit "$status"
}

usage() {
  cat <<EOF
Usage:
  bash script/provision-fork.sh [upstream-rpc] [config] [block]   # provision; leaves anvil running
  bash script/provision-fork.sh check                             # is the run live on the local anvil?
  bash script/provision-fork.sh stop                              # stop the anvil a previous run started
EOF
}

trap on_exit EXIT
arm_termination_traps

# --- stop subcommands -----------------------------------------------------------------------------------------
if [ "$ACTION" = "stop" ] || [ "$ACTION" = "stop-if-owned" ]; then
  acquire_lock
  if [ "$ACTION" = "stop-if-owned" ]; then
    stop_owned_anvil_if_matches "$STOP_EXPECTED_PID" "$STOP_EXPECTED_START" "$STOP_EXPECTED_TOKEN"
  else
    stop_owned_anvil
  fi
  exit 0
fi
if [ "$ACTION" = "-h" ] || [ "$ACTION" = "--help" ]; then usage; exit 0; fi

# --- check subcommand -----------------------------------------------------------------------------------------
# Exits 0 when the local anvil hosts the deployment recorded in $RUN_DIR. Says nothing about whether that
# deployment matches the current sources — it answers "can the fork suites run", not "is it up to date".
if [ "$ACTION" = "check" ]; then
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

# --- 1. deploy config + resource preflight --------------------------------------------------------------------
UPSTREAM="${1:-${RPC_URL:-}}"
if [ -z "$UPSTREAM" ] && [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
  UPSTREAM="${RPC_URL:-}"
fi

if [ -n "$RESULT_FILE" ] || [ -n "$REQUEST_TOKEN" ]; then
  [ -n "$RESULT_FILE" ] && [ -n "$REQUEST_TOKEN" ] \
    || die "PROVISION_RESULT_FILE and PROVISION_REQUEST_TOKEN must be set together"
  case "$REQUEST_TOKEN" in *[!A-Za-z0-9._-]*|'') die "invalid PROVISION_REQUEST_TOKEN" ;; esac
  [ ! -e "$RESULT_FILE" ] || die "provision result already exists at $RESULT_FILE"
  [ -d "$(dirname "$RESULT_FILE")" ] || die "provision result directory does not exist"
fi

[ -f "$CONFIG_TOML" ] || die "deploy config not found: $CONFIG_TOML"
# Bare integer, so it needs its own reader. Deliberately the config's chain id, not the run's: the Makefile
# resolves the RUN's chain id from its protocol.toml, which at this point may still be the previous network's.
CHAIN_ID="$(sed -n 's/^[[:space:]]*chain_id[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$CONFIG_TOML" | head -1)"
[ -n "$CHAIN_ID" ] || die "$CONFIG_TOML is missing key 'chain_id'"

MARKET_NAMES="$(toml_array "$CONFIG_TOML" provision markets)" \
  || die "$CONFIG_TOML is missing a valid [provision].markets string array"
[ -n "$MARKET_NAMES" ] || die "$CONFIG_TOML defines no provision markets"
# Optional scalar: the bundler config the run deploys its Bundler3 and adapters from. Absent means the step is
# skipped and the bundled fork suites skip with it.
BUNDLER_NAME="$(toml_str "$CONFIG_TOML" bundler)"
# Unquoted on purpose: provision resource names are validated as whitespace-free logical names by toml_array.
MARKETS=($MARKET_NAMES)

AGENT="$(toml_req "$CONFIG_TOML" agent)"
EXECUTOR="$(toml_req "$CONFIG_TOML" evm_script_executor)"
CIRCUIT_BREAKER="$(toml_req "$CONFIG_TOML" circuit_breaker_artifact)"

acquire_lock
recover_previous_run

# Market-scoped resources are derived from the selected market configs. Validate every source before touching
# the node/run; the protocol-wide CircuitBreaker is selected by the deploy config.
ORACLES="" GUARDIAN_GROUPS=""
for market in "${MARKETS[@]}"; do
  mcfg="script/config/markets/${market}.toml"
  [ -f "$mcfg" ] || die "market config not found: $mcfg"
  ORACLES="$(add_unique "$ORACLES" "$(toml_req "$mcfg" oracle_artifact)")"
  GUARDIAN_GROUPS="$(add_unique "$GUARDIAN_GROUPS" "$(toml_req "$mcfg" guardian_group)")"
done
[ -f "script/config/circuit-breakers/${CIRCUIT_BREAKER}.toml" ] \
  || die "CircuitBreaker config not found: script/config/circuit-breakers/${CIRCUIT_BREAKER}.toml"
for oracle in $ORACLES; do
  ocfg="script/config/oracles/${oracle}.toml"
  [ -f "$ocfg" ] || die "oracle config not found: $ocfg"
  case "$(toml_req "$ocfg" kind)" in
    wsteth|usdy) ;;
    *) die "$ocfg has an unsupported oracle kind" ;;
  esac
done
for group in $GUARDIAN_GROUPS; do
  [ -f "script/config/guardians/${group}.toml" ] \
    || die "guardian config not found: script/config/guardians/${group}.toml"
done
[ -z "$BUNDLER_NAME" ] || [ -f "script/config/bundlers/${BUNDLER_NAME}.toml" ] \
  || die "bundler config not found: script/config/bundlers/${BUNDLER_NAME}.toml"
log "markets: ${MARKETS[*]}"
log "bundler: ${BUNDLER_NAME:-none}"
log "circuit breaker: $CIRCUIT_BREAKER  oracles: ${ORACLES:-none}  guardians: ${GUARDIAN_GROUPS:-none}"

# --- 2. anvil --------------------------------------------------------------------------------------------------

if cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1; then
  [ -z "$PIN_BLOCK" ] \
    || die "PIN_BLOCK cannot be honored while reusing $RPC_LOCAL; stop that node and provision again"
  REUSED_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_LOCAL")"
  [ "$REUSED_CHAIN_ID" = "$CHAIN_ID" ] \
    || die "anvil on :8545 reports chain id $REUSED_CHAIN_ID, not $CHAIN_ID; stop it or free the port"
  if [ -f "$PID_FILE" ] && ! owned_anvil; then
    log "discarding stale pid file $PID_FILE without signalling its pid"
    rm -f "$PID_FILE"
  fi
  log "reusing the anvil already listening on $RPC_LOCAL"
else
  case "$UPSTREAM" in
    "") die "pass an upstream archive RPC as the first argument, or set RPC_URL in .env" ;;
    *127.0.0.1*|*localhost*) die "upstream RPC must be a real archive node, not the local anvil ($UPSTREAM)" ;;
  esac
  # Probed before anvil starts: an unreachable upstream reports the node's own error instead of a 60s timeout.
  UPSTREAM_CHAIN_ID="$(cast chain-id --rpc-url "$UPSTREAM" 2>/dev/null)" \
    || die "upstream RPC is not answering"
  [ "$UPSTREAM_CHAIN_ID" = "$CHAIN_ID" ] \
    || die "upstream chain id $UPSTREAM_CHAIN_ID does not match $CONFIG_TOML ($CHAIN_ID)"
  log "upstream chain $CHAIN_ID, block $(cast block-number --rpc-url "$UPSTREAM")"

  log "starting anvil (fork of the upstream, chain-id $CHAIN_ID, block ${PIN_BLOCK:-tip}) -> $LOG_FILE"
  mkdir -p deployed
  [ ! -f "$PID_FILE" ] || stop_owned_anvil
  : >"$LOG_FILE" # so a failure never reports a previous run's log
  ANVIL_TOKEN="provision-$$-$RANDOM-$RANDOM"
  PID_LAUNCH_TMP="${PID_FILE}.launch.${ANVIL_TOKEN}"

  spawn_anvil_launcher() {
    PROVISION_PID_FILE="$PID_FILE" PROVISION_ANVIL_TOKEN="$ANVIL_TOKEN" nohup /bin/bash -c '
      set -e
      child_start="$(ps -p "$$" -o lstart= 2>/dev/null | awk '\''{$1=$1; print}'\'')"
      [ -n "$child_start" ]
      record_tmp="${PROVISION_PID_FILE}.launch.${PROVISION_ANVIL_TOKEN}"
      (umask 077; printf "%s\n%s\n%s\n" "$$" "$child_start" "$PROVISION_ANVIL_TOKEN") >"$record_tmp"
      mv "$record_tmp" "$PROVISION_PID_FILE"
      exec "$@"
    ' provision-anvil "$@" >"$LOG_FILE" 2>&1 </dev/null &
    ANVIL_PID="$!"
  }

  # Signals are queued only across fork + $! capture. Once STARTED_ANVIL is armed, EXIT cleanup can follow the
  # launch token through the wrapper's atomic record and the exec into anvil.
  defer_termination
  if [ -n "$PIN_BLOCK" ]; then
    spawn_anvil_launcher anvil --quiet --fork-url "$UPSTREAM" --port 8545 --chain-id "$CHAIN_ID" \
      --auto-impersonate --fork-block-number "$PIN_BLOCK"
  else
    spawn_anvil_launcher anvil --quiet --fork-url "$UPSTREAM" --port 8545 --chain-id "$CHAIN_ID" \
      --auto-impersonate
  fi
  STARTED_ANVIL=1
  resume_termination

  for _ in $(seq 1 100); do
    if [ -f "$PID_FILE" ] && [ "$(sed -n '1p' "$PID_FILE")" = "$ANVIL_PID" ] \
      && [ "$(sed -n '3p' "$PID_FILE")" = "$ANVIL_TOKEN" ]; then
      ANVIL_START="$(sed -n '2p' "$PID_FILE")"
      break
    fi
    direct_child "$ANVIL_PID" || break
    sleep 0.02
  done
  [ -n "$ANVIL_START" ] || die "anvil launcher exited before publishing ownership"
  record_matches "$ANVIL_PID" "$ANVIL_START" "$ANVIL_TOKEN" \
    || die "anvil launcher published a mismatched ownership record"
  PID_LAUNCH_TMP=""

  for _ in $(seq 1 60); do
    cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1 && break
    sleep 1
  done
  if ! cast block-number --rpc-url "$RPC_LOCAL" >/dev/null 2>&1; then
    echo "[provision] --- last lines of $LOG_FILE ---" >&2
    tail -20 "$LOG_FILE" >&2
    die "anvil did not come up (see $LOG_FILE)"
  fi
  owned_anvil || die "anvil launcher did not exec the expected process"
  log "anvil up (pid $ANVIL_PID), block $(cast block-number --rpc-url "$RPC_LOCAL")"
fi

# --- 3. make the reused node capable of running the same pipeline as a self-started node ----------------------
for actor in "$DEPLOYER_ADDRESS" "$AGENT" "$EXECUTOR"; do
  cast rpc anvil_setBalance "$actor" "$TEN_ETHER_HEX" --rpc-url "$RPC_LOCAL" >/dev/null \
    || die "$RPC_LOCAL is not a compatible Anvil (anvil_setBalance failed)"
done
for actor in "$AGENT" "$EXECUTOR"; do
  cast rpc anvil_impersonateAccount "$actor" --rpc-url "$RPC_LOCAL" >/dev/null \
    || die "$RPC_LOCAL is not a compatible Anvil (cannot impersonate $actor)"
done
log "deployer, agent and executor funded; governance actors impersonated"

# Artifact writers are immutable. Keep the previous run as a rollback until the new run passes post-activation
# acceptance, so a failed reprovision never destroys the last known-good artifact set.
prepare_run

# VERIFY is off: a local node has no verifier.
deploy() {
  make "$@" CONFIG="$CONFIG_NAME" RUN="$RUN_NAME" RPC_URL="$RPC_LOCAL" \
    DEPLOYER_ACCOUNT= DEPLOYER_SENDER="$DEPLOYER_ADDRESS" VERIFY=false RESUME=false
}

# --- 4..8. the deploy pipeline --------------------------------------------------------------------------------
log "deploying CircuitBreaker"
deploy deploy-circuit-breaker

# The oracle config's explicit kind selects its deployment script.
for oracle in $ORACLES; do
  ocfg="script/config/oracles/${oracle}.toml"
  case "$(toml_req "$ocfg" kind)" in
    wsteth)
      log "deploying wstETH rate oracle ($oracle)"
      deploy deploy-oracle ORACLE="$oracle"
      ;;
    usdy)
      log "deploying USDY stable oracle ($oracle)"
      deploy deploy-oracle-usdy ORACLE="$oracle"
      ;;
  esac
done

log "deploying protocol backbone (config=$CONFIG_NAME, run dir=$RUN_DIR)"
deploy deploy-protocol

# After the protocol (the market factory is recorded there) and before the markets, which require the
# registry of the group they name. One per group, so markets sharing a committee share its registry.
for group in $GUARDIAN_GROUPS; do
  log "deploying GuardianSignals ($group)"
  deploy deploy-guardian GUARDIAN_GROUP="$group"
done

for market in "${MARKETS[@]}"; do
  log "deploying market ($market)"
  deploy deploy-market MARKET="$market"
done

if [ -n "$BUNDLER_NAME" ]; then
  log "deploying bundler3 + adapters ($BUNDLER_NAME)"
  deploy deploy-bundler BUNDLER="$BUNDLER_NAME"
fi

# Verification uses the same acceptance suite as a real deployment, against the artifacts this run wrote. Each
# acceptance test forks the node itself, so its state changes do not reach the anvil. While the markets are
# inert MarketMotionReadiness runs and MarketActivated self-skips.
for market in "${MARKETS[@]}"; do
  log "verifying $market is ready for the motion (acceptance)"
  make acceptance-run RUN="$RUN_NAME" MARKET="$market" RPC_URL="$RPC_LOCAL"
done

# The two-market simulation performs the motion itself, covering the activation write path and cross-market
# singleton state.
if [ "${#MARKETS[@]}" -ge 2 ]; then
  log "simulating the activation motion over ${MARKETS[0]} + ${MARKETS[1]} (acceptance)"
  make acceptance-run-multi RUN="$RUN_NAME" MARKET_A="${MARKETS[0]}" MARKET_B="${MARKETS[1]}" RPC_URL="$RPC_LOCAL"
fi

log "activating markets (motion replay as the executor)"
deploy activate-markets

# After activation the halves swap: MarketActivated runs, MarketMotionReadiness self-skips.
for market in "${MARKETS[@]}"; do
  log "verifying $market is activated and fully wired (acceptance)"
  make acceptance-run RUN="$RUN_NAME" MARKET="$market" RPC_URL="$RPC_LOCAL" \
    ACCEPTANCE_PAUSER_COMMITTEE="$AGENT" ACCEPTANCE_ENABLE_SETTLEMENT=true
done

commit_run
if [ "$STARTED_ANVIL" = 1 ]; then
  publish_result started
else
  publish_result reused
fi
log "done."
log "  run dir : $RUN_DIR"
log "anvil is left running on $RPC_LOCAL (stop it with: bash script/provision-fork.sh stop)"
echo
echo "Run the fork suites against it with:"
echo "  make test-fork RPC_URL=$RPC_LOCAL ARTIFACTS_DIR=$RUN_NAME"
