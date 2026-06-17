#!/usr/bin/env bash
# clean-checkout.sh — concurrency primitive for ACF specialist agents.
#
# Usage: clean-checkout.sh <TASK_FILE>
#   TASK_FILE: absolute path to the task markdown (in .backlog/pending/ or in-progress/).
#
# Resolves the task's Worktree slug, lazy-creates an isolated git worktree on
# worktree/<slug>, validates the branch, re-aligns the branch's own commits onto local trunk
# (code-only, never importing .backlog history), stashes unrelated changes, logs the
# clean-checkout OK token, and prints the worktree path.
# The lock is git itself: `git worktree add -b <branch>` fails when the branch is
# already checked out elsewhere — that failure is the mutual-exclusion primitive.
#
# Exit codes (all fatal to the caller unless noted):
#   0  success (worktree path printed on stdout)
#   1  Worktree: field missing on a code-touching task
#   2  branch in use elsewhere (lock held by another agent — defer, try another task)
#   3  worktree exists but on the wrong branch (manual intervention)
#   5  trunk branch not resolvable (detached HEAD)
#  99  lock contention persisted past backoff (transient; retry next iteration)

set -u

# Hard-coded agent field for the transition-log token. MUST be the literal
# "clean-checkout-before-task" — NOT $(basename "$0"), which would become
# "clean-checkout.sh" and drift the documented token format that quality-reviewer
# and greppers rely on.
ACFW_AGENT_FIELD="clean-checkout-before-task"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

# ---- Step 1: Resolve slug from task front-matter ----
TASK_FILE="${1:-}"
if [ -z "$TASK_FILE" ]; then
  echo "FATAL: clean-checkout.sh requires a TASK_FILE argument." >&2
  exit 1
fi
SLUG=$(grep -E '^- \*\*Worktree\*\*:' "$TASK_FILE" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')

if [ -z "$SLUG" ]; then
  echo "FATAL: task $TASK_FILE has no Worktree: field. Run '/whip-doctor --fix' to derive and backfill the slug (or have task-engineer set it)." >&2
  exit 1
fi

# ---- Step 2: Derive paths and resolve trunk ----
REPO_ROOT="${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}"
TRUNK_BRANCH="${ACFW_TRUNK_BRANCH:-$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null)}"
acfw_load_namespace "$REPO_ROOT"   # sets ACFW_WORKTREE_DIR / ACFW_BRANCH_PREFIX
WORKTREE_PATH="$REPO_ROOT/$ACFW_WORKTREE_DIR/$SLUG"
BRANCH="$ACFW_BRANCH_PREFIX/$SLUG"

if [ -z "$TRUNK_BRANCH" ]; then
  echo "FATAL: cannot resolve trunk branch (HEAD detached?). Refuse to create worktree." >&2
  exit 5
fi

# ---- Step 3: Lazy-create the worktree ----
WORKTREE_WAS_CREATED=0
if [ ! -d "$WORKTREE_PATH" ]; then
  if ! git_with_lock_backoff -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$BRANCH" "$TRUNK_BRANCH" >&2; then
    rc=$?
    [ $rc -eq 99 ] && exit 99
    echo "FATAL: cannot create worktree for $SLUG. Likely another agent owns branch $BRANCH." >&2
    exit 2
  fi
  WORKTREE_WAS_CREATED=1
  # Record the fork base: the branch's code commits sit on top of this trunk SHA. Both the
  # code-only re-sync (Step 5) and integrate-worktree replay ONLY base..HEAD, never merging trunk's
  # .backlog history into the branch — so the branch stays code-only by construction.
  git -C "$REPO_ROOT" update-ref "refs/acfw/forkbase/$SLUG" "$(git -C "$REPO_ROOT" rev-parse "$TRUNK_BRANCH")" 2>/dev/null || true
fi

# ---- Step 3.5: Worktree env hydration (.worktreeinclude) ----
# Inserted in Phase 1. Honors $REPO_ROOT/.worktreeinclude to copy/symlink untracked
# files (e.g. .env, node_modules) into a freshly created worktree so it can run a full
# dev sandbox. Idempotent; no-op when the manifest is absent. Placeholder for now.
if [ "$WORKTREE_WAS_CREATED" = "1" ] && [ -f "$SCRIPT_DIR/hydrate-worktree.sh" ] && [ -f "$REPO_ROOT/.worktreeinclude" ]; then
  bash "$SCRIPT_DIR/hydrate-worktree.sh" "$REPO_ROOT" "$WORKTREE_PATH" "$TASK_FILE" || \
    echo "WARN: worktree hydration reported a problem for $SLUG; continuing." >&2
fi

# ---- Step 4: Validate branch in the worktree ----
ACTUAL_BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current)
if [ "$ACTUAL_BRANCH" != "$BRANCH" ]; then
  echo "FATAL: worktree $WORKTREE_PATH is on $ACTUAL_BRANCH, expected $BRANCH." >&2
  echo "Resolve manually before continuing. Do not auto-checkout." >&2
  exit 3
fi

