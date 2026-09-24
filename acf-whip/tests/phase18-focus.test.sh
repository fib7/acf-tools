#!/usr/bin/env bash
# phase18-focus.test.sh — the run focus: what a bare `/go` runs (3.4.0).
#
# WHY THE FOCUS EXISTS. `/go` with no arguments meant "the whole backlog". On a checkout whose backlog
# is its own, that is what the operator meant. On a SHARED board it never is — one person's bare `/go`
# would be everyone's — so teams stop running the shipped orchestrator and hand-author throwaway ones
# instead. Naming ids every time is the workaround, and it is the thing people actually complain about.
#
# WHAT THIS FILE GUARDS. A focus is a SELECTION, and the ways a selection goes wrong are all quiet:
#   - it holds what you typed rather than what that resolved to, so it means something different later
#   - a partially-applied write leaves a focus nobody chose
#   - it gets committed, and one person's selection becomes everyone's
#   - it outlives the work, so a bare `/go` reports "nothing to do" against a stale list forever
#   - it is mistaken for a pause, which it is not and must not silently pretend to be
#
# Run: bash acf-whip/tests/phase18-focus.test.sh
set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOCUS_BIN="$ACF_WHIP/skills/lib/bin/acfw-focus"
STORE_BIN="$ACF_WHIP/skills/lib/bin/acfw-store"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p18focus.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO"
unset ACFW_STORE ACFW_GO_BARE 2>/dev/null || true

mkdir -p .backlog/pending .backlog/in-progress .backlog/completed .backlog/in-review \
         .backlog/blocked .backlog/rejected .backlog/accepted .backlog/draft .backlog/archive
