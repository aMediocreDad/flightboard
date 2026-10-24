#!/bin/bash
# record-review.sh — log one Claude review of a PR at a specific head commit.
#
#   bash record-review.sh <owner/repo> <number> <head-sha> <clean|findings> <count> [posted]
#
# Appends a row to $FLIGHTBOARD_STATE/reviews.tsv. The ledger is append-only;
# review-state.py reads the newest row per PR, and a row whose sha no longer
# matches the PR's head reads as stale. Pass `posted` when the findings went
# to GitHub as comments.

set -euo pipefail
usage="usage: bash record-review.sh <owner/repo> <number> <head-sha> <clean|findings> <count> [posted]"
repo=${1:?$usage} num=${2:?$usage} sha=${3:?$usage} verdict=${4:?$usage} count=${5:?$usage}
posted=${6:--}

[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "bad repo: $repo" >&2; exit 2; }
[[ $num =~ ^[0-9]+$ ]] || { echo "bad number: $num" >&2; exit 2; }
[[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "head sha must be the full 40-char sha: $sha" >&2; exit 2; }
[[ $verdict == clean || $verdict == findings ]] || { echo "verdict is clean or findings: $verdict" >&2; exit 2; }
[[ $count =~ ^[0-9]+$ ]] || { echo "bad count: $count" >&2; exit 2; }
[[ $verdict == clean && $count != 0 ]] && { echo "a clean review has 0 findings" >&2; exit 2; }
[[ $posted == posted || $posted == - ]] || { echo "last argument is 'posted' or nothing" >&2; exit 2; }

state=${FLIGHTBOARD_STATE:-$HOME/.claude/flightboard/state}
mkdir -p "$state"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%Y-%m-%dT%H:%MZ)" "$repo" "$num" "$sha" "$verdict" "$count" "$posted" \
  >> "$state/reviews.tsv"
echo "recorded: $repo#$num at ${sha:0:7} — $verdict ($count)"