# ---- Step 5: Re-align the slug branch onto current trunk — CODE-ONLY ----
# NEVER merge trunk's .backlog history into the branch (the historical `merge --ff-only` did exactly
# that whenever the branch had no code commit yet, then drifted on a stale base once it did — the
# root cause of the integrate reject-loop). Instead replay ONLY the branch's own commits (base..HEAD)
# onto a fresh trunk snapshot via `rebase --onto`, so the branch is code-only by construction. On any
# conflict (or a dirty tree) abort and leave the branch on its existing code-only state; integrate-
# worktree rebases + resolves at integration time.
BASE_REF="refs/acfw/forkbase/$SLUG"
git_with_lock_backoff -C "$WORKTREE_PATH" fetch "$REPO_ROOT" "${TRUNK_BRANCH}:refs/acfw/trunk-snapshot" --quiet >&2
BASE=$(git -C "$WORKTREE_PATH" rev-parse --verify "$BASE_REF" 2>/dev/null || true)
SNAP=$(git -C "$WORKTREE_PATH" rev-parse refs/acfw/trunk-snapshot 2>/dev/null || true)
if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain)" ]; then
  echo "WARN: $SLUG worktree has uncommitted changes; skipping trunk re-align (defer to integrate)." >&2
elif [ -n "$BASE" ]; then
  # Fork base known (2.4.1+ branch): replay ONLY base..HEAD onto fresh trunk — code-only by construction.
  if git_with_lock_backoff -C "$WORKTREE_PATH" rebase --onto refs/acfw/trunk-snapshot "$BASE" "$BRANCH" >&2; then
    git -C "$WORKTREE_PATH" update-ref "$BASE_REF" "$SNAP" 2>/dev/null || true
  else
    git -C "$WORKTREE_PATH" rebase --abort 2>/dev/null || true
    echo "WARN: cannot re-align $BRANCH onto $TRUNK_BRANCH (code-only rebase hit conflicts)." >&2
    echo "Continue on existing code-only state; integrate-worktree will rebase + resolve at integration time." >&2
  fi
else
  # Pre-2.4.1 branch with NO recorded fork base. NEVER fall back to a far-back merge-base — on a
  # long-lived repo that base trails trunk by hundreds of commits and the replay drags the whole
  # imported .backlog phantom range, the root cause of the phantom-conflict reject-loop. Instead
  # derive the branch's genuine code commits by patch-id and reconstruct a clean code-only tip on
  # fresh trunk. A specialist must never inherit a mid-sequencer worktree, so on ANY conflict we
  # abort + restore and defer to integrate-time.
  PENDING=$(acfw_pending_code_commits "$WORKTREE_PATH" refs/acfw/trunk-snapshot "$BRANCH")
  BK=$(git -C "$WORKTREE_PATH" rev-parse "$BRANCH" 2>/dev/null || true)
  if [ -z "$PENDING" ]; then
    # All of the branch's code is already on trunk by patch-id (or it carries only .backlog phantoms):
    # align the branch to current trunk; the code is preserved on trunk, the phantoms are dropped.
    git_with_lock_backoff -C "$WORKTREE_PATH" reset --hard refs/acfw/trunk-snapshot >&2
    git -C "$WORKTREE_PATH" update-ref "$BASE_REF" "$SNAP" 2>/dev/null || true
  else
    git_with_lock_backoff -C "$WORKTREE_PATH" reset --hard refs/acfw/trunk-snapshot >&2
    if git_with_lock_backoff -C "$WORKTREE_PATH" cherry-pick $PENDING >&2; then
      git -C "$WORKTREE_PATH" update-ref "$BASE_REF" "$SNAP" 2>/dev/null || true
    else
      git -C "$WORKTREE_PATH" cherry-pick --abort 2>/dev/null || true
      [ -n "$BK" ] && git -C "$WORKTREE_PATH" reset --hard "$BK" >&2
      echo "WARN: cannot re-align legacy $BRANCH onto $TRUNK_BRANCH (patch-id replay hit conflicts)." >&2
      echo "Continue on existing code-only state; integrate-worktree will reconstruct + resolve at integration time." >&2
    fi
  fi
fi

# ---- Step 6: Stash unrelated working-tree changes ----
TASK_ID=$(basename "$TASK_FILE" .md)
if [ -n "$(git -C "$WORKTREE_PATH" status --porcelain)" ]; then
  git_with_lock_backoff -C "$WORKTREE_PATH" stash push -u -m "pre-task-start: $TASK_ID" --quiet >&2 || true
fi

# ---- Step 7: Log the OK token ----
# Format (machine-greppable): | <UTC ts> | clean-checkout | ok | clean-checkout-before-task | <slug> | <branch> |
# Spliced into the ## Transition Log table (append_log_row) so it stays in-section and bounded (I3),
# while remaining greppable anywhere in the file for the reviewer's auto-reject check.
TS=$(date -u +"%Y-%m-%d %H:%M:%S")
LINE="| $TS | clean-checkout | ok | $ACFW_AGENT_FIELD | $SLUG | $BRANCH |"
append_log_row "$TASK_FILE" "$LINE"

# ---- Step 8: Print the worktree path for the caller ----
echo "$WORKTREE_PATH"
