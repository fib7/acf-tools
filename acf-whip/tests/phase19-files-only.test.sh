#!/usr/bin/env bash
# phase19-files-only.test.sh — `scan-backlog.sh --only` and the relay header on the files backend (3.4.0).
#
# Two defects this pins, both of which produced a CONFIDENT WRONG ANSWER rather than an error:
#
#   1. The digest drops a terminal-accepted task that nothing depends on. That is the right call for
#      the working set — but it means the orchestrator, which can only see what it was handed, told
#      an operator who scoped to a finished task that the id "does not exist in the backlog". A seed
#      is now retained through the collapse, so the run can recognise it as done and say so.
#
#   2. The snapshot is produced by this script and DELIVERED by an agent echoing its stdout into a
#      schema string. A shortened-but-valid echo parses cleanly and is indistinguishable from a
#      smaller board. The relay header states what was emitted so the consumer can prove it got it.
#
# Run: bash acf-whip/tests/phase19-files-only.test.sh
set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAN="$ACF_WHIP/skills/go/bin/scan-backlog.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "phase19-files-only: jq unavailable — SKIP"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p19files.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO"
unset ACFW_STORE 2>/dev/null || true

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

mk pending      ui-021-login    UI-21   ui    api-014-token
mk pending      ui-021-logout   UI-22   ui2   none
mk blocked      api-014-token   API-14  api   db-001-schema
mk accepted     db-001-schema   DB-1    none  none
mk accepted     solo-500-done   SOLO-5  none  none
mk pending      unrelated-777   UN-77   other none
mk draft        doc-009-draft   DOC-9   none  none
mk archive      old-300-arch    OLD-3   none  none

S(){ bash "$SCAN" "$@"; }

# ============================ the A4 defect: a finished seed "does not exist" ==================
BASE=$(S --digest --mode default)
check "baseline: a terminal-accepted task nothing depends on is collapsed out of the working set" \
  "! printf '%s' \"\$BASE\" | jq -e '[.tasks[].stem,.satisfiedDeps[].stem]|index(\"solo-500-done\")' >/dev/null"

ONLY_DONE=$(S --digest --mode default --only solo-500-done)
check "--only RETAINS that task so the caller's id resolves" \
  "printf '%s' \"\$ONLY_DONE\" | jq -e '[.satisfiedDeps[].stem]|index(\"solo-500-done\")' >/dev/null"
check "...and records what the seed resolved to" \
  "[ \"\$(printf '%s' \"\$ONLY_DONE\" | jq -r '.scope.resolved[\"solo-500-done\"]')\" = 'solo-500-done' ]"
check "...without calling it unresolvable" \
  "printf '%s' \"\$ONLY_DONE\" | jq -e '(.scope.unresolved|length) == 0' >/dev/null"

# Retention must hold in FULL mode too (the same collapse runs there, via slim stubs).
ONLY_FULL=$(S --mode default --only solo-500-done)
check "full (non-digest) mode retains the seed as well" \
  "printf '%s' \"\$ONLY_FULL\" | jq -e '[.tasks[].stem]|index(\"solo-500-done\")' >/dev/null"

# ============================ seed resolution ==================================================
check "a seed resolves by exact stem" \
  "[ \"\$(S --digest --only ui-021-login | jq -r '.scope.resolved[\"ui-021-login\"]')\" = 'ui-021-login' ]"
check "a seed resolves by the ID field" \
  "[ \"\$(S --digest --only UI-21 | jq -r '.scope.resolved[\"UI-21\"]')\" = 'ui-021-login' ]"
check "a seed resolves by a UNIQUE stem prefix" \
  "[ \"\$(S --digest --only unrelated | jq -r '.scope.resolved[\"unrelated\"]')\" = 'unrelated-777' ]"

# An ambiguous prefix must be REPORTED, never resolved by first match. On a large board first-match
# silently selects whichever card the filesystem happened to list first.
AMB=$(S --digest --only ui-021)
check "an AMBIGUOUS prefix is reported, not guessed" \
  "printf '%s' \"\$AMB\" | jq -e '.scope.ambiguous[0].tok == \"ui-021\"' >/dev/null"
check "...naming every candidate (not one fewer)" \
  "[ \"\$(printf '%s' \"\$AMB\" | jq -r '.scope.ambiguous[0].candidates|sort|join(\",\")')\" = 'ui-021-login,ui-021-logout' ]"
check "...and resolving nothing on the guess" \
  "printf '%s' \"\$AMB\" | jq -e '(.scope.resolved|length) == 0' >/dev/null"
check "an exact stem still wins over its own prefix ambiguity" \
  "[ \"\$(S --digest --only ui-021-login | jq -r '.scope.ambiguous|length')\" = '0' ]"

check "an unknown seed is reported as unresolved" \
  "printf '%s' \"\$(S --digest --only nope-404)\" | jq -e '.scope.unresolved|index(\"nope-404\")' >/dev/null"

# ============================ inactive seeds: paused is not missing =============================
DRAFT=$(S --digest --only doc-009-draft)
check "a DRAFT seed is reported as inactive, not unresolvable" \
  "printf '%s' \"\$DRAFT\" | jq -e '.scope.inactiveSeeds[0].stem == \"doc-009-draft\"' >/dev/null"
