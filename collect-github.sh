#!/bin/bash
# collect-github.sh — every GitHub read the sweep needs, in one call.
#
#   bash collect-github.sh <scan.tsv>
#
# Replaces three sequential rounds of gh calls with one. The searches run
# serially, because the search resource is 30/min and GitHub asks for serial
# requests per user; PR review/CI state fans out with xargs; and the per-branch
# "has a PR ever existed for this head?" lookups — which cost ~15s EACH as
# `gh pr list --head` — collapse into a single aliased GraphQL query (~1s
# for all of them). Takes scan-local.sh's TSV so lookups use the real repo
# slug from origin instead of a guessed owner.
#
# Run it as `bash collect-github.sh`, never under zsh: the fan-out relies on
# bash word-splitting and exported functions.
#
# Output is "### SECTION" headers followed by TSV — a table to read, not JSON.

set -o pipefail
scan=${1:?usage: bash collect-github.sh <scan.tsv>}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Any read that failed sets this. It drives a non-zero exit, so a caller can
# detect a bad sweep without parsing the output. Failures also mirror to stderr,
# which is the surface collect.sh already checks with [ -s github.err ].
collect_fail=0

# --- three searches, serially, and never silently -----------------------------
# These used to run concurrently with 2>/dev/null and no exit-code check. On a
# 403 gh exits 1 and writes a 0-byte file; `jq -r '.[]'` over 0 bytes emits
# nothing and exits 0, so the sweep rendered "no open PRs" and collect.sh's only
# error surface ([ -s github.err ]) was empty *because* of the discard. The
# search resource is 30/min and GitHub asks for serial requests per user, so
# these run in sequence (~2s), and a hard failure is loud in three ways at once:
# a marker above the empty section, the real error on stderr, and a non-zero
# exit. Success is "gh exited 0 AND the body is a JSON array", which accepts a
# legitimately empty [] and rejects a truncated or empty body. The one retry is
# for a transient 5xx or a secondary limit; it will not clear a primary 403,
# whose window is 60s. The marker, not the retry, is what does the work there.
run_search() {           # run_search <outfile> <label> -- <gh args...>
  local out=$1 label=$2; shift 3
  local err="$out.err" n
  for n in 1 2; do
    if gh "$@" > "$out" 2>"$err" && jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
      return 0
    fi
    [ "$n" = 1 ] && sleep 3
  done
  collect_fail=1
  echo "### GITHUB_SEARCH_FAILED	$label"
  sed 's/^/# /' "$err" | head -3
  echo "# This section is EMPTY BECAUSE THE QUERY FAILED, not because there is"
  echo "# nothing there. Do not publish a board from this run — re-run the sweep."
  { echo "search($label) failed:"; sed 's/^/  /' "$err" | head -3; } >&2
  echo '[]' > "$out"
}
run_search "$tmp/mine.json" my-prs -- search prs --author "@me" --state open --limit 50 \
   --json repository,number,title,updatedAt,isDraft,url
run_search "$tmp/rr.json" review-requested -- search prs --review-requested "@me" --state open --limit 30 \
   --json repository,number,title,updatedAt,url
run_search "$tmp/iss.json" assigned-issues -- search issues --assignee "@me" --state open --limit 30 \
   --json repository,number,title,updatedAt,url

echo "### MY_PRS	repo	num	updated	draft	title	url"
jq -r '.[] | [.repository.nameWithOwner, .number, (.updatedAt|split("T")[0]),
              (if .isDraft then "draft" else "-" end), .title, .url] | @tsv' "$tmp/mine.json"

echo
echo "### REVIEW_REQUESTS	repo	num	updated	title	url"
jq -r '.[] | [.repository.nameWithOwner, .number, (.updatedAt|split("T")[0]), .title, .url] | @tsv' "$tmp/rr.json"

echo
echo "### ISSUES	repo	num	updated	title	url"
jq -r '.[] | [.repository.nameWithOwner, .number, (.updatedAt|split("T")[0]), .title, .url] | @tsv' "$tmp/iss.json"

# --- review + CI state, only for PRs active within 14 days ------------------
# Fetching state for ALL open PRs is the documented mistake; filter, then fan out.
jq -r '.[] | select((.updatedAt|fromdateiso8601) > (now - 14*86400))
       | "\(.repository.nameWithOwner) \(.number)"' "$tmp/mine.json" > "$tmp/recent"

