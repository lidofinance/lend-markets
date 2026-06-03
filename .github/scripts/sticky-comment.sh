#!/usr/bin/env bash
# Post or update a single ("sticky") PR comment, identified by a marker line.
#
# Usage: sticky-comment.sh <pr-number> <marker> <body-file>
#   - <marker>     HTML comment used as the comment's identity (must appear on the first line).
#   - <body-file>  File whose contents become the comment body (marker is prepended).
#
# Required env: GH_TOKEN (or GITHUB_TOKEN), GITHUB_REPOSITORY (set by Actions).
set -euo pipefail

pr="${1:?usage: sticky-comment.sh <pr> <marker> <body-file>}"
marker="${2:?marker required}"
body_file="${3:?body file required}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"

if [ ! -f "$body_file" ]; then
  echo "body file not found: $body_file" >&2
  exit 1
fi

body=$(printf '%s\n\n%s' "$marker" "$(cat "$body_file")")

existing=$(gh api --paginate "repos/${repo}/issues/${pr}/comments" \
  --jq ".[] | select(.body | startswith(\"${marker}\")) | .id" | head -n 1 || true)

if [ -n "$existing" ]; then
  gh api -X PATCH "repos/${repo}/issues/comments/${existing}" -f body="$body" >/dev/null
  echo "Updated sticky comment ${existing} on PR #${pr}"
else
  gh pr comment "$pr" --repo "$repo" --body "$body" >/dev/null
  echo "Created sticky comment on PR #${pr}"
fi
