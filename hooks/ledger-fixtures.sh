#!/usr/bin/env bash
# Fixture table for hooks/ledger.py and the flightboard scripts that read its NOW.md.
# Usage: bash hooks/ledger-fixtures.sh   (from the repo root; needs git and jq)
cd "$(dirname "$0")/.." || exit 1
FB=$PWD
L="$FB/hooks/ledger.py"
W=$(mktemp -d "${TMPDIR:-/tmp}/ledger-fixtures.XXXXXX"); trap 'chmod -R u+w "$W"; rm -rf "$W"' EXIT
W=$(cd "$W" && pwd -P)
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"
pass=0; fail=0
check(){ name=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); m=ok; else fail=$((fail+1)); m=FAIL; fi
  printf '%-4s %s\n' $m "$name"; }
mkrepo(){ r=$1; mkdir -p "$r/src" "$r/docs"
  git -C "$r" init -q -b main; git -C "$r" config user.email t@t; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false
  printf 'a\n' > "$r/src/app.js"; echo doc > "$r/docs/x.md"
  git -C "$r" add -A; git -C "$r" commit -qm init; }
transcript(){ t="$W/$1.jsonl"
  { echo '{"type":"user","message":{"content":"older ask"}}'
    jq -cn --arg c "$2" '{type:"user",message:{content:$c}}'
    echo '{"type":"user","message":{"content":[{"type":"tool_result","content":"noise"}]}}'
    echo '{"type":"user","message":{"content":"<command-name>/gs</command-name>"}}'; } > "$t"
  echo "$t"; }
edit(){ jq -n --arg s "$1" --arg f "$2" --arg c "$3" --arg t "${4:-}" \
  '{session_id:$s,cwd:$c,transcript_path:$t,tool_name:"Edit",tool_input:{file_path:$f}}' \
  | python3 -I "$L" edit; }
stop(){ jq -n --arg s "$1" --arg c "$2" --arg m "${3:-}" \
  '{session_id:$s,cwd:$c,last_assistant_message:$m,stop_hook_active:false}' \
  | python3 -I "$L" stop; }
state(){ jq -r "$2" "$1/.claude/work/state.json"; }

R="$W/repo"; mkrepo "$R"
T=$(transcript s1 "fix the   roll clamp")

# Opening slugs
edit s1 "$R/docs/x.md" "$R" "$T"
check "docs edit opens no slug"                     test ! -e "$R/.claude/work"
edit s1 "$W/loose.js" "$W" "$T"
check "edit outside git opens no slug"              test ! -e "$W/.claude/work"
edit s1 "$R/src/app.js" "$R" "$T"
check "code edit opens a slug"                      test "$(state "$R" '.slugs|length')" = 1
check "slug title is the newest typed prompt"       test "$(state "$R" '.slugs[].title')" = "fix the roll clamp"
check "NOW.md lists it as open"                     grep -q "S-.* · open · main @ main checkout · 1 files" "$R/.claude/work/NOW.md"
check "log.md has the opening line"                 grep -q "opened · main · main checkout · fix the roll clamp" "$R/.claude/work/log.md"
check ".claude/work is excluded from git"           test -z "$(git -C "$R" status --porcelain)"
edit s1 "$R/src/other.js" "$R" "$T"
check "second file, same session: same slug"        test "$(state "$R" '.slugs|length')" = 1
check "second file recorded"                        test "$(state "$R" '.slugs[].files|length')" = 2
edit s2 "$R/src/app.js" "$R" "$T"
check "another session opens its own slug"          test "$(state "$R" '.slugs|length')" = 2

