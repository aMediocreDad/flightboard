#!/bin/bash
# build.sh — assemble the Flightboard page from its parts.
#
#   bash build.sh <board.json> <footnotes.html> > flightboard.html
#
# board.json is the only part written by hand each run: bucket 1's cards, the
# in-flight and going-stale rows, the issue queue, and any footnote that
# carries judgment. Everything else is assembled here:
#
#   page/head.html          title, fonts, the whole stylesheet   (static)
#   page/foot.html          the standing explainer               (static)
#   $STATE/dead-rows.html   the dead pile, cached between runs   (edit deltas)
#   $STATE/last-summary     ambient counts, written by render.py  (derived)
#   <footnotes.html>        from scan-local.sh --footnotes       (generated)
#
# STATE lives OUTSIDE this directory — see state_dir() below — so that
# reinstalling or updating the plugin never clobbers your dashboard URL, and so
# that a clone of this repo never carries someone else's board.
#
# render.py derives every count on the page from an array length, so the tiles
# and section headings cannot drift from the content they describe.

set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
board=${1:?usage: bash build.sh <board.json> <footnotes.html>}
foot=${2:?usage: bash build.sh <board.json> <footnotes.html>}

state="${FLIGHTBOARD_STATE:-$HOME/.claude/flightboard/state}"
mkdir -p "$state"
rows="$state/dead-rows.html"
# A fresh install has no dead pile yet. Absent means zero rows, not an error:
# hard-failing here would make a first run unable to produce a page at all.
[ -f "$rows" ] || : > "$rows"

for f in "$board" "$foot" "$here/page/head.html" "$here/page/foot.html"; do
  [ -r "$f" ] || { echo "build.sh: missing or unreadable: $f" >&2; exit 1; }
done

# Render first, so a malformed board.json fails before anything is emitted.
# render.py also writes $state/last-summary — the SessionStart hook's counts are
# the same five array lengths the tiles use, so they are derived, never typed.
body=$(python3 "$here/render.py" "$board" "$rows" "$foot" "$state/last-summary")

cat "$here/page/head.html"
printf '%s\n' "$body"
cat "$here/page/foot.html"
