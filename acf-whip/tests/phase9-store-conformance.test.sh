#!/usr/bin/env bash
# phase9-store-conformance.test.sh — the adapter CONTRACT exerciser (contract v1).
#
# Runs the SAME assertions against any task-store adapter (see adapters/CONTRACT.md):
#   capabilities → init (idempotent) → create (+ duplicate = exit 4) → snapshot fields
#   → full lifecycle with reject loop (rejection-count bump) and re-apply idempotency
#   → block (block-count bump) → read (fields + body sentinel round-trip)
#   → update-field deps → typed errors (invalid state = 7, missing key = 3) → doctor
#   → key resolution (a draft/archived task's full stem is that task, never an active one containing it).
#
# Usage:
#   bash tests/phase9-store-conformance.test.sh                       # files adapter (default)
#   ADAPTER=/path/to/acfw-store-x bash tests/phase9-store-conformance.test.sh
#
# The adapter is invoked DIRECTLY (not through the dispatcher): this test pins the
# adapter side of the contract. Dispatcher behavior is tests/phase9-dispatcher.test.sh.
# Requires node (already a repo test dependency) for order-independent JSON assertions.

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${ADAPTER:-$ACF_WHIP/adapters/files/acfw-store-files}"
[ -x "$ADAPTER" ] || { echo "FATAL: adapter not executable: $ADAPTER" >&2; exit 1; }

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

# jget <json> <expr> — evaluate a node expression over the parsed JSON bound to `j`.
# Order-independent (adapters may emit fields in any order). Objects/arrays print as JSON.
jget(){
  printf '%s' "$1" | node -e '
    let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
      let j; try { j=JSON.parse(d) } catch(e) { process.stdout.write("PARSE-ERROR"); return }
      let v; try { v=eval(process.argv[1]) } catch(e) { v=undefined }
      if (v===undefined||v===null) process.stdout.write("");
      else if (typeof v==="object") process.stdout.write(JSON.stringify(v));
      else process.stdout.write(String(v));
    })' "$2"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p9conf.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .claude/agents; echo "# test-agent" > .claude/agents/test-agent.md
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk
export ACFW_STORE_CONFIG="" ACFW_CONTRACT_VERSION=1 ACFW_PLUGIN_LIB="$ACF_WHIP/skills/lib"

mkdoc(){ # <stem> <worktree> <deps> — a contract-shaped task document on stdout
  cat <<EOF
# Task: Conformance $1

## Metadata

- **ID**: $1
- **Status**: pending
- **Priority**: high
- **Assigned Agent**: test-agent
- **Worktree**: $2
- **PR Group**: $2
- **Touches Globs**: none
- **Dependencies**: $3
- **Rejection Count**: 0
- **Block-Count**: 0

## Description

BODY-SENTINEL-7391 with "quotes" and	a literal tab.

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-07-15 00:00:00 | draft | pending | task-engineer | Initial task creation |
EOF
}

echo "== conformance: $ADAPTER =="

# ---- capabilities ----
CAPS=$("$ADAPTER" capabilities)
check "capabilities is valid JSON with backend name" "[ -n \"\$(jget \"\$CAPS\" 'j.backend')\" ]"
check "capabilities declares contractVersion 1" "[ \"\$(jget \"\$CAPS\" 'j.contractVersion')\" = '1' ]"
check "capabilities lists the required subcommands' caps" "[ -n \"\$(jget \"\$CAPS\" 'j.capabilities.includes(\"snapshot\")&&j.capabilities.includes(\"read\")&&j.capabilities.includes(\"create\")&&j.capabilities.includes(\"transition\")')\" ]"

# ---- init: idempotent ----
if printf '%s' "$CAPS" | grep -q '"init"'; then
  "$ADAPTER" init >/dev/null; R1=$?
  "$ADAPTER" init >/dev/null; R2=$?
  check "init exits 0 and is idempotent" "[ $R1 -eq 0 ] && [ $R2 -eq 0 ]"
else
  ok "init capability absent (skipped)"
fi

