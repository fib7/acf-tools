#!/usr/bin/env bash
# phase23-autopilot.test.sh: acfw-autopilot and its Stop hook (/whip --auto, acf-whip 3.6.0).
#
# WHAT THIS PINS. The decisions the hook hands a session: which skill runs next and with which args,
# when the run pauses for a person, when a judge is dispatched, and which verdicts count. It pins the
# machine parts of a block reason (the skill name, its args, the judge prompt path) and the load-bearing
# phrases of a pause ("waiting for your yes", "did not start", "parked work"), not the rest of the prose.
#
# HOW. `tick` reads the hook's JSON on stdin, so every case feeds crafted JSON (a session id and the
# background task list) and parses what comes back. Most rows need a NEXT line that is awkward to build
# for real, so ACFW_AUTOPILOT_CYCLE_BIN points at a stand-in that prints a canned `status` and passes
# every other verb to the real acfw-cycle. Pre-approval runs against a real cycle on the files store,
# because what matters there is the commit it makes.
#
# Run: bash acf-whip/tests/phase23-autopilot.test.sh
set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ACF_WHIP/skills/lib/bin"
AP="$BIN/acfw-autopilot"
CYCLE="$BIN/acfw-cycle"
STORE_BIN="$BIN/acfw-store"
FOCUS_BIN="$BIN/acfw-focus"
HANDLER="$ACF_WHIP/hooks/handlers/autopilot-stop.sh"
BASH32=/bin/bash; [ -x "$BASH32" ] || BASH32=$(command -v bash)

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (acfw-cycle status needs it)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed (the hook parses its JSON with it)"; exit 0; }

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; [ -n "${OUT:-}" ] && echo "        out: $(printf '%s' "$OUT" | cut -c1-300)"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p23.XXXXXX") || exit 1
WORK=$(cd "$WORK" && pwd -P)
trap 'cd /; rm -rf "$WORK"' EXIT
export GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 GIT_CEILING_DIRECTORIES="$WORK"
unset ACFW_STORE ACFW_CONFIG_FILE ACFW_TRUNK_BRANCH ACFW_AUTOPILOT ACFW_AUTOPILOT_CYCLE_BIN CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR 2>/dev/null || true
mkdir -p "$WORK/nohooks"

