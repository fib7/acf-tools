#!/usr/bin/env bash
# phase0-extraction.test.sh — verifies the extracted bin/*.sh behave correctly.
# Creates a throwaway git repo under $TMPDIR and exercises the lib + clean-checkout.sh +
# apply-transition.sh primitives. (Integrator behavior is covered by phase8-lpcas-integrate
# and phase6-worktree-codeonly under the LP-CAS engine.)
#
# Run: bash acf-whip/tests/phase0-extraction.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="$ACF_WHIP/skills/clean-checkout-before-task/bin/clean-checkout.sh"
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

# NOTE (3.0.0): the integrator's behavior (FF/skip/resolver-needed/post-resolver, idempotency, poison,
# union gate, CAS-land) moved to the LP-CAS engine and is covered end-to-end by phase8-lpcas-integrate
# and phase6-worktree-codeonly (Scenario C). This file now scopes to the lib + clean-checkout + apply-
# transition primitives, which the scheduler-pure extraction and producer path depend on.

echo ""
echo "==================================================="
echo "Phase 0 extraction test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
