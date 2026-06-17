#!/usr/bin/env bash
# phase7-patchid-integration.test.sh — verifies the 2.5.0 patch-id-aware integration engine.
#
# Root cause it guards against: on long-lived repos, worktree/<slug> branches born before 2.4.1
# (no forkbase ref) fell back to a far-back merge-base, so integrate replayed ~1000 phantom commits
# and produced spurious conflicts -> the accepted->rejected reject-loop; and accepted-but-unintegrated
# work whose equivalent code was already on trunk (by patch-id) never registered terminal, stalling
# /go on "needs operator". A botched/aborted integration could also destroy the branch's code.
#
# Asserts:
#   E  patch-id SHORT-CIRCUIT: a branch whose code is already on trunk by patch-id integrates with
#      exit 0 (no rebase, no conflict), stamps Integrated-At, and does NOT re-apply the code.
#   F  LEGACY far-back branch (no forkbase ref, 1 real code commit + N .backlog phantom commits, base
#      far behind trunk) reduces to its ONE real commit: exit 0, code on trunk, NO phantom .backlog
#      file on trunk, trunk advances by exactly 2 (code + marker).
#   G  SAFETY: a real cherry-pick conflict records refs/acfw/preintegrate/<slug> (the pre-integration
#      tip); a resolver FAILURE restores the branch from it (code survives, never destroyed), rejects
#      cleanly (exit 6), and deletes the backup ref.
# Run: bash acf-whip/tests/phase7-patchid-integration.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTEGRATE="$ACF_WHIP/skills/integrate-worktree/bin/integrate-worktree.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p7.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
printf '.worktree/\n' > .gitignore
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk

mktask(){ # <dir> <stem> <slug>
  cat > ".backlog/$1/$2.md" <<EOF
# Task: $2

## Metadata

- **ID**: $2
- **Status**: $1
- **Assigned Agent**: go-engineer
- **Worktree**: $3
- **Rejection Count**: 0

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-06-01 00:00:00 | draft | pending | task-engineer | Initial task creation |
EOF
}
# A legacy worktree branch: created directly with `git worktree add` (NO forkbase ref), as a
# pre-2.4.1 branch would be.
legacy_worktree(){ # <slug>
  git -C "$REPO" worktree add -q "$REPO/.worktree/$1" -b "worktree/$1" trunk
}

echo "== Scenario E: patch-id short-circuit (code already on trunk) =="
mktask accepted bug-e fix-e
git add -A; git commit -qm "add bug-e"
legacy_worktree fix-e
WTE="$REPO/.worktree/fix-e"
echo "content-e" > "$WTE/ee.txt"; git -C "$WTE" add -A; git -C "$WTE" commit -qm "feat: bug-e add ee.txt"
# The SAME change lands on trunk independently (the code is effectively already integrated).
echo "content-e" > "$REPO/ee.txt"; git add -A; git commit -qm "trunk: ee.txt arrives by another path"
TRUNK_BEFORE_E=$(git rev-parse trunk)
bash "$INTEGRATE" "$REPO/.backlog/accepted/bug-e.md" >"$WORK/e.out" 2>&1; RC=$?
check "E1: integrate exits 0 (short-circuit)" "[ $RC -eq 0 ]"
check "E2: 'already-integrated' emitted (no rebase ran)" "grep -q 'ACFW-INTEGRATE: already-integrated' '$WORK/e.out'"
check "E3: Integrated-At stamped" "grep -qE '^- \*\*Integrated-At\*\*: [0-9a-f]{7,}' '$REPO/.backlog/accepted/bug-e.md'"
check "E4: trunk advanced by exactly 1 (only the Integrated-At marker, code NOT re-applied)" \
  "[ \"\$(git rev-list --count $TRUNK_BEFORE_E..trunk)\" = 1 ]"
check "E5: task stays accepted (not rejected)" "[ -f '$REPO/.backlog/accepted/bug-e.md' ] && [ ! -f '$REPO/.backlog/rejected/bug-e.md' ]"