# Stop: status from git, decisions from the message
MSG=$'Done.\n\n## Judgment calls made\n- Clamped at -1 and 1, the rules\' range.\n- Kept the old field name.\n\n## Decisions needed\n- Ship? yes / no'
echo b >> "$R/src/app.js"
stop s1 "$R" "$MSG"
S1=$(jq -r '.slugs|to_entries[]|select(.value.session=="s1")|.key' "$R/.claude/work/state.json")
check "dirty files: in progress"                    test "$(state "$R" ".slugs[\"$S1\"].status")" = "in progress"
check "judgment calls land in decisions.md"         grep -q "$S1: Clamped at -1 and 1" "$R/.claude/work/decisions.md"
check "only the judgment-call bullets are taken"    test "$(grep -c "$S1" "$R/.claude/work/decisions.md")" = 2
check "NOW.md shows recent decisions"               grep -q "Kept the old field name" "$R/.claude/work/NOW.md"
git -C "$R" commit -qam "clamp the roll"
stop s1 "$R" "all set"
check "committed and clean: done"                   test "$(state "$R" ".slugs[\"$S1\"].status")" = done
check "done slug lists its commit"                  test "$(state "$R" ".slugs[\"$S1\"].commits|length")" = 1
check "NOW.md moves it to recently closed"          grep -A3 "^## Recently closed" "$R/.claude/work/NOW.md" | grep -q "$S1"
check "log.md records done with the commit"         grep -q "$S1 done · .* clamp the roll" "$R/.claude/work/log.md"
check "slug file has one entry per turn"            test "$(grep -c '^## ' "$R/.claude/work/slugs/$S1.md")" = 2
RV="$W/revert"; mkrepo "$RV"
edit s5 "$RV/src/app.js" "$RV" "$T"; echo x >> "$RV/src/app.js"; stop s5 "$RV" ""
git -C "$RV" checkout -q -- src/app.js; stop s5 "$RV" ""
S5=$(jq -r '.slugs|keys[0]' "$RV/.claude/work/state.json")
check "edited then reverted: no changes left"       test "$(state "$RV" ".slugs[\"$S5\"].status")" = "no changes left"
# Known limit: commits carry no session id, so a second session that touched the same
# file in the same checkout is credited with the first one's commit.
stop s2 "$R" ""

# Worktree: ledger in the main checkout, lead files survive removal
WT="$W/repo-wt"; git -C "$R" worktree add -q -b feat "$WT"
mkdir -p "$WT/.claude/lead"; echo "PASS" > "$WT/.claude/lead/VERDICT.md"; echo bar > "$WT/.claude/lead/VERIFICATION.md"
T3=$(transcript s3 "port the career paths")
edit s3 "$WT/src/app.js" "$WT" "$T3"
check "worktree edit writes the MAIN ledger"        test "$(jq -r '.slugs|to_entries[]|select(.value.session=="s3")|.value.branch' "$R/.claude/work/state.json")" = feat
check "no ledger inside the worktree"               test ! -e "$WT/.claude/work"
echo c >> "$WT/src/app.js"
stop s3 "$WT" "$MSG"
S3=$(jq -r '.slugs|to_entries[]|select(.value.session=="s3")|.key' "$R/.claude/work/state.json")
check "worktree verdict picked up"                  test "$(state "$R" ".slugs[\"$S3\"].verdict")" = PASS
check "lead files copied to slugs/<id>/"            test -f "$R/.claude/work/slugs/$S3/VERIFICATION.md"
git -C "$R" worktree remove --force "$WT"
stop s3 "$R" ""
check "removed worktree closes the slug"            test "$(state "$R" ".slugs[\"$S3\"].status")" = done
check "copied lead files survive removal"           test -f "$R/.claude/work/slugs/$S3/VERDICT.md"

# Round-1 adjudication findings
Y="$W/yaml"; mkrepo "$Y"; mkdir -p "$Y/helm"; echo "a: 1" > "$Y/helm/values.yaml"
edit s6 "$Y/helm/values.yaml" "$Y" "$T"
check "YAML edit opens a slug"                      test "$(state "$Y" '.slugs|length')" = 1
ST="$W/stale"; mkrepo "$ST"
edit s7 "$ST/src/app.js" "$ST" "$T"; echo z >> "$ST/src/app.js"; stop s7 "$ST" ""
git -C "$ST" commit -qam "committed by hand later"
stop s8 "$ST" ""
S7=$(jq -r '.slugs|keys[0]' "$ST/.claude/work/state.json")
check "another session's stop closes a stale slug"  test "$(state "$ST" ".slugs[\"$S7\"].status")" = done
check "stale slug gets no foreign judgment calls"   test ! -s "$ST/.claude/work/decisions.md"
LT="$W/lead.jsonl"
{ echo '{"type":"user","message":{"content":"earlier question"}}'
  echo '{"type":"user","message":{"content":"<command-message>lead</command-message>\n<command-name>/lead</command-name>\n<command-args>port the career paths</command-args>"}}'; } > "$LT"