# The stand-in: canned status from $P23_STATUS (exit $P23_STATUS_RC), everything else to the real engine.
FAKE="$WORK/fake-cycle"
cat > "$FAKE" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = status ] && [ \$# -eq 1 ] && [ -n "\${P23_STATUS:-}" ]; then cat "\$P23_STATUS"; exit "\${P23_STATUS_RC:-0}"; fi
exec bash "$CYCLE" "\$@"
EOF
chmod +x "$FAKE"
STATUS="$WORK/status.txt"
canned(){ printf '%s\n' "$@" > "$STATUS"; export P23_STATUS="$STATUS"; }   # canned <line>...

new_repo() { # <name>: a files-store repo with specialists, a pinned mode, and trunk as its branch
  local s
  REPO="$WORK/$1"; rm -rf "$REPO"
  git init -q -b trunk "$REPO" && cd "$REPO" || return 1
  git config user.email t@t; git config user.name t; git config core.hooksPath "$WORK/nohooks"
  printf '.acfwhip/run/\n.backlog/.acfw-run.json\n' > .gitignore
  mkdir -p .claude/agents .acfwhip
  printf '# python-engineer\n' > .claude/agents/python-engineer.md
  printf '# quality-reviewer\n' > .claude/agents/quality-reviewer.md
  printf 'ACFW_INTEGRATION_MODE=default\n' > .acfwhip/config
  for s in draft pending in-progress completed in-review accepted rejected blocked archive; do
    mkdir -p ".backlog/$s"; : > ".backlog/$s/.gitkeep"
  done
  echo seed > seed; git add -A && git commit -qm seed
  export ACFW_TRUNK_ROOT="$REPO"
  unset P23_STATUS P23_STATUS_RC 2>/dev/null || true
}
task() { # <stem> <state>
  local doc="$WORK/doc.$1.md"
  cat > "$doc" <<EOF
# Task: $1

- **ID**: $1
- **Status**: $2
- **Priority**: high
- **Assigned Agent**: python-engineer
- **Worktree**: $1
- **PR Group**: $1
- **Touches Globs**: src/$1/**
- **Dependencies**: none
- **Rejection Count**: 0
- **Block-Count**: 0

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
EOF
  bash "$STORE_BIN" create --file "$doc" --stem "$1" --folder "$2" >/dev/null 2>&1 || bad "fixture: create $1 in $2"
}
plan_file() { # <file> <title>
  printf '# %s\n\n## Problem\n\nA tester runs phase23.\n\n## Deliverables\n\n### D1: it works\n\n- AC1.1: it works\n' "$2" > "$1"
}

ST(){ sed -n "s/^$1=//p" "$REPO/.acfwhip/run/autopilot/state" 2>/dev/null | head -1; }
sset(){ local f="$REPO/.acfwhip/run/autopilot/state"; grep -v "^$1=" "$f" > "$f.t"; printf '%s=%s\n' "$1" "$2" >> "$f.t"; mv "$f.t" "$f"; }
start(){ OUT=$("$BASH32" "$AP" start "$@" 2>&1); RC=$?; }
# tick [<bg-json>] [<session>]: one Stop hook call through the stand-in engine.
tick(){ OUT=$(printf '{"session_id":"%s","stop_hook_active":false,"background_tasks":%s}' "${2:-S1}" "${1:-[]}" \
  | ACFW_AUTOPILOT_CYCLE_BIN="$FAKE" "$BASH32" "$AP" tick 2>"$WORK/tick.err"); RC=$?; }
is_json(){ printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("decision")=="block" and d.get("reason") else 1)'; }
reason(){ printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])' 2>/dev/null; }
blk(){ is_json && reason | grep -qF -- "$1"; }       # a block whose reason contains <text>
nothing(){ [ "$RC" = 0 ] && [ -z "$OUT" ]; }

echo "== silence: the hook costs nothing and says nothing without a run =="
new_repo quiet
OUT=$(printf 'not json' | CLAUDE_PROJECT_DIR="$REPO" "$BASH32" "$HANDLER"); RC=$?
check "handler, no run: exit 0, no output" 'nothing'
tick; check "tick, no run: nothing" 'nothing'
start --goal 'add a flag'
check "start: exit 0 with the AUTOPILOT line" '[ "$RC" = 0 ] && printf "%s" "$OUT" | grep -q "^AUTOPILOT|started|run=[0-9]*|rounds=3|approve=no$"'
check "start: with no --until the condition is the goal" '[ "$(ST until)" = "the goal is achieved: add a flag" ]'
start --goal 'plan: add a flag'
check "start: the routing word \"plan\" is not part of the condition" '[ "$(ST until)" = "the goal is achieved: add a flag" ] && [ "$(ST goal)" = "plan: add a flag" ]'
start --goal 'planet names in the greeting'
check "start: a goal that only starts with the letters plan keeps them" '[ "$(ST until)" = "the goal is achieved: planet names in the greeting" ]'
start --goal 'add a flag'
OUT=$(printf 'not json' | CLAUDE_PROJECT_DIR="$REPO" "$BASH32" "$HANDLER"); RC=$?
check "handler, garbage stdin with a run: exit 0, no output" 'nothing'
OUT=$(cd "$REPO/.backlog" && printf '{"session_id":"S9","background_tasks":[{"status":"running"}]}' | env -u CLAUDE_PROJECT_DIR "$BASH32" "$HANDLER"); RC=$?
check "handler finds the run by walking up from a subdirectory (and a running task means nothing)" 'nothing && [ "$(ST session)" = S9 ]'
sset session S1
canned "STATUS x" "" "NEED YOU: nothing" "" "NEXT /go"
tick "[]" S2; check "another session's turn: nothing" 'nothing'
tick '[{"id":"w1","type":"workflow","status":"running"}]'
check "a running background workflow: nothing, and the round counts as worked" 'nothing && [ "$(ST saw_bg)" = 1 ] && [ "$(ST worked)" = 1 ]'

echo "== NEXT mapping: one skill, exact args =="
tick; check "NEXT /go with no focus: go with no args" 'blk "invoke the acf-whip:go skill with no args"'
task p23-001-a pending; task p23-002-b draft; task p23-003-c accepted
bash "$FOCUS_BIN" set --no-resolve --by task p23-001-a p23-002-b p23-003-c >/dev/null 2>&1
tick '[{"status":"running"}]'; tick
check "NEXT /go with a focus: the runnable stems only (draft and accepted left out)" "blk \"invoke the acf-whip:go skill with args 'p23-001-a'\""
canned "STATUS x" "" "NEED YOU: nothing" "" "NEXT /task --plan docs/cycles/20260929-x-y/plan.md"
tick; check "NEXT /task --plan: task with --plan <path>" 'blk "invoke the acf-whip:task skill with args --plan docs/cycles/20260929-x-y/plan.md"'
canned "STATUS x" "" "NEED YOU: nothing" "" "NEXT /retro 20260929-x-y"
tick; check "NEXT /retro: retro with the cycle id" 'blk "invoke the acf-whip:retro skill with args 20260929-x-y"'
canned "STATUS x" "  wait: /go is running" "" "NEED YOU: nothing" "" "NEXT wait: /go is running"
tick; check "NEXT wait: nothing (the run holding the lock reports to its own session)" 'nothing'
check "every hand-off is logged in events.log" 'grep -q "^[0-9-]* [0-9:]*|issue|retro:20260929-x-y$" "$REPO/.acfwhip/run/autopilot/events.log"'

echo "== stall: the same step from the same state, with nothing started, pauses once =="
canned "STATUS y" "" "NEED YOU: nothing" "" "NEXT /retro 20260929-s-t"
tick; check "first hand-off" 'blk "acf-whip:retro"'
tick; check "same state again: paused, the step did not start" 'blk "paused: the step did not start" && [ "$(ST state)" = paused ]'
tick; check "and then quiet" 'nothing'
"$BASH32" "$AP" on >/dev/null 2>&1; sset session S1
tick; check "on clears the stall: the step is handed out again" 'blk "acf-whip:retro"'
tick '[{"status":"running"}]'; tick
check "a background run seen since the hand-off is progress, not a stall" 'blk "acf-whip:retro"'

echo "== pauses: cards, errors, and resuming by itself =="
canned "STATUS x" "" "NEED YOU" "  WHAT task p23-009 is blocked at the cap" "  RISK r" "  REPLY /whip-move p23-009 pending" "" "NEXT /whip-move p23-009 pending"
tick; check "a card: paused with its WHAT line" 'blk "paused: task p23-009 is blocked at the cap" && [ "$(ST state)" = paused ]'
tick; check "the same card again: quiet" 'nothing'
canned "STATUS x" "" "NEED YOU: nothing" "" "NEXT /task --plan docs/cycles/20260929-q-r/plan.md"
tick; check "card resolved: resumes by itself" 'blk "--plan docs/cycles/20260929-q-r/plan.md" && [ "$(ST state)" = running ]'
export P23_STATUS_RC=4; tick; unset P23_STATUS_RC
check "status fails: paused with the exit code" 'blk "acfw-cycle status failed (exit 4)"'
canned "STATUS x" "" "NEED YOU" "  WHAT approve docs/cycles/20260929-q-r/plan.md \"Q\" (1 deliverable)" "  RISK r" "  REPLY yes: approve" "  content=0123456789ab" "" "NEXT yes: approve docs/cycles/20260929-q-r/plan.md (content=0123456789ab)"
tick; check "approval card without --approve: waiting for your yes" 'blk "waiting for your yes on the card"'

echo "== round end: the judge, its nonce, and what a verdict does =="
new_repo judge
start --goal 'add a flag' --until 'npm test passes' --rounds 2
sset session S1
canned "STATUS no active cycle" "" "NEED YOU: nothing" "" 'NEXT /whip "<goal>"'
tick; check "idle before any work: start the round's goal through /whip --auto-round" "blk \"invoke the acf-whip:whip skill with args --auto-round 'add a flag'\""
tick '[{"status":"running"}]'
tick
N=$(ST judge_nonce); JF="$REPO/.acfwhip/run/autopilot/judge-$N.md"
check "idle after work: the judge is dispatched in the foreground with a nonce" 'blk "Dispatch the autopilot judge now, in the foreground" && blk "Read $JF and follow it exactly" && [ -n "$N" ]'
check "the judge prompt carries the condition, HEAD and the nonce, and no placeholder" 'grep -qF "npm test passes" "$JF" && grep -qF "$(git rev-parse HEAD)" "$JF" && grep -qF -- "--nonce $N" "$JF" && ! grep -q "{{" "$JF"'
check "the judge prompt forbids tracked edits" 'grep -q "Do not edit, create, delete or stage any tracked file" "$JF"'
OUT=$("$BASH32" "$AP" verdict --nonce 000000000000 met --reason x 2>&1); RC=$?
check "verdict for another nonce: exit 2, not recorded" '[ "$RC" = 2 ] && [ ! -s "$REPO/.acfwhip/run/autopilot/verdict" ]'
tick; check "no verdict yet: the same judge again is a stall" 'blk "the step did not start: the autopilot judge"'
"$BASH32" "$AP" on >/dev/null 2>&1; sset session S1
tick; N=$(ST judge_nonce)
check "on after a judge that recorded nothing issues a fresh nonce" '[ -n "$N" ] && blk "Dispatch the autopilot judge now"'
long=$(printf 'line one\nline two\001%0400d' 0)
OUT=$("$BASH32" "$AP" verdict --nonce "$N" not-met --reason "$long" --next 'Make the CLI tests pass' 2>&1); RC=$?
check "verdict: exit 0, VERDICT line" '[ "$RC" = 0 ] && printf "%s" "$OUT" | grep -q "^VERDICT|not-met|round=1|nonce=$N$"'
check "verdict: one line, control characters gone, reason capped at 300" '[ "$(wc -l < "$REPO/.acfwhip/run/autopilot/verdict" | tr -d " ")" = 1 ] && ! LC_ALL=C grep -q "$(printf "\001")" "$REPO/.acfwhip/run/autopilot/verdict" && [ "$(cut -d"|" -f6 "$REPO/.acfwhip/run/autopilot/verdict" | wc -c | tr -d " ")" -le 301 ]'
tick
check "not-met under the cap: round 2 starts with the judge's next goal" "blk \"--auto-round 'Make the CLI tests pass'\" && [ \"\$(ST round)\" = 2 ] && [ -z \"\$(ST judge_nonce)\" ]"
tick '[{"status":"running"}]'; tick
N=$(ST judge_nonce)
"$BASH32" "$AP" verdict --nonce "$N" not-met --reason 'still red' >/dev/null 2>&1
tick; check "not-met at the cap: stopped, with the reason" 'blk "autopilot stopped: not met after 2 round(s): still red" && [ "$(ST state)" = stopped ]'
tick; check "a stopped run is silent" 'nothing'
OUT=$("$BASH32" "$AP" on 2>&1); RC=$?
check "on after the round cap refuses and names --rounds" '[ "$RC" = 3 ] && printf "%s" "$OUT" | grep -q "on --rounds 3" && [ "$(ST state)" = stopped ]'
OUT=$("$BASH32" "$AP" on --rounds 3 2>&1); RC=$?; sset session S1
tick; check "on --rounds 3 continues into round 3 with the judge's next goal" '[ "$(ST round)" = 3 ] && blk "Start round 3 now"'

new_repo met
start --goal 'g'; sset session S1; sset worked 1
canned "STATUS closed" "" "NEED YOU: nothing" "" 'NEXT /whip "<next goal>"'
tick; N=$(ST judge_nonce)
"$BASH32" "$AP" verdict --nonce "$N" met --reason 'npm test: 12 passing' >/dev/null 2>&1
tick; check "met: done, with the judge's reason" 'blk "autopilot done: met in round 1: npm test: 12 passing" && [ "$(ST state)" = done ]'
tick; check "a done run is silent" 'nothing'

new_repo impossible
start --goal 'g'; sset session S1; sset worked 1
canned "STATUS closed" "" "NEED YOU: nothing" "" 'NEXT /whip "<next goal>"'
tick; N=$(ST judge_nonce)
"$BASH32" "$AP" verdict --nonce "$N" impossible --reason 'needs production credentials' >/dev/null 2>&1
tick; check "impossible: stopped, with the reason" 'blk "cannot be met: needs production credentials" && [ "$(ST state)" = stopped ]'
OUT=$("$BASH32" "$AP" on --rounds 5 2>&1); RC=$?
check "on after impossible refuses, even with more rounds" '[ "$RC" = 3 ] && printf "%s" "$OUT" | grep -q "cannot be met" && [ "$(ST state)" = stopped ]'

new_repo moved
start --goal 'g'; sset session S1; sset worked 1
canned "STATUS closed" "" "NEED YOU: nothing" "" 'NEXT /whip "<next goal>"'
tick; N=$(ST judge_nonce)
echo changed > seed
"$BASH32" "$AP" verdict --nonce "$N" met --reason 'fine' >/dev/null 2>&1
git checkout -q -- seed
tick; check "a verdict recorded over a changed tree is not used" 'blk "verdict was not used" && [ "$(ST state)" = paused ]'

new_repo parked
start --goal 'g'; sset session S1; sset worked 1
task p23-010-x blocked
bash "$FOCUS_BIN" set --no-resolve --by task p23-010-x >/dev/null 2>&1
canned "STATUS no active cycle" "" "NEED YOU: nothing" "" 'NEXT /whip "<goal>"'
tick; check "round end with a blocked focus task: parked work pauses, no judge" 'blk "parked work needs you: p23-010-x (blocked)" && [ -z "$(ST judge_nonce)" ]'

new_repo steps
start --goal 'g'; sset session S1; sset steps 60
canned "STATUS x" "" "NEED YOU: nothing" "" "NEXT /go"
tick; check "the step cap stops the run" 'blk "stopped after 60 steps" && [ "$(ST state)" = stopped ]'

echo "== pre-approval: only with the user's opt-in, only for this run's plans =="
new_repo preapprove
plan_file "$WORK/old.md" "Old plan"
"$BASH32" "$CYCLE" init 20260101-old-plan --from-file "$WORK/old.md" --kind feature --source p23 >/dev/null 2>&1
sleep 1
start --goal 'g' --approve
check "start --approve: approve=yes from the flag" 'printf "%s" "$OUT" | grep -q "approve=yes" && [ "$(ST approve_src)" = flag ]'
sset session S1
tick; check "a draft made before the run is not pre-approved" 'blk "created before this autopilot run"'
"$BASH32" "$CYCLE" abandon 20260101-old-plan >/dev/null 2>&1
plan_file "$WORK/new.md" "New plan"
"$BASH32" "$CYCLE" init 20260929-new-plan --from-file "$WORK/new.md" --kind feature --source p23 >/dev/null 2>&1
H0=$(git rev-parse HEAD)
tick
check "this run's draft: approved via autopilot, then /task --plan" 'blk "invoke the acf-whip:task skill with args --plan docs/cycles/20260929-new-plan/plan.md" && [ "$(git rev-parse HEAD)" != "$H0" ]'
check "the approved row says via autopilot" 'git show HEAD:docs/cycles/20260929-new-plan/record.md | grep -E "^\| [0-9-]+ [0-9:]+ \| approved \|" | head -1 | grep -q "; via autopilot"'
check "the commit is an ordinary approve with its trailer" 'git log -1 --format=%s | grep -q "^docs(plan): approve " && git log -1 --format=%B | grep -q "^ACFW-Plan-Event: approved "'

new_repo loosen
start --goal 'g' --approve; sset session S1
plan_file "$WORK/loose.md" "Loosen a gate"
printf '\n### D2: drop the lint gate [loosens: yes, lint gate]\n\n- AC2.1: lint no longer runs\n' >> "$WORK/loose.md"
"$BASH32" "$CYCLE" init 20260929-loose-plan --from-file "$WORK/loose.md" --kind feature --source p23 >/dev/null 2>&1
H0=$(git rev-parse HEAD)
tick; check "a plan that loosens a control waits for the user, and nothing is committed" 'blk "loosens a control, which only you approve" && [ "$(git rev-parse HEAD)" = "$H0" ]'

new_repo stale
start --goal 'g' --approve; sset session S1
plan_file "$WORK/stale.md" "Stale"
"$BASH32" "$CYCLE" init 20260929-stale-plan --from-file "$WORK/stale.md" --kind feature --source p23 >/dev/null 2>&1
canned "STATUS x" "" "NEED YOU" "  WHAT approve docs/cycles/20260929-stale-plan/plan.md" "" "NEXT yes: approve docs/cycles/20260929-stale-plan/plan.md (content=000000000000)"
tick; check "a stale content hash: approve refuses (9) and the run pauses" 'blk "pre-approval of docs/cycles/20260929-stale-plan was refused" && blk "REFUSED (9)"'

new_repo setting
printf 'ACFW_AUTOPILOT=approve\n' >> .acfwhip/config
OUT=$("$BASH32" "$AP" setting 2>"$WORK/set.err"); RC=$?
check "an uncommitted ACFW_AUTOPILOT=approve counts only as on, with a WARN" '[ "$OUT" = "SETTING|on" ] && grep -q "not committed" "$WORK/set.err"'
start --goal g --from-setting
check "...so a run started from it does not pre-approve" '[ "$(ST approve)" = 0 ]'
git add .acfwhip/config && git commit -qm "autopilot approve"
OUT=$("$BASH32" "$AP" setting 2>/dev/null)
check "committed: SETTING|approve" '[ "$OUT" = "SETTING|approve" ]'
start --goal g --from-setting
check "...and a run started from it pre-approves (source: config)" '[ "$(ST approve)" = 1 ] && [ "$(ST approve_src)" = config ]'

echo "== acfw-cycle approve --via =="
new_repo via
plan_file "$WORK/via.md" "Via"
"$BASH32" "$CYCLE" init 20260929-via-plan --from-file "$WORK/via.md" --kind feature --source p23 >/dev/null 2>&1
OUT=$("$BASH32" "$CYCLE" approve 20260929-via-plan --expect 000000000000 --via other 2>&1); RC=$?
check "--via accepts only autopilot (exit 2)" '[ "$RC" = 2 ]'

echo "== start, on, off, status =="
new_repo lifecycle
export CLAUDE_CODE_SESSION_ID=A; start --goal one
check "start binds the session from CLAUDE_CODE_SESSION_ID" '[ "$(ST session)" = A ]'
export CLAUDE_CODE_SESSION_ID=B; start --goal two
check "a second live run from another session is refused (exit 7)" '[ "$RC" = 7 ] && [ "$(ST goal)" = one ]'
export CLAUDE_CODE_SESSION_ID=A; start --goal two
check "the same session may replace its run" '[ "$RC" = 0 ] && [ "$(ST goal)" = two ] && printf "%s" "$OUT" | grep -q "replaces the run"'
OUT=$("$BASH32" "$AP" status); check "status: one running line" 'printf "%s" "$OUT" | grep -q "^autopilot: running, round 1/3"'
"$BASH32" "$AP" off >/dev/null
canned "STATUS x" "" "NEED YOU: nothing" "" "NEXT /go"
tick "[]" A; check "off: the hook is silent" 'nothing'
OUT=$("$BASH32" "$AP" status); check "status after off says how to resume" 'printf "%s" "$OUT" | grep -q "/whip --auto on resumes it"'
export CLAUDE_CODE_SESSION_ID=C; OUT=$("$BASH32" "$AP" on 2>&1); unset CLAUDE_CODE_SESSION_ID
check "on resumes and rebinds to the calling session" '[ "$(ST state)" = running ] && [ "$(ST session)" = C ]'
tick "[]" C; check "...and the next turn end hands out the step" 'blk "acf-whip:go"'

echo "== the hook is registered =="
check "hooks.json registers the Stop handler with a 600 s timeout" 'jq -e ".hooks.Stop[0].hooks[0] | (.command | test(\"autopilot-stop.sh\")) and .timeout == 600" "$ACF_WHIP/hooks/hooks.json" >/dev/null'
check "the handler is executable" '[ -x "$HANDLER" ]'

echo
echo "phase23-autopilot: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
