#!/usr/bin/env bash
# phase21-spec-tools.test.sh: the spec-tool engine `acfw-spec` (acf-whip 3.5.0, plan section 7).
#
# WHAT A SPEC TOOL IS. Any reviewer, linter, debugger or editing workbench plugs into the cycle through
# ONE committed file, `.acfwhip/spec-tools/<name>` (key=value, never sourced), and the engine is the only
# thing that ever runs one. That single choke point is what makes the guarantees below enforceable at
# all, so this suite drives the engine as a black box with a fake tool (fixtures/spec-tool-fake.sh) and
# pins what a caller can observe: exit codes, the machine lines acfw-cycle and whip-task parse
# (TOOL| REVIEWED| END| ROW| FACT| CARD| AGENT| FROM| ANSWER|), the files the plan names
# (.acfwhip/run/spec/..., .acfwhip/run/workbench/<key>, .acfwhip/run/cycle/<ID>/pending.log), and how
# many times the tool actually ran. It was written from the plan and INTERFACES.md before the engine
# existed (TDD from the spec, not the code). It never reads acfw-spec except for the static no-tool-names
# check.
#
# WHY EACH GROUP EXISTS (the failure it prevents):
#   no declarations  a project that never opts in must see byte-identical output: zero lines, zero state
#   parse errors     a declaration is committed text other people wrote; a bad one must refuse (exit 2),
#                    never run, never be sourced (a `$(...)` line in it must stay inert)
#   secret lint      a committed declaration is the one place a key would leak to every clone; exit 20
#                    says rotate, never echoes the key, and the SHIPPED examples must pass their own lint
#   redaction        refusing to RUN is not enough: an error, a CARD or the REVIEW block about a
#                    declaration quotes its text, and must not print the key it is complaining about;
#                    pull and prompt refuse a literal like review and push do
#   discovery order  env > project drop-in > shipped > $PATH, like store adapters, or a project cannot
#                    override a shipped driver without forking
#   HEAD policy      a local edit (declaration, driver, env, $PATH) can never LOOSEN a block gate
#   normalization    exit 0/1/3/other -> go/nogo/skip/error, whatever the tool prints
#   unstructured     any linter works with no wrapper: on NO-GO with no records, first 20 lines = findings
#   watchdog         macOS has no setsid/timeout; a hung tool's curl-like grandchild must die with it
#   cache            a paid tool is billed once per blob; errors and skips are retried, never cached
#   rerun=ask        a paid tool does not re-bill on every edit; the card says its result is stale
#   gate             approve needs GO at the exact bytes or a recorded override; ACFW_SPEC=off is not
#                    an override
#   budget           a block tool the engine never started (budget spent) is not a result the gate
#                    passes, or a slow tool ahead of it would switch the gate off
#   task parallelism the task stage runs at most 4 tools at once, and genuinely more than 1
#   F1..F8           the card cap cuts only below high: every critical/high finding is shown
#   ROW hygiene      Plan Log rows are committed: no URL, no capability link, no raw `|`, no C0 bytes
#   workbench (dir)  push/pull is a 3-way merge that never loses either side, never commits, and the
#                    gate refuses while the plan is OUT
#   ANSWER/--from    workbench decisions come back as replies; a spec can start in the workbench
#   trust            a new or changed declaration is shown and skipped once before it ever runs
#   AGENT|           prompt-only tools become work orders for the session (exit 21), then collected
#   store-agnostic   the engine makes zero task-store calls (proved on the multica fake's call log)
#   approve order    acfw-cycle approve checks rule 11, then 10, then the spec gate (12), guarded on
#                    acfw-cycle being present
#   stages           the card, the hook run and the gate agree on which tools gate a plan (committed at=:
#                    plan or absent gates approval, task only holds tasks), or the card offers "yes"
#                    while the gate refuses with advice review can never act on
#   fail closed      a committed block line the strict parser rejects (a trailing comment, Block,
#                    quotes, polcy=) still gates, with the override still available
#   task from HEAD   the task stage's policy and hold come from HEAD at output time: an edited copy,
#                    a dropped at=task, or a result cached before the commit never releases a task
#   secret lint 2    JSON-quoted keys in a tracked .mcp.json; a literal removed only locally is still in
#                    HEAD and still refuses
#   first card       a skip (no key yet) or error does not use up a rerun=ask tool's first card
#   not-run rows     every plan reviewer leaves a Plan Log row at approval, so the retro can tell
#                    "declared but never reviewed these bytes" from "not declared"
#   agent workbench  a push collected after plan.md moved records the bytes the agent drafted from, so
#                    the pull merges instead of fast-forwarding over the edit; a stale order is reissued
#   budget cut       a block tool the shared budget cut short is no result (gate 22, task held)
#   dir sync         a push never overwrites a folder copy edited after the last sync
#   symlinks         a committed link to a dirty or out-of-repo driver runs advisory
#   invalid names    `no_tbd` or a copied `x.example` is flagged, never silently ignored
#   trust binding    "run tools" trusts the version shown in full, never one that changed after the notice,
#                    and never a command the capped status card cut short
#   control chars    a CR, an ESC or a bidi override in a declaration could make the notice show one
#                    command and run another: a declaration error, never trusted or run
#   SUMMARY          a SUMMARY| line that disagrees with the exit code (one planted in the plan and echoed
#                    by a grep, or a later go after a nogo) is NO-GO, never a non-gating error
#   tool versions    a GO from an older committed driver is stale, never current, and never passes a gate
#   gate reasons     a teammate's committed change is not "your local edit"; a reverted experiment gets
#                    its committed GO back instead of a second paid run
#   index flags      assume-unchanged / skip-worktree cannot make an edited block driver look clean
#   lint scope       JSON field names in plans and tasks ("partitionKey") are not credentials; .mcp.json is
#   echo redaction   a workbench URL token never reaches status or push output
#   dir from path    a path outside the workbench folder is refused, never swapped for a same-named file
#   AGENT| quoting   the prompt command runs as printed from a checkout path holding an apostrophe
#
# INTERPRETATIONS this suite commits to where the plan leaves room (each is asserted; a failure on one of
# these may be a disagreement about the reading rather than a bug, and says so in its message):
#   I1 "runs advisory" (plan 7, APPROVE) means the run's verdict can never SATISFY a block gate: an edited
#      declaration, a dirty driver, or a driver found via env/$PATH yields gate 22 for a HEAD block tool.
#      The only reading under which "a local edit therefore cannot loosen a gate" holds.
#   I2 Trust on first use is explicit consent: a new or changed declaration (or the executable it would
#      run) is printed and skipped on every run until the operator's "run tools" reply, which the engine
#      takes as `acfw-spec trust [<name>|<name>=<key>...]`; the trust lands in .acfwhip/run/spec/trusted as
#      "<name> <sha>". The reply trusts only the version the operator was SHOWN IN FULL (a TRUST| notice:
#      every declaration line, uncapped), never one that changed after the notice, and never one seen
#      only on a status CARD, whose cells are capped at 160 characters. So every section "primes" the way
#      a person does: status shows the card, "run tools" prints the full notice, and "run tools" again
#      trusts. It re-primes after it changes a declaration or moves/dirties a driver.
#   I3 Plan-stage key = the cycle ID (ACFW_SPEC_KEY, .acfwhip/run/workbench/<ID>, <ID>.conflict.md).
#   I4 "A pull ends OUT" means a completed pull ENDS the OUT state (gate stops returning 26). A conflicting
#      pull (23) or a refused one (24) leaves it OUT; --drop ends it without touching the plan.
#   I5 `review --stage task --machine` REVIEWED task-id: the task files here set `- **ID**:` equal to the
#      file stem, so either reading matches.
#   I6 ACFW_SPEC=off means the engine runs no tool; the gate still refuses a block tool without an override.
#   I7 An agent= prompt path resolves next to the declaration (.acfwhip/spec-tools/); a copy also sits at
#      the repo root so a repo-relative reading resolves too.
#
# Offline: every tool is the fake or a shipped offline driver (dir). GAPTRAP_* is unset and any stray
# network attempt is pointed at 127.0.0.1:9 (discard). Runs the engine under /bin/bash (3.2 on macOS).
#
# Run: bash acf-whip/tests/phase21-spec-tools.test.sh
set -u
ACF_WHIP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE="$ACF_WHIP_SRC/tests/fixtures/spec-tool-fake.sh"
REAL_SPEC="$ACF_WHIP_SRC/skills/lib/bin/acfw-spec"
EMAIL="spec.tester@example.test"
ID="20260928-seat-notice"
CALL_TIMEOUT=150