echo "== Scenario F: legacy far-back branch with N phantom .backlog commits reduces to 1 real commit =="
mktask accepted bug-f fix-f
git add -A; git commit -qm "add bug-f"
legacy_worktree fix-f
WTF="$REPO/.worktree/fix-f"
mkdir -p "$WTF/.backlog/pending"
# Interleave phantom .backlog commits around the ONE real code commit.
for n in 1 2 3; do echo "p$n" > "$WTF/.backlog/pending/phantom-$n.md"; git -C "$WTF" add -A; git -C "$WTF" commit -qm "task: phantom-$n pending -> in-progress"; done
echo "real-f" > "$WTF/code-f.txt"; git -C "$WTF" add -A; git -C "$WTF" commit -qm "feat: bug-f the only real code"
for n in 4 5; do echo "p$n" > "$WTF/.backlog/pending/phantom-$n.md"; git -C "$WTF" add -A; git -C "$WTF" commit -qm "task: phantom-$n pending -> in-progress"; done
# Advance trunk far ahead so the branch's base is far behind (the field shape).
for n in 1 2 3 4 5 6; do echo "adv$n" > "trunk-adv-$n.txt"; git add -A; git commit -qm "trunk advance $n"; done
NPHANTOM=$(git log --oneline trunk..worktree/fix-f -- .backlog/ | wc -l | tr -d ' ')
check "F0: branch really carries phantom .backlog commits pre-integrate" "[ \"$NPHANTOM\" -ge 5 ]"
check "F0b: NO forkbase ref (legacy branch)" "! git rev-parse --verify -q refs/acfw/forkbase/fix-f >/dev/null"
TRUNK_BEFORE_F=$(git rev-parse trunk)
bash "$INTEGRATE" "$REPO/.backlog/accepted/bug-f.md" >"$WORK/f.out" 2>&1; RC=$?
check "F1: integrate exits 0 (salvaged, not rejected)" "[ $RC -eq 0 ]"
check "F2: the one real code file landed on trunk" "git cat-file -e trunk:code-f.txt 2>/dev/null"
check "F3: NO phantom .backlog file leaked onto trunk" "! git cat-file -e trunk:.backlog/pending/phantom-1.md 2>/dev/null"
check "F4: trunk advanced by exactly 2 (code + Integrated-At marker), not the phantom range" \
  "[ \"\$(git rev-list --count $TRUNK_BEFORE_F..trunk)\" = 2 ]"
check "F5: Integrated-At stamped" "grep -qE '^- \*\*Integrated-At\*\*: [0-9a-f]{7,}' '$REPO/.backlog/accepted/bug-f.md'"
check "F6: task not rejected" "[ ! -f '$REPO/.backlog/rejected/bug-f.md' ]"

echo "== Scenario G: conflict -> backup ref; resolver failure restores the code (never destroyed) =="
mktask accepted bug-g fix-g
git add -A; git commit -qm "add bug-g"
legacy_worktree fix-g
WTG="$REPO/.worktree/fix-g"
echo "branch version" > "$WTG/shared.txt"; git -C "$WTG" add -A; git -C "$WTG" commit -qm "feat: bug-g shared.txt"
BRANCH_TIP_G=$(git -C "$WTG" rev-parse worktree/fix-g)
# Trunk adds the SAME file with DIFFERENT content -> add/add conflict on replay.
echo "trunk version" > "$REPO/shared.txt"; git add -A; git commit -qm "trunk: shared.txt different"
bash "$INTEGRATE" "$REPO/.backlog/accepted/bug-g.md" >"$WORK/g1.out" 2>&1; RC=$?
check "G1: conflict -> exit 7 (resolver-needed)" "[ $RC -eq 7 ]"
check "G2: backup ref refs/acfw/preintegrate/fix-g created = pre-integration tip" \
  "[ \"\$(git rev-parse -q --verify refs/acfw/preintegrate/fix-g)\" = \"$BRANCH_TIP_G\" ]"
check "G3: the branch's code is reachable via the backup ref" \
  "[ \"\$(git show refs/acfw/preintegrate/fix-g:shared.txt 2>/dev/null)\" = 'branch version' ]"
check "G4: worktree left mid-cherry-pick" "git -C '$WTG' rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null"
# Simulate a resolver that FAILS: do nothing (leave the conflict), then re-invoke --post-resolver.
bash "$INTEGRATE" --post-resolver "$REPO/.backlog/accepted/bug-g.md" >"$WORK/g2.out" 2>&1; RC=$?
check "G5: resolver failure -> exit 6 (rejected)" "[ $RC -eq 6 ]"
check "G6: task moved to rejected/ (not accepted)" "[ -f '$REPO/.backlog/rejected/bug-g.md' ] && [ ! -f '$REPO/.backlog/accepted/bug-g.md' ]"
check "G7: branch RESTORED to pre-integration tip — code SURVIVED (not destroyed by reset)" \
  "[ \"\$(git -C '$WTG' show worktree/fix-g:shared.txt 2>/dev/null)\" = 'branch version' ]"
check "G8: backup ref deleted after restore" "! git rev-parse -q --verify refs/acfw/preintegrate/fix-g >/dev/null"
check "G9: rejection count incremented" "grep -qE '^- \*\*Rejection Count\*\*: 1' '$REPO/.backlog/rejected/bug-g.md'"

echo ""
echo "==================================================="
echo "Phase 7 patch-id integration test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
