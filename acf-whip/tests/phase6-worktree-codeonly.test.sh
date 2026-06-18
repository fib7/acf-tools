#!/usr/bin/env bash
# phase6-worktree-codeonly.test.sh — verifies the LP-CAS (3.0.0) PRODUCER contract for clean-checkout.
#
# Root cause it guards against (the keystone, #1): clean-checkout USED to refresh a cached
# refs/acfw/trunk-snapshot via a non-force fetch whose exit status was discarded, then rebase/reset the
# branch onto it. On a rewritten trunk the fetch silently refused to advance, freezing every worktree's
# base ~1292 commits stale — cascading into false dep-blocks, phantom-conflict reject-loops, and the
# one-layer-per-run stall. LP-CAS DELETES that machinery: no snapshot, no rebase. The branch simply
# carries the specialist's code on top of its fork-base, and the integrator applies it onto the LIVE
# trunk at integration time. This test asserts the new, snapshot-free producer behavior.
#
# Asserts:
#   A  clean-checkout creates the worktree on worktree/<slug>, records the fork-base, and creates NO
#      trunk-snapshot ref (the keystone is gone by construction).
#   B  re-entry never imports trunk's .backlog history and never rebases/destroys the branch's code:
#      `git log trunk..branch -- .backlog/` stays EMPTY and the code commit SHA is stable across runs.
#   C  END-TO-END: after trunk is REWRITTEN/advanced far past the fork point, the LP-CAS integrator
#      still lands the branch's code onto the LIVE trunk (cherry-pick of the single-parent candidate),
#      co-commits the in-tree ledger marker, and the change is reachable from trunk — proving the
#      stale-base cascade cannot occur in the real producer→integrator pipeline.
#   E  a legacy worktree with NO fork-base ref is BACKFILLED (merge-base) without any rebase/heal,
#      and its code is preserved untouched.
# Run: bash acf-whip/tests/phase6-worktree-codeonly.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="$ACF_WHIP/skills/clean-checkout-before-task/bin/clean-checkout.sh"
INTEGRATE="$ACF_WHIP/skills/integrate-lpcas/bin/integrate-lpcas.sh"

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

echo "== Scenario A: clean-checkout creates a code-only producer, no trunk-snapshot (keystone gone) =="
trunk_backlog_commit churn-1   # trunk .backlog history BEFORE the worktree forks
mktask in-progress bug-1 fix-a in-progress
git add -A; git commit -qm "add bug-1"

bash "$CC" "$REPO/.backlog/in-progress/bug-1.md" >/dev/null 2>&1
WT="$REPO/.worktree/fix-a"
check "A0: worktree created on worktree/fix-a" "[ \"\$(git -C '$WT' branch --show-current 2>/dev/null)\" = worktree/fix-a ]"
check "A1: fork-base ref created on worktree add" "git -C '$REPO' rev-parse --verify -q refs/acfw/forkbase/fix-a >/dev/null"
check "A2: NO trunk-snapshot ref created (the keystone defect is gone by construction)" \
  "! git -C '$REPO' rev-parse --verify -q refs/acfw/trunk-snapshot >/dev/null"

echo "== Scenario B: re-entry never imports .backlog and never rebases/destroys the code =="
echo "the fix" > "$WT/src-fix.txt"; git -C "$WT" add -A; git -C "$WT" commit -qm "fix: bug-1 code change"
CODE_SHA=$(git -C "$REPO" rev-parse worktree/fix-a)
# Trunk advances with MORE .backlog churn (other tasks transitioning while bug-1 is in flight).
trunk_backlog_commit churn-2
trunk_backlog_commit churn-3
# Re-entry: clean-checkout the SAME reused-slug task again.
bash "$CC" "$REPO/.backlog/in-progress/bug-1.md" >/dev/null 2>&1
check "B1: NO .backlog commits on the branch (code-only by construction)" \
  "[ -z \"\$(git -C '$REPO' log --oneline trunk..worktree/fix-a -- .backlog/ 2>/dev/null)\" ]"
