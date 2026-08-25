#!/bin/bash
# doctor.sh — check that this machine can actually run a sweep.
#
#   bash doctor.sh
#
# Four of the five ways a sweep fails are quiet rather than loud: an
# unauthenticated gh returns empty JSON that reads as "no PRs", a missing jq
# kills collect-github.sh mid-pipe, and roots that match nothing produce a
# cheerful empty board. So check them up front and say what to do about each.

state="${FLIGHTBOARD_STATE:-$HOME/.claude/flightboard/state}"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail=0

ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✘\033[0m %s\n     → %s\n' "$1" "$2"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n     → %s\n' "$1" "$2"; }

echo "Flightboard doctor"
echo
echo "Dependencies"
for c in git jq python3 gh; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c ($(command -v "$c"))"
  else
    case $c in
      jq)      bad "jq not found"      "brew install jq — collect-github.sh cannot parse without it" ;;
      gh)      bad "gh not found"      "brew install gh, then: gh auth login" ;;
      python3) bad "python3 not found" "install Python 3 — render.py builds the page" ;;
      git)     bad "git not found"     "install git" ;;
    esac
  fi
done

echo
echo "GitHub"
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh is authenticated as $(gh api user --jq .login 2>/dev/null || echo '?')"
  else
    bad "gh is not authenticated" "gh auth login — without it every search returns empty and the board looks falsely quiet"
  fi
fi

echo
echo "Roots"
bash "$here/scan-local.sh" --roots | sed 's/^/  /'
found=$(bash "$here/scan-local.sh" --roots | awk '/checkouts found:/{print $3}')
if [ "${found:-0}" -eq 0 ]; then
  bad "no git checkouts found" "set FLIGHTBOARD_ROOTS, or write one directory per line to ~/.claude/flightboard/roots"
elif [ "${found:-0}" -lt 3 ]; then
  warn "only $found checkout(s) found" "if that seems low, check the roots above and \$FLIGHTBOARD_DEPTH (currently ${FLIGHTBOARD_DEPTH:-4})"
else
  ok "$found checkouts discoverable"
fi

echo
echo "State  ($state)"
mkdir -p "$state" 2>/dev/null
if [ -w "$state" ]; then ok "writable"; else bad "not writable" "check permissions on $state"; fi
if [ -s "$state/dashboard-url" ]; then
  ok "dashboard: $(head -1 "$state/dashboard-url")"
else
  ok "no dashboard yet — the first sweep publishes one and records its URL here"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "Ready. Run /flightboard in Claude Code."
else
  echo "Fix the ✘ items above, then re-run: bash doctor.sh"
  exit 1
fi