echo
echo "### PR_STATE	repo	num	head	review	mergeState	checks"
echo "# review=no-signal means the repo has no required reviews. Not a decision."
prstate() {
  gh pr view "$2" -R "$1" --json headRefName,reviewDecision,mergeStateStatus,statusCheckRollup 2>/dev/null \
  | jq -r --arg r "$1" --arg n "$2" '
      (.statusCheckRollup // []) as $c
      | ($c | map(select((.conclusion // .state // .status) == "FAILURE"))) as $bad
      | [$r, $n, .headRefName,
         (if (.reviewDecision // "") == "" then "no-signal" else .reviewDecision end),
         (.mergeStateStatus // "-"),
         (if ($c|length) == 0 then "none"
          elif ($bad|length) > 0 then "FAIL: " + ($bad | map(.name // .context) | join(","))
          else "\($c|length) ok" end)] | @tsv'
}
export -f prstate
xargs -P 8 -L1 bash -c 'prstate "$@"' _ < "$tmp/recent"

# --- has a PR ever existed for each live local branch? ----------------------
# Item rows younger than 56 days only: the dead pile is grouped, never verified.
awk -F'\t' '$2=="item" && $7>=0 && $7<=56 && $10!="-" {print $10"\t"$3}' "$scan" > "$tmp/heads.tsv"

echo
echo "### HEAD_LOOKUP	repo	branch	result"
if [ -s "$tmp/heads.tsv" ]; then
  python3 - "$tmp/heads.tsv" > "$tmp/q.graphql" <<'PY'
import sys
print("query {")
for i, line in enumerate(open(sys.argv[1])):
    slug, branch = line.rstrip("\n").split("\t")
    owner, _, name = slug.partition("/")
    print(f'  r{i}: repository(owner: "{owner}", name: "{name}") {{'
          f' defaultBranchRef {{ name }}'
          f' pullRequests(headRefName: "{branch}", first: 5,'
          f' states: [OPEN, CLOSED, MERGED],'
          f' orderBy: {{field: CREATED_AT, direction: DESC}})'
          f' {{ nodes {{ number state url }} }} }}')
print("}")
PY
  if gh api graphql -F query=@"$tmp/q.graphql" > "$tmp/heads.json" 2>"$tmp/heads.err"; then
    # A null repository means the repo does not exist — which is NOT the same as
    # "no PR yet", and drives different bucket-1 advice. gh pr list conflates them.
    # The repo node is already being fetched, so defaultBranchRef is free. It only
    # matters on NO PR — that is the branch you are about to open a PR from, and
    # `gh pr create` with no --base errors out when base would equal head. A repo
    # whose only pushed branch is the feature branch has exactly that shape.
    paste "$tmp/heads.tsv" <(jq -r '.data | to_entries[] |
      [ (if .value == null then "NO REPO (does not exist on GitHub)"
         elif (.value.pullRequests.nodes | length) == 0 then "NO PR"
         else (.value.pullRequests.nodes | map("#\(.number) \(.state) \(.url)") | join("  "))
         end),
        (.value.defaultBranchRef.name // "-") ] | @tsv' "$tmp/heads.json") \
    | awk -F'\t' -v OFS='\t' '{
        if ($3 == "NO PR" && $4 != "-")
          $3 = ($4 == $2) \
             ? $3 " (repo default IS this branch — push a base branch first, then --base it)" \
             : $3 " (base: " $4 ")"
        print $1, $2, $3 }'
  else
    collect_fail=1
    echo "# GraphQL lookup failed:"; sed 's/^/# /' "$tmp/heads.err" | head -5
    { echo "GraphQL head lookup failed:"; sed 's/^/  /' "$tmp/heads.err" | head -3; } >&2
  fi
fi

# --- does the local truth contradict the searches? ---------------------------
# The one failure mode an exit-code check cannot see is a 200 whose body is [].
# HEAD_LOOKUP is built from local branches + GraphQL, entirely independent of
# the search API, so "GraphQL found OPEN PRs but MY_PRS is empty" is a
# contradiction inside a single run. Costs no extra API call.
if [ -s "$tmp/heads.json" ]; then
  open_prs=$(jq '[.data[]? | select(. != null) | .pullRequests.nodes[]?
                  | select(.state == "OPEN")] | length' "$tmp/heads.json" 2>/dev/null || echo 0)
  my_prs=$(jq 'length' "$tmp/mine.json" 2>/dev/null || echo 0)
  if [ "${open_prs:-0}" -gt 0 ] && [ "${my_prs:-0}" -eq 0 ]; then
    collect_fail=1
    echo
    echo "### GITHUB_INCONSISTENT	HEAD_LOOKUP found $open_prs OPEN PR(s) but MY_PRS is empty"
    echo "# The searches are lying — they returned a well-formed empty result."
    echo "# Do not publish a board from this run; re-run the sweep."
    echo "HEAD_LOOKUP found $open_prs OPEN PR(s) but MY_PRS is empty" >&2
  fi
fi

# A bad sweep must be detectable without reading the output.
[ "$collect_fail" = 0 ] || exit 1
