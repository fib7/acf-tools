#!/usr/bin/env bash
# phase6-worktree-codeonly.test.sh — verifies the 2.4.1 fix: worktree/<slug> branches are CODE-ONLY.
#
# Root cause it guards against: clean-checkout used `merge --ff-only` (importing trunk's .backlog
# task-transition commits onto the branch) and integrate used a bare whole-branch `rebase` (replaying
# the stale merge-base..HEAD range), so a long-lived branch ballooned to hundreds of phantom commits
# and the integrate rebase produced spurious conflicts -> the accepted->rejected reject-loop.
#
# Asserts:
#   A  clean-checkout re-sync replays ONLY the branch's own code commits (no .backlog import), even
#      after trunk accrues new .backlog commits -> `git log trunk..branch -- .backlog/` stays EMPTY.
#   B  integrate folds exactly the branch's code commit (branch is 1 ahead, not 367) and stamps Integrated-At.
#   C  a contaminated branch (carries a .backlog/ commit) is REFUSED with exit 8 / "contaminated"; trunk unchanged.
#   D  the per-slug fork-base ref is created on worktree add and deleted on full reap.
# Run: bash acf-whip/tests/phase6-worktree-codeonly.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="$ACF_WHIP/skills/clean-checkout-before-task/bin/clean-checkout.sh"
INTEGRATE="$ACF_WHIP/skills/integrate-worktree/bin/integrate-worktree.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p6.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
printf '.worktree/\n' > .gitignore   # .worktree/ is ephemeral + gitignored, as in real repos
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk

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

# Simulate a trunk-side .backlog task-transition commit (the kind that used to leak into branches).
trunk_backlog_commit(){ # <name>
  echo "$1" > ".backlog/pending/$1.md"
  git add -A; git commit -qm "task: $1 pending -> in-progress"
}

echo "== Scenario A: clean-checkout re-sync keeps the branch CODE-ONLY =="
trunk_backlog_commit churn-1   # trunk .backlog history BEFORE the worktree forks
mktask in-progress bug-1 fix-a in-progress
git add -A; git commit -qm "add bug-1"

# First clean-checkout: lazy-creates the worktree + records the fork base.
bash "$CC" "$REPO/.backlog/in-progress/bug-1.md" >/dev/null 2>&1
WT="$REPO/.worktree/fix-a"
check "A0: worktree created on worktree/fix-a" "[ \"\$(git -C '$WT' branch --show-current 2>/dev/null)\" = worktree/fix-a ]"
check "D1: fork-base ref created on worktree add" "git -C '$REPO' rev-parse --verify -q refs/acfw/forkbase/fix-a >/dev/null"

# The specialist makes a CODE commit in the worktree.
echo "the fix" > "$WT/src-fix.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "fix: bug-1 code change"

# Trunk advances with MORE .backlog churn (other tasks transitioning while bug-1 is in flight).
trunk_backlog_commit churn-2
trunk_backlog_commit churn-3

# Re-entry: clean-checkout the SAME reused-slug task again -> must re-align code-only (rebase --onto),
# NEVER merge trunk's .backlog history in.
bash "$CC" "$REPO/.backlog/in-progress/bug-1.md" >/dev/null 2>&1
check "A1: NO .backlog commits on the branch (code-only)" "[ -z \"\$(git -C '$REPO' log --oneline trunk..worktree/fix-a -- .backlog/ 2>/dev/null)\" ]"
AHEAD=$(git -C "$REPO" rev-list --count trunk..worktree/fix-a 2>/dev/null || echo 99)
check "A2: branch is exactly 1 commit ahead of trunk (the code fix), not a phantom blow-up" "[ \"$AHEAD\" = 1 ]"
check "A3: branch re-based onto current trunk tip (merge-base == trunk HEAD)" \
  "[ \"\$(git -C '$REPO' merge-base trunk worktree/fix-a)\" = \"\$(git -C '$REPO' rev-parse trunk)\" ]"
