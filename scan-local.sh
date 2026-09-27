#!/bin/bash
# scan-local.sh — inventory every git checkout under the configured roots,
# pre-classified.
#
#   bash scan-local.sh             # TSV, one row per checkout
#   bash scan-local.sh --items     # TSV, only rows that are triage items
#   bash scan-local.sh --footnotes # ready-to-paste <details> blocks
#   bash scan-local.sh --roots     # show which roots are configured, and why
#   bash scan-local.sh --dead-check <scan.tsv> [dead-rows.html]
#                                  # reconcile the cached dead pile against the
#                                  # scan: rows to add, rows that came back
#
# WHERE IT LOOKS, in order:
#   $FLIGHTBOARD_ROOTS                       colon-separated list of directories
#   ~/.claude/flightboard/roots              one directory per line, # for comments
#   $HOME/repos, src, code, Projects, dev    whichever exist
# Depth defaults to 4 below each root, so a flat ~/code/<repo> layout and a
# nested ~/repos/<area>/<repo> or ~/repos/<area>/worktrees/<name> one both work.
# Override with $FLIGHTBOARD_DEPTH.
#
# Columns: path kind branch default dirty last_iso age_days unpushed handoff
#          repo_slug rel ahead dirty_files
#   path      absolute path to the checkout
#   rel       path relative to its root; its first segment groups the footnotes
#
# kind — the row's disposition, computed here so the caller never re-derives it:
#   item      triage it: branch differs from default, or local-only with a commit <= 14d
#   scrap     no commits at all
#   localonly no upstream anywhere, and too old to be an item
#   mess      dirty on its default branch
#   leftover  PR_BODY.md sitting on the default branch
#   oddball   detached HEAD
#   omit      clean on default with an upstream — the common, boring case
# Order matters: scrap > oddball > item > localonly > mess > leftover > omit.
#
# default: from origin/HEAD, else "-" (main/master treated as default then).
# unpushed: commits ahead of upstream, "all" when the branch has no upstream.
# ahead: commits ahead of the DEFAULT branch — the number a card actually quotes
#   ("2 commits ahead of origin/main"). Not the same as unpushed, which counts
#   against the branch's own upstream and says "all" when there isn't one.
# dirty_files: up to 3 uncommitted paths, so a card can name what a PR would
#   leave out without the caller shelling out for `git status`.
# Both are computed for item rows only — they are per-item detail, and paying
# for them across every checkout under the roots would dominate the scan.
# handoff: comma-joined AGENT_STATUS.md / PR_BODY.md / BRIEF.md in the checkout's
#          .claude/lead/ (older runs: its gitdir). On a feature branch, files
#          older than the branch are an earlier run's and are left out; see
#          handoff-path.sh.
# repo_slug: owner/repo parsed from origin, "-" when there is no remote. The
#   caller needs this to hit the GitHub API without guessing owners.

set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/handoff-path.sh"
mode=${1:-}
now=$(date +%s)
depth=${FLIGHTBOARD_DEPTH:-4}
conf="${FLIGHTBOARD_CONFIG:-$HOME/.claude/flightboard}/roots"

roots() {
  if [ -n "${FLIGHTBOARD_ROOTS:-}" ]; then
    printf '%s\n' "$FLIGHTBOARD_ROOTS" | tr ':' '\n'
  elif [ -r "$conf" ]; then
    grep -v '^[[:space:]]*\(#\|$\)' "$conf"
  else
    for d in "$HOME/repos" "$HOME/src" "$HOME/code" "$HOME/Projects" "$HOME/dev"; do
      [ -d "$d" ] && echo "$d"
    done
  fi
}

# Where the roots came from, so a first run that finds nothing can say why.
roots_source() {
  if [ -n "${FLIGHTBOARD_ROOTS:-}" ]; then echo "\$FLIGHTBOARD_ROOTS"
  elif [ -r "$conf" ]; then echo "$conf"
  else echo "autodetected (no \$FLIGHTBOARD_ROOTS, no $conf)"
  fi
}