# ---- create A (no deps) + B (deps on A) ----
mkdoc conf-a slug-a none > "$WORK/conf-a.md"
OUT=$("$ADAPTER" create --file "$WORK/conf-a.md" --folder pending)
check "create A returns its key" "[ \"\$(jget \"\$OUT\" 'j.key')\" = 'conf-a' ]"
mkdoc conf-b slug-b conf-a > "$WORK/conf-b.md"
OUT=$("$ADAPTER" create --file "$WORK/conf-b.md" --folder pending --set 'Touches Globs=src/**')
check "create B (with --set override) returns its key" "[ \"\$(jget \"\$OUT\" 'j.key')\" = 'conf-b' ]"
"$ADAPTER" create --file "$WORK/conf-a.md" >/dev/null 2>&1; RC=$?
check "duplicate create is a typed conflict (exit 4)" "[ $RC -eq 4 ]"

# ---- snapshot: both tasks, states, deps, counts ----
SNAP=$("$ADAPTER" snapshot)
check "snapshot is valid JSON" "[ \"\$(jget \"\$SNAP\" 'typeof j')\" = 'object' ]"
check "snapshot counts.pending == 2" "[ \"\$(jget \"\$SNAP\" 'j.counts.pending')\" = '2' ]"
check "snapshot carries A as pending" "[ \"\$(jget \"\$SNAP\" 'j.tasks.find(t=>t.stem===\"conf-a\").folder')\" = 'pending' ]"
check "snapshot carries B's dep on A" "[ \"\$(jget \"\$SNAP\" 'j.tasks.find(t=>t.stem===\"conf-b\").deps')\" = '[\"conf-a\"]' ]"
check "snapshot carries B's worktree slug" "[ \"\$(jget \"\$SNAP\" 'j.tasks.find(t=>t.stem===\"conf-b\").slug')\" = 'slug-b' ]"
check "snapshot carries B's --set Touches Globs override" "[ \"\$(jget \"\$SNAP\" 'j.tasks.find(t=>t.stem===\"conf-b\").touchesGlobs')\" = '[\"src/**\"]' ]"

# ---- full lifecycle on A, with a reject loop ----
"$ADAPTER" transition conf-a in-progress orchestrator "dispatch" 0 0 >/dev/null
"$ADAPTER" transition conf-a completed specialist "done" 0 0 >/dev/null
"$ADAPTER" log-event conf-a --row '| 2026-07-15 10:00:00 | clean-checkout | ok | clean-checkout-before-task | slug-a | worktree/slug-a |' >/dev/null 2>&1 || true

# hasCleanCheckoutToken is a flat per-task boolean with NO state qualifier (CONTRACT.md). Two shipped
# adapters answered it for the review states only and emitted false everywhere else, so every task the
# orchestrator lifted from completed into review read the token as absent and had its review skipped.
# Nothing here asserted the field at all, which is why that shipped. Assert it in `completed` FIRST —
# the state both of them got wrong — then again after the move into in-review.
if printf '%s' "$CAPS" | grep -q '"log-event"'; then
  SNAP_C=$("$ADAPTER" snapshot)
  check "hasCleanCheckoutToken is true in COMPLETED, right after log-event" \
    "[ \"\$(jget \"\$SNAP_C\" 'j.tasks.find(t=>t.stem===\"conf-a\").hasCleanCheckoutToken')\" = 'true' ]"
  check "a task that never logged one still reports false (not blanket true)" \
    "[ \"\$(jget \"\$SNAP_C\" 'j.tasks.find(t=>t.stem===\"conf-b\").hasCleanCheckoutToken')\" = 'false' ]"
else
  ok "log-event capability absent (token assertions skipped)"
fi

"$ADAPTER" transition conf-a in-review orchestrator "review" 0 0 >/dev/null
if printf '%s' "$CAPS" | grep -q '"log-event"'; then
  SNAP_R=$("$ADAPTER" snapshot)
  check "hasCleanCheckoutToken survives the move into IN-REVIEW" \
    "[ \"\$(jget \"\$SNAP_R\" 'j.tasks.find(t=>t.stem===\"conf-a\").hasCleanCheckoutToken')\" = 'true' ]"