check "B2: re-entry did NOT rebase/move the branch (code commit SHA stable)" \
  "[ \"\$(git -C '$REPO' rev-parse worktree/fix-a)\" = \"$CODE_SHA\" ]"
check "B3: the code commit survived re-entry" "git -C '$WT' cat-file -e worktree/fix-a:src-fix.txt 2>/dev/null"
check "B4: still NO trunk-snapshot ref after re-entry" \
  "! git -C '$REPO' rev-parse --verify -q refs/acfw/trunk-snapshot >/dev/null"

echo "== Scenario C: END-TO-END producer -> LP-CAS integrator lands code onto the LIVE (advanced) trunk =="
# Move bug-1 to accepted/ (folder is source of truth); integrate from there.
mv .backlog/in-progress/bug-1.md .backlog/accepted/bug-1.md
git add -A; git commit -qm "accept bug-1"
# Advance trunk yet again AFTER acceptance — the branch's fork-base is now far behind the live tip.
trunk_backlog_commit churn-4
TRUNK_BEFORE=$(git -C "$REPO" rev-parse trunk)
bash "$INTEGRATE" "$REPO/.backlog/accepted/bug-1.md" >"$WORK/c.out" 2>&1; RC=$?
check "C1: integrate exits 0 (integrated)" "[ $RC -eq 0 ]"
check "C2: ACFW-INTEGRATE integrated verdict emitted" "grep -q 'ACFW-INTEGRATE: integrated' '$WORK/c.out'"
check "C3: the code fix landed on the LIVE trunk (no stale base)" "git -C '$REPO' cat-file -e trunk:src-fix.txt 2>/dev/null"
check "C4: the in-tree ledger marker is reachable from trunk (integration oracle)" \
  ". '$ACF_WHIP/skills/lib/acfw-git.sh'; acfw_is_integrated '$REPO' trunk bug-1"
check "C5: trunk advanced by exactly ONE commit (code + marker co-committed, no phantom range)" \
  "[ \"\$(git -C '$REPO' rev-list --count $TRUNK_BEFORE..trunk)\" = 1 ]"
check "C6: a candidate ref was published from the branch (deterministic producer)" \
  "git -C '$REPO' rev-parse --verify -q refs/acfw/patch/bug-1 >/dev/null"

echo "== Scenario E: clean-checkout BACKFILLS a legacy no-forkbase branch (no rebase/heal) =="
mktask in-progress bug-5 fix-e in-progress
git add -A; git commit -qm "add bug-5"
git -C "$REPO" worktree add -q "$REPO/.worktree/fix-e" -b worktree/fix-e trunk
WT5="$REPO/.worktree/fix-e"
echo "code-e" > "$WT5/code-e.txt"; git -C "$WT5" add -A; git -C "$WT5" commit -qm "feat: bug-5 code"
E_SHA=$(git -C "$REPO" rev-parse worktree/fix-e)
git -C "$REPO" update-ref -d refs/acfw/forkbase/fix-e 2>/dev/null || true   # ensure legacy (no base)
trunk_backlog_commit churn-e1; trunk_backlog_commit churn-e2   # trunk advances
bash "$CC" "$REPO/.backlog/in-progress/bug-5.md" >/dev/null 2>&1
check "E1: fork-base ref backfilled for the legacy branch" "git -C '$REPO' rev-parse --verify -q refs/acfw/forkbase/fix-e >/dev/null"
check "E2: the code commit was NOT rebased/destroyed (SHA stable)" "[ \"\$(git -C '$REPO' rev-parse worktree/fix-e)\" = \"$E_SHA\" ]"
check "E3: the code commit survived" "git -C '$WT5' cat-file -e worktree/fix-e:code-e.txt 2>/dev/null"

echo ""
echo "==================================================="
echo "Phase 6 worktree code-only test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
