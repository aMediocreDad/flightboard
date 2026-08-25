#!/bin/bash
# flightboard-context.sh — SessionStart hook: inject the last sweep's summary
# line into session context, with a staleness nudge. Silent when no sweep has
# ever run, so a fresh install adds nothing until there is something to say.
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
