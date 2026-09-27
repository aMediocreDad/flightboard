#!/bin/bash
# read-handoff.sh — print the agent handoff files, excerpted head and tail.
#
#   bash read-handoff.sh <scan.tsv>
#
# AGENT_STATUS.md is short and every line matters, so it prints whole.
# BRIEF.md and PR_BODY.md exist to be long: the sweep only needs enough to
# say what the work is and which PR it belongs to, so they are excerpted.
# Reading them in full cost ~41KB of context on the run that motivated this.
#
# The excerpt takes the head AND the tail, because a head-only cap reads the
# wrong end. A PR body opens by describing the change and closes with the fact
# that decides its bucket: what is deliberately unfinished, what it is blocked
# on, which open PR it stacks under. One sweep classified a leftover PR_BODY.md
# as drafted-never-shipped territory and was saved only by the closing sentence
# "the doc consolidation land in follow-up PRs stacked on this one", at byte
# 1357 of a 1392B file. Thirty-five bytes of margin under the old 1600B head
# cap. Head+tail is both smaller and lands on the sentence that matters.
#
# Column 1 of the scan is an absolute path, so no repo root is assumed here.
# Files are read from the checkout's .claude/lead/; the gitdir is where older
# runs left them.

set -o pipefail
scan=${1:?usage: bash read-handoff.sh <scan.tsv>}
HEAD_B=${HEAD_B:-800}
TAIL_B=${TAIL_B:-400}

awk -F'\t' '$9!="-" {print $1"\t"$9}' "$scan" | while IFS=$'\t' read -r d files; do
  gd=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null) || continue
  echo "########## $(printf '%s' "$d" | sed "s|^$HOME|~|")"
  IFS=',' read -ra fs <<< "$files"
  for f in "${fs[@]}"; do
    p="$d/.claude/lead/$f"; [ -f "$p" ] || p="$gd/$f"
    [ -f "$p" ] || continue
    size=$(wc -c < "$p" | tr -d ' ')
    if [ "$f" = AGENT_STATUS.md ] || [ "$size" -le "$((HEAD_B + TAIL_B))" ]; then
      # Short enough that an excerpt would print most of it twice.
      echo "----- $f (${size}B, full) -----"; cat "$p"
    else
      echo "----- $f (${size}B, first ${HEAD_B}B + last ${TAIL_B}B) -----"
      head -c "$HEAD_B" "$p"
      printf '\n…[%sB elided from the middle; read the file directly if a card needs it]\n\n' \
             "$((size - HEAD_B - TAIL_B))"
      tail -c "$TAIL_B" "$p"
      echo
    fi
    echo
  done
done
