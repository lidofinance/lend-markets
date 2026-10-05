#!/bin/sh
# One resumable step of `make deploy-all`. Runs the make target unless the step's artifact already records a
# contract with code on chain. An artifact whose address has no code stops the run: a broadcast that failed after
# the simulation wrote the file, which has to be deleted by hand before retrying.
#
# usage: deploy-step.sh <artifact-path> <address-key> <rpc-url> <make-target> [VAR=value ...]
set -eu

[ $# -ge 4 ] || { echo "usage: deploy-step.sh <artifact-path> <address-key> <rpc-url> <make-target> [VAR=value ...]" >&2; exit 2; }
artifact=$1
key=$2
rpc=$3
target=$4
shift 4

if [ -f "$artifact" ]; then
  address=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\(0x[0-9a-fA-F]\{40\}\)\".*/\1/p" "$artifact" | head -n 1)
  if [ -n "$address" ]; then
    code=$(cast code "$address" --rpc-url "$rpc") || { echo "ERROR: cannot read the code at $address via $rpc" >&2; exit 1; }
    if [ "$code" != "0x" ]; then
      echo "deploy-all: $artifact records a live contract, skipping $target"
      exit 0
    fi
  fi
  echo "ERROR: $artifact records no contract on the chain behind $rpc: a broadcast that failed after the" >&2
  echo "       simulation wrote it. Delete the file, then rerun deploy-all." >&2
  case "$artifact" in
    */protocol.toml) echo "       protocol.toml is written together with exit-books.toml: delete both." >&2 ;;
  esac
  exit 1
fi

exec "${MAKE:-make}" "$target" RPC_URL="$rpc" "$@"
