#!/usr/bin/env bash
# phase0-extraction.test.sh — verifies the extracted bin/*.sh behave correctly.
# Creates a throwaway git repo under $TMPDIR and exercises clean-checkout.sh,
# apply-transition.sh, and integrate-worktree.sh (FF / resolver-needed / post-resolver).
#
# Run: bash acf-whip/tests/phase0-extraction.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="$ACF_WHIP/skills/clean-checkout-before-task/bin/clean-checkout.sh"
IW="$ACF_WHIP/skills/integrate-worktree/bin/integrate-worktree.sh"
AT="$ACF_WHIP/skills/go/bin/apply-transition.sh"
LIB="$ACF_WHIP/skills/lib/acfw-git.sh"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p0.XXXXXX")
REPO="$WORK/repo"
trap 'rm -rf "$WORK"' EXIT

git init -q -b trunk "$REPO"
cd "$REPO"
git config user.email "test@acf.local"
git config user.name "ACF Test"
mkdir -p .backlog/{pending,in-progress,completed,in-review,accepted,rejected,blocked}
echo "seed" > seed.txt
git add seed.txt && git commit -q -m "seed"

export ACFW_TRUNK_ROOT="$REPO"
export ACFW_TRUNK_BRANCH="trunk"

mktask() { # <dir> <id> <slug> [extra]
  cat > ".backlog/$1/$2.md" <<EOF
# Task: $2

## Metadata

- **ID**: $2
- **Status**: $1
- **Assigned Agent**: go-engineer
- **Worktree**: $3
- **PR Group**: $3
- **Dependencies**: none
- **Integrated-At**:
- **Rejection Count**: 0

## Transition Log
EOF
  git add ".backlog/$1/$2.md" && git commit -q -m "seed task $2"
}

echo "== lib: per-invocation error file (footgun #2) =="
check "acfw-git.sh uses mktemp, not fixed /tmp/acfw-git-err" "grep -q 'mktemp' '$LIB' && ! grep -q '2>/tmp/acfw-git-err' '$LIB'"

echo "== clean-checkout.sh =="
mktask pending feat-001 alpha
OUT=$(bash "$CC" "$REPO/.backlog/pending/feat-001.md"); RC=$?
check "clean-checkout exit 0" "[ $RC -eq 0 ]"
check "worktree created" "[ -d '$REPO/.worktree/alpha' ]"
check "worktree on branch worktree/alpha" "[ \"\$(git -C '$REPO/.worktree/alpha' branch --show-current)\" = 'worktree/alpha' ]"
check "prints worktree path" "[ \"$OUT\" = '$REPO/.worktree/alpha' ]"
check "token agent field is literal clean-checkout-before-task (footgun #1)" \
  "grep -qE '\| clean-checkout \| ok \| clean-checkout-before-task \| alpha \| worktree/alpha \|' '$REPO/.backlog/pending/feat-001.md'"
check "token does NOT contain clean-checkout.sh" "! grep -q 'clean-checkout.sh' '$REPO/.backlog/pending/feat-001.md'"

echo "== clean-checkout.sh missing slug -> exit 1 =="
mktask pending feat-noslug ""
bash "$CC" "$REPO/.backlog/pending/feat-noslug.md" >/dev/null 2>&1; RC=$?
check "missing-slug exit 1" "[ $RC -eq 1 ]"

echo "== clean-checkout.sh branch-in-use -> exit 2 =="
# A second task with the SAME slug while the worktree dir is removed but branch exists.
git -C "$REPO" worktree remove --force "$REPO/.worktree/alpha" 2>/dev/null || true
mktask pending feat-002 alpha
bash "$CC" "$REPO/.backlog/pending/feat-002.md" >/dev/null 2>&1; RC=$?
# branch worktree/alpha still exists -> `git worktree add -b` fails -> exit 2
check "branch-in-use exit 2" "[ $RC -eq 2 ]"

echo "== apply-transition.sh + idempotency =="
bash "$AT" "$REPO/.backlog/pending/feat-002.md" in-progress orchestrator dispatch >/dev/null; RC=$?
check "transition exit 0" "[ $RC -eq 0 ]"
check "file moved to in-progress" "[ -f '$REPO/.backlog/in-progress/feat-002.md' ] && [ ! -f '$REPO/.backlog/pending/feat-002.md' ]"
check "transition log line appended" "grep -qE '\| pending \| in-progress \| orchestrator \| dispatch \|' '$REPO/.backlog/in-progress/feat-002.md'"
check "transition committed" "git -C '$REPO' log -1 --pretty=%s | grep -q 'feat-002.md pending -> in-progress'"
OUT=$(bash "$AT" "$REPO/.backlog/in-progress/feat-002.md" in-progress); RC=$?
check "idempotent no-op exit 0" "[ $RC -eq 0 ]"
check "idempotent reported noop" "echo \"$OUT\" | grep -q noop"

