#!/usr/bin/env python3
"""Work ledger: track code-changing work per repo, so it outlives sessions and worktrees.

Every piece of work that edits code is a "slug". The ledger lives in the repo's main
checkout under .claude/work/ (kept out of git through .git/info/exclude), whichever
worktree the edit happened in, so one place shows what is happening in the repo:

  NOW.md          one screen: open slugs, recently closed ones, recent decisions
  log.md          one appended line per event
  decisions.md    one appended line per judgment call, tagged with its slug
  slugs/<id>.md   per slug: what was asked, then one entry per turn that touched it
  slugs/<id>/     copies of a worktree run's .claude/lead/ files, so they survive
                  the worktree being removed
  state.json      the machine state behind all of the above

Events (hooks.json wires them):
  edit   PreToolUse on Edit|Write|MultiEdit|NotebookEdit: opens a slug on the first code
         edit by this session in a checkout, and records the file. Never blocks.
  prebash / postbash   Pre- and PostToolUse on Bash: code written or committed through
         the shell (heredocs, sed -i, scripts) opens and fills a slug the same way.
  Gitignored files never count.
  stop   Stop and SubagentStop: updates each open slug of this session from git (dirty
         files, commits since it opened, .claude/lead/VERDICT.md), records the
         "Judgment calls" bullets of the last message, closes slugs whose files are
         committed and clean, and rewrites NOW.md.

Questions and research that change no code never open a slug. Every failure is
swallowed: the ledger must never get in the way of the work it records.
"""
import datetime
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys

# Structured config (.yaml, .json, .toml) counts as code: Helm values and whoami.yaml are
# real work. Prose, images and lockfiles do not.
NON_CODE_EXT = {".md", ".mdx", ".txt", ".rst", ".lock", ".csv", ".svg", ".png", ".jpg",
                ".webp", ".gif"}
NON_CODE_NAMES = {"package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Cargo.lock", "go.sum",
                  "uv.lock", "poetry.lock", ".gitignore"}
LEAD_FILES = ("BRIEF.md", "VERIFICATION.md", "VERDICT.md", "REVIEW.md", "AGENT_STATUS.md",
              "PR_BODY.md")
WORK = os.path.join(".claude", "work")
CLOSED_SHOWN = 5
DECISIONS_SHOWN = 10


def stamp():
    return datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M")


def git(root, *args):
    try:
        r = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def checkout_root(path):
    d = path if os.path.isdir(path) else os.path.dirname(path)
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    out = git(d, "rev-parse", "--show-toplevel") if d else None
    return os.path.realpath(out.strip()) if out else None


def main_root(root):
    """The main checkout that owns this (possibly linked) worktree."""
    common = git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not common:
        return root
    common = os.path.realpath(common.strip())
    return os.path.dirname(common) if os.path.basename(common) == ".git" else root


def is_code(rel):
    parts = rel.split(os.sep)
    if ".claude" in parts:
        return False
    name = parts[-1]
    if name in NON_CODE_NAMES or name.startswith(".env"):
        return False
    return os.path.splitext(name)[1].lower() not in NON_CODE_EXT


