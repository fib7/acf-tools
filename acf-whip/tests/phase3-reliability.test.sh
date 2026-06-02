#!/usr/bin/env bash
# phase3-reliability.test.sh — verifies the 2.1.0 reliability fixes that live in the shell layer:
#   I4  apply-transition.sh syncs "- **Status**:" to the destination folder (no self-inflicted FATAL)
#   I2  apply-transition.sh increments "- **Block-Count**:" on a flagged specialist re-block
#   I3  append_log_row splices rows INTO the "## Transition Log" table and caps the body length
#   I5B integrate-worktree.sh treats a branch with no commits ahead of trunk as terminal (no retry loop)
# Run: bash acf-whip/tests/phase3-reliability.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="$ACF_WHIP/skills/go/bin/apply-transition.sh"
INTEGRATE="$ACF_WHIP/skills/integrate-worktree/bin/integrate-worktree.sh"
LIB="$ACF_WHIP/skills/lib/acfw-git.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p3.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk

# Minimal task file mirroring the template's load-bearing lines (Status, Rejection Count, the
# Transition Log table, and a section AFTER it so we can prove rows splice in, not dangle at EOF).
mktask(){ # <dir> <stem> <slug> <status>
  cat > ".backlog/$1/$2.md" <<EOF
# Task: $2

## Metadata

- **ID**: $2
- **Status**: $4
- **Assigned Agent**: go-engineer
- **Worktree**: $3
- **Rejection Count**: 0

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-06-01 00:00:00 | draft | pending | task-engineer | Initial task creation |

## Implementation Notes

(none)
EOF
}

echo "== I4: apply-transition syncs Status to the destination folder =="
mktask pending t-move slugm pending
git add -A; git commit -qm t-move
bash "$APPLY" "$REPO/.backlog/pending/t-move.md" in-progress orchestrator "dispatch" 0 0 >/dev/null
check "file moved to in-progress/" "[ -f '$REPO/.backlog/in-progress/t-move.md' ] && [ ! -f '$REPO/.backlog/pending/t-move.md' ]"
check "I4: Status rewritten to in-progress" "grep -qE '^- \*\*Status\*\*: in-progress\$' '$REPO/.backlog/in-progress/t-move.md'"
check "I4: no stale 'Status: pending' left" "! grep -qE '^- \*\*Status\*\*: pending\$' '$REPO/.backlog/in-progress/t-move.md'"

echo "== I3: the transition row splices INTO the Transition Log, not after the last heading =="
# The new row must appear BEFORE the '## Implementation Notes' heading (i.e. inside the table section).
ROW_LINE=$(grep -n '| pending | in-progress | orchestrator | dispatch |' "$REPO/.backlog/in-progress/t-move.md" | head -1 | cut -d: -f1)
IMPL_LINE=$(grep -n '^## Implementation Notes' "$REPO/.backlog/in-progress/t-move.md" | head -1 | cut -d: -f1)
check "I3: row is present" "[ -n \"$ROW_LINE\" ]"
check "I3: row sits inside the Transition Log section (before Implementation Notes)" "[ -n \"$ROW_LINE\" ] && [ -n \"$IMPL_LINE\" ] && [ \"$ROW_LINE\" -lt \"$IMPL_LINE\" ]"
check "I3: file still ends with the Implementation Notes section (no dangling rows at EOF)" "tail -3 '$REPO/.backlog/in-progress/t-move.md' | grep -q 'none'"