LR="$W/leadrepo"; mkrepo "$LR"; edit s10 "$LR/src/app.js" "$LR" "$LT"
check "/lead with args becomes the title"           test "$(state "$LR" '.slugs[].title')" = "/lead port the career paths"
MR="$W/notranscript"; mkrepo "$MR"
jq -n --arg r "$MR" '{session_id:"s11",cwd:$r,tool_input:{file_path:($r+"/src/app.js")}}' | python3 -I "$L" edit
check "missing transcript: untitled work"           test "$(state "$MR" '.slugs[].title')" = "untitled work"
DR="$W/dedupe"; mkrepo "$DR"
edit s12 "$DR/src/app.js" "$DR" "$T"; echo q >> "$DR/src/app.js"
stop s12 "$DR" "$MSG"; stop s12 "$DR" "$MSG"
check "relayed judgment calls recorded once"        test "$(wc -l < "$DR/.claude/work/decisions.md" | tr -d ' ')" = 2
S12=$(jq -r '.slugs|keys[0]' "$DR/.claude/work/state.json")
check "a stop with nothing new writes no entry"     test "$(grep -c '^## ' "$DR/.claude/work/slugs/$S12.md")" = 1

# Work done through Bash (the live PokeMath run wrote every file with heredocs and sed -i)
CALL=0
hookcall(){ jq -n --arg s "$1" --arg c "$2" --arg t "$T" --arg u "$3" \
  '{session_id:$s,cwd:$c,transcript_path:$t,tool_name:"Bash",tool_use_id:$u}' | python3 -I "$L" "$4"; }
bash_call(){ sid=$1; cwd=$2; shift 2; CALL=$((CALL+1)); u="toolu_$CALL"
  hookcall "$sid" "$cwd" "$u" prebash
  (cd "$cwd" && eval "$@")
  hookcall "$sid" "$cwd" "$u" postbash; }
B="$W/bashrepo"; mkrepo "$B"; echo "mine" >> "$B/src/app.js"
bash_call s13 "$B" 'printf "x\n" > src/new.js'
check "file written through Bash opens a slug"      test "$(state "$B" '.slugs[].files|join(",")')" = "src/new.js"
check "pre-existing dirty file is not attributed"   sh -c "! jq -e '.slugs[].files|index(\"src/app.js\")' '$B/.claude/work/state.json'"
bash_call s13 "$B" 'git add src/new.js && git commit -qm "add new via shell"'
bash_call s14 "$B" 'git commit -qam "the user commits app.js"'
check "Bash commit by another session not added"    test "$(jq -r '.slugs|to_entries[]|select(.value.session=="s13")|.value.files|length' "$B/.claude/work/state.json")" = 1
stop s13 "$B" ""
S13=$(jq -r '.slugs|to_entries[]|select(.value.session=="s13")|.key' "$B/.claude/work/state.json")
check "shell-committed work closes as done"         test "$(state "$B" ".slugs[\"$S13\"].status")" = done
C="$W/commitrepo"; mkrepo "$C"
bash_call s15 "$C" 'printf "y\n" > src/c.js && git add src/c.js && git commit -qm "write and commit in one call"'
check "write+commit in one Bash call is caught"     test "$(state "$C" '.slugs[].files|join(",")')" = "src/c.js"
stop s15 "$C" ""
check "...and closes done with that commit"         test "$(state "$C" '.slugs[].status')" = done
I="$W/ignored"; mkrepo "$I"; echo "shots/" > "$I/.gitignore"; git -C "$I" add .gitignore; git -C "$I" commit -qm ign
mkdir -p "$I/shots"; edit s16 "$I/shots/run.mjs" "$I" "$T"
check "gitignored code file opens no slug"          test ! -e "$I/.claude/work/state.json"
D2="$W/docsbash"; mkrepo "$D2"; bash_call s17 "$D2" 'echo more >> docs/x.md'
check "docs written through Bash open no slug"      test ! -e "$D2/.claude/work"