def ensure_excluded(main):
    out = git(main, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude")
    if not out:
        return
    path = out.strip()
    lines = open(path).read().splitlines() if os.path.exists(path) else []
    if ".claude/work/" not in lines:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write("\n# flightboard work ledger\n.claude/work/\n")


class Ledger:
    def __init__(self, main):
        self.main = main
        self.dir = os.path.join(main, WORK)
        os.makedirs(os.path.join(self.dir, "slugs"), exist_ok=True)
        self.lock = open(os.path.join(self.dir, ".lock"), "w")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            with open(os.path.join(self.dir, "state.json")) as f:
                self.state = json.load(f)
        except (OSError, ValueError):
            self.state = {}
        self.state.setdefault("slugs", {})
        self.state.setdefault("decisions", [])

    def close(self, changed=True):
        if changed:
            tmp = os.path.join(self.dir, "state.json.tmp")
            with open(tmp, "w") as f:
                json.dump(self.state, f, indent=1)
            os.replace(tmp, os.path.join(self.dir, "state.json"))
            self.write_now()
        fcntl.flock(self.lock, fcntl.LOCK_UN)
        self.lock.close()

    def append(self, name, line):
        with open(os.path.join(self.dir, name), "a") as f:
            f.write(line.rstrip("\n") + "\n")

    def where(self, root):
        return "main checkout" if root == self.main else root.replace(os.path.expanduser("~"), "~")

    def open_slug(self, session, root, title_of, base=None):
        """title_of is called only when a new slug opens: reading the transcript is not free."""
        for sid, s in self.state["slugs"].items():
            if s["session"] == session and s["root"] == root and s["status"] != "done":
                return sid, s
        title = title_of()
        day = datetime.datetime.now().strftime("%m%d")
        sid = f"S-{day}-{1 + sum(1 for k in self.state['slugs'] if k.startswith(f'S-{day}-'))}"
        branch = (git(root, "branch", "--show-current") or "").strip() or "(detached)"
        s = {"title": title, "session": session, "root": root, "branch": branch,
             "base": base or (git(root, "rev-parse", "HEAD") or "").strip(), "opened": stamp(),
             "updated": stamp(), "status": "open", "files": [], "commits": [], "verdict": None}
        self.state["slugs"][sid] = s
        self.append("log.md", f"- {stamp()} {sid} opened · {branch} · {self.where(root)} · {title}")
        with open(os.path.join(self.dir, "slugs", f"{sid}.md"), "w") as f:
            f.write(f"# {sid}: {title}\n\n- Opened: {s['opened']}\n- Where: {self.where(root)}\n"
                    f"- Branch: {branch}\n- Session: {session}\n")
        return sid, s

    def write_now(self):
        slugs = self.state["slugs"]
        open_ = sorted(((k, v) for k, v in slugs.items() if v["status"] != "done"),
                       key=lambda kv: kv[1]["opened"])
        done = sorted(((k, v) for k, v in slugs.items() if v["status"] == "done"),
                      key=lambda kv: kv[1]["updated"], reverse=True)[:CLOSED_SHOWN]
        out = [f"# Work in {os.path.basename(self.main)}", f"Updated: {stamp()}", "", "## Open"]
        for k, v in open_:
            verdict = f" · verdict {v['verdict']}" if v.get("verdict") else ""
            out.append(f"- {k} · {v['status']}{verdict} · {v['branch']} @ {self.where(v['root'])} · "
                       f"{len(v['files'])} files · since {v['opened']} · {v['title']}")
        if not open_:
            out.append("- none")
        out += ["", "## Recently closed"]
        out += [f"- {k} · {v['updated']} · {v['branch']} · "
                f"{', '.join(v['commits'][-2:]) or 'no commits'} · {v['title']}" for k, v in done]
        if not done:
            out.append("- none")
        out += ["", "## Recent decisions"]
        out += [f"- {d}" for d in self.state["decisions"][-DECISIONS_SHOWN:]] or ["- none"]
        out += ["", "History: log.md, decisions.md and slugs/ beside this file."]
        tmp = os.path.join(self.dir, "NOW.md.tmp")
        with open(tmp, "w") as f:
            f.write("\n".join(out) + "\n")
        os.replace(tmp, os.path.join(self.dir, "NOW.md"))


def last_user_prompt(transcript):
    """The newest prompt the user typed, as one line, for the slug title."""
    title = None
    try:
        with open(transcript, errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("type") != "user" or e.get("isMeta"):
                    continue
                c = (e.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = " ".join(b.get("text", "") for b in c
                                 if isinstance(b, dict) and b.get("type") == "text")
                if not isinstance(c, str):
                    continue
                # A slash command arrives wrapped: keep "/lead port the paths", drop the rest.
                cmd = re.search(r"<command-name>\s*(/?[^<]*?)\s*</command-name>", c)
                args = re.search(r"<command-args>(.*?)</command-args>", c, flags=re.S)
                if cmd:
                    c = f"{cmd.group(1)} {args.group(1) if args else ''}"
                else:
                    c = re.sub(r"<([a-z-]+)[^>]*>.*?</\1>", " ", c, flags=re.S)
                c = c.strip()
                if c and not (cmd and not (args and args.group(1).strip())):
                    title = c
    except (OSError, TypeError):
        pass
    title = " ".join((title or "untitled work").split())
    return title[:90] + ("…" if len(title) > 90 else "")


def judgment_calls(message):
    """Bullets under a "Judgment calls" heading in the agent's final message."""
    calls, inside = [], False
    for line in (message or "").splitlines():
        s = line.strip()
        if re.match(r"^(#+\s*|\d+\.\s*)?\**\s*judgment calls", s, re.I):
            inside = True
            continue
        if inside:
            if s.startswith(("- ", "* ")):
                calls.append(" ".join(s[2:].split()))
            elif s and not s.startswith(" "):
                if calls or s.startswith(("#", "**")):
                    break
    return calls


def edited_path(data):
    ti = data.get("tool_input") or {}
    path = ti.get("file_path") or ti.get("notebook_path")
    if not path:
        return None
    return os.path.realpath(os.path.join(data.get("cwd") or os.getcwd(), path))


def ignored(root, rel):
    return git(root, "check-ignore", "-q", "--", rel) is not None


def record(data, root, rels, base=None):
    """Open (or reuse) this session's slug in root's checkout and add the code files."""
    rels = [r for r in rels if is_code(r) and not ignored(root, r)]
    if not rels:
        return
    main = main_root(root)
    ensure_excluded(main)
    session = data.get("session_id", "unknown")
    remember_main(session, main)
    led = Ledger(main)
    try:
        _, s = led.open_slug(session, root, lambda: last_user_prompt(data.get("transcript_path")),
                             base)
        for rel in rels:
            if rel not in s["files"]:
                s["files"].append(rel)
        s["updated"] = stamp()
    finally:
        led.close()


def on_edit(data):
    path = edited_path(data)
    root = checkout_root(path) if path else None
    if root:
        record(data, root, [os.path.relpath(path, root)])


# Sessions often write code through Bash (heredocs, sed -i, scripts) and commit there.
# Before each Bash call, snapshot the cwd checkout's HEAD and dirty files; after it,
# whatever became dirty or got committed in between is this session's work.

def snapshot(root):
    head = (git(root, "rev-parse", "HEAD") or "").strip()
    status = git(root, "status", "--porcelain", "--untracked-files=all") or ""
    return head, sorted(ln[3:].split(" -> ")[-1].strip().strip('"')
                        for ln in status.splitlines() if ln.strip())


def snapshot_path(session):
    return session_index(session)[:-4] + ".bash.json"


def on_prebash(data):
    root = checkout_root(data.get("cwd") or "")
    if not root:
        return
    head, dirty = snapshot(root)
    with open(snapshot_path(data.get("session_id", "unknown")), "w") as f:
        json.dump({"root": root, "head": head, "dirty": dirty}, f)


def on_postbash(data):
    p = snapshot_path(data.get("session_id", "unknown"))
    try:
        with open(p) as f:
            pre = json.load(f)
    except (OSError, ValueError):
        return
    root = pre["root"]
    if not os.path.isdir(root):
        return
    head, dirty = snapshot(root)
    rels = set(dirty) - set(pre["dirty"])
    if head and pre["head"] and head != pre["head"]:
        out = git(root, "diff", "--name-only", pre["head"], head) or ""
        rels |= {ln.strip() for ln in out.splitlines() if ln.strip()}
    if rels:
        record(data, root, sorted(rels), base=pre["head"] or None)


def on_stop(data):
    session = data.get("session_id", "unknown")
    calls = judgment_calls(data.get("last_assistant_message"))
    for main in dict.fromkeys(session_mains(session, data.get("cwd"))):
        if not os.path.exists(os.path.join(main, WORK, "state.json")):
            continue
        led = Ledger(main)
        changed = False
        try:
            # Every open slug is refreshed from git, not only this session's: a slug whose
            # session ended before its commit would otherwise stay open forever. Judgment
            # calls belong to this session's slugs only.
            for sid, s in led.state["slugs"].items():
                if s["status"] != "done":
                    changed |= update_slug(led, sid, s, calls if s["session"] == session else [])
        finally:
            led.close(changed)


def update_slug(led, sid, s, calls):
    """Refresh one slug from git. Returns whether anything changed; writes only then."""
    root, files = s["root"], s["files"]
    if not os.path.isdir(root):
        s.update(status="done", updated=stamp())
        led.append("log.md", f"- {stamp()} {sid} closed · worktree gone")
        return True
    status = git(root, "status", "--porcelain", "--", *files) if files else ""
    dirty = [ln[3:].strip() for ln in (status or "").splitlines() if ln.strip()]
    log = git(root, "log", "--format=%h %s", f"{s['base']}..HEAD", "--", *files) \
        if files and s.get("base") else ""
    commits = [c for c in (log or "").splitlines() if c.strip()]
    verdict = None
    vpath = os.path.join(root, ".claude", "lead", "VERDICT.md")
    if os.path.exists(vpath):
        first = open(vpath, errors="replace").read().strip().splitlines()[:1]
        verdict = first[0][:60] if first else None
    new = "in progress" if dirty else "done" if commits else "no changes left"
    hashes = [c.split()[0] for c in commits]
    # A subagent's report is often relayed again by its parent: record each call once.
    recorded = {d.split(": ", 1)[-1] for d in led.state["decisions"] if f" {sid}: " in d}
    calls = [c for c in calls if c not in recorded]
    moved = new != s["status"] or verdict != s.get("verdict") or hashes != s.get("commits")
    if not moved and not calls:
        return False
    entry = [f"\n## {stamp()} · {new}"]
    if dirty:
        entry.append(f"- Uncommitted: {', '.join(dirty[:8])}")
    if commits:
        entry.append(f"- Commits: {'; '.join(commits[:8])}")
    if verdict:
        entry.append(f"- Verdict: {verdict}")
    entry += [f"- Judgment call: {c}" for c in calls]
    with open(os.path.join(led.dir, "slugs", f"{sid}.md"), "a") as f:
        f.write("\n".join(entry) + "\n")
    for c in calls:
        line = f"{stamp()} {sid}: {c}"
        led.state["decisions"].append(line)
        led.append("decisions.md", f"- {line}")
    if root != led.main:
        copy_lead(led, sid, root)
    if new != s["status"] or verdict != s.get("verdict"):
        led.append("log.md", f"- {stamp()} {sid} {new}"
                   + (f" · verdict {verdict}" if verdict else "")
                   + (f" · {commits[0]}" if commits else ""))
    s.update(status=new, verdict=verdict, commits=hashes, updated=stamp())
    return True


def copy_lead(led, sid, root):
    src = os.path.join(root, ".claude", "lead")
    if not os.path.isdir(src):
        return
    dst = os.path.join(led.dir, "slugs", sid)
    os.makedirs(dst, exist_ok=True)
    for name in LEAD_FILES:
        if os.path.exists(os.path.join(src, name)):
            shutil.copy2(os.path.join(src, name), os.path.join(dst, name))


def session_index(session):
    base = os.path.join(os.environ.get("TMPDIR") or "/tmp", "flightboard-ledger")
    os.makedirs(base, exist_ok=True)
    safe = "".join(c for c in str(session) if c.isalnum() or c in "-_") or "unknown"
    return os.path.join(base, f"{safe}.txt")


def remember_main(session, main):
    p = session_index(session)
    known = open(p).read().splitlines() if os.path.exists(p) else []
    if main not in known:
        with open(p, "a") as f:
            f.write(main + "\n")


def session_mains(session, cwd):
    """Main checkouts that can hold this session's slugs: recorded ones, plus the cwd's."""
    p = session_index(session)
    mains = open(p).read().splitlines() if os.path.exists(p) else []
    root = checkout_root(cwd) if cwd else None
    if root:
        mains.append(main_root(root))
    return mains


def main():
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        data = json.load(sys.stdin)
        if event == "edit":
            on_edit(data)
        elif event == "prebash":
            on_prebash(data)
        elif event == "postbash":
            on_postbash(data)
        elif event == "stop":
            on_stop(data)
    except Exception as exc:  # the ledger never blocks the work it records
        print(f"ledger: {type(exc).__name__}: {exc}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