PASS=0 FAIL=0 SKIPS=0
RC=0 OUT="" ERR="" LAST="(none)"
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){
  FAIL=$((FAIL+1)); echo "  FAIL: $1"
  echo "        last call: $LAST -> rc=$RC"
  [ -n "$OUT" ] && printf '%s\n' "$OUT" | head -3 | sed 's/^/        out| /'
  [ -n "$ERR" ] && printf '%s\n' "$ERR" | head -3 | sed 's/^/        err| /'
  return 0
}
skip(){ SKIPS=$((SKIPS+1)); echo "  SKIP: $1"; }
t(){ local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
not(){ ! "$@"; }
sec(){ echo; echo "== $1"; }

# Output predicates over the LAST engine call (stdout = OUT, stderr = ERR).
has(){ printf '%s\n' "$OUT" | grep -q -- "$1"; }
hasE(){ printf '%s\n' "$OUT" | grep -Eq -- "$1"; }
either_i(){ printf '%s\n%s\n' "$OUT" "$ERR" | grep -iq -- "$1"; }
rc(){ [ "$RC" -eq "$1" ]; }
rc_not(){ [ "$RC" -ne "$1" ]; }
line_of(){ printf '%s\n' "$OUT" | grep -E -- "$1" | head -1; }
count_of(){ printf '%s\n' "$OUT" | grep -Ec -- "$1"; }
C0RE=$(printf '[\001-\011\013-\037]')   # every C0 byte except the line terminator itself
has_bytes(){ LC_ALL=C grep -q "$(printf "$2")" "$1"; }   # <file> <octal escapes>: raw byte sequence present

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p21.XXXXXX")
ours(){ ps -o command= -p "$1" 2>/dev/null | grep -q -- "$2"; }   # <pid> <pattern>: alive AND still ours
cleanup(){
  # A broken watchdog leaves the fake and its curl-like grandchild alive. Reap every one the fake ever
  # recorded, but only while that pid still runs what the fake started: pids are reused, and a kill by
  # a stale number could land on an unrelated process. No process-GROUP kill, for the same reason (and
  # because an engine that never setpgrp'd its tool leaves the fake in this suite's own group).
  local d p
  for d in "$WORK"/ctl-*; do
    [ -d "$d" ] || continue
    for p in $(cat "$d/grandchild.pids" "$d/sleep.pids" 2>/dev/null); do ours "$p" 'sleep' && kill -KILL "$p" 2>/dev/null; done
    for p in $(cat "$d/fake.pids" 2>/dev/null); do ours "$p" 'spec-tool-fake' && kill -KILL "$p" 2>/dev/null; done
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Environment hygiene: nothing from the operator's shell may steer the engine.
unset ACFW_SPEC ACFW_SPEC_TOOL_PATH ACFW_WORKBENCH_DIR CLAUDE_PLUGIN_ROOT ACFW_STORE ACFW_STORE_ADAPTER_PATH \
      GAPTRAP_API_KEY GAPTRAP_APP_URL GAPTRAP_TEMPLATE_ID ACFW_LOG_ROW_CAP ACFW_INTEGRATION_MODE \
      ACFW_MULTICA_BIN MC_FAKE_STATE MC_FAKE_LOG 2>/dev/null || true
for v in $(env | sed -n 's/^\(ACFW_SPEC_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
export GAPTRAP_MCP_URL="http://127.0.0.1:9/mcp"
ORIG_PATH="$PATH"

# A private copy of the plugin: discovery tier 3 is <plugin>/spec-tools/<name>/, and this suite must drop
# a driver there without touching the real tree. The engine finds its plugin root from its own location.
PLUGIN="$WORK/plugin"
cp -R "$ACF_WHIP_SRC" "$PLUGIN" 2>/dev/null
SPEC="$PLUGIN/skills/lib/bin/acfw-spec"
CYCLE="$PLUGIN/skills/lib/bin/acfw-cycle"

# Every engine call: /bin/bash (3.2 on macOS), stdin closed, and a per-call alarm so a hung engine fails
# this suite instead of stalling run-all forever.
S(){ perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$CALL_TIMEOUT" /bin/bash "$SPEC" "$@" </dev/null; }
sx(){ S "$@" >"$WORK/o" 2>"$WORK/e"; RC=$?; OUT=$(cat "$WORK/o"); ERR=$(cat "$WORK/e"); LAST="acfw-spec $*"; }
CYC(){ perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$CALL_TIMEOUT" /bin/bash "$CYCLE" "$@" </dev/null; }
cx(){ CYC "$@" >"$WORK/o" 2>"$WORK/e"; RC=$?; OUT=$(cat "$WORK/o"); ERR=$(cat "$WORK/e"); LAST="acfw-cycle $*"; }

rep(){ local s="" i=0; while [ "$i" -lt "$2" ]; do s="$s$1"; i=$((i+1)); done; printf '%s' "$s"; }

# ---------------------------------------------------------------------------------------------------
# Fixtures: a scratch repo holding one DRAFT cycle (untracked, as /whip leaves a draft).
plan_body(){ cat <<'EOF'
# Seat notice

## Problem
Owners cannot see seat notices.
**Actor & trigger**: an owner opens the billing page.

## Scope
Show a notice on the billing page.

## Non-scope
Email delivery.

## Assumptions
Notices are per workspace.

## Risks
Shell bait $(touch PWNED-SUBST) and `touch PWNED-TICK` must stay inert text.

## Deliverables
<!-- D-ids are permanent: new work takes the next unused number. -->

### D1: Owner sees the notice
- AC1.1: the notice renders for owners

### D2: Admin can dismiss it
- AC2.1: dismissing hides it for the workspace

### D3: Audit row written
- AC3.1: every dismissal writes one audit row
EOF
}
write_record(){ # [| Dn | stems | rows...]
  { cat <<EOF
<!-- acf-whip cycle record. Written only by acfw-cycle. The folder name is the ID: never rename or move it.
     plan.md edits re-arm approval. Frozen once Status is closed or abandoned. -->
# Cycle Record: Seat notice

## Metadata
<!-- DO NOT EDIT MANUALLY - acfw-cycle writes this section -->
- **Format**: 1
- **ID**: $ID
- **Status**: draft
- **Kind**: feature
- **Source**: /whip draft
- **Created By**: $EMAIL
- **Created At**: 2026-09-28 10:00:00 UTC
- **Approved By**:
- **Approved At**:
- **Approved Content**:
- **Retro**:

## Tasks
<!-- DO NOT EDIT MANUALLY - acfw-cycle writes this section -->
| Deliverable | Tasks |
|---|---|
EOF
    for r in "$@"; do printf '%s\n' "$r"; done
    cat <<'EOF'

## Plan Log
<!-- DO NOT EDIT MANUALLY - acfw-cycle writes this section (newest first) -->
| Date Time | Event | By | Content | Details |
|---|---|---|---|---|
EOF
  } > "$REPO/docs/cycles/$ID/record.md"
}
new_repo(){ # <name>: fresh repo, cd into it, PLAN points at its draft cycle
  REPO="$WORK/r-$1"
  git init -q -b main "$REPO" && cd "$REPO" || { echo "cannot create $REPO"; exit 1; }
  git config user.email "$EMAIL"; git config user.name "Spec Tester"; git config commit.gpgsign false
  printf '.acfwhip/run/\n' > .gitignore          # what whip-init writes
  echo seed > seed.txt
  git add .gitignore seed.txt && git commit -qm seed
  mkdir -p "docs/cycles/$ID"
  PLAN="docs/cycles/$ID/plan.md"
  plan_body > "$PLAN"; write_record
  export ACFW_TRUNK_ROOT="$REPO"
  PATH="$ORIG_PATH"; unset ACFW_SPEC_TOOL_PATH ACFW_SPEC 2>/dev/null || true
}
decl(){ local n="$1"; shift; mkdir -p "$REPO/.acfwhip/spec-tools"; printf '%s\n' "$@" > "$REPO/.acfwhip/spec-tools/$n"; }
commit_all(){ # stage declarations + project drivers by pathspec (never -A), commit
  local p=".acfwhip/spec-tools"; [ -d "$REPO/.acfwhip/adapters" ] && p="$p .acfwhip/adapters"
  # shellcheck disable=SC2086
  git -C "$REPO" add -A -- $p && git -C "$REPO" commit -qm "${1:-spec tools}" >/dev/null 2>&1
}
mkctl(){ local d="$WORK/ctl-$1"; rm -rf "$d"; mkdir -p "$d"; : > "$d/calls"; printf '%s' "$d"; }
rcmd(){ printf "/bin/bash '%s' --ctl '%s' --tag %s" "$FAKE" "$1" "${2:-rv}"; }
mkdrv(){ # <dir> <name> <ctl> <tag>: install the fake as driver executable acfw-spec-<name>
  mkdir -p "$1"
  printf '#!/bin/bash\nexec /bin/bash %s --ctl %s --tag %s "$@"\n' "'$FAKE'" "'$3'" "$4" > "$1/acfw-spec-$2"
  chmod +x "$1/acfw-spec-$2"
}
ncalls(){ grep -c "^${2:-review} " "$1/calls" 2>/dev/null || true; }
last_tag(){ grep '^review ' "$1/calls" | tail -1 | sed -n 's/.* tag=\([^ ]*\) .*/\1/p'; }
prime(){ S status --machine >/dev/null 2>&1; S trust >/dev/null 2>&1; S trust >/dev/null 2>&1; }   # I2: card, notice, reply
prime_task(){ prime; }                  # trust is per declaration + executable, not per stage
bump(){ printf 'Note: %s\n' "$1" >> "$REPO/$PLAN"; }
c12(){ git -C "$REPO" hash-object "$REPO/$PLAN" | cut -c1-12; }    # fixtures are already normalized
set_ctl(){ printf '%s\n' "$3" > "$1/$2"; }                          # <ctl> <file> <content>
rows(){ printf '%s\n' "$OUT" | grep '^ROW|'; }
reviewed_row(){ printf '%s\n' "$OUT" | grep "^ROW|reviewed|$1|" | head -1; }
rows_have_no_url(){ [ -n "$(rows)" ] && ! rows | grep -q "://"; }       # anchored: needs >= 1 ROW
rows_have_no_c0(){ [ -n "$(rows)" ] && ! rows | LC_ALL=C grep -q "$C0RE"; }
rows_have_five_cells(){ [ -n "$(rows)" ] && rows | awk -F'|' 'NF != 5 { bad=1 } END { exit bad }'; }
details_short(){ [ -n "$(rows)" ] && rows | cut -d'|' -f5- | awk '{ if (length($0) > 160) bad=1 } END { exit bad }'; }
mktask(){ # <dir> <stem> <salt>: a files-backend task document whose ID equals its stem (I5)
  mkdir -p "$1"
  cat > "$1/$2.md" <<EOF
# $2

## Metadata
- **ID**: $2
- **Status**: pending
- **Worktree**: $2
- **Priority**: medium
- **Agent**: python-engineer
- **Dependencies**: none
- **Rejection Count**: 0

## Description
Case $3.
EOF
}
reviewed_line(){ printf '%s\n' "$OUT" | grep "^REVIEWED|$1|$2|" | head -1; }   # <task-id> <tool>
fieldn(){ printf '%s\n' "$1" | cut -d'|' -f"$2"; }
end_matches_reviewed(){
  local n k; n=$(count_of '^REVIEWED\|'); k=$(printf '%s\n' "$OUT" | sed -n 's/^END|lines=\([0-9]*\)$/\1/p' | tail -1)
  [ -n "$k" ] && [ "$k" = "$n" ]
}
state_out(){ # is the plan OUT in a workbench? either status form may carry the fact line
  { S status --machine; S status "$PLAN" --machine; } 2>/dev/null | grep -q '^FACT|OUT '
}
pending_log(){ printf '%s' "$REPO/.acfwhip/run/cycle/$ID/pending.log"; }

echo "phase21-spec-tools: engine=$SPEC"
echo "  /bin/bash: $(/bin/bash --version | head -1)"

# =================================================================================================
sec "the engine exists and names no specific tool"
t "acfw-spec is present and executable" [ -x "$REAL_SPEC" ]
no_tool_names(){ [ -f "$REAL_SPEC" ] && ! grep -qi 'gaptrap' "$REAL_SPEC" && ! grep -Eqiw 'vale' "$REAL_SPEC"; }
t "acfw-spec names no specific tool (no 'gaptrap', no word 'vale'): tools plug in by declaration" no_tool_names
t "the shared secret-pattern file ships (spec-tools/secret-patterns)" [ -s "$ACF_WHIP_SRC/spec-tools/secret-patterns" ]
t "...and the engine reads that one file rather than a private copy of the regexes" \
  grep -q 'secret-patterns' "$REAL_SPEC" 2>/dev/null
t "the protocol page ships (spec-tools/CONTRACT.md)" [ -s "$ACF_WHIP_SRC/spec-tools/CONTRACT.md" ]

# =================================================================================================
sec "no declarations: no output, no state"
new_repo nodecl
C=$(c12)
for cmd in "list --machine" "list --at plan --machine" "list --at task --machine" "status --machine" \
           "status $PLAN --machine" "review $PLAN" "show $PLAN --blob $C" "gate $PLAN --blob $C"; do
  sx $cmd
  t "no spec-tools dir: '$cmd' prints nothing" [ -z "$OUT" ]
  t "...and exits 0" rc 0
done
mkdir -p .acfwhip/spec-tools
printf '# notes about our tools\n' > .acfwhip/spec-tools/README.md
printf '## review\nnot a declaration\n' > .acfwhip/spec-tools/critic.md
for cmd in "list --machine" "status --machine" "review $PLAN" "gate $PLAN --blob $C"; do
  sx $cmd
  t "only files WITH an extension in spec-tools/: '$cmd' still prints nothing (they are not declarations)" [ -z "$OUT" ]
done
t "no declarations: nothing written under .acfwhip/run/spec" [ ! -e "$REPO/.acfwhip/run/spec" ]
t "no declarations: no pending events invented for the cycle" [ ! -s "$(pending_log)" ]

# =================================================================================================
sec "usage errors exit 2"
sx;                     t "no verb -> exit 2" rc 2
sx frobnicate;          t "unknown verb -> exit 2" rc 2
sx gate "$PLAN";        t "gate without --blob -> exit 2" rc 2

# =================================================================================================
sec "declaration parsing: refusals, defaults, never sourced"
new_repo parse
CP=$(mkctl parse); R=$(rcmd "$CP" parse)
decl none1    'at=plan' 'policy=advisory'
decl two1     'driver=fk' "review=$R" 'at=plan'
decl tmolow   "review=$R" 'at=plan' 'timeout=4'
decl tmohigh  "review=$R" 'at=plan' 'timeout=541'
decl tmonan   "review=$R" 'at=plan' 'timeout=soon'
decl badpol   "review=$R" 'at=plan' 'policy=strict'
decl badat    "review=$R" 'at=deploy'
decl badrerun "review=$R" 'at=plan' 'rerun=sometimes'
decl okmin    "review=$R" 'at=plan' 'timeout=5'
decl okmax    "review=$R" 'at=plan,task' 'timeout=540' 'policy=block' 'rerun=ask'
decl okdef    '# comments and blank lines are fine' '' "review=$R" 'at=task'
decl noat     "review=$R"
decl evil     '$(touch "'"$WORK"'/pwn-1")' '`touch "'"$WORK"'/pwn-2"`' 'label=$(touch "'"$WORK"'/pwn-3")' \
              "review=$R" 'at=plan'
commit_all
prime
sx list --machine
for n in none1 two1 tmolow tmohigh tmonan badpol badat badrerun; do
  t "invalid declaration '$n' is not listed as a TOOL (while valid ones are)" eval "has '^TOOL|' && ! has '^TOOL|$n|'"
done
t "valid: okmin -> TOOL|okmin|review|plan|advisory|every|5" has '^TOOL|okmin|review|plan|advisory|every|5$'
t "valid: okmax -> TOOL|okmax|review|plan,task|block|ask|540" has '^TOOL|okmax|review|plan,task|block|ask|540$'
t "valid: okdef (comments, blank line) -> defaults advisory/every/120" has '^TOOL|okdef|review|task|advisory|every|120$'
t "valid: no at= is still a declared tool" has '^TOOL|noat|review|'
sx list --at plan --machine
t "list --at plan: okmin and okmax" eval 'has "^TOOL|okmin|" && has "^TOOL|okmax|"'
t "list --at plan: not a task-only tool" eval 'has "^TOOL|" && ! has "^TOOL|okdef|"'
t "list --at plan: not a tool with no at= (it runs only on an explicit /whip --review)" eval 'has "^TOOL|" && ! has "^TOOL|noat|"'
sx list --at task --machine
t "list --at task: okmax and okdef" eval 'has "^TOOL|okmax|" && has "^TOOL|okdef|"'
t "list --at task: not a plan-only tool" eval 'has "^TOOL|" && ! has "^TOOL|okmin|"'
for n in none1 two1 tmolow tmohigh tmonan badpol badat badrerun; do
  : > "$CP/calls"
  sx review "$PLAN" --tool "$n"
  t "review --tool $n (invalid declaration) -> exit 2" rc 2
  t "...and the tool never ran" [ "$(ncalls "$CP")" = 0 ]
done
sx status --machine
t "status exits 0 even with broken declarations (it reports, it does not refuse)" rc 0
for n in none1 two1 tmolow badpol; do
  t "status has a CARD naming broken declaration '$n'" eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q '$n'"
done
t "status carries the spec-tools fact line (e.g. okmax(plan+task,block...))" \
  eval "printf '%s\n' \"\$OUT\" | grep '^FACT|spec tools:' | grep -q 'okmax(plan+task,block'"
sx review "$PLAN" --tool evil; sx review "$PLAN" --tool evil
saw_evil(){ S list --machine 2>/dev/null | grep -q '^TOOL|evil|' || S status --machine 2>/dev/null | grep '^CARD|' | grep -q evil; }
t "declarations are never sourced: the engine read 'evil', yet no \$(...), backtick or value substitution ran" \
  eval 'saw_evil && [ ! -e "$WORK/pwn-1" ] && [ ! -e "$WORK/pwn-2" ] && [ ! -e "$WORK/pwn-3" ]'

# =================================================================================================
sec "secret lint"
GT="gtmcp""_$(rep A 44)"
SK="sk""-$(rep b 24)"
LONGVAL="$(rep q 20)"
new_repo secret
CS=$(mkctl secret); R=$(rcmd "$CS" sec)
lint_case(){ # <label> <expect: 20|clean> <review= value> [<the literal, to prove it is never echoed>]
  local lit="${4:-}"
  decl lint "review=$3" 'at=plan'; commit_all "lint $1"
  prime                                  # a secret-bearing declaration must refuse even the trust reply
  : > "$CS/calls"
  sx review "$PLAN"; local r1=$RC o1="$OUT$ERR"
  sx review "$PLAN"; local r2=$RC o2="$OUT$ERR"
  if [ "$2" = 20 ]; then
    RC=$r2; t "secret lint [$1]: review refuses with exit 20" eval "[ $r1 -eq 20 ] && [ $r2 -eq 20 ]"
    t "...the tool never ran" [ "$(ncalls "$CS")" = 0 ]
    t "...the message says to ROTATE the key" eval "printf '%s' \"\$o1\" | grep -qi rotate"
    t "...and never echoes the literal back" eval "! printf '%s' \"\$o1\$o2\" | grep -qF -- \"\$lit\""
    sx status --machine
    t "...status reports it as a CARD (exit 0)" eval 'rc 0 && has "^CARD|"'
    t "...and the card does not echo the literal either" not grep -qF -- "$lit" "$WORK/o"
  else
    RC=$r2; t "secret lint [$1]: not flagged (no exit 20)" eval "[ $r1 -ne 20 ] && [ $r2 -ne 20 ]"
    t "...and the tool ran" [ "$(ncalls "$CS")" -ge 1 ]
  fi
}
lint_case "gtmcp_ key"          20    "$R --arg $GT" "$GT"
lint_case "sk- key"             20    "$R --arg $SK" "$SK"
lint_case "API_KEY=<16+ chars>" 20    "env MY_API_KEY=$LONGVAL $R" "$LONGVAL"
lint_case "KEY=\"\$VAR\" (a reference, not a literal)" clean "env MY_API_KEY=\"\$MY_API_KEY\" $R"
lint_case "short sk- (below length)"   clean "$R --arg sk-short"
lint_case "short gtmcp_ (below length)" clean "$R --arg gtmcp_short"
decl lint "review=$R" 'at=plan'; commit_all "clean lint"; prime
printf '{"mcpServers":{"wb":{"headers":{"Authorization":"Bearer %s"}}}}\n' "$GT" > .mcp.json
printf '.mcp.json\n' >> .gitignore
: > "$CS/calls"; sx review "$PLAN"; sx review "$PLAN"
t "an UNTRACKED (gitignored) .mcp.json key is not flagged: that is where a key belongs" \
  eval 'rc_not 20 && [ "$(ncalls "$CS")" -ge 1 ]'
git add -f .mcp.json && git commit -qm "oops, tracked mcp config"
: > "$CS/calls"; sx review "$PLAN"
t "a TRACKED .mcp.json holding a key literal -> exit 20" rc 20
t "...and no tool ran" [ "$(ncalls "$CS")" = 0 ]
t "...without echoing the key" not grep -qF -- "$GT" "$WORK/o" "$WORK/e"

sec "the shipped example declarations pass their own secret lint"
EXAMPLES=$(find "$ACF_WHIP_SRC/spec-tools" -name '*.example' 2>/dev/null | sort)
t "shipped *.example declarations exist (non-vacuity floor)" [ -n "$EXAMPLES" ]
new_repo examples
for f in $EXAMPLES; do
  n=$(basename "$f" .example); mkdir -p .acfwhip/spec-tools; cp "$f" ".acfwhip/spec-tools/$n"
  for md in "$(dirname "$f")"/*.md; do
    case "$(basename "$md")" in README.md|CONTRACT.md) ;; *) [ -f "$md" ] && cp "$md" .acfwhip/spec-tools/ ;; esac
  done
  echo "    example: ${f#"$ACF_WHIP_SRC"/}"
done
[ -n "$EXAMPLES" ] && commit_all examples
sx status --machine
t "status over every shipped example exits 0" rc 0
t "...with no secret-lint card (rotate/credential/secret)" \
  not eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -Eqi 'rotate|credential|secret|literal'"
sx list --machine
t "list over every shipped example lists them and is not a secret refusal" eval 'rc_not 20 && has "^TOOL|"'
decl leaky "review=true --arg $GT" 'at=plan'; commit_all leaky
sx status --machine
t "positive control: the lint is live in the same repo (a leaky neighbour gets a secret card)" \
  eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -Eqi 'rotate|credential|secret|literal|leaky'"

sec "redaction: no surface echoes a credential-shaped declaration value"
# The lint refuses to RUN; this is about what gets PRINTED. A key pasted into the wrong field
# (driver=<key>) parses as a driver name, is not found, and every error about it quotes the name:
# the list WARN, the status CARD, the REVIEW block the approval card embeds, the gate's reasons.
new_repo redact
LEAKV="sk-$(rep c 24)"
CRD=$(mkctl redact)
decl leakdrv "driver=$LEAKV" 'at=plan' 'policy=block'
decl okr "review=$(rcmd "$CRD")" 'at=plan' 'policy=advisory'
commit_all
C=$(c12)
for cmd in "list" "list --machine" "status" "status --machine" "status $PLAN --machine" "show $PLAN --blob $C" \
           "gate $PLAN --blob $C" "gate $PLAN --blob $C --override leakdrv" "review $PLAN" "trust" "push $PLAN" "prompt leakdrv review"; do
  sx $cmd
  t "'$cmd' never prints the credential-shaped value (stdout or stderr)" \
    eval '! printf "%s\n%s\n" "$OUT" "$ERR" | grep -qF -- "$LEAKV"'
done
sx status --machine
t "...while status still names the broken declaration in a CARD" eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q leakdrv"
t "...and raises the secret card (rotate)" eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -qi rotate"
sx show "$PLAN" --blob "$C"
t "...and the REVIEW block still reports leakdrv's declaration error" eval 'has "leakdrv" && has "declaration error"'
t "the untouched tool never ran while a literal sat in a neighbouring declaration" [ "$(ncalls "$CRD")" = 0 ]

# =================================================================================================
sec "driver discovery order: \$ACFW_SPEC_TOOL_PATH > .acfwhip/adapters/ > <plugin>/spec-tools/<name>/ > \$PATH"
new_repo disc
CD=$(mkctl disc)
mkdrv "$WORK/disc-env"            fk "$CD" env
mkdrv "$REPO/.acfwhip/adapters"   fk "$CD" repo
mkdrv "$PLUGIN/spec-tools/fk"     fk "$CD" plugin
mkdrv "$WORK/disc-path"           fk "$CD" path
decl fk 'driver=fk' 'at=plan' 'policy=advisory'
commit_all
export ACFW_SPEC_TOOL_PATH="$WORK/disc-env"; PATH="$WORK/disc-path:$ORIG_PATH"
# Trust covers the executable that would run, so each tier switch is a new thing to trust.
prime; sx review "$PLAN" --fresh
t "tier 1: \$ACFW_SPEC_TOOL_PATH wins over every other location" [ "$(last_tag "$CD")" = env ]
unset ACFW_SPEC_TOOL_PATH
prime; sx review "$PLAN" --fresh
t "tier 2: the project drop-in .acfwhip/adapters/acfw-spec-fk" [ "$(last_tag "$CD")" = repo ]
rm -f "$REPO/.acfwhip/adapters/acfw-spec-fk"
prime; sx review "$PLAN" --fresh
t "tier 3: the shipped <plugin>/spec-tools/fk/acfw-spec-fk" [ "$(last_tag "$CD")" = plugin ]
rm -rf "$PLUGIN/spec-tools/fk"
prime; sx review "$PLAN" --fresh
t "tier 4: \$PATH" [ "$(last_tag "$CD")" = path ]
rm -f "$WORK/disc-path/acfw-spec-fk"
: > "$CD/calls"
prime; sx review "$PLAN" --fresh
t "no driver anywhere: nothing ran, and the engine did not crash (exit 0 or 2)" \
  eval '[ "$(ncalls "$CD")" = 0 ] && { rc 0 || rc 2; }'
PATH="$ORIG_PATH"

# =================================================================================================
sec "policy comes from HEAD: a local edit can never loosen a block gate (I1)"
# (a) HEAD says block; the working tree edits it to advisory.
new_repo pola
CA=$(mkctl pola); set_ctl "$CA" exit 1
decl blk "review=$(rcmd "$CA")" 'at=plan,task' 'policy=block'; commit_all
prime; bump a1; C=$(c12); sx review "$PLAN"
sx gate "$PLAN" --blob "$C"
t "baseline: a HEAD block tool at NO-GO -> gate 22" rc 22
perl -pi -e 's/^policy=block$/policy=advisory/' .acfwhip/spec-tools/blk
sx review "$PLAN"; o1="$OUT$ERR"; sx review "$PLAN"; o2="$OUT$ERR"
t "a working-tree edit to a declaration is reported with a WARN" eval "printf '%s' \"\$o1\$o2\" | grep -qi warn"
sx gate "$PLAN" --blob "$C"
t "HEAD block + local edit to policy=advisory -> gate STILL 22" rc 22
CA2=$(mkctl pola-go)
decl blk "review=$(rcmd "$CA2" go)" 'at=plan,task' 'policy=advisory'
bump a2; C=$(c12); prime; sx review "$PLAN"; sx review "$PLAN"
sx gate "$PLAN" --blob "$C"
t "...even when the same edit swaps in a command that says GO -> gate 22 (the edited run is advisory only)" rc 22
git checkout -q -- .acfwhip/spec-tools/blk

# (b) HEAD says advisory; the working tree tightens it to block.
new_repo polb
CB=$(mkctl polb); set_ctl "$CB" exit 1
decl adv "review=$(rcmd "$CB")" 'at=plan' 'policy=advisory'; commit_all
perl -pi -e 's/^policy=advisory$/policy=block/' .acfwhip/spec-tools/adv
prime; bump b1; C=$(c12); sx review "$PLAN"; o1="$OUT$ERR"; sx review "$PLAN"; o2="$OUT$ERR"
t "an uncommitted tightening is reported with a WARN" eval "printf '%s' \"\$o1\$o2\" | grep -qi warn"
sx gate "$PLAN" --blob "$C"
t "HEAD advisory + uncommitted policy=block -> gate 0 (policy is read from HEAD)" rc 0

# (c) the declaration is not in HEAD at all.
new_repo polc
CC=$(mkctl polc); set_ctl "$CC" exit 1
decl newblk "review=$(rcmd "$CC")" 'at=plan,task' 'policy=block'        # never committed
prime; bump c1; C=$(c12); sx review "$PLAN"; o1="$OUT$ERR"; sx review "$PLAN"; o2="$OUT$ERR"
t "an uncommitted declaration runs, with a WARN" eval "printf '%s' \"\$o1\$o2\" | grep -qi warn"
sx gate "$PLAN" --blob "$C"
t "an uncommitted policy=block declaration gates nothing -> gate 0" rc 0
TDC="$WORK/tasks-polc"; mktask "$TDC" polc-001-a c; prime_task "$TDC/polc-001-a.md"
sx review --stage task --machine "$TDC/polc-001-a.md"
t "task stage: an uncommitted block declaration reviews as advisory" \
  [ "$(fieldn "$(reviewed_line polc-001-a newblk)" 4)" = advisory ]

# (d) a committed project driver that is dirty against HEAD.
new_repo pold
CDD=$(mkctl pold)                                                       # exit 0: GO
mkdrv "$REPO/.acfwhip/adapters" dd "$CDD" repo
decl dd 'driver=dd' 'at=plan' 'policy=block'; commit_all
prime; bump d1; C=$(c12); sx review "$PLAN"; sx review "$PLAN"
sx gate "$PLAN" --blob "$C"
t "baseline: a clean committed driver's GO satisfies a block gate -> gate 0" rc 0
printf '# local tweak\n' >> "$REPO/.acfwhip/adapters/acfw-spec-dd"
prime                                                    # trust the edited driver, so it really RUNS
bump d2; C=$(c12); sx review "$PLAN"; o1="$OUT$ERR"; sx review "$PLAN"; o2="$OUT$ERR"
t "the dirty driver really ran (so the gate below judges a real GO)" [ "$(ncalls "$CDD")" -ge 2 ]
t "a driver dirty against HEAD is reported with a WARN" eval "printf '%s' \"\$o1\$o2\" | grep -qi warn"
sx gate "$PLAN" --blob "$C"
t "a dirty driver's GO cannot satisfy a block gate -> gate 22" rc 22

# (e)/(f) a driver found via env or $PATH.
for via in env path; do
  new_repo "pol-$via"
  CV=$(mkctl "pol-$via")
  mkdrv "$WORK/drv-$via" vd "$CV" "$via"
  decl vd 'driver=vd' 'at=plan' 'policy=block'; commit_all
  if [ "$via" = env ]; then export ACFW_SPEC_TOOL_PATH="$WORK/drv-$via"; else PATH="$WORK/drv-$via:$ORIG_PATH"; fi
  prime; bump "$via"; C=$(c12); sx review "$PLAN"; o1="$OUT$ERR"; sx review "$PLAN"; o2="$OUT$ERR"
  t "a driver found via $via ran" [ "$(ncalls "$CV")" -ge 1 ]
  t "...with a WARN" eval "printf '%s' \"\$o1\$o2\" | grep -qi warn"
  sx gate "$PLAN" --blob "$C"
  t "...and its GO cannot satisfy a block gate -> gate 22" rc 22
  unset ACFW_SPEC_TOOL_PATH; PATH="$ORIG_PATH"
done

# =================================================================================================
sec "verdict normalization: exit 0/1/3/other -> go/nogo/skip/error (task stage machine lines)"
new_repo norm
CN=$(mkctl norm); CPO=$(mkctl norm-planonly)
decl tk "review=$(rcmd "$CN" tk)" 'at=plan,task' 'policy=advisory'
decl planonly "review=$(rcmd "$CPO" po)" 'at=plan' 'policy=advisory'
commit_all
TD="$WORK/tasks-norm"
mktask "$TD" norm-000-prime prime; prime; prime_task "$TD/norm-000-prime.md"
norm_case(){ # <stem> <exit> <stdout-lines or ""> <stderr or ""> <expected verdict> [<expected n>]
  rm -f "$CN/stdout" "$CN/stderr"
  set_ctl "$CN" exit "$2"
  [ -n "$3" ] && printf '%b' "$3" > "$CN/stdout"
  [ -n "$4" ] && printf '%s\n' "$4" > "$CN/stderr"
  mktask "$TD" "$1" "$1"
  sx review --stage task --machine "$TD/$1.md"
  local L; L=$(reviewed_line "$1" tk)
  t "exit $2 [$1]: REVIEWED line present" [ -n "$L" ]
  t "exit $2 [$1]: verdict = $5" [ "$(fieldn "$L" 5)" = "$5" ]
  [ -n "${6:-}" ] && t "exit $2 [$1]: n = $6" [ "$(fieldn "$L" 6)" = "$6" ]
  t "exit $2 [$1]: END|lines=<k> matches the REVIEWED count" end_matches_reviewed
  t "exit $2 [$1]: the review verb itself exits 0" rc 0
}
norm_case norm-001-go   0 ""                                                              "" go 0
norm_case norm-002-nogo 1 'FINDING|high|fp-n1|L3|Missing actor\nFINDING|low|fp-n2|-|Nit\n' "" nogo 2
L=$(reviewed_line norm-002-nogo tk)
t "nogo: maxsev = high" [ "$(fieldn "$L" 7)" = high ]
t "nogo: policy field = advisory" [ "$(fieldn "$L" 4)" = advisory ]
FP=$(fieldn "$L" 8)
t "nogo: the findings path exists and holds the finding title" eval '[ -f "$FP" ] && grep -q "Missing actor" "$FP"'
norm_case norm-003-skip 3 "" "quota exhausted for this key" skip
norm_case norm-004-err2 2 "" "" error
norm_case norm-005-err5 5 "" "" error
norm_case norm-006-err127 127 "" "" error
norm_case norm-007-sumok 1 'FINDING|high|fp-s1|D1|Agreeing summary\nSUMMARY|verdict=nogo\n' "" nogo 1
rm -f "$CN/stdout"; set_ctl "$CN" exit 1; printf 'SUMMARY|verdict=go\n' > "$CN/stdout"
mktask "$TD" norm-008-sumlie lie; sx review --stage task --machine "$TD/norm-008-sumlie.md"
t "a SUMMARY that contradicts the exit code is never go" \
  eval '[ -n "$(reviewed_line norm-008-sumlie tk)" ] && [ "$(fieldn "$(reviewed_line norm-008-sumlie tk)" 5)" != go ]'
rm -f "$CN/stdout"; set_ctl "$CN" exit 0
mktask "$TD" norm-009-a a; mktask "$TD" norm-010-b b
sx review --stage task --machine "$TD/norm-009-a.md" "$TD/norm-010-b.md"
t "two task files in one call -> one REVIEWED line each" \
  eval '[ -n "$(reviewed_line norm-009-a tk)" ] && [ -n "$(reviewed_line norm-010-b tk)" ]'
t "...and END|lines= counts them" end_matches_reviewed
# Scan every env record, not last-env: the task stage may run up to 4 jobs at once, so "last" is a race.
env_saw(){ # <ctl> <line> <line>: one single call's env held both lines
  local f; for f in "$1"/env.*; do [ -f "$f" ] && grep -qx -- "$2" "$f" && grep -qx -- "$3" "$f" && return 0; done; return 1
}
t "task stage: the tool saw ACFW_SPEC_STAGE=task and the task as its key" \
  env_saw "$CN" 'ACFW_SPEC_STAGE=task' 'ACFW_SPEC_KEY=norm-010-b'
t "a plan-only tool never runs at the task stage (while the plan,task tool did)" \
  eval 'grep -q "stage=task" "$CN/calls" && ! grep -q "stage=task" "$CPO/calls"'

# =================================================================================================
sec "unstructured linter output: on NO-GO with no records, the first 20 lines are findings"
i=1; : > "$WORK/noise"; while [ $i -le 25 ]; do printf 'plan.md:%d: lint message number %d\n' $i $i >> "$WORK/noise"; i=$((i+1)); done
cp "$WORK/noise" "$CN/stdout"; set_ctl "$CN" exit 1
mktask "$TD" norm-011-lint lint; sx review --stage task --machine "$TD/norm-011-lint.md"
L=$(reviewed_line norm-011-lint tk)
t "25 plain lines + exit 1 -> nogo" [ "$(fieldn "$L" 5)" = nogo ]
t "...with exactly 20 findings" [ "$(fieldn "$L" 6)" = 20 ]
FP=$(fieldn "$L" 8)
t "...line 1 and line 20 are findings, line 21 is not" \
  eval '[ -f "$FP" ] && grep -Eq "message number 1([^0-9]|\$)" "$FP" && grep -Eq "message number 20([^0-9]|\$)" "$FP" && ! grep -Eq "message number 21([^0-9]|\$)" "$FP"'
set_ctl "$CN" exit 0
mktask "$TD" norm-012-chatty chatty; sx review --stage task --machine "$TD/norm-012-chatty.md"
L=$(reviewed_line norm-012-chatty tk)
t "the same noise with exit 0 -> go with 0 findings (chatter is not a finding)" \
  eval '[ "$(fieldn "$L" 5)" = go ] && [ "$(fieldn "$L" 6)" = 0 ]'
{ cat "$WORK/noise"; printf 'FINDING|medium|fp-u1|L2|Real one\nFINDING|low|fp-u2|L9|Real two\n'; } > "$CN/stdout"; set_ctl "$CN" exit 1
mktask "$TD" norm-013-mixed mixed; sx review --stage task --machine "$TD/norm-013-mixed.md"
t "records present -> only the records are findings (noise ignored)" [ "$(fieldn "$(reviewed_line norm-013-mixed tk)" 6)" = 2 ]
# the plan stage: same fallback, seen through the gate's Plan Log row
new_repo unstr
CU=$(mkctl unstr); cp "$WORK/noise" "$CU/stdout"; set_ctl "$CU" exit 1
decl lint "review=$(rcmd "$CU")" 'at=plan' 'policy=advisory'; commit_all
prime; bump u1; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "plan stage: an advisory NO-GO does not block the gate" rc 0
t "plan stage: the reviewed row reads 'nogo n=20'" hasE "^ROW\\|reviewed\\|lint\\|$C\\|nogo n=20"
# a real linter, shipped: no-tbd is `grep ... ; test $? -eq 1` (a grep error must not read as GO)
NOTBD="$ACF_WHIP_SRC/spec-tools/examples/no-tbd.example"
if [ -f "$NOTBD" ]; then
  new_repo notbd
  mkdir -p .acfwhip/spec-tools
  grep -Ev '^(at|policy)=' "$NOTBD" > .acfwhip/spec-tools/no-tbd; printf 'at=plan,task\npolicy=advisory\n' >> .acfwhip/spec-tools/no-tbd
  commit_all
  TDN="$WORK/tasks-notbd"; mktask "$TDN" tbd-000-prime x; prime; prime_task "$TDN/tbd-000-prime.md"
  mktask "$TDN" tbd-001-clean clean; sx review --stage task --machine "$TDN/tbd-001-clean.md"
  t "shipped no-tbd: a clean task -> go" [ "$(fieldn "$(reviewed_line tbd-001-clean no-tbd)" 5)" = go ]
  mktask "$TDN" tbd-002-dirty dirty; printf 'Retry policy: TBD\n' >> "$TDN/tbd-002-dirty.md"
  sx review --stage task --machine "$TDN/tbd-002-dirty.md"
  L=$(reviewed_line tbd-002-dirty no-tbd)
  t "shipped no-tbd: a TBD -> nogo with its grep line as the one finding" \
    eval '[ "$(fieldn "$L" 5)" = nogo ] && [ "$(fieldn "$L" 6)" = 1 ]'
else
  bad "shipped spec-tools/examples/no-tbd.example is missing (plan 7 ships it)"
fi

# =================================================================================================
sec "watchdog: a hung tool and its curl-like grandchild are reaped (process group, /bin/bash)"
new_repo wd
CW=$(mkctl wd)
decl wd "review=$(rcmd "$CW" wd)" 'at=plan' 'timeout=5' 'policy=advisory'; commit_all
prime; : > "$CW/calls"
cat > "$WORK/wdrun.sh" <<'EOF'
#!/bin/bash
out=$1; shift
"$@" > "$out.o" 2> "$out.e" < /dev/null
echo $? > "$out.rc"
EOF
wd_run(){ # <limit seconds>: review in our OWN process group, so a hang is killable from here
  rm -f "$WORK/wd.rc" "$CW/grandchild.pid" "$CW/fake.pid" "$CW/sleep.pid"
  perl -e 'setpgrp(0,0); exec @ARGV' /bin/bash "$WORK/wdrun.sh" "$WORK/wd" /bin/bash "$SPEC" review "$PLAN" &
  local bg=$! start; start=$(date +%s)
  while [ ! -f "$WORK/wd.rc" ] && [ $(( $(date +%s) - start )) -lt "$1" ]; do sleep 1; done
  WD_SECS=$(( $(date +%s) - start ))
  if [ -f "$WORK/wd.rc" ]; then WD_RC=$(cat "$WORK/wd.rc"); else WD_RC=hung; kill -KILL -"$bg" 2>/dev/null; fi
  wait "$bg" 2>/dev/null
  LAST="acfw-spec review (watchdog)"; RC=0; OUT=$(cat "$WORK/wd.o" 2>/dev/null); ERR=$(cat "$WORK/wd.e" 2>/dev/null)
}
returned_and_dead(){ [ "$WD_RC" != hung ] && dead "$1"; }   # a hung engine gets no credit for OUR kill
dead(){ # <pidfile>: gone within 3s (a reparented zombie is reaped by init almost at once)
  local p i=0; [ -f "$1" ] || return 1; p=$(cat "$1")
  while kill -0 "$p" 2>/dev/null; do [ $i -ge 3 ] && return 1; sleep 1; i=$((i+1)); done
  return 0
}
set_ctl "$CW" sleep 120; set_ctl "$CW" grandchild plain
bump w1; wd_run 60
t "timeout=5: the engine returns instead of hanging on the grandchild's pipe (took ${WD_SECS}s)" [ "$WD_RC" != hung ]
t "...after actually waiting for the timeout (>= 4s), not by skipping the tool" [ "$WD_SECS" -ge 4 ]
t "...within timeout + TERM/KILL grace (<= 45s)" [ "$WD_SECS" -le 45 ]
t "the tool itself is dead" returned_and_dead "$CW/fake.pid"
t "the tool's own hung child (its sleep) is dead, not orphaned" returned_and_dead "$CW/sleep.pid"
t "the curl-like grandchild is dead (killed with the group, not orphaned)" returned_and_dead "$CW/grandchild.pid"
N1=$(ncalls "$CW"); wd_run 60                      # SAME blob: only a non-cached result re-runs
t "a timeout is an error, and errors are not cached: the same bytes run the tool again" \
  eval '[ "$WD_RC" != hung ] && [ "$(ncalls "$CW")" -gt "$N1" ]'
set_ctl "$CW" grandchild ignore-term; : > "$CW/trap-term"
bump w3; wd_run 60
t "TERM-immune tool + grandchild: the engine still returns (KILL follows TERM) (${WD_SECS}s)" [ "$WD_RC" != hung ]
t "...the TERM-immune tool itself is dead (KILL followed the ignored TERM)" returned_and_dead "$CW/fake.pid"
t "...and the TERM-immune grandchild is dead" returned_and_dead "$CW/grandchild.pid"
t "...and so is the TERM-immune tool's hung child" returned_and_dead "$CW/sleep.pid"
rm -f "$CW/trap-term" "$CW/grandchild" "$CW/sleep"

# =================================================================================================
sec "cache: one invocation per blob; skip and error are never cached"
new_repo cache
CK=$(mkctl cache)
decl ca "review=$(rcmd "$CK" ca)" 'at=plan' 'rerun=every' 'policy=advisory'; commit_all; prime
sx review "$PLAN"; sx review "$PLAN"
t "same blob, two reviews: the tool ran exactly once" [ "$(ncalls "$CK")" = 1 ]
sx review "$PLAN"
t "a third review of the same bytes is served from the cache" [ "$(ncalls "$CK")" = 1 ]
sx review "$PLAN" --fresh
t "--fresh bypasses the cache" [ "$(ncalls "$CK")" = 2 ]
bump k1; sx review "$PLAN"
t "an edit (new blob) re-runs a rerun=every tool" [ "$(ncalls "$CK")" = 3 ]
sx review "$PLAN"; t "...once" [ "$(ncalls "$CK")" = 3 ]
C=$(c12); sx show "$PLAN" --blob "$C"; sx gate "$PLAN" --blob "$C"; sx status --machine
t "show, gate and status never run a tool" [ "$(ncalls "$CK")" = 3 ]
set_ctl "$CK" exit 2; bump k2; sx review "$PLAN"; sx review "$PLAN"
t "exit 2 (error) is not cached: two reviews, two runs" [ "$(ncalls "$CK")" = 5 ]
set_ctl "$CK" exit 3; printf 'service unavailable\n' > "$CK/stderr"; bump k3; sx review "$PLAN"; sx review "$PLAN"
t "exit 3 (skip) is not cached: two reviews, two runs" [ "$(ncalls "$CK")" = 7 ]
rm -f "$CK/stderr"; set_ctl "$CK" exit 0; sx review "$PLAN"; sx review "$PLAN"
t "the same blob once the tool answers GO: one run, then cached" [ "$(ncalls "$CK")" = 8 ]
set_ctl "$CK" exit 1; bump k4; sx review "$PLAN"; sx review "$PLAN"
t "NO-GO is cached like GO" [ "$(ncalls "$CK")" = 9 ]
N=$(ncalls "$CK"); decl ca "review=$(rcmd "$CK" ca)" 'at=plan' 'rerun=every' 'policy=advisory' 'timeout=121'; commit_all
sx review "$PLAN"
t "a changed declaration does not run until it is trusted again" [ "$(ncalls "$CK")" = "$N" ]
prime; sx review "$PLAN"; sx review "$PLAN"
t "a committed declaration change is a new cache key: same bytes, exactly one more run" [ "$(ncalls "$CK")" = $((N+1)) ]
CE=$(mkctl cache-eq)
decl eq "review=env ACFW_P21_EQ=1 $(rcmd "$CE" eq)" 'at=plan'; commit_all; prime
sx review "$PLAN"
t "a review= value containing '=' is split on the FIRST '=' only (the command runs)" [ "$(ncalls "$CE")" -ge 1 ]

sec "the tool contract: env inputs, frozen read-only file"
E="$CK/last-env"
t "ACFW_SPEC_VERB=review" grep -q '^ACFW_SPEC_VERB=review$' "$E"
t "ACFW_SPEC_STAGE=plan" grep -q '^ACFW_SPEC_STAGE=plan$' "$E"
t "ACFW_SPEC_KEY is the cycle ID (I3)" grep -q "^ACFW_SPEC_KEY=$ID\$" "$E"
t "ACFW_SPEC_BLOB carries the plan's content hash" grep -q "^ACFW_SPEC_BLOB=.*$(c12)" "$E"
t "ACFW_SPEC_FILE is a frozen copy under .acfwhip/run/spec/, not plan.md itself" \
  eval 'grep -q "^ACFW_SPEC_FILE=.*/\.acfwhip/run/spec/" "$E" && ! grep -q "^ACFW_SPEC_FILE=.*/docs/cycles/" "$E"'
LASTPID=$(grep '^review ' "$CK/calls" | tail -1 | sed -n 's/.* pid=\([0-9]*\) .*/\1/p')
t "...holding exactly the plan bytes" cmp -s "$CK/file.$LASTPID" "$REPO/$PLAN"
t "...and it is read-only" grep -q '^FAKE_FILE_WRITABLE=no$' "$E"
t "ACFW_SPEC_OUT exists as a directory when the tool starts" grep -q '^FAKE_OUT_IS_DIR=yes$' "$E"
t "ACFW_SPEC_STATE exists as a directory" grep -q '^FAKE_STATE_IS_DIR=yes$' "$E"
t "ACFW_SPEC_DEADLINE is an integer" grep -Eq '^ACFW_SPEC_DEADLINE=[0-9]+$' "$E"
TR=$(sed -n 's/^ACFW_TRUNK_ROOT=//p' "$E")
t "ACFW_TRUNK_ROOT is the repo" eval '[ -n "$TR" ] && [ "$(cd "$TR" 2>/dev/null && pwd -P)" = "$(cd "$REPO" && pwd -P)" ]'
S1=$(grep -h '^ACFW_SPEC_STATE=' "$CK"/env.* | sort -u | wc -l | tr -d ' ')
t "ACFW_SPEC_STATE is the same directory across blobs (per tool+key)" [ "$S1" = 1 ]
t "plan text is data: tools read it, yet its \$(...) and backticks never ran" \
  eval '[ "$(ncalls "$CK")" -ge 1 ] && [ -z "$(find "$WORK" -name "PWNED-*" 2>/dev/null)" ]'

# =================================================================================================
sec "rerun=ask: a paid tool runs on the first card, then shows 'stale since your edit'"
new_repo ask
CQ=$(mkctl ask); set_ctl "$CQ" cost "1 unit per review"; set_ctl "$CQ" egress "api.example.test"
CF=$(mkctl ask-free)
mkdrv "$REPO/.acfwhip/adapters" paid "$CQ" paid
mkdrv "$REPO/.acfwhip/adapters" free "$CF" free
decl paid 'driver=paid' 'at=plan'
decl free 'driver=free' 'at=plan'
commit_all
prime; sx review "$PLAN"
t "first card: the paid tool ran exactly once" [ "$(ncalls "$CQ")" = 1 ]
sx list --machine
t "a driver whose capabilities print COST| defaults to rerun=ask" has '^TOOL|paid|driver|plan|advisory|ask|120$'
t "a driver without COST| defaults to rerun=every" has '^TOOL|free|driver|plan|advisory|every|120$'
NF=$(ncalls "$CF")
bump q1; C=$(c12); sx review "$PLAN"
t "after an edit, the paid tool does NOT re-run" [ "$(ncalls "$CQ")" = 1 ]
t "...while the free tool does" [ "$(ncalls "$CF")" -gt "$NF" ]
sx show "$PLAN" --blob "$C"
t "the card shows the paid tool's last result as stale" either_i 'stale'
sx review "$PLAN" --tool paid
t "replying 'review' (an explicit --tool paid) re-runs it" [ "$(ncalls "$CQ")" = 2 ]
sx show "$PLAN" --blob "$C"
t "...and the card (still rendered) is no longer stale" eval '[ -n "$OUT" ] && ! either_i stale'

# =================================================================================================
sec "the card: F/Q numbering, critical first, round labels"
new_repo card
CR=$(mkctl card)
decl crit "review=$(rcmd "$CR")" 'at=plan' 'policy=advisory'; commit_all
prime
printf 'FINDING|low|fp-alpha|D2|Alpha gap\nFINDING|critical|fp-bravo|D1|Bravo gap\nQ|Should owners see it on mobile? (default: yes)\n' > "$CR/stdout"
set_ctl "$CR" exit 1; bump r1; C=$(c12); sx review "$PLAN"; sx show "$PLAN" --blob "$C"
t "show prints the REVIEW block with both findings" eval 'has "Alpha gap" && has "Bravo gap"'
t "findings are numbered and critical comes first (F1 = Bravo)" eval "printf '%s\n' \"\$OUT\" | grep 'F1' | grep -q 'Bravo gap'"
t "the closed question is numbered Q1 with its text" eval 'has "Q1" && has "on mobile"'
printf 'FINDING|critical|fp-bravo|D1|Bravo gap\nFINDING|high|fp-charlie|D3|Charlie gap\n' > "$CR/stdout"
bump r2; C=$(c12); sx review "$PLAN"; sx show "$PLAN" --blob "$C"
t "round 2: a finding seen before is labelled persisting" eval "printf '%s\n' \"\$OUT\" | grep 'Bravo gap' | grep -qi 'persist'"
t "round 2: a first-seen finding is labelled new" eval "printf '%s\n' \"\$OUT\" | grep 'Charlie gap' | grep -qi 'new'"
t "round 2: a finding that went away is reported resolved" either_i 'resolved'
# F1..F8 is a cap on the LOW end only: every critical/high finding is shown, however many there are.
: > "$CR/stdout"; i=1
while [ $i -le 10 ]; do printf 'FINDING|high|fp-cap-h%d|D1|Cap high number %02d\n' $i $i >> "$CR/stdout"; i=$((i+1)); done
printf 'FINDING|medium|fp-cap-m1|D2|Cap medium one\nFINDING|low|fp-cap-l1|D3|Cap low one\n' >> "$CR/stdout"
bump r3; C=$(c12); sx review "$PLAN"; sx show "$PLAN" --blob "$C"
t "ten high findings: all ten shown (critical/high are never cut at F8)" \
  eval '[ "$(printf "%s\n" "$OUT" | grep -Ec "^ *F[0-9]+ .*Cap high number")" = 10 ]'
t "...the tenth is F10" eval "printf '%s\n' \"\$OUT\" | grep -E '^ *F10 ' | grep -q 'Cap high number'"
t "...lower-severity findings are the ones held back" eval '! has "Cap medium one" && ! has "Cap low one"'
t "...and the card says how many it is not showing (+2)" eval "printf '%s\n' \"\$OUT\" | grep -Eq '\\+2 .*not shown'"
: > "$CR/stdout"; printf 'FINDING|high|fp-cap2-h1|D1|Cap2 high\n' >> "$CR/stdout"; i=1
while [ $i -le 10 ]; do printf 'FINDING|medium|fp-cap2-m%d|D2|Cap2 medium %02d\n' $i $i >> "$CR/stdout"; i=$((i+1)); done
bump r4; C=$(c12); sx review "$PLAN"; sx show "$PLAN" --blob "$C"
t "one high + ten medium: exactly F1..F8, the high one first" \
  eval '[ "$(printf "%s\n" "$OUT" | grep -Ec "^ *F[0-9]+ ")" = 8 ] && printf "%s\n" "$OUT" | grep -E "^ *F1 " | grep -q "Cap2 high"'

# =================================================================================================
sec "gate: pass, unmet, override; ACFW_SPEC=off still needs the override"
new_repo gate
CGB=$(mkctl gate-blk); CGA=$(mkctl gate-adv)
set_ctl "$CGA" exit 1; printf 'FINDING|medium|fp-g1|D2|Advisory nit\n' > "$CGA/stdout"
decl blk "review=$(rcmd "$CGB" blk)" 'at=plan' 'policy=block'
decl adv "review=$(rcmd "$CGA" adv)" 'at=plan' 'policy=advisory'
commit_all
prime; bump g1; C1=$(c12); sx review "$PLAN"
NB=$(ncalls "$CGB"); NA=$(ncalls "$CGA")
sx gate "$PLAN" --blob "$C1"
t "block tool GO + advisory NO-GO -> gate 0" rc 0
t "reviewed row for the block tool: 'go n=0'" hasE "^ROW\\|reviewed\\|blk\\|$C1\\|go n=0"
t "reviewed row for the advisory tool too (advisory tools are recorded)" hasE "^ROW\\|reviewed\\|adv\\|$C1\\|nogo n=1"
t "the gate is cache-only: it ran no tool" eval '[ "$(ncalls "$CGB")" = "$NB" ] && [ "$(ncalls "$CGA")" = "$NA" ]'
bump g2; C2=$(c12)
sx gate "$PLAN" --blob "$C2"
t "no result at these exact bytes -> gate 22" rc 22
t "...naming the block tool" either_i 'blk'
set_ctl "$CGB" exit 1; sx review "$PLAN"
sx gate "$PLAN" --blob "$C2"
t "block tool NO-GO at these bytes -> gate 22" rc 22
sx gate "$PLAN" --blob "$C2" --override adv
t "overriding a DIFFERENT tool does not pass -> 22" rc 22
sx gate "$PLAN" --blob "$C2" --override blk
t "--override blk -> gate 0" rc 0
t "...recording the override with the operator's email" \
  has "^ROW|overridden|$EMAIL|$C2|blk NO-GO overridden"
t "...and the NO-GO it overrode" hasE "^ROW\\|reviewed\\|blk\\|$C2\\|nogo"
t "rows: no URL" rows_have_no_url
bump g3; C3=$(c12); NB=$(ncalls "$CGB")
export ACFW_SPEC=off
sx review "$PLAN"
t "ACFW_SPEC=off: review runs no tool" [ "$(ncalls "$CGB")" = "$NB" ]
sx gate "$PLAN" --blob "$C3"
t "ACFW_SPEC=off does not open the gate: a block tool without GO -> 22" rc 22
sx gate "$PLAN" --blob "$C3" --override blk
t "ACFW_SPEC=off + the recorded override -> gate 0" rc 0
t "...and the override is recorded" has "^ROW|overridden|$EMAIL|$C3|blk"
unset ACFW_SPEC

sec "budget: a block tool the engine never started is no result the gate can pass"
# skip/error are non-gates because the TOOL could not run. A budget-exhausted placeholder is the
# ENGINE not trying: passing it would let a slow tool ahead of a block tool switch that gate off.
new_repo budget
CBB=$(mkctl budget-blk); CBA=$(mkctl budget-adv)
decl blk "review=$(rcmd "$CBB" blk)" 'at=plan' 'policy=block'
decl adv "review=$(rcmd "$CBA" adv)" 'at=plan' 'policy=advisory'
commit_all; prime; bump bu1; C=$(c12)
export ACFW_SPEC_BUDGET=4                       # below the 5 s floor any tool needs to start
sx review "$PLAN"
unset ACFW_SPEC_BUDGET
t "a budget too small to start any tool: nothing ran" eval '[ "$(ncalls "$CBB")" = 0 ] && [ "$(ncalls "$CBA")" = 0 ]'
t "...and the card says the budget ran out" either_i 'budget'
sx gate "$PLAN" --blob "$C"
t "a block tool that never started -> gate 22, not a pass" rc 22
t "...naming it" has '^GATE|unmet|blk|'
sx gate "$PLAN" --blob "$C" --override blk
t "...the override still approves (0)" rc 0
sx review "$PLAN"
t "with the budget back, the same bytes resume: both tools run (the placeholder was not a cache hit)" \
  eval '[ "$(ncalls "$CBB")" = 1 ] && [ "$(ncalls "$CBA")" = 1 ]'
sx gate "$PLAN" --blob "$C"
t "...and the block tool's GO now passes the gate" rc 0

# =================================================================================================
sec "task stage: at most 4 tools run at once, and they do run in parallel"
new_repo conc
CC4=$(mkctl conc); set_ctl "$CC4" sleep 2
decl par "review=$(rcmd "$CC4" par)" 'at=task' 'policy=advisory'; commit_all; prime
TDP="$WORK/tasks-conc"; CFILES=""
i=1; while [ $i -le 9 ]; do mktask "$TDP" "conc-00$i-t" "c$i"; CFILES="$CFILES $TDP/conc-00$i-t.md"; i=$((i+1)); done
: > "$CC4/conc"
# shellcheck disable=SC2086
sx review --stage task --machine $CFILES
t "nine task files: nine REVIEWED lines and a matching END" eval '[ "$(count_of "^REVIEWED\\|")" = 9 ] && end_matches_reviewed'
MAXC=$(sort -n "$CC4/conc" 2>/dev/null | tail -1)
t "peak concurrency is at most 4 (saw ${MAXC:-none})" eval '[ -n "$MAXC" ] && [ "$MAXC" -le 4 ]'
t "...and above 1: jobs overlap, the stage is not serial (saw ${MAXC:-none})" eval '[ -n "$MAXC" ] && [ "$MAXC" -ge 2 ]'

# =================================================================================================
sec "Plan Log rows: no URL, capability REF refused, '|' escaped, C0 stripped, <= 160 chars"
new_repo rows
CL=$(mkctl rows); set_ctl "$CL" exit 1
decl adv "review=$(rcmd "$CL")" 'at=plan' 'policy=advisory'; commit_all
prime
printf 'FINDING|high|fp-r1|D1|Pipe | inside a title\nFINDING|critical|fp-r2|L3|Ctl\001char\033[31mred\ttab\nREF|https://workbench.example.test/share/cap-9f8e7d6c5b4a\nURL|https://workbench.example.test/s/abc?token=cap123\n' > "$CL/stdout"
bump l1; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "gate 0 (advisory)" rc 0
t "a reviewed row exists" [ -n "$(reviewed_row adv)" ]
t "no ROW holds a URL (URL| is display only; a capability REF| is refused)" rows_have_no_url
t "no ROW holds a C0 control byte (SOH, ESC, TAB stripped)" rows_have_no_c0
t "every ROW has exactly five cells: a '|' inside a title never splits a cell" rows_have_five_cells
t "the '|' in the high finding's title is replaced with '/'" eval "reviewed_row adv | grep -q 'Pipe / inside'"
t "high-or-worse titles ride in the reviewed row's details" eval "reviewed_row adv | grep -q 'char'"
printf 'FINDING|high|fp-r3|D1|Plain\nREF|spec-4242\n' > "$CL/stdout"
bump l2; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "a plain REF id is kept as ref=<id>" eval "reviewed_row adv | grep -q 'ref=spec-4242'"
: > "$CL/stdout"; i=1
while [ $i -le 12 ]; do printf 'FINDING|high|fp-long-%d|D1|A long high-severity finding title number %02d that goes on\n' $i $i >> "$CL/stdout"; i=$((i+1)); done
bump l3; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "twelve long high titles: the details cell stays <= 160 chars" details_short
t "...and n counts all twelve" eval "reviewed_row adv | grep -q 'nogo n=12'"

# =================================================================================================
sec "workbench round-trip with the shipped dir driver"
DIRDRV="$PLUGIN/spec-tools/dir/acfw-spec-dir"
if [ ! -x "$DIRDRV" ]; then
  bad "shipped dir driver spec-tools/dir/acfw-spec-dir is missing: the dir push/pull, --from and OUT checks did not run"
else
  new_repo dir
  export ACFW_WORKBENCH_DIR="$WORK/wb"; mkdir -p "$ACFW_WORKBENCH_DIR"
  if [ -f "$ACF_WHIP_SRC/spec-tools/dir/dir.example" ]; then
    mkdir -p .acfwhip/spec-tools; cp "$ACF_WHIP_SRC/spec-tools/dir/dir.example" .acfwhip/spec-tools/dir
  else
    bad "spec-tools/dir/dir.example is missing (plan 7 ships it); using a minimal declaration"
    decl dir 'driver=dir'
  fi
  commit_all
  prime
  wbfile(){ find "$ACFW_WORKBENCH_DIR" -type f -name '*.md' ! -name 'my-spec.md' 2>/dev/null | head -1; }
  push_dir(){ sx push "$PLAN" --tool dir; [ -n "$(wbfile)" ] || sx push "$PLAN" --tool dir; }   # I2: one trust skip
  HEAD0=$(git rev-parse HEAD); cp "docs/cycles/$ID/record.md" "$WORK/record.before"
  C=$(c12)

  # --- no-op
  push_dir
  t "push: exit 0" rc 0
  t "push: the plan text is in the workbench" eval '[ -n "$(wbfile)" ] && grep -q "### D1: Owner sees the notice" "$(wbfile)"'
  t "push: the plan is OUT (status fact line)" state_out
  t "push: live state kept under .acfwhip/run/workbench/<key> (I3)" \
    eval 'ls "$REPO/.acfwhip/run/workbench" 2>/dev/null | grep -q "$ID"'
  sx gate "$PLAN" --blob "$C"
  t "gate refuses while the plan is OUT -> 26" rc 26
  PL=$(pending_log)
  t "push: a pending 'pushed' event for the approve commit to fold in" \
    eval "[ -f \"\$PL\" ] && cut -d'|' -f2,3 \"\$PL\" | grep -qx 'pushed|dir'"
  t "...shaped <ts>|pushed|dir|<c12>|details, five cells" \
    eval "grep '|pushed|' \"\$PL\" | awk -F'|' 'NF != 5 { bad=1 } END { exit bad }'"
  t "...its details carry base=<12 hex>" eval "grep '|pushed|' \"\$PL\" | cut -d'|' -f5 | grep -Eq 'base=[0-9a-f]{12}'"
  t "...and no URL" not grep -q '://' "$PL"
  # approve refused while OUT, end to end through acfw-cycle (guarded), on this still-pristine draft
  if [ -x "$CYCLE" ]; then
    cx approve "$PLAN" --expect "$C"
    t "acfw-cycle approve while OUT -> exit 26 (propagated from the gate)" rc 26
    t "...and nothing committed" [ "$(git rev-parse HEAD)" = "$HEAD0" ]
  else
    skip "acfw-cycle not present yet: approve-while-OUT is covered by the gate's 26 above only"
  fi
  cp "$PLAN" "$WORK/plan.before"
  sx pull "$PLAN" --tool dir
  t "pull with no changes on either side: exit 0" rc 0
  t "...plan byte-identical (no-op)" cmp -s "$PLAN" "$WORK/plan.before"
  t "...and the pull ended OUT (I4)" not state_out
  sx gate "$PLAN" --blob "$C"
  t "...so the gate no longer returns 26" rc_not 26
  t "pull: a pending 'pulled' event" eval "cut -d'|' -f2,3 \"\$PL\" | grep -qx 'pulled|dir'"

  # --- fast-forward + normalization
  push_dir; W=$(wbfile); cp "$PLAN" "$WORK/plan.before"
  perl -pi -e 's/^Owners cannot see seat notices\.$/Owners\xc2\xa0cannot\xe2\x80\x8b see seat notices on mobile.   /' "$W"
  perl -pi -e 's/\n/\r\n/; s/^/\xef\xbb\xbf/ if $. == 1' "$W"
  sed 's/^Owners cannot see seat notices\.$/Owners cannot see seat notices on mobile./' "$WORK/plan.before" > "$WORK/plan.expect"
  sx pull "$PLAN" --tool dir
  t "fast-forward: exit 0" rc 0
  t "fast-forward: plan.md becomes the remote text, normalized" cmp -s "$PLAN" "$WORK/plan.expect"
  t "normalized: no CR" not has_bytes "$PLAN" '\015'
  t "normalized: NBSP became a plain space" not has_bytes "$PLAN" '\302\240'
  t "normalized: no U+200B" not has_bytes "$PLAN" '\342\200\213'
  t "normalized: no U+FEFF (BOM)" not has_bytes "$PLAN" '\357\273\277'
  t "normalized: no trailing whitespace" not grep -q '[[:space:]]$' "$PLAN"
  t "fast-forward: ended OUT" not state_out

  # --- clean merge
  push_dir; W=$(wbfile)
  perl -pi -e 's/^Show a notice on the billing page\.$/Show a notice on the billing and seats pages./' "$PLAN"
  perl -pi -e 's/^- AC1\.1: the notice renders for owners$/- AC1.1: the notice renders for owners and billing admins/' "$W"
  sx pull "$PLAN" --tool dir
  t "clean merge: exit 0" rc 0
  t "clean merge: the local edit survived" grep -q 'billing and seats pages' "$PLAN"
  t "clean merge: the remote edit arrived" grep -q 'owners and billing admins' "$PLAN"
  t "clean merge: ended OUT" not state_out

  # --- conflict, then --ours
  push_dir; W=$(wbfile)
  perl -pi -e 's/^Email delivery\.$/Email delivery and SMS./' "$PLAN"
  perl -pi -e 's/^Email delivery\.$/Email delivery and push./' "$W"
  cp "$PLAN" "$WORK/plan.local"
  sx pull "$PLAN" --tool dir
  t "conflict: exit 23" rc 23
  t "conflict: plan.md untouched" cmp -s "$PLAN" "$WORK/plan.local"
  CF=$(find "$REPO" -path "$REPO/.git" -prune -o -name "$ID.conflict.md" -print 2>/dev/null | head -1)
  t "conflict: <key>.conflict.md written with both sides" eval '[ -n "$CF" ] && grep -q "and SMS" "$CF" && grep -q "and push" "$CF"'
  t "conflict: the plan stays OUT (nothing was pulled)" state_out
  patches(){ find "$REPO" -path "$REPO/.git" -prune -o -type f \( -name '*patch*' -o -name '*.diff' \) -print 2>/dev/null | sort; }
  patches > "$WORK/patches.before"
  sx pull "$PLAN" --tool dir --ours
  t "--ours: exit 0" rc 0
  t "--ours: the local side is kept" eval 'grep -q "and SMS" "$PLAN" && ! grep -q "and push" "$PLAN"'
  NEWP=$(patches | comm -13 "$WORK/patches.before" -)
  t "--ours: the discarded remote side is saved as a patch" eval '[ -n "$NEWP" ] && grep -q "and push" $NEWP'
  t "--ours: ended OUT" not state_out

  # --- conflict, then --theirs
  push_dir; W=$(wbfile)
  perl -pi -e 's/^Notices are per workspace\.$/Notices are per workspace and user./' "$PLAN"
  perl -pi -e 's/^Notices are per workspace\.$/Notices are per workspace and team./' "$W"
  sx pull "$PLAN" --tool dir; t "second conflict: exit 23" rc 23
  patches > "$WORK/patches.before"
  sx pull "$PLAN" --tool dir --theirs
  t "--theirs: exit 0" rc 0
  t "--theirs: the remote side is taken" eval 'grep -q "and team" "$PLAN" && ! grep -q "and user" "$PLAN"'
  NEWP=$(patches | comm -13 "$WORK/patches.before" -)
  t "--theirs: the discarded local side is saved as a patch" eval '[ -n "$NEWP" ] && grep -q "and user" $NEWP'

  # --- validation 24: a lost ## Deliverables heading
  push_dir; W=$(wbfile); cp "$PLAN" "$WORK/plan.before"
  perl -ni -e 'print unless /^## Deliverables$/' "$W"
  sx pull "$PLAN" --tool dir
  t "remote dropped '## Deliverables' that BASE had -> exit 24" rc 24
  t "...plan untouched" cmp -s "$PLAN" "$WORK/plan.before"
  sx pull "$PLAN" --tool dir --drop
  t "--drop: exit 0" rc 0
  t "--drop: ends OUT without touching the plan" eval '! state_out && cmp -s "$PLAN" "$WORK/plan.before"'

  # --- D removal is free before any task names a D
  push_dir; W=$(wbfile)
  perl -0pi -e 's/### D3: Audit row written\n- AC3\.1: every dismissal writes one audit row\n//' "$W"
  sx pull "$PLAN" --tool dir
  t "before decomposition, dropping D3 in the workbench is allowed (exit 0)" rc 0
  t "...and the pull says so (names D3)" either_i 'D3'
  t "...plan.md no longer has D3" not grep -q '^### D3' "$PLAN"

  t "no pull so far committed anything (HEAD unchanged)" [ "$(git rev-parse HEAD)" = "$HEAD0" ]
  t "no pull so far wrote record.md (a workbench never supplies it)" cmp -s "docs/cycles/$ID/record.md" "$WORK/record.before"

  # --- once record.md ## Tasks names D2, D2 may not vanish
  plan_body > "$PLAN"
  write_record '| D1 | api-001-a |' '| D2 | api-002-b |'
  git add "docs/cycles/$ID/record.md" && git commit -qm "decomposed (fixture)"
  HEAD0=$(git rev-parse HEAD); cp "docs/cycles/$ID/record.md" "$WORK/record.before"
  push_dir; W=$(wbfile); cp "$PLAN" "$WORK/plan.before"
  perl -0pi -e 's/### D2: Admin can dismiss it\n- AC2\.1: dismissing hides it for the workspace\n//' "$W"
  sx pull "$PLAN" --tool dir
  t "after decomposition, a pull that drops recorded D2 -> exit 24" rc 24
  t "...plan untouched" cmp -s "$PLAN" "$WORK/plan.before"
  sx pull "$PLAN" --tool dir --drop
  t "a refused pull does not commit either" [ "$(git rev-parse HEAD)" = "$HEAD0" ]
  t "...nor write record.md" cmp -s "docs/cycles/$ID/record.md" "$WORK/record.before"

  sec "--from: start a cycle from a workbench-authored spec"
  printf '# Imported spec\n\n## Deliverables\n\n### D1: Import works\n- AC1.1: the file arrives intact\n' > "$ACFW_WORKBENCH_DIR/my-spec.md"
  cp "$ACFW_WORKBENCH_DIR/my-spec.md" "$WORK/my-spec.orig"
  sx from dir my-spec.md
  printf '%s\n' "$OUT" | grep -q '^FROM|' || sx from dir my-spec.md
  FROMP=$(printf '%s\n' "$OUT" | sed -n 's/^FROM|//p' | head -1)
  t "from: exit 0 with a FROM|<path> line" eval 'rc 0 && [ -n "$FROMP" ]'
  t "from: the fetched markdown is the workbench text" eval '[ -f "$FROMP" ] && cmp -s "$FROMP" "$WORK/my-spec.orig"'
  t "from: the workbench source is never written" cmp -s "$ACFW_WORKBENCH_DIR/my-spec.md" "$WORK/my-spec.orig"
  if [ -x "$CYCLE" ] && [ -n "$FROMP" ]; then
    cx init from-demo --from-file "$FROMP" --kind feature --source dir:my-spec.md
    NP=$(printf '%s\n' "$OUT" | sed -n 's/^INIT|[^|]*|//p' | head -1)
    t "acfw-cycle init --from-file <FROM path>: INIT line" eval 'rc 0 && [ -n "$NP" ]'
    t "...plan.md is the fetched spec" eval '[ -f "$REPO/$NP" ] && cmp -s "$REPO/$NP" "$WORK/my-spec.orig"'
    t "...record.md Source names the tool and ref" eval 'grep -q "dir:my-spec.md" "$(dirname "$REPO/$NP")/record.md"'
  else
    skip "acfw-cycle not present yet: --from stops at FROM|<path>"
  fi
  unset ACFW_WORKBENCH_DIR
fi

# =================================================================================================
sec "workbench protocol with the fake: ANSWER| folding, REF hygiene, verb not offered (25)"
new_repo fwb
CWB=$(mkctl fwb); set_ctl "$CWB" verbs "review,push,pull"
mkdrv "$REPO/.acfwhip/adapters" wbf "$CWB" wbf
decl wbf 'driver=wbf' 'at=plan' 'policy=advisory'
CRV=$(mkctl fwb-rv)
decl rv "review=$(rcmd "$CRV")" 'at=plan'
commit_all
prime
push_fake(){ rm -f "$CWB/pushed.md"; sx push "$PLAN" --tool wbf; [ -f "$CWB/pushed.md" ] || sx push "$PLAN" --tool wbf; }
push_fake
t "push through a driver: exit 0" rc 0
t "the driver was handed exactly the plan bytes" cmp -s "$CWB/pushed.md" "$PLAN"
t "the driver saw ACFW_SPEC_VERB=push" grep -q '^ACFW_SPEC_VERB=push$' "$CWB/last-env"
t "the plan is OUT" state_out
t "the pushed event keeps the REF id (ref=fake-ref-1)" \
  eval "grep '|pushed|wbf|' \"\$(pending_log)\" | grep -q 'ref=fake-ref-1'"
t "...and never the URL the driver printed" not grep -q '://' "$(pending_log)"
cp "$PLAN" "$WORK/plan.before"
printf 'ANSWER|fp-q1|30 days, the default\nANSWER|fp-q2|owners only\n' > "$CWB/pull.stdout"
sx pull "$PLAN" --tool wbf
t "a pull that returns decisions: exit 0" rc 0
t "ANSWER| lines are relayed verbatim for the session to fold in" \
  eval 'has "^ANSWER|fp-q1|30 days, the default$" && has "^ANSWER|fp-q2|owners only$"'
t "...and plan.md is untouched (decisions are folded by the session, not pasted)" cmp -s "$PLAN" "$WORK/plan.before"
t "...and the pull ended OUT" not state_out
rm -f "$CWB/pull.stdout"
printf 'REF|https://wb.example.test/s/cap-77aa?k=zz\nURL|https://wb.example.test/s/cap-77aa\n' > "$CWB/push.stdout"
push_fake
t "a capability link offered as REF| is refused: no URL reaches pending.log" not grep -q '://' "$(pending_log)"
sx pull "$PLAN" --tool wbf --drop
set_ctl "$CWB" verbs "review"
sx push "$PLAN" --tool wbf
t "a driver whose VERBS| lacks push -> exit 25" rc 25
t "...and the plan is not OUT" not state_out
sx push "$PLAN" --tool rv
t "a review= tool has no push verb -> exit 25" rc 25
# A pull RUNS the tool, so it refuses exactly like review and push while any declaration holds a
# credential literal, and before the tool's pull verb is invoked.
set_ctl "$CWB" verbs "review,push,pull"; rm -f "$CWB/push.stdout"
push_fake
t "(setup) pushed again: the plan is OUT" state_out
NPULL=$(ncalls "$CWB" pull); LEAKP="sk-$(rep d 24)"
decl leak "review=true --arg $LEAKP" 'at=plan'; commit_all leak
sx pull "$PLAN" --tool wbf
t "a credential literal in a neighbouring declaration: pull refuses (20)" rc 20
t "...before the tool's pull verb ran" [ "$(ncalls "$CWB" pull)" = "$NPULL" ]
t "...without echoing the literal" eval '! printf "%s\n%s\n" "$OUT" "$ERR" | grep -qF -- "$LEAKP"'
t "...and the plan stays OUT" state_out
git rm -q .acfwhip/spec-tools/leak && git commit -qm "drop leak"
sx pull "$PLAN" --tool wbf --drop
# Text that came back by hand (a saved export, a paste): --file and --clipboard merge it with no tool
# run, against the last synced text as BASE. The clipboard reader is a fake pbpaste first on PATH, so
# the suite never reads or changes the real clipboard of whoever runs it.
cp "$PLAN" "$WORK/plan.hand"; perl -pi -e 's/^Email delivery\.$/Email delivery, edited by hand./' "$WORK/plan.hand"
cp "$WORK/plan.hand" "$WORK/plan.hand.orig"; NRUN=$(wc -l < "$CWB/calls" | tr -d ' ')
sx pull "$PLAN" --file "$WORK/plan.hand"
t "--file: exit 0" rc 0
t "--file: the edit arrived in plan.md" grep -q 'edited by hand' "$PLAN"
t "--file: the source file is never written" cmp -s "$WORK/plan.hand" "$WORK/plan.hand.orig"
t "--file: no tool ran" [ "$(wc -l < "$CWB/calls" | tr -d ' ')" = "$NRUN" ]
t "--file: a pending 'pulled' event" eval "cut -d'|' -f2 \"\$(pending_log)\" | grep -qx pulled"
mkdir -p "$WORK/fakeclip"
{ printf '#!/bin/bash\n'; printf 'cat %s\n' "'$WORK/clip.txt'"; } > "$WORK/fakeclip/pbpaste"; chmod +x "$WORK/fakeclip/pbpaste"
sed 's/^Notices are per workspace\.$/Notices are per workspace, pasted./' "$PLAN" | perl -pe 's/\n/\r\n/' > "$WORK/clip.txt"
PATH="$WORK/fakeclip:$ORIG_PATH"; sx pull "$PLAN" --clipboard; PATH="$ORIG_PATH"
t "--clipboard: exit 0" rc 0
t "--clipboard: the pasted edit arrived, normalized (no CR)" eval 'grep -q "per workspace, pasted" "$PLAN" && ! has_bytes "$PLAN" "\\015"'
t "--clipboard: the earlier --file edit survived the merge" grep -q 'edited by hand' "$PLAN"

# =================================================================================================
sec "trust on first use"
new_repo tofu
CT=$(mkctl tofu)
decl tofu "review=$(rcmd "$CT" v1)" 'at=plan' 'policy=advisory'; commit_all
sx status --machine
t "status: a new declaration gets a first-use trust CARD" eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q tofu"
sx review "$PLAN"
t "review: the new declaration is printed" eval 'either_i "tofu" && either_i "review="'
t "...skipped (the tool did not run)" [ "$(ncalls "$CT")" = 0 ]
t "...and the reply that runs it is named ('run tools')" either_i 'run tools'
sx review "$PLAN"
t "reviewing again without the reply still does not run it (consent is explicit)" [ "$(ncalls "$CT")" = 0 ]
sx trust
t "the 'run tools' reply (acfw-spec trust) exits 0" rc 0
TRUST="$REPO/.acfwhip/run/spec/trusted"
t "trust is stored as '<name> <sha>' in .acfwhip/run/spec/trusted" grep -Eq '^tofu [0-9a-f]{8,}$' "$TRUST"
t "...which is gitignored run state, never a commit candidate" \
  not eval "git status --porcelain --untracked-files=all | grep -q '\\.acfwhip/run'"
sx review "$PLAN"
t "after the reply: it runs" [ "$(ncalls "$CT")" = 1 ]
sx status --machine
t "...and status no longer asks to trust it" \
  eval "rc 0 && ! printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q tofu"
decl tofu "review=$(rcmd "$CT" v2)" 'at=plan' 'policy=advisory'; commit_all
bump f1; sx review "$PLAN"
t "a CHANGED declaration is printed and skipped again" eval '[ "$(ncalls "$CT")" = 1 ] && either_i "tofu"'
t "...showing the new text" either_i 'tag v2'
sx trust tofu; sx review "$PLAN"
t "...then runs after the reply" [ "$(ncalls "$CT")" = 2 ]
t "...as the new version" [ "$(last_tag "$CT")" = v2 ]

# =================================================================================================
sec "AGENT| work orders: prompt-only tools become subagent jobs (exit 21)"
new_repo agent
mkdir -p .acfwhip/spec-tools
cat > .acfwhip/spec-tools/critic.md <<'EOF'
# Plan critic
## review
MARK-REVIEW-SECTION: read the plan and print FINDING records, then a SUMMARY record.
## push
MARK-PUSH-SECTION
## pull
MARK-PULL-SECTION
EOF
cp .acfwhip/spec-tools/critic.md critic.md                     # I7: either base resolves
# rerun=every stated outright: CONTRACT.md defaults agent tools to ask (a subagent is paid), and this
# group is about work orders, not about that default.
decl critic 'agent=critic.md' 'at=plan,task' 'policy=advisory' 'rerun=every'
git add critic.md; commit_all; prime
sx review "$PLAN"; [ "$RC" -eq 21 ] || sx review "$PLAN"
t "an agent tool with no collected result: review exits 21" rc 21
AL=$(line_of '^AGENT\|critic\|review\|')
t "...printing AGENT|critic|review|<prompt-cmd>" [ -n "$AL" ]
PCMD=$(printf '%s' "$AL" | cut -d'|' -f4-)
t "...whose command is the engine's prompt verb (quoting aside)" eval "printf '%s' \"\$PCMD\" | tr -d \"'\\\"\" | grep -q 'prompt critic review'"
PTXT=$(cd "$REPO" && perl -e 'alarm 60; exec @ARGV' /bin/bash -c "$PCMD" 2>/dev/null </dev/null)
t "running it prints the prompt's '## review' section" eval "printf '%s' \"\$PTXT\" | grep -q MARK-REVIEW-SECTION"
t "...and not another verb's section" not eval "printf '%s' \"\$PTXT\" | grep -q MARK-PUSH-SECTION"
sx prompt critic review
t "prompt critic review, called directly, prints the same section" has 'MARK-REVIEW-SECTION'
AOUT=$(printf '%s' "$PTXT" | grep -Eo "/[^[:space:]\"'\`]*/stdout" | head -1)
if [ -z "$AOUT" ]; then
  AD=$(printf '%s' "$PTXT" | grep -Eo "/[^[:space:]\"'\`)]*\\.acfwhip/run/spec/[^[:space:]\"'\`)]*" | head -1)
  [ -n "$AD" ] && AOUT="${AD%/}/stdout"
fi
t "the prompt tells the agent where to write (<out>/stdout)" [ -n "$AOUT" ]
C=$(c12)
if [ -n "$AOUT" ]; then
  mkdir -p "$(dirname "$AOUT")"
  printf 'FINDING|high|fp-ag1|D1|Agent says D1 lacks an actor\nSUMMARY|verdict=nogo\n' > "$AOUT"
fi
sx review "$PLAN"
t "re-running review collects <out>/stdout: exit 0, no AGENT line" eval 'rc 0 && ! has "^AGENT|"'
sx gate "$PLAN" --blob "$C"
t "the agent's verdict is recorded like any tool's: 'nogo n=1'" hasE "^ROW\\|reviewed\\|critic\\|$C\\|nogo n=1"
bump ag2; C=$(c12)
sx review "$PLAN"
t "a new blob needs a new work order (21)" rc 21
PCMD=$(line_of '^AGENT\|critic\|review\|' | cut -d'|' -f4-)
PTXT=$(cd "$REPO" && perl -e 'alarm 60; exec @ARGV' /bin/bash -c "$PCMD" 2>/dev/null </dev/null)
AOUT=$(printf '%s' "$PTXT" | grep -Eo "/[^[:space:]\"'\`]*/stdout" | head -1)
if [ -n "$AOUT" ]; then mkdir -p "$(dirname "$AOUT")"; printf 'FINDING|high|fp-ag2|D1|No summary given\n' > "$AOUT"; fi
sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "an agent result without SUMMARY| is never GO (SUMMARY is required for agent tools)" \
  not eval 'reviewed_row critic | grep -q "|go n="'
TDA="$WORK/tasks-agent"; mktask "$TDA" agent-001-a a
sx review --stage task --machine "$TDA/agent-001-a.md"
t "task stage (a background run): agent tools never run, no exit 21" eval 'rc_not 21 && has "^END|"'
t "...and no AGENT| work order" eval 'has "^END|" && ! has "^AGENT|"'
# The prompt is handed to a subagent verbatim: a key anywhere in it would travel on. Refuse it.
cp .acfwhip/spec-tools/critic.md "$WORK/critic.md.bak"; LEAKA="$(rep z 20)"
printf 'Call it with MY_API_KEY=%s set.\n' "$LEAKA" >> .acfwhip/spec-tools/critic.md
sx prompt critic review
t "prompt refuses a prompt file holding a credential literal (20)" rc 20
t "...without echoing it" eval '! printf "%s\n%s\n" "$OUT" "$ERR" | grep -qF -- "$LEAKA"'
cp "$WORK/critic.md.bak" .acfwhip/spec-tools/critic.md

# =================================================================================================
sec "store-agnostic: zero task-store calls on a multica-configured checkout"
MCF="$ACF_WHIP_SRC/tests/fixtures/multica-fake.sh"
if [ -f "$MCF" ]; then
  # shellcheck source=/dev/null
  . "$MCF"
  new_repo multica
  multica_fake_install "$WORK/multica-fake"
  export ACFW_STORE=multica ACFW_MULTICA_BIN="$WORK/multica-fake" MC_FAKE_STATE="$WORK/mc-state.json" MC_FAKE_LOG="$WORK/mc.log"
  CM=$(mkctl multica); set_ctl "$CM" exit 1; printf 'FINDING|high|fp-m1|D1|Same on multica\n' > "$CM/stdout"
  decl adv "review=$(rcmd "$CM")" 'at=plan,task' 'policy=advisory'; commit_all
  TDM="$WORK/tasks-mc"; mktask "$TDM" mc-001-a a
  prime; prime_task "$TDM/mc-001-a.md"; bump m1; C=$(c12)
  sx list --machine;            t "multica: list works" has '^TOOL|adv|review|plan,task|advisory|'
  sx review "$PLAN";            t "multica: review exits 0" rc 0
  sx show "$PLAN" --blob "$C";  t "multica: show renders the finding" has 'Same on multica'
  sx gate "$PLAN" --blob "$C";  t "multica: gate records 'nogo n=1' exactly as on files" hasE "^ROW\\|reviewed\\|adv\\|$C\\|nogo n=1"
  sx status --machine;          t "multica: status exits 0" rc 0
  sx review --stage task --machine "$TDM/mc-001-a.md"
  t "multica: the task stage emits its REVIEWED line" [ -n "$(reviewed_line mc-001-a adv)" ]
  t "the engine made ZERO calls to the multica backend" eval '[ ! -s "$WORK/mc.log" ]'
  unset ACFW_STORE ACFW_MULTICA_BIN MC_FAKE_STATE MC_FAKE_LOG
else
  bad "tests/fixtures/multica-fake.sh is missing: the non-files store run did not happen"
fi

# =================================================================================================
sec "acfw-cycle approve: rule 11, then rule 10, then the spec gate (rule 12)"
if [ ! -x "$CYCLE" ]; then
  skip "acfw-cycle is not present/executable yet (W1): approve-order checks not run"
else
  new_repo order
  cx init spec-order --kind feature --source test
  IDO=$(printf '%s\n' "$OUT" | sed -n 's/^INIT|\([^|]*\)|.*/\1/p' | head -1)
  t "acfw-cycle init prints INIT|<ID>|<path>" [ -n "$IDO" ]
  PLAN="docs/cycles/$IDO/plan.md"
  plan_body > "$PLAN"
  CO=$(mkctl order)
  decl blk "review=$(rcmd "$CO" blk)" 'at=plan' 'policy=block'; commit_all
  prime; sx review "$PLAN"; C0=$(c12)
  cx approve "$PLAN" --expect "$C0"
  t "approve with the block tool at GO -> exit 0" rc 0
  RECO="docs/cycles/$IDO/record.md"
  t "the approve commit's Plan Log holds the tool's reviewed row" \
    eval "git show HEAD:$RECO | grep 'reviewed' | grep -q 'blk'"
  t "...and no URL anywhere in record.md" not eval "git show HEAD:$RECO | grep -q '://'"
  cx record "$PLAN" api-001-a=D1 api-002-b=D2 api-003-c=D3
  t "record maps D1..D3 to tasks" rc 0
  # A new D2 inserted above the old one renumbers D2->D3 and D3->D4: a rule-10 violation.
  plan_body | perl -0pe 's/### D3: /### D4: /; s/### D2: /### D3: /; s/(### D3: Admin)/### D2: Brand new work\n- AC2.1: new\n\n$1/' > "$PLAN"
  set_ctl "$CO" exit 1; sx review "$PLAN"; C1=$(c12)
  H=$(git rev-parse HEAD); cp "$PLAN" "$WORK/plan.order"
  cx approve "$PLAN" --expect "$C0"
  t "stale --expect is refused FIRST (rule 11 -> 9), though rules 10 and 12 would also refuse" rc 9
  t "...prints no copyable approve command" not either_i 'acfw-cycle approve'
  cx approve "$PLAN" --expect "$C1"
  t "fresh --expect: rule 10 refuses next (8), before the spec gate's 22" rc 8
  t "...and nothing was committed or rewritten" eval '[ "$(git rev-parse HEAD)" = "$H" ] && cmp -s "$PLAN" "$WORK/plan.order"'
  plan_body | perl -pe 's/^### D2: Admin can dismiss it$/### D2: Admin can dismiss the notice/' > "$PLAN"
  sx review "$PLAN"; C2=$(c12)
  cx approve "$PLAN" --expect "$C2"
  t "rewording D2 in place passes rules 11 and 10; the block NO-GO then refuses (22)" rc 22
  t "...nothing committed" [ "$(git rev-parse HEAD)" = "$H" ]
  cx approve "$PLAN" --expect "$C2" --override blk
  t "the recorded override approves (0)" rc 0
  t "...the Plan Log carries the override with the operator's email" \
    eval "git show HEAD:$RECO | grep 'overridden' | grep -q '$EMAIL'"
  t "...and still no URL" not eval "git show HEAD:$RECO | grep -q '://'"
  bump off1; C3=$(c12); H=$(git rev-parse HEAD)
  export ACFW_SPEC=off
  cx approve "$PLAN" --expect "$C3"
  t "ACFW_SPEC=off: approve still refuses a block tool without GO (22)" rc 22
  t "...nothing committed" [ "$(git rev-parse HEAD)" = "$H" ]
  cx approve "$PLAN" --expect "$C3" --override blk
  t "ACFW_SPEC=off + override approves (0)" rc 0
  unset ACFW_SPEC
fi

# =================================================================================================
sec "stages: the card, the hook run and the gate agree on which tools gate a plan"
# A block tool gates plan approval when its COMMITTED at= names plan or is absent; a task-only block
# tool holds tasks and never gates the plan. When the gate ignored at=, a task-only linter made every
# plan unapprovable without an override, and the gate's advice ("review these bytes first") looped,
# because review never runs a task-only tool on a plan.
new_repo stages
CST=$(mkctl stages-task); set_ctl "$CST" exit 1
decl tonly "review=$(rcmd "$CST" tonly)" 'at=task' 'policy=block'; commit_all; prime
bump s1; C=$(c12); : > "$CST/calls"
sx review "$PLAN"
t "at=task block tool: the plan hook run does not run it" [ "$(ncalls "$CST")" = 0 ]
sx show "$PLAN" --blob "$C"
t "...the card offers no override for it" not has 'override tonly'
sx gate "$PLAN" --blob "$C"
t "...and the gate agrees: a task-only tool does not gate the plan (0)" rc 0
t "...nor does it get a plan-stage Plan Log row" not has '^ROW|reviewed|tonly|'
sx review "$PLAN" --all
t "the 'review' reply (review --all) skips a task-only tool" [ "$(ncalls "$CST")" = 0 ]
TDS="$WORK/tasks-stages"; mktask "$TDS" st-001-a a
sx review --stage task --machine "$TDS/st-001-a.md"
t "...while at the task stage it still holds: REVIEWED ...|block|nogo" \
  eval '[ "$(fieldn "$(reviewed_line st-001-a tonly)" 4)" = block ] && [ "$(fieldn "$(reviewed_line st-001-a tonly)" 5)" = nogo ]'

new_repo stages-noat
CSN=$(mkctl stages-noat)
decl onreq "review=$(rcmd "$CSN" onreq)" 'policy=block'; commit_all; prime
bump s2; C=$(c12); : > "$CSN/calls"
sx review "$PLAN"
t "no-at= block tool: the hook run leaves it alone (it runs on request)" [ "$(ncalls "$CSN")" = 0 ]
sx show "$PLAN" --blob "$C"
t "...but the card lists it as not run yet, with the 'review' reply" eval 'has "onreq" && has "not run on this plan yet"'
t "...and offers 'yes, override onreq', because the gate will refuse" has 'yes, override onreq'
sx gate "$PLAN" --blob "$C"
t "...the gate refuses it unreviewed (22), agreeing with the card" rc 22
sx review "$PLAN" --all
t "the 'review' reply runs it" [ "$(ncalls "$CSN")" = 1 ]
sx gate "$PLAN" --blob "$C"
t "...and its GO then passes the gate (0)" rc 0

new_repo stages-drop
CSD=$(mkctl stages-drop)
decl pb "review=$(rcmd "$CSD" pb)" 'at=plan' 'policy=block'; commit_all; prime
perl -pi -e 's/^at=plan$/at=task/' .acfwhip/spec-tools/pb; prime
bump s3; C=$(c12); : > "$CSD/calls"
sx review "$PLAN"
t "a local edit dropping plan from a committed block tool's at=: the hook still runs it" [ "$(ncalls "$CSD")" = 1 ]
sx show "$PLAN" --blob "$C"
t "...the card shows its block line and the override reply (the edited run is advisory only)" has 'yes, override pb'
sx gate "$PLAN" --blob "$C"
t "...and the gate agrees (22)" rc 22
git checkout -q -- .acfwhip/spec-tools/pb

new_repo stages-err
CSE=$(mkctl stages-err)
decl nb "review=$(rcmd "$CSE" nb)" 'at=plan' 'policy=block'; commit_all; prime
printf 'polcy=advisory\n' >> .acfwhip/spec-tools/nb
bump s4; C=$(c12)
sx show "$PLAN" --blob "$C"
t "a committed block tool whose local copy no longer parses stays on the card" eval 'has "nb" && has "declaration error"'
t "...with the override reply" has 'yes, override nb'
sx gate "$PLAN" --blob "$C"
t "...the gate refuses (22)" rc 22
t "...naming the declaration error, not 'review these bytes' (review cannot run it)" either_i 'declaration has an error'
sx gate "$PLAN" --blob "$C" --override nb
t "...and the override approves (0)" rc 0
git checkout -q -- .acfwhip/spec-tools/nb

# =================================================================================================
sec "a committed block declaration that fails to parse still gates (fail closed)"
i=0
for pv in 'policy=block   # required by the team' 'policy=Block' 'policy="block"' 'polcy=block'; do
  i=$((i+1)); new_repo "failclosed-$i"
  decl fc 'review=true' 'at=plan' "$pv"; commit_all
  C=$(c12)
  sx show "$PLAN" --blob "$C"
  t "[$pv] the card lists the declaration error and the override reply" eval 'has "declaration error" && has "yes, override fc"'
  sx gate "$PLAN" --blob "$C"
  t "[$pv] the gate refuses (22): a malformed committed block line never loosens the gate" rc 22
  t "[$pv] ...naming the invalid committed declaration" either_i 'committed declaration is invalid'
  sx gate "$PLAN" --blob "$C" --override fc
  t "[$pv] ...the override still approves, recorded as unreviewed" eval "rc 0 && has '^ROW|overridden|$EMAIL|$C|fc unreviewed, overridden'"
done
new_repo failclosed-adv
decl fa 'review=true' 'at=plan' 'policy=advisory   # advice only'; commit_all
C=$(c12); sx gate "$PLAN" --blob "$C"
t "control: a broken declaration that says advisory does not gate (0)" rc 0

# =================================================================================================
sec "task stage: policy and holds come from HEAD, never from the working tree or a cached result"
new_repo taskhead
CTH=$(mkctl taskhead); set_ctl "$CTH" exit 1
decl th "review=$(rcmd "$CTH" th)" 'at=plan,task' 'policy=block' 'timeout=20'; commit_all; prime
TDH="$WORK/tasks-taskhead"
mktask "$TDH" th-001-a a
sx review --stage task --machine "$TDH/th-001-a.md"
L=$(reviewed_line th-001-a th)
t "baseline: committed block tool, NO-GO -> REVIEWED ...|block|nogo (the task is held)" \
  eval '[ "$(fieldn "$L" 4)" = block ] && [ "$(fieldn "$L" 5)" = nogo ]'
perl -pi -e 's/^timeout=20$/timeout=30/' .acfwhip/spec-tools/th; prime
mktask "$TDH" th-002-b b
sx review --stage task --machine "$TDH/th-002-b.md"
L=$(reviewed_line th-002-b th)
t "a harmless local edit (timeout=) does not demote the hold: still block|nogo" \
  eval '[ "$(fieldn "$L" 4)" = block ] && [ "$(fieldn "$L" 5)" = nogo ]'
set_ctl "$CTH" exit 0
mktask "$TDH" th-003-c c
sx review --stage task --machine "$TDH/th-003-c.md"
L=$(reviewed_line th-003-c th)
t "even a GO from the locally edited declaration holds (block|nogo): its run is advisory only" \
  eval '[ "$(fieldn "$L" 4)" = block ] && [ "$(fieldn "$L" 5)" = nogo ]'
t "...and the findings path says why: commit or revert the local edit" \
  eval '[ -f "$(fieldn "$L" 8)" ] && grep -qi "commit or revert" "$(fieldn "$L" 8)"'
git checkout -q -- .acfwhip/spec-tools/th
perl -pi -e 's/^at=plan,task$/at=plan/' .acfwhip/spec-tools/th; prime
sx list --at task --machine
t "a local edit dropping task from at= keeps the tool in the task stage (list --at task)" has '^TOOL|th|'
set_ctl "$CTH" exit 1
mktask "$TDH" th-004-d d
sx review --stage task --machine "$TDH/th-004-d.md"
t "...and in review --stage task: still block|nogo" \
  eval '[ "$(fieldn "$(reviewed_line th-004-d th)" 4)" = block ] && [ "$(fieldn "$(reviewed_line th-004-d th)" 5)" = nogo ]'
git checkout -q -- .acfwhip/spec-tools/th

new_repo taskcache
CTC=$(mkctl taskcache); set_ctl "$CTC" exit 1
decl tc "review=$(rcmd "$CTC" tc)" 'at=plan,task' 'policy=block'      # not committed yet
prime
TDC2="$WORK/tasks-taskcache"; mktask "$TDC2" tc-001-a a
sx review --stage task --machine "$TDC2/tc-001-a.md"
t "uncommitted block declaration: the task stage reports advisory" [ "$(fieldn "$(reviewed_line tc-001-a tc)" 4)" = advisory ]
plan_reviewed(){ printf '%s\n' "$OUT" | grep "^REVIEWED|$ID|$1|" | head -1; }
bump tc1; sx review "$PLAN" --machine
t "...and so does the plan stage's review --machine" [ "$(fieldn "$(plan_reviewed tc)" 4)" = advisory ]
commit_all "commit the identical declaration"
N0=$(ncalls "$CTC")
sx review --stage task --machine "$TDC2/tc-001-a.md"
t "the identical bytes committed, the same task reviewed: served from the cache (no new call)" [ "$(ncalls "$CTC")" = "$N0" ]
t "...yet the line says block|nogo, the policy in force now (never the cached advisory)" \
  eval '[ "$(fieldn "$(reviewed_line tc-001-a tc)" 4)" = block ] && [ "$(fieldn "$(reviewed_line tc-001-a tc)" 5)" = nogo ]'
sx review "$PLAN" --machine
t "...and the plan stage's REVIEWED line says block too" [ "$(fieldn "$(plan_reviewed tc)" 4)" = block ]

# =================================================================================================
sec "secret lint: JSON-quoted keys in a tracked .mcp.json, and a literal removed only locally"
new_repo secret2
CS2=$(mkctl secret2)
decl ok2 "review=$(rcmd "$CS2")" 'at=plan'; commit_all; prime
JK="a1b2c3d4e5f6$(rep 0 24)"
printf '{"mcpServers":{"lin":{"headers":{"X-Api-Key":"%s"}}}}\n' "$JK" > .mcp.json
git add -f .mcp.json && git commit -qm "tracked mcp config with a JSON key"
: > "$CS2/calls"; sx review "$PLAN"
t "a tracked .mcp.json holding \"X-Api-Key\":\"<literal>\" -> exit 20" rc 20
t "...no tool ran" [ "$(ncalls "$CS2")" = 0 ]
t "...and the key is not echoed" not grep -qF -- "$JK" "$WORK/o" "$WORK/e"
sx status --machine
t "...status carries a secret CARD for .mcp.json" eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q 'mcp.json'"
printf '{"mcpServers":{"or":{"env":{"OPENROUTER_API_KEY":"or-v1-%s"}}}}\n' "$(rep 7 24)" > .mcp.json
git commit -qm "an env-block literal" -- .mcp.json
sx review "$PLAN"
t "\"OPENROUTER_API_KEY\":\"<literal>\" -> exit 20" rc 20
printf '{"mcpServers":{"wb":{"headers":{"X-Api-Key":"${WB_KEY}","Authorization":"Bearer ${WB_TOKEN}"}}}}\n' > .mcp.json
git commit -qm "references only" -- .mcp.json
: > "$CS2/calls"; sx review "$PLAN"
t "\${VAR} and \"Bearer \${VAR}\" references are not literals: no 20, and the tool runs" \
  eval 'rc_not 20 && [ "$(ncalls "$CS2")" -ge 1 ]'
SKH="sk""-$(rep h 24)"
decl ok2 "review=$(rcmd "$CS2") --arg $SKH" 'at=plan'; commit_all "a literal committed"
decl ok2 "review=$(rcmd "$CS2")" 'at=plan'                    # removed locally, not committed
: > "$CS2/calls"; sx review "$PLAN"
t "a literal removed only in the working tree still refuses (20): HEAD carries it to the next push" rc 20
t "...no tool ran" [ "$(ncalls "$CS2")" = 0 ]
t "...not echoed" not grep -qF -- "$SKH" "$WORK/o" "$WORK/e"
sx status --machine
t "...status still cards it, labelled HEAD:" eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q 'HEAD:'"
commit_all "remove the literal"; prime
sx review "$PLAN"
t "once the removal is committed, review runs again (no 20)" rc_not 20

# =================================================================================================
sec "rerun=ask: a skip or error does not use up the first card"
new_repo askskip
CK=$(mkctl askskip); set_ctl "$CK" cost "1 unit"
mkdrv "$REPO/.acfwhip/adapters" paid2 "$CK" paid2
decl paid2 'driver=paid2' 'at=plan'; commit_all; prime
set_ctl "$CK" exit 3; printf 'PAID_KEY is not set\n' > "$CK/review.stderr"
bump k1; sx review "$PLAN"
t "card 1: the paid tool ran and skipped (its key is not set yet)" [ "$(ncalls "$CK")" = 1 ]
rm -f "$CK/review.stderr"; set_ctl "$CK" exit 0
bump k2; C=$(c12); sx review "$PLAN"
t "card 2, key now set: it runs on its own (the skip billed nothing and used up no first card)" [ "$(ncalls "$CK")" = 2 ]
sx show "$PLAN" --blob "$C"
t "...and the card shows its GO, never 'stale'" eval 'has "paid2" && has "GO" && ! either_i stale'
bump k3; C=$(c12); sx review "$PLAN"
t "card 3, after an edit: now it waits for 'review' (card 2 was its first go/nogo)" [ "$(ncalls "$CK")" = 2 ]
sx show "$PLAN" --blob "$C"
t "...shown as stale since your edit, last GO" eval 'either_i "stale since your edit" && has "last GO"'

# =================================================================================================
sec "Plan Log: every plan reviewer leaves a row, even with nothing at the approved bytes"
new_repo norunrow
CNR=$(mkctl norunrow); set_ctl "$CNR" cost "1 unit"
mkdrv "$REPO/.acfwhip/adapters" asky "$CNR" asky
decl asky 'driver=asky' 'at=plan' 'policy=advisory'; commit_all; prime
bump nr1; sx review "$PLAN"                                   # the first card runs it
bump nr2; C=$(c12); sx review "$PLAN"                         # stale from here on
CNU=$(mkctl norunrow-u)
decl untr "review=$(rcmd "$CNU")" 'at=plan'; commit_all       # new, never trusted
sx gate "$PLAN" --blob "$C"
t "gate 0 (advisory tools never block)" rc 0
t "a stale rerun=ask tool still gets its reviewed row: not run at this content (stale since <b12>)" \
  hasE "^ROW\\|reviewed\\|asky\\|$C\\|not run at this content \\(stale since [0-9a-f]{12}\\)$"
t "an untrusted tool gets one too: (untrusted on this machine)" \
  has "^ROW|reviewed|untr|$C|not run at this content (untrusted on this machine)"
t "rows stay five cells" rows_have_five_cells

# =================================================================================================
sec "agent tools: default rerun, and a workbench push that keeps edits made while the agent worked"
new_repo agentwb
mkdir -p .acfwhip/spec-tools
cat > .acfwhip/spec-tools/drafter.md <<'EOF'
# drafter
## review
Review the plan.
## push
Draft a revision into your state directory.
## pull
Copy your draft to the output directory.
## from
Fetch the named spec.
EOF
decl drafter 'agent=drafter.md' 'policy=advisory'; commit_all; prime
sx list --machine
t "an agent= tool without rerun= defaults to every (no capabilities verb, so no COST|)" has '^TOOL|drafter|agent|-|advisory|every|120$'
C0=$(c12)
sx push "$PLAN"
t "agent push: exit 21 with an AGENT|drafter|push| work order" eval 'rc 21 && has "^AGENT|drafter|push|"'
ORDER="$REPO/.acfwhip/run/workbench/$ID/push/order"
OFILE=$(sed -n 's/^file=//p' "$ORDER" 2>/dev/null); OOUT=$(sed -n 's/^out=//p' "$ORDER" 2>/dev/null); OST=$(sed -n 's/^state=//p' "$ORDER" 2>/dev/null)
t "...the order names the frozen bytes, an out dir and a state dir" eval '[ -f "$OFILE" ] && [ -n "$OOUT" ] && [ -n "$OST" ]'
mkdir -p "$OST" "$OOUT"
perl -pe 's/^(- AC1\.1: the notice renders for owners)$/$1\n- AC1.2: DRAFT ADDED/' "$OFILE" > "$OST/draft.md"
printf 'REF|drafter-1\n' > "$OOUT/stdout"
perl -pi -e 's/^Email delivery\.$/Email delivery. USER EDIT WHILE THE AGENT WORKED./' "$PLAN"
sx push "$PLAN"
t "collecting the push after plan.md moved: exit 0" eval 'rc 0 && has "^PUSHED|drafter|"'
t "...BASE is the bytes the agent drafted from ($C0), not today's plan" has "^PUSHED|drafter|ref=drafter-1|content=$C0"
t "...and the pending 'pushed' row says base=$C0" eval "grep '|pushed|' \"\$(pending_log)\" | grep -q 'base=$C0'"
sx pull "$PLAN"
t "agent pull: exit 21 with a work order" eval 'rc 21 && has "^AGENT|drafter|pull|"'
POUT=$(sed -n 's/^out=//p' "$REPO/.acfwhip/run/workbench/$ID/pull/order" 2>/dev/null)
mkdir -p "$POUT"; cp "$OST/draft.md" "$POUT/remote.md"; printf 'REF|drafter-1\n' > "$POUT/stdout"
sx pull "$PLAN"
t "collecting the pull: a real 3-way merge (PULLED|drafter|merged)" eval 'rc 0 && has "^PULLED|drafter|merged|"'
t "...the agent's draft arrived" grep -q 'AC1.2: DRAFT ADDED' "$PLAN"
t "...and the edit made while the agent worked survived" grep -q 'USER EDIT WHILE THE AGENT WORKED' "$PLAN"
sx from drafter spec-a
t "agent from: exit 21 with a work order" eval 'rc 21 && has "^AGENT|drafter|from|"'
FORDER="$REPO/.acfwhip/run/workbench/_from/drafter/fetch/order"
FOUT=$(sed -n 's/^out=//p' "$FORDER" 2>/dev/null); mkdir -p "$FOUT"
printf '# Spec A\n\n## Deliverables\n\n### D1: A\n- AC1.1: a\n' > "$FOUT/remote.md"; printf 'REF|spec-a\n' > "$FOUT/stdout"
sx from drafter spec-b
t "asking for another ref never collects the spec-a result: a fresh order (21), no FROM|" eval 'rc 21 && ! has "^FROM|"'
t "...issued for ref=spec-b" grep -qx 'ref=spec-b' "$FORDER"
printf '## review\nORIGINAL-PROMPT\n' > .acfwhip/spec-tools/pa.md
decl pa 'agent=pa.md' 'at=plan'; commit_all; prime
sx prompt pa review
t "prompt: a trusted agent prompt prints" eval 'rc 0 && has ORIGINAL-PROMPT'
printf '## review\nCHANGED-PROMPT\n' > .acfwhip/spec-tools/pa.md
sx prompt pa review
t "prompt: a prompt changed after trust is refused (25), never handed on unseen" eval 'rc 25 && ! has CHANGED-PROMPT'

# =================================================================================================
sec "budget: a block tool the budget cuts short is no result either"
new_repo budgetcut
CBS=$(mkctl budgetcut-slow); set_ctl "$CBS" sleep 3
CBK=$(mkctl budgetcut-blk); set_ctl "$CBK" sleep 20; set_ctl "$CBK" exit 1
decl a-slow "review=$(rcmd "$CBS" slow)" 'at=plan' 'policy=advisory' 'timeout=10'
decl b-blk  "review=$(rcmd "$CBK" blk)"  'at=plan,task' 'policy=block' 'timeout=60'
commit_all; prime; bump bc1; C=$(c12)
export ACFW_SPEC_BUDGET=9
sx review "$PLAN"
unset ACFW_SPEC_BUDGET
t "the block tool STARTED (cut short, not skipped)" [ "$(ncalls "$CBK")" = 1 ]
t "...and the card says the budget ran out while it ran" either_i 'budget ran out while it ran'
sx gate "$PLAN" --blob "$C"
t "a block tool the budget cut short -> gate 22, not a pass" rc 22
t "...naming it" has '^GATE|unmet|b-blk|'
rm -f "$CBK/sleep"; set_ctl "$CBK" exit 0
sx review "$PLAN"
t "with the budget back, the same bytes run it again (the cut run was not cached)" [ "$(ncalls "$CBK")" = 2 ]
sx gate "$PLAN" --blob "$C"
t "...and its GO now passes (0)" rc 0
set_ctl "$CBK" sleep 20
TDB="$WORK/tasks-budgetcut"; mktask "$TDB" bc-001-a a
export ACFW_SPEC_BUDGET=6
sx review --stage task --machine "$TDB/bc-001-a.md"
unset ACFW_SPEC_BUDGET
L=$(reviewed_line bc-001-a b-blk)
t "task stage: a block tool the budget cut short reports block|nogo (held), never error (released)" \
  eval '[ "$(fieldn "$L" 4)" = block ] && [ "$(fieldn "$L" 5)" = nogo ]'
rm -f "$CBK/sleep"

# =================================================================================================
sec "dir workbench: a push never overwrites folder edits made after the last sync"
if [ -x "$DIRDRV" ]; then
  new_repo dirsync
  export ACFW_WORKBENCH_DIR="$WORK/wb-sync"; mkdir -p "$ACFW_WORKBENCH_DIR"
  decl dir 'driver=dir' 'policy=advisory' 'timeout=30'; commit_all; prime
  sx push "$PLAN"; sx pull "$PLAN"
  t "push, then pull: back in (0)" rc 0
  W="$ACFW_WORKBENCH_DIR/$ID.md"
  perl -pi -e 's/^Notices are per workspace\.$/Notices are per workspace. PHONE EDIT AFTER SYNC./' "$W"
  perl -pi -e 's/^Email delivery\.$/Email delivery. LOCAL EDIT./' "$PLAN"
  sx push "$PLAN"
  t "a push over a folder copy edited since the last sync is refused (25)" rc 25
  t "...the folder copy still holds that edit" grep -q 'PHONE EDIT AFTER SYNC' "$W"
  AS=$(find "$REPO/.acfwhip/run" -name 'unsynced-*' -type f 2>/dev/null | head -1)
  t "...a copy is saved under .acfwhip/run" eval '[ -n "$AS" ] && grep -q "PHONE EDIT AFTER SYNC" "$AS"'
  t "...and a HINT names the way forward (pull --file)" eval 'has "^HINT|" && has "pull --file"'
  t "...the plan did not go OUT" not state_out
  sx pull "$PLAN" --file "$AS"
  t "pull --file <saved copy>: a clean 3-way merge (0)" rc 0
  t "...both edits are in plan.md" eval 'grep -q "PHONE EDIT AFTER SYNC" "$PLAN" && grep -q "LOCAL EDIT" "$PLAN"'
  sx push "$PLAN"
  t "the next push goes through (0)" rc 0
  t "...and the folder copy carries both edits" eval 'grep -q "PHONE EDIT AFTER SYNC" "$W" && grep -q "LOCAL EDIT" "$W"'
  unset ACFW_WORKBENCH_DIR
else
  bad "shipped dir driver is missing: the unsynced-edit guard was not checked"
fi

# =================================================================================================
sec "a symlinked driver is judged by its target: a dirty or outside target runs advisory"
new_repo symdrv
CSY=$(mkctl symdrv)
mkdrv "$REPO/scripts" lnk "$CSY" sym
mkdir -p .acfwhip/adapters; ln -s ../../scripts/acfw-spec-lnk .acfwhip/adapters/acfw-spec-lnk
decl lnk 'driver=lnk' 'at=plan' 'policy=block'
git add scripts; commit_all; prime
bump sy1; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "baseline: a committed symlinked driver with a clean target backs the gate (0)" rc 0
printf '# local tweak\n' >> scripts/acfw-spec-lnk; prime
N0=$(ncalls "$CSY"); bump sy2; C=$(c12); sx review "$PLAN"
t "its target edited locally: it still runs" [ "$(ncalls "$CSY")" -gt "$N0" ]
sx gate "$PLAN" --blob "$C"
t "...but its GO cannot satisfy the gate (22): the link text is clean, what runs is not" rc 22
git checkout -q -- scripts/acfw-spec-lnk
mkdrv "$WORK/outside" lnk "$CSY" out
rm -f .acfwhip/adapters/acfw-spec-lnk; ln -s "$WORK/outside/acfw-spec-lnk" .acfwhip/adapters/acfw-spec-lnk
commit_all "link out of the repo"; prime
bump sy3; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "a committed link to a target outside the repo never backs the gate (22)" rc 22

# =================================================================================================
sec "a declaration with an invalid file name is flagged, never silently ignored"
new_repo badname
decl no_tbd 'review=true' 'at=plan' 'policy=block'
cp "$ACF_WHIP_SRC/spec-tools/examples/vale.example" .acfwhip/spec-tools/vale.example
printf '# notes\nreview=grep x (an example in a note)\n' > .acfwhip/spec-tools/NOTES.md
commit_all
sx status --machine
t "status: a CARD says no_tbd is not a valid spec tool name" \
  eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q 'no_tbd is not a valid spec tool name'"
t "status: a copied vale.example (extension kept) is flagged too" eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q 'vale.example'"
t "status: a .md note is never flagged" not eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q 'NOTES.md'"
sx list --machine
t "list: a WARN names no_tbd" eval 'printf "%s\n" "$ERR" | grep -q "no_tbd is not a valid spec tool name"'

# =================================================================================================
sec "trust binds to what was shown: a change after the notice is shown again, never trusted unseen"
new_repo toctou
CTT=$(mkctl toctou)
decl tt "review=$(rcmd "$CTT" v1)" 'at=plan'; commit_all
sx review "$PLAN"
t "the notice shows v1 and its version key" eval 'either_i "tag v1" && hasE "^TRUST\\|tt\\|.*\\|version=[0-9a-f]+$"'
decl tt "review=$(rcmd "$CTT" v3)" 'at=plan'; commit_all "a teammate's change pulled in after the notice"
sx trust
t "'run tools' after an unseen change: exit 0, but NOT trusted" \
  eval 'rc 0 && ! grep -q "^tt " "$REPO/.acfwhip/run/spec/trusted" 2>/dev/null'
t "...the new version is shown instead" either_i 'tag v3'
KEYV=$(printf '%s\n' "$OUT" | sed -n 's/^TRUST|tt|.*|version=\([0-9a-f]*\)$/\1/p' | head -1)
sx review "$PLAN"
t "...and it did not run" [ "$(ncalls "$CTT")" = 0 ]
sx trust "tt=0000000000000000"
t "trust <name>=<a key that is not the current one> does not trust" not grep -q '^tt ' "$REPO/.acfwhip/run/spec/trusted"
sx trust "tt=$KEYV"
t "trust <name>=<the key shown> trusts exactly that version" eval '[ -n "$KEYV" ] && grep -qx "tt $KEYV" "$REPO/.acfwhip/run/spec/trusted"'
sx review "$PLAN"
t "...and it runs, as v3" eval '[ "$(ncalls "$CTT")" = 1 ] && [ "$(last_tag "$CTT")" = v3 ]'

# =================================================================================================
sec "trust: a status CARD is not consent; a command longer than the card is shown in full first"
new_repo tofu160
CT6=$(mkctl tofu160)
TAIL6="$WORK/tofu160-tail-ran"
decl longcmd "review=grep -c TBD \"\$ACFW_SPEC_FILE\" >/dev/null; : a long harmless looking comment $(rep x 150); touch '$TAIL6'" 'at=plan'
commit_all
sx status --machine
t "status: a trust CARD for the long command" eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep -q longcmd"
t "...whose capped cells never reach the command's tail" not has 'tofu160-tail-ran'
sx trust
t "'run tools' after only the card: exit 0, but NOT trusted" \
  eval 'rc 0 && ! grep -q "^longcmd " "$REPO/.acfwhip/run/spec/trusted" 2>/dev/null'
t "...it prints the full declaration instead, tail included" has 'tofu160-tail-ran'
t "...and asks for the reply again" either_i 'run tools'
sx review "$PLAN"
t "...so the next review still does not run it: the tail never ran" [ ! -e "$TAIL6" ]
sx trust
t "a 'run tools' after the full notice trusts it" grep -q '^longcmd ' "$REPO/.acfwhip/run/spec/trusted"
sx review "$PLAN"
t "...and it runs, tail and all: the operator saw every byte before consenting" [ -e "$TAIL6" ]

# =================================================================================================
sec "a control character in a declaration is a declaration error: never shown reflowed, never run"
new_repo ctlchar
PWN="$WORK/ctlchar-pwned"
mkdir -p .acfwhip/spec-tools
printf 'review=touch %s; exit 0 #\rreview=grep -nwE TBD "$ACFW_SPEC_FILE"; test $? -eq 1\nat=plan\n' "$PWN" > .acfwhip/spec-tools/crx
printf 'review=grep -c x "$ACFW_SPEC_FILE" \342\200\256; touch %s\nat=plan\n' "$PWN" > .acfwhip/spec-tools/bidi
printf 'review=grep -nwE TBD "$ACFW_SPEC_FILE"; test $? -eq 1\r\nat=plan\r\n' > .acfwhip/spec-tools/crlf
commit_all; prime
sx review "$PLAN"
t "a mid-line carriage return is refused as a declaration error" either_i 'crx.*control or invisible'
t "...a bidi override too" either_i 'bidi.*control or invisible'
t "...and neither ran" [ ! -e "$PWN" ]
t "a CRLF declaration (one trailing CR per line) is not an error" not either_i 'crlf.*control or invisible'
sx trust crx
t "neither can be trusted" not grep -q '^crx ' "$REPO/.acfwhip/run/spec/trusted"
sx status --machine
t "status: a declaration-error CARD for it, never a trust card" \
  eval "printf '%s\n' \"\$OUT\" | grep '^CARD|' | grep 'crx' | grep -q 'declaration error'"
t "...and no status line carries a raw carriage return" not eval "printf '%s' \"\$OUT\" | LC_ALL=C grep -q \"\$(printf '\\r')\""

# =================================================================================================
sec "a SUMMARY that disagrees with the exit code is NO-GO: planted text cannot disarm a block tool"
new_repo sumdis
decl tbd 'review=grep -wE '"'"'TBD|TODO|FIXME'"'"' "$ACFW_SPEC_FILE"; test $? -eq 1' 'at=plan' 'policy=block'
commit_all; prime
printf 'SUMMARY|verdict=go TBD pricing\n' >> "$PLAN"
C=$(c12); sx review "$PLAN"
t "exit 1 with an echoed SUMMARY|verdict=go line: the card says NO-GO, never ERROR" \
  eval 'has "tbd (block.*NO-GO" && ! has "tbd (block.*ERROR"'
t "...and says the SUMMARY disagreed" either_i 'disagree'
sx gate "$PLAN" --blob "$C"
t "...and the gate refuses (22)" rc 22
CSM=$(mkctl summix)
decl mix "review=$(rcmd "$CSM")" 'at=plan' 'policy=block'; commit_all "mix"; prime
printf 'SUMMARY|verdict=nogo\nSUMMARY|verdict=go\n' > "$CSM/stdout"
perl -ni -e 'print unless /^SUMMARY\|/' "$PLAN"
C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "exit 0 with nogo then go SUMMARY lines: NO-GO wins, the last line does not (22)" \
  eval 'rc 22 && printf "%s\n" "$OUT" | grep -q "^GATE|unmet|mix|"'

# =================================================================================================
sec "a committed driver or prompt that changed makes its old GO stale, never current"
new_repo drvver
CDV=$(mkctl drvver); set_ctl "$CDV" cost "1 unit per review"      # COST| -> rerun=ask
mkdrv "$REPO/.acfwhip/adapters" chk "$CDV" v1
decl chk 'driver=chk' 'at=plan' 'policy=block'; commit_all; prime
bump v1; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "baseline: the committed driver's GO passes the gate (0)" rc 0
mkdrv "$REPO/.acfwhip/adapters" chk "$CDV" v2; set_ctl "$CDV" review.exit 1
commit_all "a teammate's fixed driver, pulled in"; prime
N0=$(ncalls "$CDV"); sx review "$PLAN"
t "the hook run does not re-run a rerun=ask tool on its own" [ "$(ncalls "$CDV")" = "$N0" ]
t "...and the card labels the old GO stale, never current" has 'chk (block.*GO.*stale: the tool changed'
t "...with the reason under it" has 'note: its driver or prompt changed since this result'
sx gate "$PLAN" --blob "$C"
t "...and the old version's GO cannot satisfy the gate (22)" rc 22
sx review "$PLAN" --all; sx gate "$PLAN" --blob "$C"
t "after 'review', the new driver's own NO-GO decides (22, NO-GO)" \
  eval 'rc 22 && printf "%s\n" "$OUT" | grep "^GATE|unmet|chk|" | grep -q "NO-GO"'

# =================================================================================================
sec "the gate names the real cause: a pulled-in declaration change is not your local edit"
new_repo declchg
CDC=$(mkctl declchg)
decl dc "review=$(rcmd "$CDC" v1)" 'at=plan' 'policy=block'; commit_all; prime
bump d1; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "baseline: gate 0" rc 0
decl dc "review=$(rcmd "$CDC" v2)" 'at=plan' 'policy=block'; commit_all "a teammate's change, pulled in"
sx show "$PLAN" --blob "$C"
t "the card says the committed declaration changed" has 'committed declaration changed since this result'
t "...and never tells you to revert an edit you did not make" not has 'commit or revert'
sx gate "$PLAN" --blob "$C"
t "...the gate refuses (22) with the same reason" eval 'rc 22 && either_i "committed declaration changed"'

sec "a local experiment on a declaration does not evict the committed GO"
new_repo evict
CEV=$(mkctl evict)
decl ev "review=$(rcmd "$CEV")" 'at=plan' 'policy=block' 'rerun=ask'; commit_all; prime
bump e1; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "baseline: the committed GO passes (0)" rc 0
printf '# a local note\n' >> .acfwhip/spec-tools/ev; prime
sx review "$PLAN" --all
N1=$(ncalls "$CEV")
t "the edited copy ran (it filled the result slot)" [ "$N1" -ge 2 ]
git checkout -q -- .acfwhip/spec-tools/ev
sx gate "$PLAN" --blob "$C"
t "after reverting the experiment the committed GO passes again (0), with no new run" \
  eval 'rc 0 && [ "$(ncalls "$CEV")" = "$N1" ]'
prime; sx review "$PLAN"
t "...and the next card uses it too: the paid rerun=ask tool is not billed twice" [ "$(ncalls "$CEV")" = "$N1" ]
t "...shown as the current GO, not a stale one" eval 'has "ev (block.*GO, 0 finding" && ! has "stale: the tool changed"'

# =================================================================================================
sec "an index flag cannot make an edited block driver look clean (assume-unchanged, skip-worktree)"
new_repo idxflag
CIF=$(mkctl idxflag); set_ctl "$CIF" review.exit 1
mkdrv "$REPO/.acfwhip/adapters" strict "$CIF" s
decl strict 'driver=strict' 'at=plan' 'policy=block'; commit_all; prime
bump i0; C=$(c12); sx review "$PLAN"; sx gate "$PLAN" --blob "$C"
t "baseline: the committed driver says NO-GO (22)" rc 22
for flag in assume-unchanged skip-worktree; do
  git update-index "--$flag" .acfwhip/adapters/acfw-spec-strict
  printf '#!/bin/bash\n[ "${1:-}" = capabilities ] && { echo "VERBS|review"; echo "EGRESS|none"; }\nexit 0\n' \
    > .acfwhip/adapters/acfw-spec-strict
  t "$flag: git status shows nothing" [ -z "$(git status --porcelain -- .acfwhip)" ]
  prime; bump "i-$flag"; C=$(c12); sx review "$PLAN"; o="$OUT$ERR"
  t "$flag: the edited driver ran and is reported as edited (content, not the index)" \
    eval "printf '%s' \"\$o\" | grep -q 'edited or uncommitted'"
  sx gate "$PLAN" --blob "$C"
  t "$flag: its GO cannot satisfy the block gate (22)" rc 22
  git update-index "--no-$flag" .acfwhip/adapters/acfw-spec-strict
  git checkout -q -- .acfwhip/adapters/acfw-spec-strict
done

# =================================================================================================
sec "secret lint scope: JSON field names in plans and tasks are not credentials; .mcp.json still is"
new_repo jsonscope
CJS=$(mkctl jsonscope)
decl js "review=$(rcmd "$CJS")" 'at=plan,task' 'policy=block'; commit_all; prime
{ printf '\n```json\n'
  printf '{"partitionKey": "tenant_and_customer_id", "nextPageToken": "opaque-cursor-string"}\n'
  printf '{"apiKey": "YOUR_API_KEY_HERE"}\n```\n'; } >> "$PLAN"
C=$(c12); sx review "$PLAN"
t "a plan with JSON fields ending in Key/Token is reviewed, not refused (no 20)" \
  eval 'rc 0 && [ "$(ncalls "$CJS")" -ge 1 ]'
sx gate "$PLAN" --blob "$C"
t "...and its block tool's GO passes the gate (0)" rc 0
TDJ="$WORK/tasks-json"; mktask "$TDJ" api-001-orders j
printf '\nRequest body: {"idempotencyKey": "order-1234-retry-1"}\n' >> "$TDJ/api-001-orders.md"
sx review --stage task --machine "$TDJ/api-001-orders.md"
t "a task with a camelCase JSON key is reviewed (go), never held as a credential literal" \
  [ "$(fieldn "$(reviewed_line api-001-orders js)" 5)" = go ]
SKJ="sk""-$(rep q 24)"
printf 'Our key: %s\n' "$SKJ" >> "$PLAN"
sx review "$PLAN"
t "a real key shape in a plan still refuses (20)" rc 20
perl -ni -e 'print unless /^Our key:/' "$PLAN"
printf '{"mcpServers":{"x":{"headers":{"X-Api-Key":"%s"}}}}\n' "a1b2c3d4e5f6$(rep 0 24)" > .mcp.json
git add -f .mcp.json && git commit -qm "tracked mcp config"
sx review "$PLAN"
t "a tracked .mcp.json with a literal JSON key still refuses (20)" rc 20

# =================================================================================================
sec "tool text the engine echoes is redacted: a workbench URL token never reaches status or push output"
new_repo wbred
CWR=$(mkctl wbred); set_ctl "$CWR" verbs 'review,push,pull'
TOKW="gtmcp_$(rep A 44)"; BRW="$(rep B 24)"
printf 'REF|doc42\nURL|https://wb.example.test/d/doc42?access_token=%s\nHINT|share with Bearer %s\n' "$TOKW" "$BRW" \
  > "$CWR/push.stdout"
mkdrv "$REPO/.acfwhip/adapters" wbr "$CWR" w
decl wbr 'driver=wbr'; commit_all; prime
sx push "$PLAN" --tool wbr
t "push: exit 0, the plan is OUT" eval 'rc 0 && has "^PUSHED|wbr|ref=doc42|"'
t "...the open: line is shown" has '  open: https://wb.example.test/d/doc42'
t "...but never the token in it" not eval 'printf "%s\n%s\n" "$OUT" "$ERR" | grep -qF "$TOKW"'
t "...nor the Bearer value in its hint" not eval 'printf "%s\n%s\n" "$OUT" "$ERR" | grep -qF "$BRW"'
sx status --machine
t "status: the OUT fact is there, with its link" hasE '^FACT\|OUT .*https://wb.example.test/d/doc42'
t "...and never the token" not eval 'printf "%s\n" "$OUT" | grep -qF "$TOKW"'

# =================================================================================================
sec "dir from: a path outside the workbench folder is refused, never swapped for a same-named file"
new_repo dirfrom
export ACFW_WORKBENCH_DIR="$WORK/wb-dirfrom"; mkdir -p "$ACFW_WORKBENCH_DIR" "$WORK/elsewhere-dirfrom"
printf '# Old unrelated\n\nsome text\n' > "$ACFW_WORKBENCH_DIR/spec.md"
printf '# The one I named\n\nother text\n' > "$WORK/elsewhere-dirfrom/spec.md"
decl dir 'driver=dir'; commit_all; prime
sx from dir "$WORK/elsewhere-dirfrom/spec.md"
t "from dir <path elsewhere>: refused (25)" rc 25
t "...never importing the folder's same-named file" not has 'TITLE|Old unrelated'
t "...and the hint says to import the file directly" either_i '/whip '
sx from dir "$ACFW_WORKBENCH_DIR/spec.md"
t "from dir <path inside the folder>: imported" eval 'rc 0 && has "TITLE|Old unrelated"'
sx from dir spec.md
t "from dir <name>: imported" eval 'rc 0 && has "TITLE|Old unrelated"'
unset ACFW_WORKBENCH_DIR

# =================================================================================================
sec "AGENT| commands are shell-quoted: a checkout path with an apostrophe works"
new_repo "bob's plans"
mkdir -p .acfwhip/spec-tools
printf '# critic\n## review\nMARK-APOS-REVIEW\n' > .acfwhip/spec-tools/critic.md
decl critic 'agent=critic.md' 'at=plan' 'rerun=every'; commit_all; prime
sx review "$PLAN"
t "review from a path with an apostrophe: exit 21 with an AGENT line" eval 'rc 21 && hasE "^AGENT\\|critic\\|review\\|"'
PCMDA=$(line_of '^AGENT\|critic\|review\|' | cut -d'|' -f4-)
PTXTA=$(cd "$REPO" && perl -e 'alarm 60; exec @ARGV' /bin/bash -c "$PCMDA" 2>&1 </dev/null); PRC=$?
t "...and its command runs exactly as printed" eval '[ "$PRC" = 0 ] && printf "%s" "$PTXTA" | grep -q MARK-APOS-REVIEW'
cd "$WORK" || exit 1

# =================================================================================================
sec "capabilities prose: add shows COST and EGRESS as the driver printed them, commas kept"
# VERBS and NEEDS are word lists and split on commas; COST and EGRESS are prose a person reads before
# trusting a paid or remote tool. Splitting those turned "1 unit per review, billed monthly" into
# "1 unit per review billed monthly" on the one screen that asks for consent.
new_repo capsprose
CCP=$(mkctl capsprose)
set_ctl "$CCP" verbs "review,push"
set_ctl "$CCP" cost "1 unit per review, billed monthly"
set_ctl "$CCP" egress "api.example.test, cdn.example.test"
mkdrv "$REPO/.acfwhip/adapters" pd "$CCP" v1
decl pd 'driver=pd' 'at=plan'
sx add pd
t "add ran (exit 0)" rc 0
t "COST is shown verbatim, its comma kept" has '^  cost: 1 unit per review, billed monthly (rerun defaults to ask)$'
t "EGRESS is shown as printed" has '^  egress: api.example.test, cdn.example.test$'
t "VERBS is still a word list (the comma splits it)" has '^  verbs: review push$'
cd "$WORK" || exit 1

# =================================================================================================
sec "secret lint: a plan.md literal is listed even when a tracked .env holds one too"
# secret_die exits on the first hit list. Linting the scope first and the plan after it meant a
# tracked .env literal hid a literal in plan.md, and /whip stops only on a plan.md location, so it
# rendered an approval card whose yes commits that literal.
new_repo jointlint
CJ=$(mkctl jointlint)
decl rv "review=$(rcmd "$CJ")" 'at=plan'; commit_all; prime
printf 'MY_API_KEY=%s\n' "$(rep q 20)" > .env
git add -f .env && git commit -qm "a tracked env file"
printf 'Call it with %s.\n' "sk""-$(rep j 24)" >> "$PLAN"
PLN=$(grep -n 'Call it with sk' "$PLAN" | cut -d: -f1)
: > "$CJ/calls"; sx review "$PLAN"
t "review: exit 20" rc 20
t "...listing the plan.md line" eval 'printf "%s" "$ERR" | grep -qF "docs/cycles/$ID/plan.md:$PLN"'
t "...and the .env line" eval 'printf "%s" "$ERR" | grep -qF ".env:1"'
t "...and no tool ran" [ "$(ncalls "$CJ")" = 0 ]
cd "$WORK" || exit 1

# =================================================================================================
sec "hook review: bytes nothing can approve are not reviewed; an explicit review still runs"
# A hook review exists to put a verdict on a card. An abandoned or closed cycle, or one approved at
# exactly these bytes, has no card: reviewing it billed a rerun=ask tool or opened an agent work order
# for a yes that can never come.
if [ ! -x "$CYCLE" ]; then
  skip "acfw-cycle is not present/executable yet: hook-skip checks not run"
else
  new_repo hookskip
  cx init hook-skip --kind feature --source test
  ID=$(printf '%s\n' "$OUT" | sed -n 's/^INIT|\([^|]*\)|.*/\1/p' | head -1)
  PLAN="docs/cycles/$ID/plan.md"; RECH="docs/cycles/$ID/record.md"
  plan_body > "$PLAN"
  CHK=$(mkctl hookskip)
  decl rv "review=$(rcmd "$CHK")" 'at=plan'; commit_all; prime
  : > "$CHK/calls"; sx review "$PLAN"
  t "a draft is reviewed" eval 'rc 0 && [ "$(ncalls "$CHK")" -ge 1 ]'
  cx approve "$PLAN" --expect "$(c12)"
  t "(fixture: approved)" rc 0
  : > "$CHK/calls"; sx review "$PLAN"
  t "approved at exactly these bytes: exit 0, nothing printed, no tool ran" \
    eval 'rc 0 && [ -z "$OUT" ] && [ "$(ncalls "$CHK")" = 0 ]'
  : > "$CHK/calls"; sx review "$PLAN" --tool rv --fresh
  t "...an explicit --tool review still runs" eval '[ "$(ncalls "$CHK")" -ge 1 ]'
  bump amended
  : > "$CHK/calls"; sx review "$PLAN"
  t "an amended approved plan is up for a yes again: reviewed" eval 'rc 0 && [ "$(ncalls "$CHK")" -ge 1 ]'
  cp "$RECH" "$WORK/rec.hook"
  perl -pi -e 's/^- \*\*Status\*\*: approved$/- **Status**: abandoned/' "$RECH"
  bump amended-again
  : > "$CHK/calls"; sx review "$PLAN"
  t "a working-tree edit of record.md cannot switch the review off (the tracked record is read from HEAD)" \
    eval '[ "$(ncalls "$CHK")" -ge 1 ]'
  cp "$WORK/rec.hook" "$RECH"
  cx abandon "$PLAN" --reason 'hook skip test'
  t "(fixture: abandoned)" rc 0
  bump after-abandon                     # new bytes, so nothing below can come from the cache
  : > "$CHK/calls"; sx review "$PLAN"
  t "an abandoned cycle: exit 0, nothing printed, no tool ran" eval 'rc 0 && [ -z "$OUT" ] && [ "$(ncalls "$CHK")" = 0 ]'
  : > "$CHK/calls"; sx review "$PLAN" --all
  t "...--all still reviews it" eval '[ "$(ncalls "$CHK")" -ge 1 ]'
  cd "$WORK" || exit 1
fi

echo
[ "$SKIPS" -gt 0 ] && echo "phase21-spec-tools: $SKIPS guarded group(s) skipped (see SKIP lines above)"
echo "phase21-spec-tools: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