# Round-2 findings: only commits the call authored count
pre_only(){ hookcall "$1" "$2" "toolu_orphan_$1" prebash; }
H="$W/headmoves"; mkrepo "$H"
git -C "$H" checkout -q -b feature; echo f >> "$H/src/app.js"; git -C "$H" commit -qam "feature work"; git -C "$H" checkout -q main
bash_call s20 "$H" 'git checkout -q feature'
check "checkout of a branch with commits: no slug"  test ! -e "$H/.claude/work/state.json"
bash_call s20 "$H" 'git checkout -q main && git merge -q --ff-only feature'
check "fast-forward merge: no slug"                 test ! -e "$H/.claude/work/state.json"
RB="$W/rebase"; mkrepo "$RB"; git -C "$RB" checkout -q -b mine
bash_call s21 "$RB" 'printf "m\n" > src/mine.js && git add src/mine.js && git commit -qm mine'
git -C "$RB" checkout -q main; printf 't\n' > "$RB/src/trunk.js"; git -C "$RB" add -A; git -C "$RB" commit -qm trunk; git -C "$RB" checkout -q mine
bash_call s21 "$RB" 'git rebase -q main'
check "rebase adds no trunk files to the slug"      test "$(state "$RB" '.slugs[].files|join(",")')" = "src/mine.js"
stop s21 "$RB" ""
check "rebase adds no trunk commits to the slug"    sh -c "! jq -r '.slugs[].commits|join(\",\")' '$RB/.claude/work/state.json' | grep -q \"\$(git -C '$RB' rev-parse --short=7 main)\""
FB2="$W/failedbash"; mkrepo "$FB2"
pre_only s22 "$FB2"; printf "z\n" > "$FB2/src/failed.js"          # the call wrote, then failed: no PostToolUse
bash_call s22 "$FB2" 'true'                                       # a fresh leftover is left alone (it may still run)
check "a running call's snapshot is not settled early"  test ! -e "$FB2/.claude/work/state.json"
jq -n --arg c "$FB2" '{session_id:"s22",cwd:$c,hook_event_name:"SubagentStop"}' | python3 -I "$L" stop
check "a subagent's stop leaves it alone too"       test ! -e "$FB2/.claude/work/state.json"
jq -n --arg c "$FB2" '{session_id:"s22",cwd:$c,hook_event_name:"Stop"}' | python3 -I "$L" stop
check "the main Stop settles the failed call"       test "$(state "$FB2" '.slugs[].files|join(",")')" = "src/failed.js"
check "reverted slug leaves the Open list"          sh -c "! awk '/^## Open/{on=1;next} /^## /{on=0} on' '$RV/.claude/work/NOW.md' | grep -q S-"
check "...and is listed as closed"                  grep -A5 "^## Recently closed" "$RV/.claude/work/NOW.md" | grep -q "no changes left"

# Round-3 findings: overlapping calls, rewritten commits
OV="$W/overlap"; mkrepo "$OV"
hookcall s30 "$OV" toolu_A prebash                                # lead A's commit call starts
hookcall s30 "$OV" toolu_B prebash                                # an ic's call starts meanwhile
(cd "$OV" && printf "a\n" > src/a.js && git add src/a.js && git commit -qm "A commits")
hookcall s30 "$OV" toolu_B postbash
hookcall s30 "$OV" toolu_A postbash
check "overlapping calls keep the commit"           test "$(state "$OV" '.slugs[].authored|length')" -ge 1
check "overlapping calls keep the file"             test "$(state "$OV" '.slugs[].files|join(",")')" = "src/a.js"
AM="$W/amend"; mkrepo "$AM"
bash_call s31 "$AM" 'printf "1\n" > src/x.js && git add src/x.js && git commit -qm first'
bash_call s31 "$AM" 'printf "2\n" >> src/x.js && git commit -qa --amend -m amended'
stop s31 "$AM" ""
check "amended commit: only the live hash listed"   test "$(state "$AM" '.slugs[].commits|join(",")')" = "$(git -C "$AM" rev-parse --short=7 HEAD)"
check "log.md names the live commit"                grep -q "done · $(git -C "$AM" rev-parse --short=7 HEAD) amended" "$AM/.claude/work/log.md"

# Never in the way
check "bad stdin exits 0"                           sh -c "echo '{bad' | python3 -I '$L' edit"
R2="$W/ro"; mkrepo "$R2"; mkdir -p "$R2/.claude"; chmod a-w "$R2/.claude"
check "unwritable ledger exits 0"                   sh -c "jq -n '{session_id:\"s9\",cwd:\"$R2\",tool_input:{file_path:\"$R2/src/app.js\"}}' | python3 -I '$L' edit"
chmod u+w "$R2/.claude"

# flightboard reads the ledger
edit s4 "$R/src/app.js" "$R" "$T"
FLIGHTBOARD_ROOTS="$W" bash "$FB/scan-local.sh" > "$W/scan.tsv" 2>/dev/null
check "scan marks the checkout with NOW.md"         awk -F'\t' -v d="$R" '$1==d && $9 ~ /NOW.md/ {f=1} END {exit !f}' "$W/scan.tsv"
check "read-handoff prints NOW.md whole"            sh -c "bash '$FB/read-handoff.sh' '$W/scan.tsv' | grep -q 'NOW.md (.*full)'"
check "session start prints open slugs"             sh -c "cd '$R' && FLIGHTBOARD_STATE='$W/none' bash '$FB/hooks/flightboard-context.sh' | grep -q 'Work ledger'"
check "session start silent outside a ledger repo"  sh -c "cd '$R2' && test -z \"\$(FLIGHTBOARD_STATE='$W/none' bash '$FB/hooks/flightboard-context.sh')\""

echo "$pass passed, $fail failed"; [ $fail -eq 0 ]
