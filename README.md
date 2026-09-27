# Flightboard

Answers one question — *where is my work?* — across every git checkout on your
machine and every open PR on GitHub, and publishes the answer as a private
dashboard you can reopen any time.

It is **read-only**. It proposes dispositions; it never pushes, closes, merges,
deletes, or comments.

The point is the work GitHub can't see: the branch you never pushed, the PR body
an agent drafted that never became a PR, the worktree parked outside your usual
directories, the repo that only exists on this laptop. Those get sorted into
four buckets by what needs you *now*, and everything mechanical — stale
checkouts, dirty working trees, repos with no commits — is folded into
collapsed footnotes so it stays out of the way.

## Install

Requires `git`, `gh` (authenticated), `jq`, `python3`, and Claude Code.

```bash
git clone <this-repo> ~/.claude/skills/flightboard
bash ~/.claude/skills/flightboard/doctor.sh
```

Cloning into `~/.claude/skills/` is enough — Claude Code auto-loads it next
session as `flightboard@skills-dir`, including its SessionStart hook. Run
`/reload-plugins` to pick it up immediately. Clone it anywhere else and install
with `claude plugin install` instead.

`doctor.sh` checks your dependencies, that `gh` is authenticated, which
directories will be swept, and that the state directory is writable. Run it
first — most failure modes here are quiet rather than loud, and an
unauthenticated `gh` in particular produces a cheerfully empty board.

Then, in Claude Code:

```
/flightboard
```

The first run publishes a new dashboard and records its URL. Every later run
updates that same page in place.

## Configuration

**Which directories get swept.** By default it looks for `~/repos`, `~/src`,
`~/code`, `~/Projects` and `~/dev`, and searches 4 levels deep inside whichever
exist — so `~/code/my-app`, `~/repos/work/my-app` and
`~/repos/work/worktrees/my-app-fix` are all found. To set it explicitly:

```bash
mkdir -p ~/.claude/flightboard
cat > ~/.claude/flightboard/roots <<'EOF'
# one directory per line
~/work
~/oss
EOF
```

or `export FLIGHTBOARD_ROOTS=~/work:~/oss`. Check what it resolved with:

```bash
bash ~/.claude/skills/flightboard/scan-local.sh --roots
```

Linked worktrees are found through git itself, so a worktree living outside
every root still shows up — flagged, because that is usually a surprise.

**Where state lives.** `~/.claude/flightboard/state`, or `$FLIGHTBOARD_STATE`.
Deliberately outside the plugin, so updating or reinstalling never destroys
your dashboard URL, and so a copy of this repo never carries someone else's
board. Three files, all created for you:

| file | what it is |
|---|---|
| `dashboard-url` | your published dashboard. **Never copy this from someone else** — a sweep would publish over their board |
| `last-summary` | one line of counts, derived by `render.py` on every build and injected into every new session by the hook |
| `dead-rows.html` | the dead pile, cached between runs and edited in deltas |

## How it triages

| Bucket | What lands there |
|---|---|
| **Needs you now** | Failing CI, changes requested, approved-but-unmerged, a PR waiting on your review, a branch with a drafted PR body and no PR, blocked delegated work |
| **In flight** | Active in the last 14 days |
| **Going stale** | 14–56 days — one nudge each |
| **Dead pile** | Older than 56 days, grouped by repo with a suggested disposition |

Assigned issues are listed separately as a queue of work not yet started.

If you use agent handoff files — `AGENT_STATUS.md`, `BRIEF.md`, `PR_BODY.md` in
a checkout's `.claude/lead/` — they are read too, so delegated work reports its own
status without extra bookkeeping. If you don't, nothing changes; that section
simply stays empty.

## How it is built

Almost everything is mechanical, and lives in scripts rather than being
regenerated each run. Only judgment is written by hand.

| | |
|---|---|
| `scan-local.sh` | classifies every checkout; `--footnotes` renders the mechanical sections |
| `collect-github.sh` | all GitHub reads in one pass — the per-branch PR lookups are a single GraphQL query rather than one ~15s call each |
| `read-handoff.sh` | agent handoff files, capped |
| `collect.sh` | runs all three; the entire data-gathering phase in one call |
| `render.py` | `board.json` → page. Every count is an array length, so tiles cannot drift from content |
| `build.sh` | renders, then wraps in the static chrome |
| `doctor.sh` | preflight |

`page/head.html` and `page/foot.html` hold the whole design. Editing them is how
you restyle the board; nothing else touches presentation.

## Privacy

The dashboard is a private Artifact, visible only to you unless you explicitly
share it. It lists repository names, branch names, PR titles and local paths —
so treat sharing it the way you would treat sharing your terminal.
