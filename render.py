#!/usr/bin/env python3
"""render.py — turn board.json into the Flightboard page body.

    python3 render.py board.json dead-rows.html footnotes.html [last-summary]

Writes the page body (everything between page/head.html and page/foot.html)
to stdout. Invoked by build.sh; not usually run directly.

Why JSON and not hand-written HTML: every count on the page is derived from
an array length here, so the tiles, the section headings and the footnote
summaries cannot drift from the content the way hand-typed numbers do. The
wrappers — cards, tables, chips, details blocks — are structure, not judgment,
so they live in this file instead of being retyped each run.

Prose fields accept inline HTML (<code>, <a>, <strong>). Anything this schema
cannot express goes in a card's optional "html" field, which is emitted
verbatim after its paragraphs.
"""

import html
import json
import re
import sys

CHIP_CLASSES = {"critical", "active", "hold", "dead"}

_CODE = re.compile(r"`([^`]+)`")
_LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_BOLD = re.compile(r"\*\*([^*]+)\*\*")
_ITAL = re.compile(r"\*([^*]+)\*")


def md(s):
    """Inline markdown for prose fields: `code`, [text](url), **bold**, *italic*.

    Raw HTML still passes through untouched — this only spares the author the
    `\"` escaping that dominates an HTML-in-JSON string. Code spans are pulled
    out first so their contents are never re-processed.
    """
    if not isinstance(s, str):
        return s
    spans = []

    def stash(m):
        spans.append(m.group(1))
        return f"\x00{len(spans) - 1}\x00"

    s = _CODE.sub(stash, s)
    s = _LINK.sub(lambda m: f'<a href="{esc(m.group(2))}">{m.group(1)}</a>', s)
    s = _BOLD.sub(r"<strong>\1</strong>", s)   # before italic: ** would match * twice
    s = _ITAL.sub(r"<em>\1</em>", s)
    return re.sub(r"\x00(\d+)\x00",
                  lambda m: f"<code>{html.escape(spans[int(m.group(1))])}</code>", s)


def fail(msg):
    sys.exit(f"render.py: {msg}")


def esc(s):
    """Escape a value used as an HTML attribute. Prose is trusted as markup."""
    return html.escape(str(s), quote=True)


def chip(text, cls):
    if cls not in CHIP_CLASSES:
        fail(f"unknown chip class {cls!r} — expected one of {sorted(CHIP_CLASSES)}")
    return f'<span class="chip {cls}">{text}</span>'


def link(text, url):
    return f'<a href="{esc(url)}">{text}</a>' if url else text


def heading(anchor, label, count):
    return (f'<h2 id="{anchor}"><a href="#{anchor}">■ {label}</a>'
            f'<span class="count">{count}</span></h2>')


def render_cards(cards):
    out = []
    for c in cards:
        for req in ("title", "meta"):
            if req not in c:
                fail(f"needsYou card missing required field {req!r}: {c.get('title', c)!r}")
        title = link(md(c["title"]), c.get("url"))
        if c.get("chip"):
            title += " " + chip(c["chip"], c.get("chipClass", "critical"))
        out.append('<div class="card">')
        out.append(f'  <h3>{title}</h3>')
        out.append(f'  <div class="meta">{md(c["meta"])}</div>')
        for p in c.get("paras", []):
            out.append(f'  <p>{md(p)}</p>')
        if c.get("html"):
            out.append("  " + c["html"])
        if c.get("note"):
            out.append(f'  <p class="note">{md(c["note"])}</p>')
        if c.get("command"):
            out.append(f'  <pre><code>{html.escape(c["command"], quote=False)}</code></pre>')
        out.append("</div>")
        out.append("")
    return out


def render_rows(rows):
    """One <tr> per item. Shared by the in-flight and going-stale tables."""
    out = []
    for r in rows:
        item = link(md(r["item"]), r.get("url"))
        if r.get("sub"):
            item += f'<span class="path">{md(r["sub"])}</span>'
        status = md(r.get("status", ""))
        if r.get("chip"):
            status = chip(r["chip"], r.get("chipClass", "active")) + (f" {status}" if status else "")
        out.append(f'    <tr><td>{item}</td><td>{r.get("repo", "")}</td>'
                   f'<td class="date">{r.get("date", "")}</td><td>{status}</td></tr>')
    return out


def render_table(headers, body_lines):
    out = ['<div class="tablewrap"><table>',
           "  <thead><tr>" + "".join(f"<th>{h}</th>" for h in headers) + "</tr></thead>",
           "  <tbody>"]
    out += body_lines
    out += ["  </tbody>", "</table></div>", ""]
    return out