echo "== I2: apply-transition bumps Block-Count only with the BLOCK_INCREMENT flag =="
# specialist re-block (flag=1): in-progress -> blocked, Block-Count 0 -> 1 (field inserted, pre-2.1.0 task)
bash "$APPLY" "$REPO/.backlog/in-progress/t-move.md" blocked go-engineer "needs missing dep" 0 1 >/dev/null
check "I2: Block-Count inserted + set to 1 on flagged block" "grep -qE '^- \*\*Block-Count\*\*: 1\$' '$REPO/.backlog/blocked/t-move.md'"
# unblock then re-block again -> 2
bash "$APPLY" "$REPO/.backlog/blocked/t-move.md" pending orchestrator "unblocked" 0 0 >/dev/null
bash "$APPLY" "$REPO/.backlog/pending/t-move.md" in-progress orchestrator "dispatch" 0 0 >/dev/null
bash "$APPLY" "$REPO/.backlog/in-progress/t-move.md" blocked go-engineer "still blocked" 0 1 >/dev/null
check "I2: Block-Count increments to 2 on second flagged block" "grep -qE '^- \*\*Block-Count\*\*: 2\$' '$REPO/.backlog/blocked/t-move.md'"
# a timeout/redesign block (flag=0) must NOT bump the counter
bash "$APPLY" "$REPO/.backlog/blocked/t-move.md" pending orchestrator "unblocked" 0 0 >/dev/null
bash "$APPLY" "$REPO/.backlog/pending/t-move.md" blocked orchestrator "timeout — stale dispatch" 0 0 >/dev/null
check "I2: unflagged block does NOT bump Block-Count (stays 2)" "grep -qE '^- \*\*Block-Count\*\*: 2\$' '$REPO/.backlog/blocked/t-move.md'"

echo "== I3: append_log_row caps the Transition Log body length =="
# shellcheck disable=SC1090
. "$LIB"
CAPFILE="$WORK/capped.md"
cat > "$CAPFILE" <<EOF
# Task: cap

## Transition Log

| Date Time | From | To | Agent | Reason |
| --------- | ---- | -- | ----- | ------ |

## End
EOF
ACFW_LOG_ROW_CAP=10
i=1; while [ $i -le 40 ]; do append_log_row "$CAPFILE" "| row $i | a | b | c | d |"; i=$((i+1)); done
NROWS=$(grep -cE '^\| row [0-9]+ \|' "$CAPFILE")
check "I3: body capped to <= cap rows (10), not 40" "[ \"$NROWS\" -le 10 ]"
check "I3: newest row retained (row 40)" "grep -qE '^\| row 40 \|' '$CAPFILE'"
check "I3: oldest row dropped (row 1)" "! grep -qE '^\| row 1 \|' '$CAPFILE'"
check "I3: '## End' section survives the rewrite" "grep -q '^## End' '$CAPFILE'"
# no Transition Log table -> append at EOF (never lose a row)
NOLOG="$WORK/nolog.md"; printf '# Task\n\nnotes only\n' > "$NOLOG"
append_log_row "$NOLOG" "| x | y | z |"
check "I3: falls back to EOF append when no table exists" "grep -qE '^\| x \| y \| z \|' '$NOLOG'"

echo "== I5B: integrate-worktree treats a branch with no commits ahead of trunk as terminal =="
mktask accepted gate-201-review emptyslug accepted
git add -A; git commit -qm gate-task
# create the worktree branch from trunk with NO further commits (a gate/verification task did no code)
git -C "$REPO" worktree add -q "$REPO/.worktree/emptyslug" -b worktree/emptyslug trunk 2>/dev/null
bash "$INTEGRATE" "$REPO/.backlog/accepted/gate-201-review.md" >/tmp/p3-integ.out 2>/dev/null; RC=$?
check "I5B: exit 0 (terminal, not an exit-10 retry loop)" "[ $RC -eq 0 ]"
check "I5B: empty-branch message emitted" "grep -q 'empty-branch' /tmp/p3-integ.out"
check "I5B: Integrated-At written -> counts terminal" "grep -qE '^- \*\*Integrated-At\*\*: [0-9a-f]{7,}' '$REPO/.backlog/accepted/gate-201-review.md'"
check "I5B: empty worktree branch reaped" "! git -C '$REPO' show-ref --verify --quiet refs/heads/worktree/emptyslug"
rm -f /tmp/p3-integ.out

echo ""
echo "==================================================="
echo "Phase 3 reliability test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
