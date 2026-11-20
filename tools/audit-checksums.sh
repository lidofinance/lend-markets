#!/usr/bin/env bash
# Prints the keccak256 of every source file in the scope of the Cyfrin audit (Lido Lend audit report v2.0,
# 2026-10-21, section "In-Scope File Checksums"), grouped and ordered like the report's tables so each row can be
# compared with it by eye. Ends with the report's aggregate root: keccak256 of all rows, each written as its 0x
# digest, two spaces and its path in this repository, sorted by path and joined by newlines with no trailing newline.
#
# A digest is taken over the exact file bytes: one changed byte changes it.
#
# usage: tools/audit-checksums.sh [<git-ref>]
#   no argument  hash the files on disk, each submodule as it is checked out
#   <git-ref>    hash the files committed at that ref of this repository (branch, tag or commit), each submodule at
#                the commit the ref pins; nothing is checked out
set -euo pipefail

cd "$(dirname "$0")/.."
ref=${1:-}

command -v cast >/dev/null || { echo "ERROR: cast not found; install Foundry" >&2; exit 1; }
[ -z "$ref" ] || git rev-parse --verify --quiet "$ref^{commit}" >/dev/null ||
  { echo "ERROR: unknown git ref: $ref" >&2; exit 1; }

LIDO_LEND_MARKETS="
src/GuardianSignals.sol
src/LidoLendERC4626.sol
src/adapters/EthereumGeneralAdapter1.sol
src/adapters/LidoLendVaultAdapter.sol
src/controllers/LidoLendMarketController.sol
src/libs/CollateralActivationLib.sol
src/libs/Constants.sol
src/libs/ExitBookLib.sol
src/libs/MaxHeapLib.sol
src/libs/SettlementQueueLib.sol
src/oracle/UsdyStableOracle.sol
src/oracle/WstEthRateOracle.sol
src/periphery/Erc4626ExitBook.sol
src/periphery/ExitBookBase.sol
src/periphery/LidoLendMarketFactory.sol
src/periphery/LidoLendOwner.sol
src/periphery/MorphoExitBook.sol
src/periphery/RiskStewardDashboard.sol
src/proxy/OssifiableProxy.sol
src/types/CollateralActivationTypes.sol
src/types/ExitBookTypes.sol
src/types/GuardianSignalsTypes.sol
src/types/SettlementTypes.sol
src/utils/AssetRecoverer.sol
src/utils/PausableUntil.sol
"

LIDO_LEND="
src/LidoLend.sol
src/libraries/ConstantsLib.sol
src/libraries/ErrorsLib.sol
src/libraries/EventsLib.sol
src/libraries/MarketParamsLib.sol
src/libraries/MathLib.sol
src/libraries/SafeTransferLib.sol
src/libraries/SharesMathLib.sol
src/libraries/UtilsLib.sol
src/libraries/periphery/MorphoBalancesLib.sol
src/libraries/periphery/MorphoLib.sol
src/libraries/periphery/MorphoStorageLib.sol
"

LIDO_LEND_IRM="
src/adaptive-curve-irm/AdaptiveCurveConfig.sol
src/adaptive-curve-irm/AdaptiveCurveIrm.sol
src/adaptive-curve-irm/libraries/AdaptiveCurveMathLib.sol
src/adaptive-curve-irm/libraries/ErrorsLib.sol
src/adaptive-curve-irm/libraries/ExpLib.sol
src/adaptive-curve-irm/libraries/MathLib.sol
src/adaptive-curve-irm/libraries/UtilsLib.sol
src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol
src/common/OwnerManagerBase.sol
src/common/OwnerManagerErrors.sol
src/irm-config-factory/IrmConfigFactory.sol
src/irm-router/IrmRouter.sol
src/irm-router/libraries/ErrorsLib.sol
src/linear-kink-irm/LinearKinkConfig.sol
src/linear-kink-irm/LinearKinkIrm.sol
src/linear-kink-irm/libraries/ErrorsLib.sol
"

# keccak256 of stdin as 0x-prefixed hex. cast reads 0x-prefixed stdin as raw bytes.
keccak() { { printf 0x; od -An -v -tx1 | tr -d ' \n'; } | cast keccak; }

# "<path in this repository> <digest>" per hashed file, for the aggregate root.
pairs=""

# Prints one report table: <name in the report> <directory here> <files relative to it>.
section() {
  local name=$1 dir=$2 files=$3 commit state path digest
  if [ -z "$ref" ]; then
    commit=$(git -C "$dir" rev-parse HEAD)
    state="checked out at $commit"
    if [ "$dir" != . ] && [ "$commit" != "$(git rev-parse "HEAD:$dir")" ]; then
      state="$state, HEAD pins $(git rev-parse "HEAD:$dir")"
    fi
    # shellcheck disable=SC2086 # one path per word
    [ -z "$(git -C "$dir" status --porcelain -- $files)" ] || state="$state, with uncommitted changes"
  elif [ "$dir" = . ]; then
    commit=$(git rev-parse "$ref^{commit}")
    state="at $commit"
  else
    commit=$(git rev-parse "$ref:$dir")
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null ||
      { echo "ERROR: $dir lacks commit $commit pinned by $ref; fetch it there first" >&2; exit 1; }
    state="at $commit"
  fi

  echo
  # shellcheck disable=SC2086 # one path per word
  echo "$name ($(echo $files | wc -w | tr -d ' ') files): $dir $state"
  printf '%-68s %s\n' File keccak256
  for path in $files; do
    if [ -z "$ref" ]; then
      [ -f "$dir/$path" ] || { echo "ERROR: $dir/$path not found" >&2; exit 1; }
      digest=$(keccak <"$dir/$path")
    else
      digest=$(git -C "$dir" cat-file blob "$commit:$path" | keccak) ||
        { echo "ERROR: $path not found in $dir at $commit" >&2; exit 1; }
    fi
    printf '%-68s %s\n' "$path" "$digest"
    if [ "$dir" = . ]; then pairs+="$path $digest"$'\n'; else pairs+="$dir/$path $digest"$'\n'; fi
  done
}

if [ -z "$ref" ]; then echo "Hashing the files on disk."; else echo "Hashing the files committed at $ref."; fi
section lido-lend-markets . "$LIDO_LEND_MARKETS"
section lido-lend lib/lend "$LIDO_LEND"
section lido-lend-irm lib/lend-irm "$LIDO_LEND_IRM"

root=$(printf '%s' "$pairs" | LC_ALL=C sort -t ' ' -k1,1 |
  awk '{ printf "%s%s  %s", (NR > 1 ? "\n" : ""), $2, $1 }' | keccak)
echo
echo "Aggregate root: $root"