fi
"$ADAPTER" transition conf-a rejected quality-reviewer "needs work" 1 0 >/dev/null
RD=$("$ADAPTER" read conf-a)
check "reject with RINC=1 bumped rejection_count to 1" "[ \"\$(jget \"\$RD\" 'j.fields.rejection_count')\" = '1' ]"
check "read reports current folder rejected" "[ \"\$(jget \"\$RD\" 'j.folder')\" = 'rejected' ]"
"$ADAPTER" transition conf-a pending orchestrator "retry" 0 0 >/dev/null
"$ADAPTER" transition conf-a in-progress orchestrator "redispatch" 0 0 >/dev/null
"$ADAPTER" transition conf-a completed specialist "done again" 0 0 >/dev/null
"$ADAPTER" transition conf-a in-review orchestrator "review" 0 0 >/dev/null
"$ADAPTER" transition conf-a accepted quality-reviewer "ship it" 0 0 >/dev/null
if printf '%s' "$CAPS" | grep -q '"log-event"'; then
  # The generic battery WARNs on an accepted task with no token, so an adapter that stops answering
  # after in-review turns every accepted task into a standing false advisory.
  #
  # But an accepted task need not be LISTED at all: `files` collapses terminal accepted tasks out of
  # tasks[] into counts + satisfiedDeps to keep the snapshot small enough for an agent to echo
  # verbatim. Absent is legal; present-and-false is not. Assert the conditional, so this passes on a
  # collapsing adapter without going vacuous on a listing one.
  SNAP_A=$("$ADAPTER" snapshot)
  # Three shapes are legal for an accepted task: collapsed out of tasks[] entirely (files does this
  # for terminal accepted work), present as a slim dependency stub, or present in full WITH its token.
  # Present-in-full-and-false is legal ONLY for an adapter that does not declare `token-all-states` —
  # where each answer costs a request, bounding the paid set to the review states is the right trade,
  # and the declaration is what stops a consumer reading that `false` as "no token".
  A_TOK=$(jget "$SNAP_A" 'j.tasks.some(t=>t.stem==="conf-a") ? (j.tasks.find(t=>t.stem==="conf-a").slim ? "slim" : String(j.tasks.find(t=>t.stem==="conf-a").hasCleanCheckoutToken)) : "absent"')
  if printf '%s' "$CAPS" | grep -q '"token-all-states"'; then
    check "accepted task reports its token (adapter declares token-all-states; got: $A_TOK)" \
      "[ \"\$A_TOK\" = 'absent' ] || [ \"\$A_TOK\" = 'slim' ] || [ \"\$A_TOK\" = 'true' ]"
  else
    check "accepted task is collapsed, slim, or reports a token the adapter admits it did not scan (got: $A_TOK)" \
      "[ \"\$A_TOK\" = 'absent' ] || [ \"\$A_TOK\" = 'slim' ] || [ \"\$A_TOK\" = 'true' ] || [ \"\$A_TOK\" = 'false' ]"
  fi
fi
RD=$("$ADAPTER" read conf-a)
check "A reached accepted" "[ \"\$(jget \"\$RD\" 'j.folder')\" = 'accepted' ]"
check "reject loop did not double-bump rejection_count" "[ \"\$(jget \"\$RD\" 'j.fields.rejection_count')\" = '1' ]"

# ---- re-apply idempotency ----
OUT=$("$ADAPTER" transition conf-a accepted quality-reviewer "ship it" 0 0); RC=$?
check "re-applied transition exits 0" "[ $RC -eq 0 ]"
check "re-applied transition reports a no-op" "printf '%s' \"\$OUT\" | grep -qi noop"
RD=$("$ADAPTER" read conf-a)
check "re-apply did not bump counters" "[ \"\$(jget \"\$RD\" 'j.fields.rejection_count')\" = '1' ]"

# ---- block B with BINC=1 ----
"$ADAPTER" transition conf-b in-progress orchestrator "dispatch" 0 0 >/dev/null
"$ADAPTER" transition conf-b blocked specialist "blocked on env" 0 1 >/dev/null
RD=$("$ADAPTER" read conf-b)
check "block with BINC=1 bumped block_count to 1" "[ \"\$(jget \"\$RD\" 'j.fields.block_count')\" = '1' ]"
check "B is in blocked" "[ \"\$(jget \"\$RD\" 'j.folder')\" = 'blocked' ]"

# ---- read: fields + body sentinel round-trip ----
RD=$("$ADAPTER" read --body conf-b)
check "read fields carry worktree slug" "[ \"\$(jget \"\$RD\" 'j.fields.worktree')\" = 'slug-b' ]"
check "read fields carry agent" "[ \"\$(jget \"\$RD\" 'j.fields.agent')\" = 'test-agent' ]"
BODY=$(jget "$RD" 'j.body')
check "body round-trips the sentinel" "printf '%s' \"\$BODY\" | grep -q 'BODY-SENTINEL-7391'"
check "body round-trips embedded double quotes" "printf '%s' \"\$BODY\" | grep -q 'with \"quotes\"'"
check "body round-trips a literal tab" "printf '%s' \"\$BODY\" | grep -q \"\$(printf 'and\ta literal tab')\""