def main():
    if len(sys.argv) not in (4, 5):
        fail("usage: render.py board.json dead-rows.html footnotes.html [last-summary]")
    board_path, dead_path, foot_path = sys.argv[1:4]
    summary_path = sys.argv[4] if len(sys.argv) == 5 else None

    try:
        with open(board_path, encoding="utf-8") as f:
            b = json.load(f)
    except json.JSONDecodeError as e:
        fail(f"{board_path} is not valid JSON: line {e.lineno} col {e.colno}: {e.msg}")
    except OSError as e:
        fail(str(e))

    if "generated" not in b:
        fail('board.json needs a "generated" timestamp, e.g. "2026-08-25 17:09 UTC"')

    dead_rows = open(dead_path, encoding="utf-8").read().rstrip("\n")
    footnotes = open(foot_path, encoding="utf-8").read().rstrip("\n")

    needs = b.get("needsYou", [])
    flight = b.get("inFlight", [])
    stale = b.get("stale", [])
    issues = b.get("issues", {})
    issue_rows = issues.get("rows", [])
    n_dead = dead_rows.count("<tr>")

    o = []

    # Header. Every tile number is a length, never a typed literal.
    o.append("<header>")
    o.append(f'  <span class="eyebrow">Last sweep · {b["generated"]} · read-only'
             " — every disposition is a proposal</span>")
    o.append('  <h1><span class="fav">🛫</span>Flightboard</h1>')
    o.append('  <div class="tiles">')
    for cls, n, label, anchor in (("critical", len(needs), "Needs you now", "now"),
                                  ("active", len(flight), "In flight", "flight"),
                                  ("hold", len(stale), "Going stale", "stale"),
                                  ("dead", n_dead, "Dead pile", "dead"),
                                  ("", len(issue_rows), "Issue queue", "issues")):
        c = f" {cls}" if cls else ""
        o.append(f'    <a class="tile{c}" href="#{anchor}">'
                 f'<span class="n">{n}</span><span class="l">{label}</span></a>')
    o.append("  </div>")
    o.append("</header>")
    o.append("")

    o.append(heading("now", "Needs you now", len(needs)))
    o.append("")
    o += render_cards(needs) if needs else [
        '<p style="color: var(--muted);">Nothing is blocked on you.</p>', ""]

    waiting = b.get("promises", {}).get("waiting", [])
    if waiting:
        total = sum(w["count"] for w in waiting)
        o.append(heading("promises", "Promises waiting", f"{total} · tower"))
        o += render_table(["Repo", "Waiting"], [
            f'    <tr><td>{esc(w["repo"])}</td><td>{w["count"]}</td></tr>' for w in waiting])

    o.append(heading("flight", "In flight", f"{len(flight)} · active ≤ 14 days"))
    o += (render_table(["Item", "Repo", "Last activity", "Status"], render_rows(flight))
          if flight else
          ['<p style="color: var(--muted);">Nothing active in the last two weeks.</p>', ""])

    o.append(heading("stale", "Going stale", f"{len(stale)} · 14–56 days"))
    o += (render_table(["Item", "Repo", "Last activity", "Nudge"], render_rows(stale))
          if stale else
          ['<p style="color: var(--muted);">Nothing in the window — everything is'
           " either fresh or long dead.</p>", ""])

    o.append(heading("dead", "Dead pile", f"{n_dead} repo groups · &gt; 56 days · proposals only"))
    # A fresh install has no dead pile yet; an empty table skeleton reads as a bug.
    o += (render_table(["Repo", "What", "Last activity", "Proposed"], [dead_rows])
          if n_dead else
          ['<p style="color: var(--muted);">Nothing older than 56 days yet.</p>', ""])

    # "label" lets an install name its own delegation command; not every setup
    # has one, so the default says nothing about tooling.
    issue_label = issues.get("label", "unstarted")
    o.append(heading("issues", "Issue queue", f"{len(issue_rows)} {issue_label}"))
    if issue_rows:
        o += render_table(["Issue", "Repo", "Last activity"], [
            f'    <tr><td>{link(md(r["item"]), r.get("url"))}</td>'
            f'<td>{r.get("repo", "")}</td><td class="date">{r.get("date", "")}</td></tr>'
            for r in issue_rows])
    if issues.get("note"):
        o.append(f'<p style="color: var(--muted);">{md(issues["note"])}</p>')
        o.append("")

    o.append('<h2 id="notes">■ Footnotes</h2>')
    for fn in b.get("footnotes", []):
        if "summary" not in fn:
            fail(f"footnote missing 'summary': {fn!r}")
        items = fn.get("items", [])
        # An explicit count wins; otherwise it is the number of items listed.
        count = fn.get("count", f"— {len(items)}")
        o.append("<details>")
        o.append(f'  <summary>{md(fn["summary"])} <span class="count">{count}</span></summary>')
        if items:
            o.append("  <ul>")
            o += [f"    <li>{md(i)}</li>" for i in items]
            o.append("  </ul>")
        if fn.get("note"):
            o.append(f'  <p class="note">{md(fn["note"])}</p>')
        o.append("</details>")
    o.append(footnotes)

    # The ambient state line is five counts and a date — all of them already
    # derived above. Hand-typing it was the last place a number on this page
    # could drift from the content it describes, so it is written here instead.
    if summary_path:
        with open(summary_path, "w", encoding="utf-8") as f:
            f.write(f"{len(needs)} need you · {len(flight)} in flight · "
                    f"{len(stale)} stale · {n_dead} dead · {len(issue_rows)} issues"
                    f" · swept {b['generated'].split()[0]}\n")

    sys.stdout.write("\n".join(o) + "\n")


if __name__ == "__main__":
    main()
