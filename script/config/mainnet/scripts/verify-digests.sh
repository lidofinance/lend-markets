#!/bin/sh
# Checks the deploy tree against Section 6 of the Cyfrin Lido Lend report.
# Usage: sh verify-digests.sh <digests.txt>   (run from the lend-markets root at the deploy commit)
set -eu
digests=${1:-digests.txt}
expected_root=0x84be32b38acdf912b6ae7fbaabe235398f03d682394d121dcdc41af042b4ecc4

keccak_file() { cast keccak "0x$(xxd -p "$1" | tr -d '\n')"; }

echo "deploy commit: $(git rev-parse HEAD)"

root=$(keccak_file "$digests")
[ "$root" = "$expected_root" ] && echo "aggregate root: OK $root" || { echo "aggregate root: MISMATCH $root"; exit 1; }

n=0; bad=0
while read -r digest path || [ -n "$digest" ]; do
  n=$((n + 1))
  if [ ! -f "$path" ]; then echo "MISSING  $path"; bad=$((bad + 1)); continue; fi
  actual=$(keccak_file "$path")
  [ "$actual" = "$digest" ] || { echo "MISMATCH $path"; echo "  report $digest"; echo "  tree   $actual"; bad=$((bad + 1)); }
done < "$digests"
echo "files: $n checked, $bad failed"

echo "submodules:"
git submodule status --recursive | grep -E ' lib/(lido-lend|lido-lend-irm|lido-lend-irm/lib/lido-lend|circuit-breaker) ' | awk '{print "  " $1, $2}'

echo "deployed sources outside the audited set:"
{ git ls-files src; git -C lib/lido-lend ls-files src | sed 's#^#lib/lido-lend/#'; git -C lib/lido-lend-irm ls-files src | sed 's#^#lib/lido-lend-irm/#'; } | grep -v -E '/(test|mocks)/' | sort > /tmp/deployed.$$
awk '{print $2}' "$digests" | sort > /tmp/audited.$$
comm -23 /tmp/deployed.$$ /tmp/audited.$$ | sed 's/^/  /'
rm -f /tmp/deployed.$$ /tmp/audited.$$

[ "$bad" -eq 0 ]