mk(){ # <folder> <stem> <id> <slug> <deps>
  cat > ".backlog/$1/$2.md" <<EOF
# $2
- **ID**: $3
- **Status**: $1
- **Worktree**: $4
- **Priority**: medium
- **Agent**: python-engineer
- **Dependencies**: $5
- **Touches**: src/**
- **Rejection Count**: 0
EOF
}
mk pending  api-014-token   API-14  api   none
mk pending  ui-021-login    UI-21   ui    none
mk pending  ui-021-logout   UI-22   ui2   none
mk pending  unrelated-777   UN-77   other none
mk accepted done-500        DONE-5  none  none
mk draft    doc-009-draft   DOC-9   none  none
git add -A; git commit -qm tasks

F(){ bash "$FOCUS_BIN" "$@"; }
FOCUS_FILE="$REPO/.acfwhip/run/focus"

# ============================ empty state ======================================================
check "with no focus, show says so plainly" "F show | grep -q 'no focus set'"
check "...and exits 0 (absence is not an error)" "F show >/dev/null 2>&1"
check "path reports where it would live" "[ \"\$(F path)\" = \"\$FOCUS_FILE\" ]"

# ============================ set / show =======================================================
F set api-014-token ui-021-login >/dev/null
check "set writes the focus" "[ -r \"\$FOCUS_FILE\" ]"
check "...with both tasks" "[ \"\$(F show | grep -c '^  ')\" = '2' ]"
check "...recording who set it" "grep -q '^# setBy=focus' \"\$FOCUS_FILE\""
check "...and when" "grep -q '^# ts=' \"\$FOCUS_FILE\""
check "...and which backend it belongs to" "grep -q '^# store=files' \"\$FOCUS_FILE\""
check "show names the count, the setter and the time" "F show | grep -qE 'focus: 2 task\\(s\\), set by focus at'"

# The file holds RESOLVED stems, never what was typed. A focus holding raw arguments would inherit
# every ambiguity of the thing typed — a prefix matching one task today and two tomorrow.
F set UI-21 >/dev/null
check "a task named by ID is stored as its STEM" "grep -qx 'ui-021-login' \"\$FOCUS_FILE\""
check "...not as the id that was typed" "! grep -qx 'UI-21' \"\$FOCUS_FILE\""
F set unrelated >/dev/null
check "a task named by a unique PREFIX is stored as its full stem" "grep -qx 'unrelated-777' \"\$FOCUS_FILE\""

# ============================ refusals leave the focus untouched ===============================
F set api-014-token ui-021-login >/dev/null
BEFORE=$(cat "$FOCUS_FILE")
F add nope-404 >/dev/null 2>&1; RC=$?
check "an unknown task refuses with exit 3" "[ $RC -eq 3 ]"
check "...and the focus is UNCHANGED (never partially applied)" "[ \"\$(cat \"\$FOCUS_FILE\")\" = \"\$BEFORE\" ]"
F add nope-404 2>&1 | grep -q 'NOT changed'
check "...and says so, rather than reporting a partial success" "[ \$? -eq 0 ]"

# An AMBIGUOUS prefix is the dangerous case: it resolves today and means something else tomorrow.
F add ui-021 >/dev/null 2>&1; RC=$?
check "an ambiguous prefix refuses rather than picking one" "[ $RC -eq 3 ]"
check "...naming every candidate" "F add ui-021 2>&1 | grep -q 'ui-021-login'"
check "...and the focus is still unchanged" "[ \"\$(cat \"\$FOCUS_FILE\")\" = \"\$BEFORE\" ]"
check "a valid task alongside an invalid one is NOT written (all or nothing)" \
  "F add unrelated-777 nope-404 >/dev/null 2>&1; ! grep -qx 'unrelated-777' \"\$FOCUS_FILE\""

# ============================ add / drop / clear ===============================================
F set api-014-token >/dev/null
F add ui-021-login >/dev/null
check "add appends" "[ \"\$(F show | grep -c '^  ')\" = '2' ]"
F add ui-021-login >/dev/null
check "...and dedups" "[ \"\$(F show | grep -c '^  ')\" = '2' ]"
F drop ui-021-login >/dev/null
check "drop removes" "[ \"\$(F show | grep -c '^  ')\" = '1' ]"
check "...and warns that dropping is not pausing" "F drop api-014-token 2>&1 | grep -q 'not pausing'"
check "...naming the command that IS" "F drop api-014-token 2>&1 | grep -q 'whip-move'"
F clear >/dev/null
check "clear removes the file" "[ ! -f \"\$FOCUS_FILE\" ]"
check "...and says what a bare /go does now" "F clear 2>&1 | grep -q 'bare-go\\|bareGo\\|policy'"

# A focus every entry of which is DONE is spent. Appending to it would carry finished work into the
# next run's scope forever, so adding to a spent focus replaces it — what starting new work means.
F set done-500 >/dev/null
check "a focus can hold an already-finished task" "grep -qx 'done-500' \"\$FOCUS_FILE\""
F add api-014-token >/dev/null
check "adding to a SPENT focus replaces it" "! grep -qx 'done-500' \"\$FOCUS_FILE\""
check "...leaving only the new work" "[ \"\$(F show | grep -c '^  ')\" = '1' ]"
# ...but a focus with live work still appends, or an operator would lose a selection they still need.
F set api-014-token >/dev/null
F add ui-021-login >/dev/null
check "adding to a LIVE focus appends instead" "[ \"\$(F show | grep -c '^  ')\" = '2' ]"

# ============================ never committed ==================================================
check "the focus lives under .acfwhip/run/" "printf '%s' \"\$FOCUS_FILE\" | grep -q '/.acfwhip/run/focus\$'"
check "...which acfw-focus ensures is gitignored" "git -C \"\$REPO\" check-ignore -q .acfwhip/run/"
check "...so git never sees the focus file" "! git -C \"\$REPO\" status --porcelain | grep -q 'acfwhip/run'"
# A project that adopted the plugin before this dir existed has no rule for it; the write adds one.
rm -f "$REPO/.gitignore"; F set api-014-token >/dev/null
check "a missing ignore rule is added rather than silently tracking the focus" \
  "git -C \"\$REPO\" check-ignore -q .acfwhip/run/"

# ============================ a focus from another backend is refused ==========================
sed -i.bak 's/^# store=files/# store=multica/' "$FOCUS_FILE" && rm -f "$FOCUS_FILE.bak"
F show >/dev/null 2>&1; RC=$?
check "a focus written for a different store is refused, not run" "[ $RC -eq 2 ]"
check "...naming the remedy" "F show 2>&1 | grep -q 'acfw-focus clear'"
F clear >/dev/null

# ============================ --live answers 'is any of this worth running?' ===================
F set api-014-token done-500 >/dev/null
LIVE=$(F show --live)
check "--live shows each task's current state" "printf '%s' \"\$LIVE\" | grep -qE 'api-014-token +pending'"
check "...including one that is already finished" "printf '%s' \"\$LIVE\" | grep -q 'done-500'"

# ============================ --no-resolve is the writer's path only ===========================
# /task chains `add --no-resolve` onto each create, so a create that fails never puts its id in the
# focus. It skips the store round-trip because the ids were just written by that same command.
F clear >/dev/null
F add --no-resolve --by task brand-new-001 >/dev/null
check "--no-resolve writes without consulting the store" "grep -qx 'brand-new-001' \"\$FOCUS_FILE\""
check "...and stamps who set it" "grep -q '^# setBy=task' \"\$FOCUS_FILE\""

# ============================ the jq-less path must behave IDENTICALLY =========================
# The `files` backend runs without jq — it is the one backend where this path is the normal path,
# not a fallback. Parsing the snapshot by scanning for "key":"value" pairs matched trunkRoot,
# branchPrefix, a commit SHA and every task's priority, and wrote all of them into the focus as if
# they were stems, reporting success. A focus that is silently wrong is wrong on every later bare /go.
if command -v jq >/dev/null 2>&1; then
  NOJQ="$WORK/nojqbin"; mkdir -p "$NOJQ"
  OLDIFS=$IFS; IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=$(basename "$f"); [ "$b" = "jq" ] && continue
      [ -e "$NOJQ/$b" ] || ln -sf "$f" "$NOJQ/$b" 2>/dev/null
    done
  done
  IFS=$OLDIFS
  NJ(){ env PATH="$NOJQ" ACFW_TRUNK_ROOT="$REPO" "$NOJQ/bash" "$FOCUS_BIN" "$@"; }
  check "the test harness really hid jq" "! env PATH=\"\$NOJQ\" \"\$NOJQ/bash\" -c 'command -v jq' >/dev/null 2>&1"

  NJ clear >/dev/null 2>&1
  NJ set api-014-token ui-021-login >/dev/null 2>&1
  check "set resolves correctly without jq" \
    "[ \"\$(grep -v '^#' \"\$FOCUS_FILE\" | sort | paste -sd, -)\" = 'api-014-token,ui-021-login' ]"
  check "...writing ONLY stems — no trunk path, SHA, priority or branch prefix leaked in" \
    "! grep -qE '^(/|\\.worktree|trunk|default|medium|pending|worktree|[0-9a-f]{40})\$' \"\$FOCUS_FILE\""
  check "...and exactly as many entries as were asked for" "[ \"\$(grep -cv '^#' \"\$FOCUS_FILE\")\" = '2' ]"

  BEFORE_NJ=$(cat "$FOCUS_FILE")
  NJ add nope-404 >/dev/null 2>&1; RC=$?
  check "an unknown task still refuses without jq" "[ $RC -eq 3 ]"
  check "...leaving the focus untouched" "[ \"\$(cat \"\$FOCUS_FILE\")\" = \"\$BEFORE_NJ\" ]"
  NJ set ui-021 >/dev/null 2>&1; RC=$?
  check "an ambiguous prefix still refuses without jq" "[ $RC -eq 3 ]"
  check "...leaving the focus untouched" "[ \"\$(cat \"\$FOCUS_FILE\")\" = \"\$BEFORE_NJ\" ]"
  NJ set UI-21 >/dev/null 2>&1
  check "an ID resolves to its stem without jq" "grep -qx 'ui-021-login' \"\$FOCUS_FILE\""
  # The guard that makes either parser trustworthy: N distinct tokens in, N resolved ENTRIES out,
  # or refuse. It counts entries and not stems on purpose — see the duplicate-token case below.
  check "the count guard is what backs the refusal, not the parser" \
    "grep -q 'but it resolved' \"\$FOCUS_BIN\""
else
  ok "jq unavailable — the jq-less path IS the path under test everywhere above"
fi

# ============================ acfw-store info exposes it =======================================
F set api-014-token ui-021-login >/dev/null
INFO=$(bash "$STORE_BIN" info)
check "info reports the focus path" "printf '%s' \"\$INFO\" | grep -q '\"focusFile\":\"[^\"]*\\.acfwhip/run/focus\"'"
check "info reports how many tasks are in it" "printf '%s' \"\$INFO\" | grep -q '\"focusCount\":2'"
check "info reports the bare-/go policy" "printf '%s' \"\$INFO\" | grep -q '\"bareGo\":\"all\"'"
check "...which defaults to all on the files backend (unchanged behaviour)" \
  "[ \"\$(printf '%s' \"\$INFO\" | sed -n 's/.*\"bareGo\":\"\\([a-z]*\\)\".*/\\1/p')\" = 'all' ]"
# ...and to refuse on a shared board, where one person's bare /go would be everyone's.
INFO2=$(ACFW_STORE=multica bash "$STORE_BIN" info 2>/dev/null || true)
check "...and to refuse on a non-files store" "printf '%s' \"\$INFO2\" | grep -q '\"bareGo\":\"refuse\"'"
INFO3=$(ACFW_GO_BARE=all ACFW_STORE=multica bash "$STORE_BIN" info 2>/dev/null || true)
check "...overridable by env" "printf '%s' \"\$INFO3\" | grep -q '\"bareGo\":\"all\"'"
mkdir -p "$REPO/.acfwhip"; printf 'ACFW_GO_BARE=all\n' > "$REPO/.acfwhip/config"
INFO4=$(ACFW_STORE=multica bash "$STORE_BIN" info 2>/dev/null || true)
check "...and by config" "printf '%s' \"\$INFO4\" | grep -q '\"bareGo\":\"all\"'"
printf 'ACFW_GO_BARE=sideways\n' > "$REPO/.acfwhip/config"
bash "$STORE_BIN" info >/dev/null 2>&1; RC=$?
check "an unrecognised bare-go pin fails loudly rather than guessing" "[ $RC -eq 2 ]"
rm -f "$REPO/.acfwhip/config"

# ============================ the model routing info =============================================
INFO=$(bash "$STORE_BIN" info)
check "info reports the shell-tier model" "printf '%s' \"\$INFO\" | grep -q '\"shell\":\"haiku\"'"
check "...and leaves judge/author unset (they inherit the session model)" \
  "printf '%s' \"\$INFO\" | grep -q '\"judge\":\"\",\"author\":\"\"'"
INFO5=$(ACFW_MODEL_SHELL=sonnet bash "$STORE_BIN" info)
check "...overridable by env" "printf '%s' \"\$INFO5\" | grep -q '\"shell\":\"sonnet\"'"

# ============================ 3.4.0 cleanup: five ways a focus lied ============================
# Every case below was reproduced against the shipped 3.4.0 tree before the fix.

# --- an EMPTY focus must not corrupt the one JSON object /go step 2 reads ----------------------
# `write_focus` always writes header lines, so dropping every entry leaves a readable file with zero
# stems. `grep -c` PRINTS 0 and EXITS 1 there, so `|| echo 0` appended a second zero and `info`
# emitted "focusCount":00 — which jq accepts and JSON.parse rejects.
F set api-014-token >/dev/null
F drop api-014-token >/dev/null 2>&1
check "an emptied focus leaves the file in place" "[ -r \"\$FOCUS_FILE\" ]"
check "...with no stems" "[ \"\$(grep -cv '^#' \"\$FOCUS_FILE\")\" = '0' ]"
EMPTY_INFO=$(bash "$STORE_BIN" info)
check "...and info reports focusCount 0, not 00" "printf '%s' \"\$EMPTY_INFO\" | grep -q '\"focusCount\":0,'"
if command -v node >/dev/null 2>&1; then
  check "...and the whole info object is parseable JSON" \
    "printf '%s' \"\$EMPTY_INFO\" | node -e 'let s=\"\";process.stdin.on(\"data\",d=>s+=d).on(\"end\",()=>{JSON.parse(s)})'"
fi

# --- two tokens naming one task is not a parse failure ----------------------------------------
# The guard compared a de-duplicated stem list against raw argv, so `set <id> <stem>` of one task
# refused with "install jq" told to a user who has jq. It counts resolved ENTRIES now.
F set API-14 api-014-token >/dev/null 2>&1; RC=$?
check "an id and its own stem resolve to one task without refusing" "[ $RC -eq 0 ]"
check "...writing that task once" "[ \"\$(grep -cv '^#' \"\$FOCUS_FILE\")\" = '1' ]"
F set api-014-token api-014-token >/dev/null 2>&1; RC=$?
check "the same token twice is accepted, not treated as a short read" "[ $RC -eq 0 ]"

# --- drop resolves ids, native ids and prefixes, as the docs promise ---------------------------
# It used to be a literal whole-line compare, so `drop API-14` removed nothing and still printed
# "focus now: N" — a success message for a no-op.
F set api-014-token ui-021-login >/dev/null
F drop API-14 >/dev/null 2>&1
check "drop by ID removes the task" "! grep -qx 'api-014-token' \"\$FOCUS_FILE\""
check "...and leaves the rest alone" "grep -qx 'ui-021-login' \"\$FOCUS_FILE\""
F set api-014-token ui-021-login >/dev/null
F drop api-014 >/dev/null 2>&1
check "drop by unique prefix removes the task" "! grep -qx 'api-014-token' \"\$FOCUS_FILE\""
DROPERR=$(F drop nothing-like-this 2>&1 >/dev/null)
check "a token that matches nothing is REPORTED, not silently ignored" \
  "printf '%s' \"\$DROPERR\" | grep -q 'matched nothing'"

# --- a spent focus is replaced even by the --no-resolve writer ---------------------------------
# /task's writers always pass --no-resolve, and the replace check was gated on it — so every /task
# run appended and a bare /go kept re-scoping over work finished several runs ago. The check asks the
# store about the tasks ALREADY in the focus, so it never needed the incoming tokens resolved.
if command -v jq >/dev/null 2>&1; then
  F set done-500 >/dev/null
  OUT_REPL=$(F add --no-resolve --by task api-014-token 2>&1)
  check "a focus whose every task is accepted is REPLACED by the /task writer" \
    "printf '%s' \"\$OUT_REPL\" | grep -q 'focus replaced'"
  check "...so the finished task is gone" "! grep -qx 'done-500' \"\$FOCUS_FILE\""
  check "...and only the new one remains" "[ \"\$(grep -cv '^#' \"\$FOCUS_FILE\")\" = '1' ]"
  F set api-014-token >/dev/null
  OUT_APP=$(F add --no-resolve --by task ui-021-login 2>&1)
  check "a focus with live work still APPENDS" "printf '%s' \"\$OUT_APP\" | grep -q 'focus now'"
  check "...keeping both" "[ \"\$(grep -cv '^#' \"\$FOCUS_FILE\")\" = '2' ]"
fi

# --- a write refusal must be the SCRIPT's exit, not a subshell's ------------------------------
# write_focus was the last stage of a pipeline, so every `exit` inside it (and inside the gitignore
# hard gate it calls) terminated only that subshell: the FATAL printed, nothing was written, and the
# next line reported success with status 0.
check "write_focus takes its stems as an argument, never on stdin" \
  "! grep -qE '\\| *write_focus' \"\$FOCUS_BIN\""
RO="$WORK/ro"; git init -q -b trunk "$RO"; ( cd "$RO"; git config user.email t@t; git config user.name t; \
  mkdir -p .backlog/pending; echo x > .gitignore; git add -A; git commit -qm s ) >/dev/null 2>&1
chmod 444 "$RO/.gitignore"
RO_OUT=$(ACFW_TRUNK_ROOT="$RO" bash "$FOCUS_BIN" set whatever 2>&1); RO_RC=$?
chmod 644 "$RO/.gitignore"
check "an unwritable .gitignore refuses with a nonzero status" "[ $RO_RC -ne 0 ]"
check "...and never claims the focus was set" "! printf '%s' \"\$RO_OUT\" | grep -q 'focus set:'"
check "...leaving no focus behind" "[ ! -e \"\$RO/.acfwhip/run/focus\" ]"

# --- show --live says when it cannot answer ----------------------------------------------------
# /go step 3 decides whether to launch from this output. Without jq the live path was skipped in
# silence, so a focus of finished tasks looked exactly like a focus of runnable ones.
F set api-014-token >/dev/null
if [ -n "${NOJQ:-}" ]; then
  LIVE_NOJQ=$(env PATH="$NOJQ" ACFW_TRUNK_ROOT="$REPO" "$NOJQ/bash" "$FOCUS_BIN" show --live 2>&1 || true)
  check "show --live without jq says the live state is unavailable" \
    "printf '%s' \"\$LIVE_NOJQ\" | grep -q 'live state unavailable'"
  check "...and still lists the stored selection" "printf '%s' \"\$LIVE_NOJQ\" | grep -q 'api-014-token'"
else
  ok "jq unavailable — show --live already takes the no-jq path everywhere above"
fi

echo
echo "phase18-focus: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