# ---- materialize: a readable task document at a printed path ----
mkdir -p "$WORK/specs"
MAT=$("$ADAPTER" read --materialize "$WORK/specs" conf-b)
check "materialize prints an existing file path" "[ -f \"\$MAT\" ]"
check "materialized document contains the body sentinel" "grep -q 'BODY-SENTINEL-7391' \"\$MAT\""
check "materialized document carries the Worktree field" "grep -qE '^- \*\*Worktree\*\*: slug-b' \"\$MAT\""

# ---- update-field ----
if printf '%s' "$CAPS" | grep -q '"update-field"'; then
  "$ADAPTER" update-field conf-b --set 'Priority=low' >/dev/null
  "$ADAPTER" update-field conf-b --add-dep conf-extra >/dev/null 2>&1 || \
    "$ADAPTER" update-field conf-b --set 'Dependencies=conf-a, conf-extra' >/dev/null
  RD=$("$ADAPTER" read conf-b)
  check "update-field --set changed priority" "[ \"\$(jget \"\$RD\" 'j.fields.priority')\" = 'low' ]"
  SNAP=$("$ADAPTER" snapshot)
  check "snapshot reflects the added dependency" "[ \"\$(jget \"\$SNAP\" 'j.tasks.find(t=>t.stem===\"conf-b\").deps.includes(\"conf-extra\")')\" = 'true' ]"
else
  ok "update-field capability absent (skipped)"
fi

# ---- typed errors ----
"$ADAPTER" transition conf-b not-a-state >/dev/null 2>&1; RC=$?
check "invalid TO_STATE is exit 7" "[ $RC -eq 7 ]"
"$ADAPTER" read no-such-task-xyz >/dev/null 2>&1; RC=$?
check "read of a missing key is exit 3" "[ $RC -eq 3 ]"
"$ADAPTER" transition no-such-task-xyz pending >/dev/null 2>&1; RC=$?
check "transition of a missing key is exit 3" "[ $RC -eq 3 ]"

