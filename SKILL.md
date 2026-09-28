---
name: flightboard
description: Use when the user asks what they are working on, what needs their attention, for a standup / status report / triage of in-flight work, or when a session should refresh the work dashboard — pending PRs, review requests, local feature branches, worktrees, stale branches.
---

# Standup

## Overview

One pass that answers "where is my work?" across every checkout under
the configured roots and every open PR on GitHub, triaged by what needs
the user now.
It reads the handoff files agents already write (`AGENT_STATUS.md`,
`PR_BODY.md`, `BRIEF.md` in each checkout's `.claude/lead/`) so delegated work surfaces
without extra bookkeeping. **Read-only**: it proposes dispositions, it
never pushes, closes, deletes, or comments.

The scripts own everything mechanical — classifying rows, batching the
GitHub reads, rendering the footnotes, holding the page's chrome. Spend
your turn on the part that needs judgment: which items need the user today
and what they should do about them.

`<skill-dir>` below is this skill's own directory — the base directory named
when the skill is invoked. Substitute it; do not type it literally, and do not
use `${CLAUDE_PLUGIN_ROOT}`, which is only expanded inside `hooks.json`.

State — the dashboard URL, the ambient summary line, the cached dead pile —
lives in `$FLIGHTBOARD_STATE`, default `~/.claude/flightboard/state`, outside
the plugin. Never write state into the plugin directory: an update would wipe
it, and a copy of the plugin would carry someone else's board.

## Collect

Two things, **both in the same message** — they do not depend on each other:

1. `bash <skill-dir>/collect.sh <scratchpad>/flightboard`

   The whole data-gathering phase in one call (~10s). Prints the item rows,
   the GitHub state, the dead-pile delta, and the handoff files. Leaves
   `scan.tsv` and `footnotes.html` there for the Deliver phase. Run it with
   `bash`, never under the session's zsh — the fan-out needs bash
   word-splitting.

2. Artifact `action: "read"` on the URL in
   `$FLIGHTBOARD_STATE/dashboard-url`.

   **Do this now, not at publish time.** The previous sweep published from
   a different session, so the publish will be refused until you have viewed
   the live version — three wasted round-trips and two full-page dumps if you
   discover it at the end. Read it here and the publish goes through first try.
   You are rebuilding the page from fresh data, so nothing needs merging;
   the read exists to satisfy the view requirement and to show you what is
   already on the board.

**A `### GITHUB_SEARCH_FAILED` or `### GITHUB_INCONSISTENT` marker in that
output means stop — do not publish.** An empty `MY_PRS` reads exactly like a
quiet week, so the collector says so itself rather than letting you infer it:
the section is empty because the query died, not because the work does not
exist. One dead search also empties `PR_STATE`, which derives from it. Only
the searches need redoing, so re-run the GitHub half alone:
`bash <skill-dir>/collect-github.sh <scratchpad>/flightboard/scan.tsv`.

**A `### TOWER_FAILED` marker also means stop — do not publish.** Tower's
ledger could not be read, so an empty promise list would read as "nothing
promised". `### TOWER_ABSENT` is fine: tower is not installed, skip its cards.

**Tower promises** (from `### TOWER`, the output of `tower list --json`):
- When the JSON has a `needs_you` array (tower phase 2 and later), make one
  `needsYou` card per item: title = `title`, meta = `kind` plus `detail` when
  it is not empty, `command` = `command` when it is not null. Tower has
  already merged pending approvals, due and failed promises, blockers
  ("unlock YubiKey: blocks 2 runs"), deadlines within 3 days, orphan
  worktrees and its own errors into that list, so do **not** also derive
  cards from `promises`, `deadlines` or `errors`. If `runs.open` has rows
  with `status: "running"`, add the para "N tower runs in progress".
- Without `needs_you` (a phase-1 tower), derive the cards instead:
  - Each promise with `status: "due"` → a `needsYou` card: title = the
    promise title, meta = repo · branch · trigger, `command` =
    `tower promise done <id>`.
  - Each promise with `approval: "pending"` → a `needsYou` card with
    `chip: "approve"` and `command` = `tower promise approve <id>`; quote the
    check command in a para so Filip sees what he approves.
  - Each deadline with `overdue: true` → a `needsYou` card (`chip: "overdue"`).
  - Any `errors` → one `needsYou` card titled "Tower errors", one para per error.
- Waiting promises (both versions) → `"promises": {"waiting": [{"repo": "<repo>", "count": <n>}]}`.

Item rows carry `ahead` (commits ahead of the **default** branch — the number
a card quotes, not `unpushed`, which counts against the branch's own upstream)
and `dirty_files` (up to 3 uncommitted paths, so a card can name what a PR
would leave out). Neither needs a `git` call of your own.

If a card needs a row that `collect.sh` did not print, it is in `scan.tsv`.
Column 1 is an absolute path. `bash scan-local.sh --roots` shows which roots
are being swept and where that setting came from — the first thing to check if
a sweep finds less than expected.

## What is an item

Buckets hold **work in progress**: open PRs, and local rows that
qualify. Assigned issues are never bucket items — they go to the
**Issue queue** (work not yet started).

`scan-local.sh` computes this and prints it as the `kind` column, so do
not re-derive it per row. `collect.sh` prints only `kind=item` rows; every
other row is already handled — `omit` never appears anywhere, and
`scrap` / `localonly` / `mess` / `leftover` / `oddball` are rendered into
the footnotes mechanically.

What the classifier means, for when you need to reason about an edge:
a row is an **item** if its branch differs from the repo's default, or it
is local-only (no upstream) with a commit ≤ 14 days — work that exists
nowhere but this machine. Detached HEADs and linked worktrees parked
outside the swept paths are oddballs, never items. When a repo has no
`origin/HEAD` and no main/master, the checked-out branch may *be* the
default: propose "verify default branch", never deletion.

**One item per piece of work.** A local branch and the PR whose head
matches it are the same item — show the PR, note the local path. The
`### HEAD_LOOKUP` section already answers "has a PR ever existed for this
branch?" for every live item; `NO REPO` there means the repo does not exist
on GitHub at all, which is a different situation from `NO PR`.

## Triage

Cutoffs count from the item's last activity (PR `updated`, or the `age_d`
column).

| Bucket | Rule |
|---|---|
| **1 Needs you now** | Any of: `review` exactly `CHANGES_REQUESTED`; a `FAIL:` in the `checks` column; `APPROVED` but unmerged; a PR awaiting the user's review; `AGENT_STATUS.md` state `blocked`; **drafted-never-shipped** — an item with `PR_BODY.md` whose `HEAD_LOOKUP` starts `NO PR` or `NO REPO` (the `NO PR` line also carries the repo's default branch, which the card's `gh pr create` needs as `--base`). A merged/closed PR there instead means the work landed: the whole row leaves the buckets → footnote it, delete file + branch |
| **2 In flight** | Active ≤ 14 days, no bucket-1 signal |
| **3 Going stale** | 14–56 days — one nudge line each |
| **4 Dead pile** | > 56 days — dead pieces grouped by repo (a repo's live items stay in their own buckets), one suggested disposition per group: close PR / delete branch / revive. `### DEAD_DELTA` names every row to add or drop; do not re-derive it by eye |

An `AGENT_STATUS.md` state `in-flight` or `ready-for-review` means a
delegated task — flag it in its bucket with the status line's content.

A landed branch that is merely still checked out is not in flight. Group
those into one footnote rather than a bucket; all that is left is
`git checkout <default>`.

## Deliver

Order of operations: triage → dashboard → sign-off.

**The dashboard is the whole deliverable.** There is no terminal summary:
do not restate bucket 1 in the reply. That means a bucket-1 card has to
stand on its own — the item, why it needs him, and the one command to act,
all on the card. Anything you would have said in the terminal belongs in
`paras` or `note`.

**Dashboard.** Write only `board.json` — content, no markup:

```jsonc
{
  "generated": "2026-08-25 17:09 UTC",          // required
  "needsYou": [{                                 // bucket 1, rendered as cards
    "title": "…", "url": "…",                    // url links the whole title;
    "chip": "CI failing",                        //   for a partial link, write
    "chipClass": "critical",                     //   [text](url) in the title
    "meta": "branch `x` · updated … · ~/path",
    "paras": ["…", "…"],
    "note": "…",                                 // optional, muted
    "html": "…",                                 // optional raw-HTML escape hatch
    "command": "the one command to act"          // optional, <pre><code>
  }],
  "inFlight": [{                                 // bucket 2, one table row each
    "item": "#42 fix: the PR title", "url": "…",
    "sub": "branch or local path, shown small",
    "repo": "my-app", "date": "2026-08-25",
    "chip": "awaiting review", "chipClass": "active",
    "status": "5 checks green"
  }],
  "stale": [],                                   // bucket 3, same row shape
  "issues": { "rows": [], "note": "…", "label": "…" },  // note shows when rows
                                                 //   is empty; label renames
                                                 //   the heading suffix
  "promises": { "waiting": [{ "repo": "heimdal", "count": 2 }] },  // optional; from ### TOWER
  "footnotes": [{ "summary": "…", "items": ["…"], "note": "…",
                  "count": "— 1 ready, 2 blocked" }]  // count is DERIVED from
                                 //   items — pass it only to say something a
                                 //   bare number cannot
}
```

Prose fields take inline markdown — `` `code` ``, `[text](url)`, `**bold**`,
`*italic*` — which is ~35% fewer tokens than the equivalent HTML, mostly
because it avoids escaping `"` inside every JSON string. Raw HTML still
passes through if you need it.

`chipClass` is one of `critical` / `active` / `hold` / `dead`, defaulting to
`critical` on cards and `active` on rows. Anything else is a hard error.

Then assemble and publish:

```bash
bash <skill-dir>/build.sh <scratchpad>/board.json \
     <scratchpad>/flightboard/footnotes.html > <scratchpad>/flightboard.html
```

- **A card's command must parse.** These forms are verified; use them
  instead of spending a round trip on `--help`:
  `gh pr create --base <b> --head <h> --title "…" --body-file <f>`
  (`-B/-H/-t/-F`; without `--base` gh resolves base == head and errors, which
  is what `HEAD_LOOKUP`'s `repo default IS this branch` warns about),
  `gh repo edit <slug> --default-branch <name>`, `gh pr list -R <slug>`.
  `/lead <intent>` reads `.claude/lead/BRIEF.md` on its own.
- **Never type a count.** Every tile number and section heading is derived
  from an array length by `render.py`. That is the point of the schema.
  Footnote counts default to `— <len(items)>` too, so omit `count` unless the
  summary genuinely needs prose ("1 ready for review, 2 blocked").
- Hand-written `footnotes` render **before** the generated `footnotes.html`,
  which is appended verbatim. So write only the complement: the delegated-work,
  landed-but-parked and leftover blocks. Re-writing a section `footnotes.html`
  already renders ships it twice.
- `page/head.html` and `page/foot.html` hold the title, fonts, the whole
  stylesheet and the standing explainer. **Never hand-write them** — that
  is ~200 lines of retyping per run. Change them only to change the design,
  and then load `artifact-design` first.
- `$FLIGHTBOARD_STATE/dead-rows.html` is the dead pile, cached between runs as
  raw `<tr>` rows, in date order. **Edit the deltas, never regenerate.**
  `### DEAD_DELTA` in the collect output already computed them: one `MISSING`
  line per item that crossed 56 days with no row, one `REVIVED` line per row
  whose branch is live again. They are candidates, not verdicts — a repo
  renamed on GitHub reads as `MISSING` when its row is filed under the old
  name — so check each against the dead table before adding it.
- A malformed `board.json` fails with a line number and emits nothing, so a
  broken build never publishes a half-page. Fix the JSON; do not fall back
  to hand-writing HTML.
- Publish with the Artifact tool, passing the URL from
  `$FLIGHTBOARD_STATE/dashboard-url` as `url` so it updates in place. Title
  `Flightboard`, favicon `🛫` — both stable across runs. If the state file
  is somehow missing, publish new and write the returned URL to it.

**Ambient state line.** Nothing to do — `build.sh` writes
`$FLIGHTBOARD_STATE/last-summary` for you, because those five counts are the
same array lengths the tiles use and a hand-typed one can drift. A SessionStart
hook injects the line into every new session, so read it back if you want to
quote it in the sign-off; do not rewrite it.

**Sign-off.** Reply with the dashboard URL, the one-line counts you just
wrote to `last-summary`, and nothing else — plus, only if it applies, the
judgment calls you made and anything the sweep could not determine. The
cards carry the rest.

## Common mistakes

- Re-deriving what the `kind` column already decided, or hand-writing the
  footnotes — `scan-local.sh --footnotes` renders them, and is more accurate
  than doing it by eye.
- Regenerating the stylesheet, the dead pile, or the footnotes into a
  fresh page. Only `board.json` is written by hand.
- Typing a bucket count anywhere. They are computed from array lengths;
  a hand-typed number is a number that can drift.
- Discovering the view-before-publish requirement at publish time instead
  of reading the artifact during Collect.
- Publishing a board whose GitHub sections came back empty. "No open PRs and
  no assigned issues" is a plausible-looking board and a silent failure looks
  exactly like it; open PRs in `HEAD_LOOKUP` alongside an empty `MY_PRS` is a
  contradiction, not a quiet week.
- Treating `review: no-signal` or `checks: none` as a bucket-1 signal —
  they mean the repo has no required reviews and no checks have registered
  yet. Empty is not a decision. A PR opened minutes ago legitimately has
  no checks.
- Acting on the dead pile. Propose; the user disposes.
- Publishing without `url`, which forks the dashboard.
- Running `git ls-remote` (or any pushing/fetching git command) against a
  `~/repos/work` checkout. SSH there is passphrase-gated and the prompt cannot
  reach the user from a tool shell, so the call hangs until it times out — two
  minutes of wall clock for a question `gh api` answers instantly. `HEAD_LOOKUP`
  already carries the remote's default branch; ask GitHub, not the remote.
- Restating bucket 1 in the terminal. The dashboard is the deliverable.
