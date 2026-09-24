#!/usr/bin/env bash
# pre-push.test.sh — the attribution gate must reject what it claims to reject.
#
# This hook is the only client-side check that survives cherry-pick, rebase replay and --no-verify,
# and it had no tests until it was changed. A gate nobody exercises is a gate nobody can safely edit:
# the failure mode is silent (it stops rejecting) and nothing downstream notices.
#
# Four properties, each in a throwaway repo with a real remote:
#   1. a NEW offending commit on an EXISTING branch is rejected
#   2. a NEW offending commit on a NEW branch is rejected
#   3. a commit ALREADY PUBLISHED on that remote, arriving via a merge, is allowed
#   4. a range that cannot be computed REFUSES rather than silently inspecting nothing
#
# (3) is the one worth explaining. The policy is that this clone does not INTRODUCE AI-attributed
# commits. A commit already on the remote is not being introduced by us, and rejecting it makes any
# fork sync or upstream merge permanently unpushable while the commit sits there either way. The
# new-branch case always had this scope (`--not --remotes=<remote>`); the existing-branch case did
# not, and that asymmetry was a range bug, not a stricter policy.
#
# Run: bash .githooks/pre-push.test.sh
set -u
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TRAILER='Co-authored-by: Claude <noreply@anthropic.com>'
SESSION='Claude-Session: https://claude.ai/chat/x'

newrepo(){ # -> prints the work dir; $1 is a scratch root
  git init -q --bare "$1/remote.git"
  git init -q -b main "$1/work"
  git -C "$1/work" config user.email t@t
  git -C "$1/work" config user.name t
  git -C "$1/work" config core.hooksPath "$HOOKS"
  git -C "$1/work" remote add origin "$1/remote.git"
  ( cd "$1/work" && echo seed > seed && git add -A && git commit -qm "chore: base" && git push -q origin main ) 2>/dev/null
  printf '%s/work' "$1"
}

W=$(mktemp -d "${TMPDIR:-/tmp}/prepush-test.XXXXXX"); trap 'rm -rf "$W"' EXIT

# ---- 1. new offending commit, existing branch ------------------------------------------------
R=$(newrepo "$W/t1"); cd "$R"
echo x > x; git add -A; git commit -q --no-verify -m "feat: thing

$TRAILER"
if git push origin main 2>&1 | grep -q 'REJECTED'; then ok "a new attributed commit is rejected on an existing branch"
else bad "a new attributed commit was ALLOWED on an existing branch"; fi

# ---- 2. new offending commit, new branch -----------------------------------------------------
R=$(newrepo "$W/t2"); cd "$R"
git checkout -q -b feature
echo y > y; git add -A; git commit -q --no-verify -m "feat: other

$SESSION"
if git push origin feature 2>&1 | grep -q 'REJECTED'; then ok "a new attributed commit is rejected on a new branch"
else bad "a new attributed commit was ALLOWED on a new branch"; fi

# ---- 3. already-published commit arriving via a merge ----------------------------------------
R=$(newrepo "$W/t3"); cd "$R"
git checkout -q -b theirs
echo d > d; git add -A; git commit -q --no-verify -m "chore: their history

$TRAILER"
git push -q --no-verify origin theirs 2>/dev/null   # simulate: it is already on the remote
git checkout -q main
echo e > e; git add -A; git commit -qm "feat: our clean work"
git push -q origin main 2>/dev/null
git merge -q --no-edit -m "chore: sync with theirs" theirs 2>/dev/null
if git push origin main 2>&1 | grep -q 'REJECTED'; then bad "merging history already on the remote was rejected"
else ok "a commit already published on that remote is not re-litigated"; fi

# ...and the same merge must still reject an offending commit that is NOT yet on the remote.
R=$(newrepo "$W/t4"); cd "$R"
git checkout -q -b local-only
echo f > f; git add -A; git commit -q --no-verify -m "chore: never pushed

$TRAILER"
git checkout -q main
git merge -q --no-edit -m "chore: merge local-only" local-only 2>/dev/null
if git push origin main 2>&1 | grep -q 'REJECTED'; then ok "an UNpublished attributed commit is still rejected through a merge"
else bad "an unpublished attributed commit rode in through a merge"; fi

# ---- 4. an uncomputable range must refuse -----------------------------------------------------
R=$(newrepo "$W/t5"); cd "$R"
OUT=$(printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
      | git hook run --to-stdin /dev/stdin pre-push -- origin "$W/t5/remote.git" 2>&1 || true)
if printf '%s' "$OUT" | grep -q 'REFUSED'; then ok "a range that cannot be computed refuses instead of inspecting nothing"
else bad "an uncomputable range silently passed the gate"; fi

echo
echo "pre-push gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
