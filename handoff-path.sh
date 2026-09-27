# handoff-path.sh — sourced by scan-local.sh and read-handoff.sh, so the scan
# and the reader always agree on which handoff file a row means.
#
# /lead, tech-lead and /delegate write AGENT_STATUS.md, BRIEF.md and
# PR_BODY.md to the checkout's .claude/lead/; the gitdir is where older runs
# left them. .claude/lead/ wins when both exist.
#
# .claude/lead/ is not tied to a branch, so in a main checkout a finished run's
# files outlive it and would get pinned on whatever branch is checked out next
# (seen: a 22 Sep PR_BODY.md about retiring plans, attached to a 25 Sep
# logging fix). On a feature branch, a file older than the branch itself
# belongs to an earlier run and is skipped. On the default branch every file
# counts: a PR_BODY.md left there is exactly the "leftover" worth flagging.

# handoff_on_default <branch> <default>
# Prints y or n. <default> is the scan's default column ("-" when origin/HEAD
# is unknown, in which case main/master count as default).
handoff_on_default() {
  if [ -z "$2" ] || [ "$2" = "-" ]; then
    case "$1" in main|master) echo y ;; *) echo n ;; esac
  elif [ "$1" = "$2" ]; then echo y
  else echo n
  fi
}

# handoff_born <checkout> <branch> <on_default>
# Epoch seconds the branch was created: the time of its reflog's
# "branch: Created" entry (the entry's own time, not the commit it points at,
# which can be days older). Empty, so nothing is filtered, when on the
# default branch or when that entry is gone: after a partial reflog expiry
# the oldest surviving entry is some later update, and filtering against it
# would hide the current run's files.
handoff_born() {
  [ "$3" = n ] && [ -n "$2" ] || return 0
  git -C "$1" reflog show --date=unix --format='%gd%x09%gs' "refs/heads/$2" -- 2>/dev/null \
  | tail -1 \
  | awk -F'\t' '$2 ~ /^branch: Created/ { sub(/.*@\{/, "", $1); sub(/\}$/, "", $1); print $1 }'
}

# handoff_path <checkout> <gitdir> <file> <born>
# Prints the path to read for <file>, or nothing (exit 1) when there is none.
handoff_path() {
  local p
  for p in "$1/.claude/lead/$3" "$2/$3"; do
    [ -f "$p" ] || continue
    if [ -n "$4" ] && [ "$(date -r "$p" +%s)" -lt "$4" ]; then continue; fi
    printf '%s\n' "$p"
    return 0
  done
  return 1
}

# handoff_stale <checkout> <gitdir> <born>
# Prints the handoff files handoff_path skipped as older than the branch, so
# the scan can list them instead of hiding them silently.
handoff_stale() {
  local p f
  [ -n "$3" ] || return 0
  for f in AGENT_STATUS.md PR_BODY.md BRIEF.md; do
    for p in "$1/.claude/lead/$f" "$2/$f"; do
      [ -f "$p" ] && [ "$(date -r "$p" +%s)" -lt "$3" ] && printf '%s\n' "$p"
    done
  done
  return 0
}
