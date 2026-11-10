#!/usr/bin/env bash
# Reproduce a mutation kill: apply certora/mutations/<Contract>/<N>.sol over its
# @target source, run its @conf on its @rules, then restore the original source.
# Reading the verdict: the last line says it. Violated or Sanity check failed
# on the mutated source = mutant Killed (a satisfy rule whose witness becomes
# UNSAT also shows Violated).
# The matching clean-source command is listed in the mutant's README block.
# Exit code: 0 Survived, 1 Killed, 2 NOT RUN or NOT DECIDED, 3 tool error,
# 130 interrupted. A cloud run returns on submission: read its job link.
# Backup: the target is copied to <target>.mutbak and restored from it on exit;
# git is used only to check that the target is pristine before and after the run.
#
#   ./certora/mutations/run_mutation.sh <Contract> <N>
#   e.g. ./certora/mutations/run_mutation.sh GuardianSignals 33
set -u
cd "$(dirname "$0")/../.." || exit 3

CONTRACT="${1:-}"
N="${2:-}"
if [ -z "$CONTRACT" ] || [ -z "$N" ]; then
    echo "usage: $0 <Contract> <N>   (e.g. $0 GuardianSignals 33)"
    exit 3
fi
MUT="certora/mutations/$CONTRACT/$N.sol"
[ -f "$MUT" ] || { echo "error: $MUT not found"; exit 3; }

hdr() { sed -n "s/^ \* @$1:[[:space:]]*//p" "$MUT" | head -1; }
CONF="$(hdr conf)"
TARGET="$(hdr target)"
RULES="$(hdr rules | tr ',' ' ')"
if [ -z "$CONF" ] || [ -z "$TARGET" ] || [ -z "$RULES" ]; then
    echo "error: incomplete @conf/@target/@rules header in $MUT"
    exit 3
fi
[ -f "$CONF" ] || { echo "error: conf not found: $CONF"; exit 3; }
[ -f "$TARGET" ] || { echo "error: target not found: $TARGET"; exit 3; }
[ -f "$TARGET.mutbak" ] && { echo "error: stale $TARGET.mutbak found; resolve it before running"; exit 3; }
command -v certoraRun >/dev/null 2>&1 || { echo "error: certoraRun not on PATH"; exit 3; }

# The pristine check has to run in the work tree that actually tracks the target.
# Targets under lib/ belong to their own repository (a submodule of this one), so a
# git command issued here would report them clean whatever their contents. Ask git
# from the target's own directory instead, and refuse to run when it does not know
# the file: that means the containing repository is not checked out here, and the
# before/after comparison would be vacuous.
TARGET_DIR="$(dirname "$TARGET")"
TARGET_BASE="$(basename "$TARGET")"
git -C "$TARGET_DIR" ls-files --error-unmatch "$TARGET_BASE" >/dev/null 2>&1 || {
    echo "error: $TARGET is not tracked in a git work tree of its own"
    echo "       (an uninitialized submodule looks like this: check it out first)"
    exit 3
}
git -C "$TARGET_DIR" diff --quiet -- "$TARGET_BASE" || { echo "error: $TARGET has local modifications; restore it before running"; exit 3; }

# A satisfy that holds still prints FAIL in its result line and a plain rule prints no
# "Violated for:", so neither is read: each rule's own table row is.
verdict() {
    local r rows reached=0 decided=1
    for r in $RULES; do
        grep -aq "Checking rule $r (" "$LOG" && reached=1
        rows="$(grep -aE "^[|]${r:0:40} *[|]" "$LOG" | cut -d'|' -f3)"
        if grep -qE "^(Violated|Sanity check) *$" <<<"$rows"; then
            echo "[run_mutation] done: mutant KILLED; $r is Violated or Sanity check failed on the mutated source"
            return 1
        fi
        [ -n "$rows" ] && ! grep -qvE "^Not violated *$" <<<"$rows" || decided=0
    done
    if [ "$reached" -eq 1 ] && [ "$decided" -eq 1 ] && [ "$status" -eq 0 ]; then
        echo "[run_mutation] done: mutant SURVIVED; every rule of @rules is Not violated on the mutated source"
        return 0
    fi
    if grep -aqE "Job submitted to server|Follow your job" "$LOG"; then
        echo "[run_mutation] done: NOT DECIDED; the job went to the cloud, so read its verdict at the link above"
        return 2
    fi
    if [ "$reached" -eq 0 ]; then
        echo "[run_mutation] done: NOT RUN; the run stopped before any rule of @rules was checked (for example a compile error, a missing submodule or a prover crash)"
        return 2
    fi
    echo "[run_mutation] done: NOT DECIDED; a rule of @rules ended without a verdict (a timeout or a prover error)"
    return 2
}

LOG="$(mktemp -t run_mutation.XXXXXX)" || { echo "error: could not create a log file"; exit 3; }
restore() {
    if [ -f "$TARGET.mutbak" ]; then
        cp "$TARGET.mutbak" "$TARGET" && rm -f "$TARGET.mutbak"
        echo "[run_mutation] restored $TARGET"
    fi
}
trap 'restore; rm -f "$LOG"' EXIT
trap 'restore; rm -f "$LOG"; trap - EXIT; exit 130' INT TERM

cp "$TARGET" "$TARGET.mutbak" || { rm -f "$TARGET.mutbak"; echo "error: could not back up $TARGET"; exit 3; }
cp "$MUT" "$TARGET" || { echo "error: could not apply $MUT"; exit 3; }
echo "[run_mutation] applied $MUT over $TARGET"
echo "[run_mutation] certoraRun $CONF --rule $RULES"
certoraRun "$CONF" --rule $RULES 2>&1 | tee "$LOG"
status="${PIPESTATUS[0]}"

restore
trap 'rm -f "$LOG"' EXIT
trap - INT TERM
git -C "$TARGET_DIR" diff --quiet -- "$TARGET_BASE" || { echo "error: $TARGET did not restore cleanly"; exit 3; }
verdict
exit $?