check "A4: the code commit survived the re-align" "git -C '$WT' cat-file -e worktree/fix-a:src-fix.txt 2>/dev/null"

echo "== Scenario B: integrate folds exactly the code commit + stamps Integrated-At =="
# Move bug-1 to accepted/ (folder is source of truth); integrate from there.
mv .backlog/in-progress/bug-1.md .backlog/accepted/bug-1.md
git add -A; git commit -qm "accept bug-1"
TRUNK_BEFORE=$(git -C "$REPO" rev-parse trunk)
PRE_INTEG_AHEAD=$(git -C "$REPO" rev-list --count trunk..worktree/fix-a)
bash "$INTEGRATE" "$REPO/.backlog/accepted/bug-1.md" >/tmp/p6-integ.out 2>/dev/null; RC=$?
check "B1: integrate exits 0" "[ $RC -eq 0 ]"
check "B2: only the single code commit was ahead pre-integrate (no 367-commit blow-up)" "[ \"$PRE_INTEG_AHEAD\" = 1 ]"
check "B3: the code fix landed on trunk" "git -C '$REPO' cat-file -e trunk:src-fix.txt 2>/dev/null"
check "B4: Integrated-At stamped" "grep -qE '^- \*\*Integrated-At\*\*: [0-9a-f]{7,}' '$REPO/.backlog/accepted/bug-1.md'"
# Exactly two new commits on trunk: the FF'd code commit + the Integrated-At marker. Never hundreds.
NEW=$(git -C "$REPO" rev-list --count "$TRUNK_BEFORE"..trunk)
check "B5: trunk advanced by 2 commits (code fix + integrate marker), not a phantom range" "[ \"$NEW\" = 2 ]"
check "B6: worktree branch reaped (no more tasks share the slug)" "! git -C '$REPO' show-ref --verify --quiet refs/heads/worktree/fix-a"
check "D2: fork-base ref deleted on full reap" "! git -C '$REPO' rev-parse --verify -q refs/acfw/forkbase/fix-a >/dev/null"
rm -f /tmp/p6-integ.out

echo "== Scenario C: a contaminated branch is REFUSED (exit 8), trunk untouched =="
mktask accepted bug-2 fix-b accepted
git add -A; git commit -qm "add bug-2"
git -C "$REPO" worktree add -q "$REPO/.worktree/fix-b" -b worktree/fix-b trunk
WT2="$REPO/.worktree/fix-b"
# Poison the branch: a .backlog/ commit that is NOT on trunk (mimics a pre-2.4.1 imported transition).
echo poison > "$WT2/.backlog/pending/poison.md"; git -C "$WT2" add -A; git -C "$WT2" commit -qm "task: poison pending -> done"
echo "real fix" > "$WT2/src-fix-b.txt"; git -C "$WT2" add -A; git -C "$WT2" commit -qm "fix: bug-2 code"
TRUNK_BEFORE_C=$(git -C "$REPO" rev-parse trunk)
bash "$INTEGRATE" "$REPO/.backlog/accepted/bug-2.md" >/tmp/p6-cont.out 2>/dev/null; RC=$?
check "C1: integrate refuses with exit 8" "[ $RC -eq 8 ]"
check "C2: 'contaminated' block emitted on stdout" "grep -q 'ACFW-INTEGRATE: contaminated' /tmp/p6-cont.out"
check "C3: recovery hint emitted" "grep -q '^recovery:' /tmp/p6-cont.out"
check "C4: trunk HEAD unchanged (nothing folded)" "[ \"\$(git -C '$REPO' rev-parse trunk)\" = \"$TRUNK_BEFORE_C\" ]"
check "C5: task stays in accepted/ (not rejected)" "[ -f '$REPO/.backlog/accepted/bug-2.md' ] && [ ! -f '$REPO/.backlog/rejected/bug-2.md' ]"
rm -f /tmp/p6-cont.out

echo ""
echo "==================================================="
echo "Phase 6 worktree code-only test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
