#!/usr/bin/env bash
# clean-checkout.sh — concurrency primitive for ACF specialist agents.
#
# Usage: clean-checkout.sh [--slug SLUG] <TASK_FILE>
#   TASK_FILE: absolute path to the task markdown — the live .backlog/ document (files store)
#              or a spec materialized by `acfw-store read --materialize` (any other store).
#   --slug     explicit Worktree slug (optional); default is the TASK_FILE's Worktree: field.
#
# Resolves the task's Worktree slug, lazy-creates an isolated git worktree on
# worktree/<slug> forked from the LIVE trunk tip, validates the branch, records the
# per-slug fork-base, stashes unrelated changes, logs the clean-checkout OK token, and
# prints the worktree path.
# The lock is git itself: `git worktree add -b <branch>` fails when the branch is
# already checked out elsewhere — that failure is the mutual-exclusion primitive.
#
# LP-CAS (3.0.0): this is a PRODUCER-side primitive only. It NEVER rebases/resets the
# branch onto a cached trunk snapshot — the keystone defect (#1) was exactly that snapshot
# going stale on a rewritten trunk and silently freezing every worktree's base. There is no
# snapshot here anymore. The branch keeps the code the specialist commits on top of its
# fork-base; the LP-CAS integrator applies that change onto the LIVE trunk at integration
# time via cherry-pick (base = the recorded fork-base), so a long-lived branch is never
# stale by construction and never needs a re-align pass.
#
# Exit codes (all fatal to the caller unless noted):
#   0  success (worktree path printed on stdout)
#   1  Worktree: field missing on a code-touching task
#   2  branch in use elsewhere (lock held by another agent — defer, try another task)
#   3  worktree exists but on the wrong branch (manual intervention)
#   5  trunk branch not resolvable (detached HEAD)
#   6  the durable clean-checkout token could not be written to a non-files task store (retry)
#  99  lock contention persisted past backoff, or a store adapter answered "could not determine"
#      (adapters/CONTRACT.md's transient code) — transient either way; retry next iteration

set -u

# Hard-coded agent field for the transition-log token. MUST be the literal
# "clean-checkout-before-task" — NOT $(basename "$0"), which would become
# "clean-checkout.sh" and drift the documented token format that quality-reviewer
# and greppers rely on.
ACFW_AGENT_FIELD="clean-checkout-before-task"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

# ---- Step 1: Resolve slug (explicit --slug wins; else the task's Worktree: field) ----
SLUG_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --slug) SLUG_OVERRIDE="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
TASK_FILE="${1:-}"
if [ -z "$TASK_FILE" ]; then
  echo "FATAL: clean-checkout.sh requires a TASK_FILE argument." >&2
  exit 1
fi
SLUG="$SLUG_OVERRIDE"
[ -n "$SLUG" ] || SLUG=$(grep -E '^- \*\*Worktree\*\*:' "$TASK_FILE" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')

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
  # Record the fork base: the trunk tip the branch forked from. The LP-CAS integrator builds the
  # task's candidate as commit-tree(branch-tree, parent=fork-base) and cherry-picks it onto the LIVE
  # trunk — diff(fork-base, branch-tree) is exactly the task's edits, so the apply is minimal and
  # never replays trunk history. The fork-base need not track trunk (it is the 3-way base, not a
  # rebase target), which is precisely why no snapshot can go stale here.
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

# ---- Step 5: Ensure the per-slug fork-base is recorded (NO rebase, NO snapshot) ----
# LP-CAS removes the entire re-align pass. The branch is NEVER reset/rebased onto a cached trunk
# snapshot — that snapshot was the keystone defect: a non-force fetch silently refused to advance it
# on a rewritten trunk, freezing every worktree's base ~1292 commits stale. There is no snapshot now.
# The branch simply carries the specialist's code on top of its fork-base; the integrator applies
# that change onto the LIVE trunk at integration time (cherry-pick, base = fork-base), so the branch
# can never be stale. All we do here is BACKFILL a missing fork-base for a pre-3.0.0 worktree so the
# integrator has a 3-way base; if even that is unavailable the integrator falls back to merge-base.
BASE_REF="refs/acfw/forkbase/$SLUG"
if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1; then
  MB=$(git -C "$REPO_ROOT" merge-base "$BRANCH" "$TRUNK_BRANCH" 2>/dev/null || true)
  [ -n "$MB" ] && git -C "$REPO_ROOT" update-ref "$BASE_REF" "$MB" 2>/dev/null || true
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
append_log_row "$TASK_FILE" "$LINE" \
  || echo "WARN: could not record the clean-checkout token in $TASK_FILE (rc=$?) — the reviewer may auto-reject" >&2
# Non-files store (3.1.0): a TASK_FILE outside .backlog/ is a MATERIALIZED spec, not the live task
# document — the append above only helps agents re-reading this spec. The durable token (what the
# reviewer's auto-reject reads after a store refresh) must land in the task store itself.
case "$TASK_FILE" in
  */.backlog/*) : ;;
  *)
    # STRICT, and the strictness is the point. On a non-`files` store this is the ONLY durable write
    # of the token: the append above landed in a materialized spec that the next `read --materialize`
    # truncates. A swallowed failure here therefore does not merely risk an auto-reject — it produces
    # a task no later review can rescue, because clean-checkout runs at DISPATCH and nothing else
    # ever writes a token. That is the in-review/ fixed point whip-go now has to park tasks out of.
    # The old form discarded the return code, sent the adapter's own diagnosis to /dev/null, and
    # exited 0 — so the one failure that matters was the one nobody could see.
    _cc_rc=0
    for _cc_try in 1 2; do
      bash "$SCRIPT_DIR/../../lib/bin/acfw-store" log-event "$TASK_ID" --row "$LINE" >/dev/null
      _cc_rc=$?
      # 99 ONLY: the contract's "could not determine / transient" (adapters/CONTRACT.md). Every other
      # non-zero is a definite refusal and retrying it just doubles the latency before the same answer.
      [ "$_cc_rc" -eq 99 ] || break
      [ "$_cc_try" -eq 1 ] && sleep 1
    done
    if [ "$_cc_rc" -ne 0 ]; then
      echo "FATAL: could not record the clean-checkout token in the task store for $TASK_ID (rc=$_cc_rc)." >&2
      echo "       The worktree is ready, but without the durable token the review gate cannot tell this" >&2
      echo "       task from one that never entered a worktree. Stopping so the next iteration retries." >&2
      exit 6
    fi
    ;;
esac

# ---- Step 8: Print the worktree path for the caller ----
echo "$WORKTREE_PATH"