# ---- doctor: runs and emits the SUMMARY protocol ----
if printf '%s' "$CAPS" | grep -q '"doctor"'; then
  DOC=$("$ADAPTER" doctor 2>/dev/null || true)
  check "doctor emits a SUMMARY line" "printf '%s\n' \"\$DOC\" | grep -q '^SUMMARY|'"

  # --quiet suppresses the ADVISORY dump, never the gate decision. Without doctor-complete the
  # dispatcher recomputes ok= from the lines it RECEIVES, so an adapter that swallows its FATALs
  # under --quiet reports a clean board to /go's startup gate while the verbose operator path shows
  # the same FATAL. Two adapters shipped that way; nothing here asserted otherwise.
  DOCQ=$("$ADAPTER" doctor --quiet 2>/dev/null || true)
  check "doctor --quiet still emits the SUMMARY line" "printf '%s\n' \"\$DOCQ\" | grep -q '^SUMMARY|'"
  check "doctor --quiet emits no REPAIRABLE/WARN advisory lines" \
    "! printf '%s\n' \"\$DOCQ\" | grep -qE '^(REPAIRABLE|WARN)\\|'"
  # If the board carries a FATAL, --quiet MUST still show it. Assert the invariant that binds the
  # two outputs, so this holds on a clean board too rather than silently checking nothing.
  NF=$(printf '%s\n' "$DOC"  | grep -c '^FATAL|' || true); NF=${NF//[^0-9]/}
  NFQ=$(printf '%s\n' "$DOCQ" | grep -c '^FATAL|' || true); NFQ=${NFQ//[^0-9]/}
  check "doctor --quiet keeps every FATAL line the verbose run reported ($NF)" "[ \"\${NFQ:-0}\" -eq \"\${NF:-0}\" ]"
  check "doctor --quiet agrees with the verbose run on ok=" \
    "[ \"\$(printf '%s\n' \"\$DOC\" | sed -n 's/.*|ok=\\(.*\\)/\\1/p' | tail -1)\" = \"\$(printf '%s\n' \"\$DOCQ\" | sed -n 's/.*|ok=\\(.*\\)/\\1/p' | tail -1)\" ]"

  # A state outside the whip vocabulary is quarantine, not corruption: inert to the scheduler, so it
  # must never gate a run. One such card produced the only FATAL on a large board.
  check "doctor reports an out-of-vocabulary state as WARN, never FATAL" \
    "! printf '%s\n' \"\$DOC\" | grep -q '^FATAL|invalid-state|'"
else
  ok "doctor capability absent (skipped)"
fi

# ---- key resolution: a FULL stem names that task, in every state ----
# The key is the task's identity (CONTRACT.md "Task model"): a prefix MAY be accepted, but a full stem
# that names a real task must answer for THAT task, wherever it sits. files looked for an exact stem in
# the active folders only, then fell through to a substring glob that also saw only the active folders.
# So a paused (draft) or cancelled (archive) task's full stem either came back exit 3 — a task that
# exists reported as missing — or, once any active stem CONTAINED it, resolved to that active task and
# returned its folder, fields and body as if it were the one asked for. The resolver is shared, so the
# same full stem also steered transition/update-field/log-event into the wrong document. Draft is how
# /whip-move pauses work on every backend (3.4.0).
#
# Parked by TRANSITION, not `create --folder draft|archive`: both targets are contract-legal on every
# adapter ("archive is a legal target"), so the setup cannot fail for a reason this case is not about.
# Each parked task is read TWICE — before its decoy exists (the false-not-found path) and after (the
# wrong-task path) — because the two failures need different board shapes and both shipped.
# Last in the file so the added cards cannot perturb any assertion above, the doctor's included.
mkdoc conf-park slug-park none > "$WORK/conf-park.md"
mkdoc conf-gone slug-gone none > "$WORK/conf-gone.md"
"$ADAPTER" create --file "$WORK/conf-park.md" --folder pending >/dev/null
"$ADAPTER" create --file "$WORK/conf-gone.md" --folder pending >/dev/null
"$ADAPTER" transition conf-park draft orchestrator "pause" 0 0 >/dev/null
"$ADAPTER" transition conf-gone archive orchestrator "cancel" 0 0 >/dev/null

RD=$("$ADAPTER" read conf-park 2>/dev/null); RC=$?
check "read of a DRAFT task's full stem finds it (exit 0; got $RC)" "[ $RC -eq 0 ]"
check "...and reports it in draft" "[ \"\$(jget \"\$RD\" 'j.stem+\"@\"+j.folder')\" = 'conf-park@draft' ]"
RD=$("$ADAPTER" read conf-gone 2>/dev/null); RC=$?
check "read of an ARCHIVED task's full stem finds it (exit 0; got $RC)" "[ $RC -eq 0 ]"
check "...and reports it in archive" "[ \"\$(jget \"\$RD\" 'j.stem+\"@\"+j.folder')\" = 'conf-gone@archive' ]"

# Decoys: ACTIVE tasks whose stems contain the parked ones' full stems.
mkdoc conf-park-next slug-park-next none > "$WORK/conf-park-next.md"
mkdoc conf-gone-next slug-gone-next none > "$WORK/conf-gone-next.md"
"$ADAPTER" create --file "$WORK/conf-park-next.md" --folder pending >/dev/null
"$ADAPTER" create --file "$WORK/conf-gone-next.md" --folder pending >/dev/null

RD=$("$ADAPTER" read conf-park 2>/dev/null)
check "a full stem of a draft task returns that task, never an active task containing it" \
  "[ \"\$(jget \"\$RD\" 'j.stem+\"@\"+j.folder')\" = 'conf-park@draft' ]"
RD=$("$ADAPTER" read conf-gone 2>/dev/null)
check "a full stem of an archived task returns that task, never an active task containing it" \
  "[ \"\$(jget \"\$RD\" 'j.stem+\"@\"+j.folder')\" = 'conf-gone@archive' ]"
# The write side of the same resolver, where the wrong answer is not a bad read but a moved card:
# re-applying the parked task's own state is a contract no-op, and must not park the decoy instead.
OUT=$("$ADAPTER" transition conf-park draft orchestrator "pause again" 0 0 2>&1); RC=$?
check "re-parking a draft task by full stem is a no-op (exit 0; got $RC)" \
  "[ $RC -eq 0 ] && printf '%s' \"\$OUT\" | grep -qi noop"
RD=$("$ADAPTER" read conf-park-next 2>/dev/null)
check "...and the active task containing its stem was not moved" \
  "[ \"\$(jget \"\$RD\" 'j.stem+\"@\"+j.folder')\" = 'conf-park-next@pending' ]"

echo
echo "phase9-store-conformance ($(basename "$ADAPTER")): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