echo "== integrate-worktree.sh: fast-forward path =="
# Fresh slug 'ff'. Task already in accepted/; clean-checkout AFTER (so trunk does not
# advance past the worktree base), add a code commit, integrate -> clean FF.
mktask accepted feat-ff ff
bash "$CC" "$REPO/.backlog/accepted/feat-ff.md" >/dev/null
echo "ffcode" > "$REPO/.worktree/ff/ff.txt"
git -C "$REPO/.worktree/ff" add ff.txt && git -C "$REPO/.worktree/ff" commit -q -m "ff code"
SHA_BEFORE=$(git -C "$REPO" rev-parse HEAD)
bash "$IW" "$REPO/.backlog/accepted/feat-ff.md"; RC=$?
check "integrate FF exit 0" "[ $RC -eq 0 ]"
check "trunk advanced" "[ \"\$(git -C '$REPO' rev-parse HEAD)\" != '$SHA_BEFORE' ]"
check "Integrated-At written" "grep -qE '^- \*\*Integrated-At\*\*: [0-9a-f]{7,}' '$REPO/.backlog/accepted/feat-ff.md'"
check "ff.txt present on trunk" "[ -f '$REPO/ff.txt' ]"
check "worktree removed (no siblings)" "[ ! -d '$REPO/.worktree/ff' ]"

echo "== integrate-worktree.sh: no branch -> exit 4 (historical/pre-2.0.0) =="
# accepted task whose worktree/<slug> branch does NOT exist -> nothing to fold; terminal; caller
# must NOT retry (the workflow maps exit 4 -> outcome 'skipped'). Guards against a phantom-fetch loop.
mktask accepted feat-hist histslug
bash "$IW" "$REPO/.backlog/accepted/feat-hist.md" >/dev/null 2>&1; RC=$?
check "no-branch integrate exit 4" "[ $RC -eq 4 ]"
check "exit-4 leaves task in accepted/ (not rejected)" "[ -f '$REPO/.backlog/accepted/feat-hist.md' ]"
check "exit-4 writes no Integrated-At" "! grep -qE '^- \*\*Integrated-At\*\*: [0-9a-f]{7,}' '$REPO/.backlog/accepted/feat-hist.md'"

echo "== integrate-worktree.sh: resolver-needed (conflict) + post-resolver reject =="
mktask pending feat-cx cx
bash "$CC" "$REPO/.backlog/pending/feat-cx.md" >/dev/null
# worktree edits conflict.txt
echo "from-worktree" > "$REPO/.worktree/cx/conflict.txt"
git -C "$REPO/.worktree/cx" add conflict.txt && git -C "$REPO/.worktree/cx" commit -q -m "cx worktree edit"
# trunk advances with a conflicting edit to the same file
echo "from-trunk" > "$REPO/conflict.txt"
git -C "$REPO" add conflict.txt && git -C "$REPO" commit -q -m "trunk conflicting edit"
git -C "$REPO" mv ".backlog/pending/feat-cx.md" ".backlog/accepted/feat-cx.md" && git -C "$REPO" commit -q -m "accept feat-cx"
OUT=$(bash "$IW" "$REPO/.backlog/accepted/feat-cx.md" 2>/dev/null); RC=$?
check "conflict -> exit 7 (resolver-needed)" "[ $RC -eq 7 ]"
check "emits resolver-needed marker" "echo \"$OUT\" | grep -q 'ACFW-INTEGRATE: resolver-needed'"
check "emits worktree + conflicted file" "echo \"$OUT\" | grep -q 'conflict.txt'"
check "worktree left mid-cherry-pick" "git -C '$REPO/.worktree/cx' rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null"
# Simulate a resolver that gave up: call --post-resolver while still mid-cherry-pick -> reject.
bash "$IW" --post-resolver "$REPO/.backlog/accepted/feat-cx.md" >/dev/null 2>&1; RC=$?
check "post-resolver (gave up) -> exit 6" "[ $RC -eq 6 ]"
check "task moved to rejected/" "[ -f '$REPO/.backlog/rejected/feat-cx.md' ]"
check "Rejection Count incremented to 1" "grep -qE '^- \*\*Rejection Count\*\*: 1' '$REPO/.backlog/rejected/feat-cx.md'"

echo "== integrate-worktree.sh: post-resolver SUCCESS =="
mktask pending feat-ok ok
bash "$CC" "$REPO/.backlog/pending/feat-ok.md" >/dev/null
echo "from-worktree" > "$REPO/.worktree/ok/shared.txt"
git -C "$REPO/.worktree/ok" add shared.txt && git -C "$REPO/.worktree/ok" commit -q -m "ok worktree edit"
echo "from-trunk" > "$REPO/shared.txt"
git -C "$REPO" add shared.txt && git -C "$REPO" commit -q -m "trunk edit shared"
git -C "$REPO" mv ".backlog/pending/feat-ok.md" ".backlog/accepted/feat-ok.md" && git -C "$REPO" commit -q -m "accept feat-ok"
bash "$IW" "$REPO/.backlog/accepted/feat-ok.md" >/dev/null 2>&1; RC=$?
check "conflict again -> exit 7" "[ $RC -eq 7 ]"
# Resolve the conflict the way a resolver would, then continue the cherry-pick.
echo "resolved" > "$REPO/.worktree/ok/shared.txt"
git -C "$REPO/.worktree/ok" add shared.txt
GIT_EDITOR=true git -C "$REPO/.worktree/ok" cherry-pick --continue >/dev/null 2>&1
bash "$IW" --post-resolver "$REPO/.backlog/accepted/feat-ok.md" >/dev/null 2>&1; RC=$?
check "post-resolver success -> exit 0" "[ $RC -eq 0 ]"
check "Integrated-At written for feat-ok" "grep -qE '^- \*\*Integrated-At\*\*: [0-9a-f]{7,}' '$REPO/.backlog/accepted/feat-ok.md'"
check "resolved content on trunk" "grep -q resolved '$REPO/shared.txt'"

echo ""
echo "==================================================="
echo "Phase 0 extraction test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