# Every checkout under every root. A worktree's .git is a FILE, not a directory,
# so this must not filter on -type d, or every worktree silently disappears.
discover() {
  while IFS= read -r root; do
    [ -d "$root" ] || continue
    root=${root%/}
    find "$root" -maxdepth "$depth" \
         \( -name node_modules -o -name .venv -o -name vendor -o -name target \) -prune \
         -o -name .git -print 2>/dev/null \
    | while IFS= read -r g; do
        d=$(dirname "$g")
        printf '%s\t%s\n' "$root" "$d"
        # A worktree nested inside its repo (.claude/worktrees/<name>, where
        # /delegate parks its runs) sits below the depth cap. Ask git for the
        # linked worktrees so each gets a full row, not just the @WT footnote.
        # Only those under this root: one parked outside every root is what the
        # @WT footnote exists to flag. Every live worktree is also recorded in
        # $wtl, so the footnote needs no second `git worktree list` per checkout.
        # A registered worktree whose directory is gone (prunable) is skipped.
        git -C "$d" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree /{sub(/^worktree /, ""); print}' \
        | while IFS= read -r wt; do
            [ -d "$wt" ] || continue
            printf '%s\n' "$wt" >> "$wtl"
            case "$wt" in "$root"/*) printf '%s\t%s\n' "$root" "$wt" ;; esac
          done
      done
  done < <(roots) | sort -u -t$'\t' -k2,2
}

# --- dead-pile reconciliation ----------------------------------------------
# Reads a scan.tsv rather than re-scanning, so this is free to run inside
# collect.sh. The cached dead pile is edited by hand between runs, which is
# exactly why it drifts: a branch crosses 56 days and nothing adds its row.
#
# Matching is deliberately lopsided. A false "MISSING" costs one glance; a
# false "covered" leaves a row absent forever, which is the bug being fixed.
# So a row counts as covered on a branch-name, repo-slug or (>=4 char) leaf
# match, and REVIVED keys off the branch name ALONE — a repo can legitimately
# have a dead PR row and a live branch at the same time.
if [ "$mode" = "--dead-check" ]; then
  scan=${2:?usage: bash scan-local.sh --dead-check <scan.tsv> [dead-rows.html]}
  state="${FLIGHTBOARD_STATE:-$HOME/.claude/flightboard/state}"
  dead=${3:-$state/dead-rows.html}
  if [ ! -r "$dead" ]; then
    echo "# no cached dead pile at $dead — nothing to reconcile"
    exit 0
  fi
  echo "# MISSING = item older than 56 days with no row in dead-rows.html; add one."
  echo "# REVIVED = a dead row whose branch is live again; delete that row."
  echo "# Candidates, not verdicts — a repo renamed on GitHub can read as MISSING."
  awk -F'\t' '$2=="item" && $7>=0' "$scan" \
  | while IFS=$'\t' read -r p k br def dty iso age unp files slug rel ahead dfiles; do
      br_hit=n
      [ -n "$br" ] && grep -qF -- "$br" "$dead" && br_hit=y
      hit=$br_hit
      if [ "$hit" = n ] && [ "$slug" != "-" ]; then
        grep -qF -- "$slug" "$dead" && hit=y
      fi
      leaf=${rel##*/}
      if [ "$hit" = n ] && [ "${#leaf}" -ge 4 ]; then
        grep -qF -- "$leaf" "$dead" && hit=y
      fi
      if [ "$age" -gt 56 ] && [ "$hit" = n ]; then
        [ "$dty" = y ] && d=dirty || d=clean
        printf 'MISSING\t%s\t%s\t%s\t%sd\t%s\t%s\n' "$rel" "$br" "$iso" "$age" "$d" "$slug"
      elif [ "$age" -le 56 ] && [ "$br_hit" = y ]; then
        printf 'REVIVED\t%s\t%s\t%s\t%sd\n' "$rel" "$br" "$iso" "$age"
      fi
    done
  exit 0
fi

wtl=$(mktemp); known=$(mktemp); trap 'rm -f "$wtl" "$known"' EXIT
pairs=$(discover)
printf '%s\n' "$pairs" | cut -f2 > "$known"

