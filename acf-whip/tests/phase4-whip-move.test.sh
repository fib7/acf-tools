#!/usr/bin/env bash
# phase4-whip-move.test.sh — verifies the BUG-6b operator command whip-move.sh:
#   - resolves a task by exact stem AND by unique prefix
#   - performs a validated state move via apply-transition.sh (Status synced, log row spliced, commit)
#   - --add-dep appends to Dependencies; --integrated-at sets Integrated-At; both land in the move commit
#   - in-place field edit (TO_STATE == current) commits without a move
#   - guards: ambiguous match, not-found, invalid state all exit 2 and do not mutate
# Run: bash acf-whip/tests/phase4-whip-move.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOVE="$ACF_WHIP/skills/whip-move/bin/whip-move.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p4move.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk

mktask(){ # <dir> <stem>
  cat > ".backlog/$1/$2.md" <<EOF
# Task: $2

- **ID**: $2
- **Status**: $1
- **Worktree**: none
- **Dependencies**: none
- **Rejection Count**: 0

## Transition Log

| Date | From | To | Agent | Notes |
|------|------|----|----|-------|
| 2026-06-01 00:00:00 | draft | pending | task-engineer | init |

## Notes
(none)
EOF
}
mktask pending test-041-promote
git add -A; git commit -qm task

# ---- move by exact stem, with --add-dep + --reason ----
bash "$MOVE" test-041-promote blocked --add-dep fixture-readiness --reason "needs fixture" >/dev/null
check "moved pending -> blocked (file relocated)" "[ -f .backlog/blocked/test-041-promote.md ] && [ ! -f .backlog/pending/test-041-promote.md ]"
check "Status synced to blocked" "grep -qE '^- \*\*Status\*\*: blocked' .backlog/blocked/test-041-promote.md"
check "dependency appended" "grep -qE '^- \*\*Dependencies\*\*: \[fixture-readiness\]' .backlog/blocked/test-041-promote.md"
check "transition row spliced into table" "grep -qE '\| blocked \| operator \| needs fixture \|' .backlog/blocked/test-041-promote.md"
check "move was committed (clean tree)" "[ -z \"\$(git status --porcelain)\" ]"

# ---- resolve by unique PREFIX, accepted + --integrated-at ----
bash "$MOVE" test-041 accepted --integrated-at a042d461 >/dev/null
check "prefix resolved + moved to accepted" "[ -f .backlog/accepted/test-041-promote.md ]"
check "Integrated-At set" "grep -qE '^- \*\*Integrated-At\*\*: a042d461' .backlog/accepted/test-041-promote.md"

# ---- idempotent: already accepted, no edits -> noop, no commit ----
BEFORE=$(git rev-parse HEAD)
bash "$MOVE" test-041-promote accepted >/dev/null
check "idempotent re-move makes no commit" "[ \"\$(git rev-parse HEAD)\" = \"$BEFORE\" ]"

# ---- in-place field edit (same state) commits without moving ----
bash "$MOVE" test-041-promote accepted --integrated-at 9f3c2aa9 >/dev/null
check "in-place Integrated-At updated" "grep -qE '^- \*\*Integrated-At\*\*: 9f3c2aa9' .backlog/accepted/test-041-promote.md"
check "in-place edit committed (clean tree)" "[ -z \"\$(git status --porcelain)\" ]"

# ---- guards ----
mktask pending dup-a; mktask pending dup-b; git add -A; git commit -qm dups
bash "$MOVE" dup accepted >/dev/null 2>&1; check "ambiguous match exits 2" "[ \$? -eq 2 ]"
check "ambiguous match did NOT move either file" "[ -f .backlog/pending/dup-a.md ] && [ -f .backlog/pending/dup-b.md ]"
bash "$MOVE" nope accepted >/dev/null 2>&1; check "not-found exits 2" "[ \$? -eq 2 ]"
bash "$MOVE" test-041-promote bogus >/dev/null 2>&1; check "invalid state exits 2" "[ \$? -eq 2 ]"

echo
echo "phase4-whip-move: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