check "...with the folder that explains why it cannot run" \
  "printf '%s' \"\$DRAFT\" | jq -e '.scope.inactiveSeeds[0].folder == \"draft\"' >/dev/null"
check "...and the card itself in inactive[], where dependency resolution can still see it" \
  "printf '%s' \"\$DRAFT\" | jq -e '[.inactive[].stem]|index(\"doc-009-draft\")' >/dev/null"
check "...never in tasks[], which is what the scheduler dispatches from" \
  "! printf '%s' \"\$DRAFT\" | jq -e '[.tasks[].stem]|index(\"doc-009-draft\")' >/dev/null"
check "an ARCHIVED seed is reported the same way" \
  "printf '%s' \"\$(S --digest --only old-300-arch)\" | jq -e '.scope.inactiveSeeds[0].folder == \"archive\"' >/dev/null"

MIX=$(S --digest --only ui-021-login --only doc-009-draft)
check "a mixed scope resolves both seeds" "printf '%s' \"\$MIX\" | jq -e '(.scope.resolved|length) == 2' >/dev/null"
check "...and still names the inactive one" "printf '%s' \"\$MIX\" | jq -e '(.scope.inactiveSeeds|length) == 1' >/dev/null"

# ============================ relay header ======================================================
relay_consistent(){ # <snapshot json>
  printf '%s' "$1" | jq -e '
    (.relay.n == ((.tasks|length) + (.inactive|length) + (.satisfiedDeps|length)))
    and (.relay.tasks == (.tasks|length))
    and (.relay.inactive == (.inactive|length))
    and (.relay.sat == (.satisfiedDeps|length))
    and (.relay.bytes == ([.tasks[].stem, .inactive[].stem, .satisfiedDeps[].stem] | map(length) | add // 0))' >/dev/null
}
check "relay matches the payload (digest)"            "relay_consistent \"\$(S --digest)\""
check "relay matches the payload (full)"              "relay_consistent \"\$(S)\""
check "relay matches the payload (scoped)"            "relay_consistent \"\$(S --digest --only ui-021-login)\""
check "relay matches the payload (scoped + inactive)" "relay_consistent \"\$(S --digest --only doc-009-draft)\""
check "relay matches the payload (override)"          "relay_consistent \"\$(S --digest --mode override)\""
check "relay is the FIRST key (a tail-elided echo still carries the expectation it fails)" \
  "printf '%s' \"\$(S --digest)\" | grep -q '^{\"relay\":'"

# ============================ no --only: byte-identical apart from the additive keys ============
# The files path is the one every existing test and every installed project already depends on.
PLAIN=$(S --digest --mode default)
check "an unscoped snapshot carries no scope block" "! printf '%s' \"\$PLAIN\" | jq -e 'has(\"scope\")' >/dev/null"
check "...and is not marked scopeApplied" "! printf '%s' \"\$PLAIN\" | jq -e '.scopeApplied == true' >/dev/null"
check "...and emits an empty inactive[] rather than omitting it" \
  "printf '%s' \"\$PLAIN\" | jq -e '(.inactive|type) == \"array\"' >/dev/null"
check "...with every pre-3.4.0 key intact" \
  "printf '%s' \"\$PLAIN\" | jq -e 'has(\"trunkRoot\") and has(\"counts\") and has(\"tasks\") and has(\"satisfiedDeps\") and has(\"worktrees\") and has(\"branchPrefix\")' >/dev/null"
# Everything except the additive keys must be EXACTLY what 3.3.1 emitted. Spelled out rather than
# compared to itself: this is the assertion that catches an accidental rename or drop in the shape
# every installed project and every other suite already reads.
EXPECTED_KEYS='branchPrefix,counts,countsOnly,detachedHead,digest,generatedAt,inProgressTimeoutHours,mode,satisfiedDeps,tasks,trunkBranch,trunkRoot,trunkSha,worktreeDir,worktrees'
check "removing the additive keys leaves exactly the 3.3.1 shape" \
  "[ \"\$(printf '%s' \"\$PLAIN\" | jq -Sr 'del(.relay,.inactive,.scope,.scopeApplied)|keys|join(\",\")')\" = \"\$EXPECTED_KEYS\" ]"

# ============================ counts are never narrowed =========================================
# The store-wide counts drive the unscoped completion test and the operator's report. Narrowing them
# would understate the board; the scoped view is the scheduler's business, not the counts'.
check "counts span the whole ACTIVE board even when scoped" \
  "[ \"\$(S --digest --only ui-021-login | jq -r '.counts.total')\" = \"\$(S --digest | jq -r '.counts.total')\" ]"
check "...and exclude draft/archive from the denominator" \
  "[ \"\$(S --digest | jq -r '.counts.total')\" = '6' ]"

# ============================ the capability is declared ========================================
CAPS=$(bash "$ACF_WHIP/adapters/files/acfw-store-files" capabilities)
check "the files adapter declares snapshot-only (so the dispatcher forwards --only to it)" \
  "printf '%s' \"\$CAPS\" | jq -e '.capabilities|index(\"snapshot-only\")' >/dev/null"

echo
echo "phase19-files-only: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
