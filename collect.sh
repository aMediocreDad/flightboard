#!/bin/bash
# collect.sh — the sweep's entire data-gathering phase, in one call.
#
#   bash collect.sh [outdir]        # default outdir: a fresh temp dir
#
# Runs the local scan, then the GitHub batch and the handoff reader against it
# — the last two concurrently, since neither needs the other. Prints only what
# needs judging: item rows, GitHub state, the dead-pile delta, handoff files.
# The omitted and footnoted rows are handled mechanically and never printed.
#
# Leaves two files behind for the Deliver phase:
#   $outdir/scan.tsv        full scan, if a card needs a row that was not printed
#                          (column 1 is an absolute path; no repo root is assumed)
#   $outdir/footnotes.html  mechanical footnotes, second argument to build.sh
#
# Run as `bash collect.sh`, never under zsh.

set -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=${1:-$(mktemp -d)}
mkdir -p "$out"

bash "$here/scan-local.sh" > "$out/scan.tsv"
bash "$here/scan-local.sh" --footnotes > "$out/footnotes.html" &
bash "$here/collect-github.sh" "$out/scan.tsv" > "$out/github.txt" 2>"$out/github.err" &
bash "$here/read-handoff.sh" "$out/scan.tsv" > "$out/handoff.txt" &
wait

echo "# outdir: $out"
echo "# scan.tsv: $(wc -l < "$out/scan.tsv" | tr -d ' ') rows · footnotes.html ready for build.sh"
echo
echo "### ITEMS	path	kind	branch	default	dirty	last	age_d	unpushed	handoff	repo	rel	ahead	dirty_files"
awk -F'\t' '$2=="item"' "$out/scan.tsv"
echo
cat "$out/github.txt"
[ -s "$out/github.err" ] && { echo; echo "### GITHUB_ERRORS"; head -5 "$out/github.err"; }
echo
echo "### DEAD_DELTA"
bash "$here/scan-local.sh" --dead-check "$out/scan.tsv"

echo
echo "### HANDOFF"
cat "$out/handoff.txt"
