#!/bin/bash
# flightboard-context.sh — SessionStart hook: inject the last sweep's summary
# line into session context, with a staleness nudge. Silent when no sweep has
# ever run, so a fresh install adds nothing until there is something to say.
#
# Also prints the open slugs from this repo's work ledger (ledger.py), so every
# session in the repo, a worktree's included, starts knowing what is in flight.
# SessionStart fires after compaction too, which is when that matters most.
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$common" ]; then
  now_md="$(dirname "$common")/.claude/work/NOW.md"
  if [ -f "$now_md" ]; then
    open=$(awk '/^## Open/{on=1; next} /^## /{on=0} on && /^- /' "$now_md" | grep -v '^- none$')
    if [ -n "$open" ]; then
      echo "Work ledger ($now_md), open in this repo:"
      echo "$open" | head -8
    fi
  fi
fi

f="${FLIGHTBOARD_STATE:-$HOME/.claude/flightboard/state}/last-summary"
[ -f "$f" ] || exit 0
line=$(head -1 "$f")
[ -n "$line" ] || exit 0
now=$(date +%s)
mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "$now")
age_days=$(( (now - mtime) / 86400 ))
if [ "$age_days" -ge 2 ]; then
  echo "Flightboard (STALE — last sweep ${age_days}d ago; suggest /flightboard when asked about in-flight work): $line"
else
  echo "Flightboard: $line"
fi