scan() {
  while IFS=$'\t' read -r root d; do
    [ -n "$d" ] || continue
    (
      rel=${d#"$root"/}
      [ "$rel" = "$d" ] && rel=$(basename "$d")

      branch=$(git -C "$d" branch --show-current 2>/dev/null)
      default=$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
      default=${default#origin/}
      dirty=n
      [ -n "$(git -C "$d" status --porcelain 2>/dev/null | head -1)" ] && dirty=y
      last_iso=$(git -C "$d" log -1 --format=%cs 2>/dev/null || echo '-')
      last_epoch=$(git -C "$d" log -1 --format=%ct 2>/dev/null || echo 0)
      if git -C "$d" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        unpushed=$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')
      else
        unpushed=all
      fi
      slug=$(git -C "$d" remote get-url origin 2>/dev/null \
             | sed -E 's#^(git@[^:]+:|ssh://[^/]+/|https?://[^/]+/)##; s#\.git$##')
      [ -n "$slug" ] || slug='-'

      if [ "$last_epoch" -gt 0 ]; then
        age=$(( (now - last_epoch) / 86400 ))
      else
        age=-1
      fi

      # Is the checked-out branch the repo's default?
      on_default=$(handoff_on_default "$branch" "${default:--}")

      # Handoff files: .claude/lead/ first, gitdir for older runs, and on a
      # feature branch only files younger than the branch (handoff-path.sh).
      # The skipped ones go out as @ST lines for the footnotes, not dropped.
      gd=$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)
      born=$(handoff_born "$d" "$branch" "$on_default")
      files=""
      for f in AGENT_STATUS.md PR_BODY.md BRIEF.md; do
        handoff_path "$d" "$gd" "$f" "$born" >/dev/null && files="${files}${f},"
      done
      files=${files%,}
      handoff_stale "$d" "$gd" "$born" | while IFS= read -r sp; do
        printf '@ST\t%s\t%s\n' "$sp" "${branch:--detached-}"
      done

      if [ "$last_epoch" -eq 0 ]; then          kind=scrap
      elif [ -z "$branch" ]; then               kind=oddball
      elif [ "$on_default" = n ]; then          kind=item
      elif [ "$unpushed" = all ] && [ "$age" -le 14 ]; then kind=item
      elif [ "$unpushed" = all ]; then          kind=localonly
      elif [ "$dirty" = y ]; then               kind=mess
      elif [[ ",$files," == *,PR_BODY.md,* ]]; then kind=leftover
      else                                      kind=omit
      fi

      # Per-item detail. Computed after kind so the 100+ non-item checkouts
      # under a typical set of roots never pay for it.
      ahead='-'; dirty_files='-'
      if [ "$kind" = item ]; then
        cands=""
        [ -n "$default" ] && [ "$default" != "-" ] && cands="origin/$default $default"
        for cand in $cands origin/main origin/master main master; do
          if git -C "$d" rev-parse --verify --quiet "$cand^{commit}" >/dev/null 2>&1; then
            ahead=$(git -C "$d" rev-list --count "$cand..HEAD" 2>/dev/null || echo '-')
            break
          fi
        done
        if [ "$dirty" = y ]; then
          n=$(git -C "$d" status --porcelain 2>/dev/null | grep -c .)
          dirty_files=$(git -C "$d" status --porcelain 2>/dev/null | head -3 \
                        | sed 's/^...//' | paste -sd, -)
          [ "$n" -gt 3 ] && dirty_files="$dirty_files,+$((n-3)) more"
        fi
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$d" "$kind" "${branch:--detached-}" "${default:--}" \
        "$dirty" "$last_iso" "$age" "$unpushed" "${files:--}" "$slug" "$rel" \
        "$ahead" "${dirty_files:--}"
    ) &
    while [ "$(jobs -rp | wc -l)" -ge 12 ]; do wait -n 2>/dev/null || break; done
  done <<< "$pairs"
  wait
}

if [ "$mode" = "--roots" ]; then
  echo "source: $(roots_source)"
  echo "depth:  $depth"
  roots | sed 's/^/  /'
  echo "checkouts found: $(printf '%s\n' "$pairs" | grep -c .)"
  exit 0
fi

all=$(scan)
rows=$(printf '%s\n' "$all" | grep -v '^@ST	' | sort -t$'\t' -k1,1)
# Handoff files skipped as older than their branch: an earlier run's, left in
# .claude/lead/ (or the gitdir). Listed so they get deleted, not just hidden.
stale=$(printf '%s\n' "$all" | grep '^@ST	' | sort -u -t$'\t' -k2,2)

# Linked worktrees can live anywhere. discover() recorded every live one in
# $wtl; those that got no row (outside every root) are parked somewhere
# unswept, which is exactly what the @WT footnote surfaces.
stray=$(sort -u "$wtl" | grep -vxF -f "$known" | while IFS= read -r wt; do
  wb=$(git -C "$wt" branch --show-current 2>/dev/null)
  wi=$(git -C "$wt" log -1 --format=%cs 2>/dev/null)
  printf '@WT\t%s\t%s\t%s\n' "$wt" "${wb:--detached-}" "${wi:--}"
done)

short() { printf '%s' "$1" | sed "s|^$HOME|~|"; }

case "$mode" in
  --items)
    printf '%s\n' "$rows" | awk -F'\t' '$2=="item"'
    ;;
  --footnotes)
    # The mechanical footnote groups: a pure function of the columns above, so
    # the caller pastes this verbatim instead of re-deriving it by eye.
    group() { printf '%s\n' "$rows" | awk -F'\t' -v k="$1" '$2==k{print $1"\t"$6"\t"$5}'; }
    c() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | grep -c .; }

    # Names for a kind, grouped by the first segment of the relative path, so a
    # nested <root>/<area>/<repo> layout keeps its areas while a flat
    # <root>/<repo> one renders as a single ungrouped list.
    names_grouped() {
      printf '%s\n' "$rows" | awk -F'\t' -v k="$1" '
        $2==k {
          rel=$11; sub(/\/$/,"",rel)
          n=split(rel,a,"/")
          if (n>=2) { g=a[1]; nm=substr(rel,length(g)+2) } else { g=""; nm=rel }
          if (!(g in seen)) { order[++cnt]=g; seen[g]=1 }
          list[g] = (list[g] ? list[g] ", " : "") nm
        }
        END { for (i=1;i<=cnt;i++) { g=order[i]
                 printf "    <li>%s%s</li>\n", (g=="" ? "" : g ": "), list[g] } }'
    }

    lo=$(group localonly); ms=$(group mess); sc=$(group scrap)
    od=$(group oddball);   lf=$(group leftover)

    if [ -n "$lo" ]; then
      echo "<details>"
      echo "  <summary>Local-only repos <span class=\"count\">— $(c "$lo"), never pushed anywhere</span></summary>"
      echo "  <ul>"
      printf '%s\n' "$lo" | sort -t$'\t' -k2,2r | while IFS=$'\t' read -r p iso dty; do
        [ "$dty" = y ] && d=", dirty" || d=""
        echo "    <li><code>$(short "$p")</code> — last commit ${iso}${d}</li>"
      done
      echo "  </ul>"
      echo "</details>"
    fi
    if [ -n "$ms" ]; then
      echo "<details>"
      echo "  <summary>Local mess <span class=\"count\">— $(c "$ms") checkouts dirty on their default branch</span></summary>"
      echo "  <ul>"
      names_grouped mess
      echo "  </ul>"
      echo "</details>"
    fi
    if [ -n "$sc" ]; then
      echo "<details>"
      echo "  <summary>Scraps <span class=\"count\">— $(c "$sc") repos with no commits</span></summary>"
      echo "  <ul>"
      names_grouped scrap
      echo "  </ul>"
      echo "</details>"
    fi
    if [ -n "$od$lf$stray$stale" ]; then
      echo "<details>"
      echo "  <summary>Oddballs <span class=\"count\">— $(( $(c "$od") + $(c "$lf") + $(c "$stray") + $(c "$stale") ))</span></summary>"
      echo "  <ul>"
      printf '%s\n' "$od" | grep -q . && printf '%s\n' "$od" | while IFS=$'\t' read -r p iso _; do
        echo "    <li><code>$(short "$p")</code> — detached HEAD, last commit ${iso}. Re-checkout its default branch.</li>"
      done
      printf '%s\n' "$lf" | grep -q . && printf '%s\n' "$lf" | while IFS=$'\t' read -r p iso _; do
        # On the default branch nothing is age-filtered, so born is empty.
        pb=$(handoff_path "$p" "$(git -C "$p" rev-parse --absolute-git-dir 2>/dev/null)" PR_BODY.md "")
        echo "    <li><code>$(short "$p")</code> — <code>$(short "$pb")</code> left behind while sitting on the default branch (${iso}).</li>"
      done
      printf '%s\n' "$stray" | grep -q . && printf '%s\n' "$stray" | while IFS=$'\t' read -r _ wt wb wi; do
        echo "    <li><code>$(short "$wt")</code> — linked worktree outside the swept roots, on <code>${wb}</code> (${wi}).</li>"
      done
      printf '%s\n' "$stale" | grep -q . && printf '%s\n' "$stale" | while IFS=$'\t' read -r _ sp sb; do
        echo "    <li><code>$(short "$sp")</code> — from an earlier run: older than <code>${sb}</code>, the branch now checked out there. Delete it.</li>"
      done
      echo "  </ul>"
      echo "</details>"
    fi
    ;;
  *)
    printf '%s\n' "$rows"
    ;;
esac
