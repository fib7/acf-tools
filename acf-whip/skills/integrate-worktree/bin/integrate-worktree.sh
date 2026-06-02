#!/usr/bin/env bash
# integrate-worktree.sh — fold one accepted worktree branch into the local trunk.
#
# Usage:
#   integrate-worktree.sh <TASK_FILE>                 # initial attempt (FF -> rebase -> retry)
#   integrate-worktree.sh --post-resolver <TASK_FILE> # after the caller dispatched a resolver
#
# Env (set by /go at startup):
#   ACFW_TRUNK_ROOT   absolute path to the repo-root checkout (trunk)
#   ACFW_TRUNK_BRANCH the branch checked out at ACFW_TRUNK_ROOT
#
# Resolver dispatch is HOISTED OUT of this script: a workflow subagent / the
# orchestrator cannot reliably spawn another subagent from inside bash. On rebase
# conflict the script assembles full conflict context, prints an "ACFW-INTEGRATE:
# resolver-needed" block on stdout, leaves the worktree mid-rebase, and exits 7. The
# caller dispatches the task's assigned_agent into the worktree, then re-invokes this
# script with --post-resolver to validate + retry the fast-forward.
#
# Exit codes:
#   0  integrated (Integrated-At written, task remains in accepted/)
#   1  task missing Worktree: field
#   4  no worktree/<slug> branch -> historical/pre-2.0.0 task already on trunk; nothing to
#      integrate (terminal). Caller must NOT retry.
#   6  conflict unresolved -> task moved to rejected/, Rejection Count incremented
#   7  resolver-needed -> context printed, worktree left mid-rebase (caller dispatches resolver)
#  10  transient git error (fetch/refspec) -> leave task accepted, retry next iteration
#  99  lock contention persisted past backoff -> transient, retry next iteration

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

# ---- Argument parsing ----
MODE="initial"
if [ "${1:-}" = "--post-resolver" ]; then
  MODE="post-resolver"
  shift
fi
TASK_FILE="${1:-}"
if [ -z "$TASK_FILE" ]; then
  echo "FATAL: integrate-worktree.sh requires a TASK_FILE argument." >&2
  exit 1
fi

if [ -z "${ACFW_TRUNK_ROOT:-}" ] || [ -z "${ACFW_TRUNK_BRANCH:-}" ]; then
  echo "FATAL: ACFW_TRUNK_ROOT / ACFW_TRUNK_BRANCH must be set by /go before integration." >&2
  exit 10
fi

# ---- Step 1: Resolve task fields ----
SLUG=$(grep -E '^- \*\*Worktree\*\*:' "$TASK_FILE" | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
ASSIGNED_AGENT=$(grep -E '^- \*\*Assigned Agent\*\*:' "$TASK_FILE" | sed -E 's/.*Assigned Agent\*\*:[[:space:]]*//' | tr -d '[:space:]')
TASK_ID=$(basename "$TASK_FILE" .md)

if [ -z "$SLUG" ]; then
  echo "FATAL: $TASK_FILE has no Worktree: field; cannot integrate. Run '/whip-doctor --fix' to backfill the slug." >&2
  exit 1
fi

WORKTREE="$ACFW_TRUNK_ROOT/.worktree/$SLUG"
BRANCH="worktree/$SLUG"
TRUNK_SHA_AFTER=""  # set before do_success

# ---- Step 7: Success path ----
do_success() {
  local TS TASK_FILE_ON_TRUNK REMAINING
  TS=$(date -u +"%Y-%m-%d %H:%M:%S")
  TASK_FILE_ON_TRUNK="$ACFW_TRUNK_ROOT/.backlog/accepted/$(basename "$TASK_FILE")"

  if grep -qE '^- \*\*Integrated-At\*\*:' "$TASK_FILE_ON_TRUNK"; then
    sed -i.bak -E "s|^- \*\*Integrated-At\*\*:.*|- **Integrated-At**: $TRUNK_SHA_AFTER|" "$TASK_FILE_ON_TRUNK"
  else
    sed -i.bak -E "/^- \*\*Worktree\*\*:/a\\
- **Integrated-At**: $TRUNK_SHA_AFTER" "$TASK_FILE_ON_TRUNK"
  fi
  rm -f "$TASK_FILE_ON_TRUNK.bak"

  append_log_row "$TASK_FILE_ON_TRUNK" "$(printf '| %s | accepted | accepted | integrate-worktree | %s | %s | integrated |' "$TS" "$SLUG" "$TRUNK_SHA_AFTER")"

  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" add ".backlog/accepted/$(basename "$TASK_FILE")"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" commit -m "integrate: $TASK_ID ($SLUG -> $ACFW_TRUNK_BRANCH)" --quiet

  # Cleanup: remove worktree iff no more pending/in-progress tasks share the slug.
  REMAINING=$(grep -lE "^- \*\*Worktree\*\*:[[:space:]]*${SLUG}[[:space:]]*\$" \
    "$ACFW_TRUNK_ROOT/.backlog/pending/"*.md \
    "$ACFW_TRUNK_ROOT/.backlog/in-progress/"*.md 2>/dev/null | wc -l)
  if [ "$REMAINING" -eq 0 ]; then
    git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true
    git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" branch -d "$BRANCH" 2>/dev/null || true
  fi
  exit 0
}

# ---- Step 6: Resolver failure path ----
do_resolver_failure() {
  local TS REASON RC NEW_RC
  git -C "$WORKTREE" rebase --abort 2>/dev/null || true
  TS=$(date -u +"%Y-%m-%d %H:%M:%S")
  REASON="conflict-unresolved by $ASSIGNED_AGENT"

  RC=$(grep -E '^- \*\*Rejection Count\*\*:' "$TASK_FILE" | sed -E 's/.*Rejection Count\*\*:[[:space:]]*([0-9]+).*/\1/')
  RC=${RC:-0}
  NEW_RC=$((RC + 1))
  sed -i.bak -E "s/^- \*\*Rejection Count\*\*:.*/- **Rejection Count**: $NEW_RC/" "$TASK_FILE" && rm -f "$TASK_FILE.bak"

  append_log_row "$TASK_FILE" "$(printf '| %s | accepted | rejected | integrate-worktree | %s | %s |' "$TS" "$SLUG" "$REASON")"

  # Folder is the source of truth: sync Status to the destination state with the mv (I4).
  sed -i.bak -E "s/^- \*\*Status\*\*:.*/- **Status**: rejected/" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
  mv "$TASK_FILE" "$ACFW_TRUNK_ROOT/.backlog/rejected/$(basename "$TASK_FILE")"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" add ".backlog/accepted/$(basename "$TASK_FILE")" ".backlog/rejected/$(basename "$TASK_FILE")"
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" commit -m "integrate: reject $TASK_ID ($REASON)" --quiet
  exit 6
}

# Emit conflict context for the caller, then exit 7. Worktree is left mid-rebase.
emit_resolver_needed() {
  local MERGE_BASE CONFLICTING_COMMITS SOURCE_TASKS CONFLICTED_FILES
  MERGE_BASE=$(git -C "$WORKTREE" merge-base HEAD refs/acfw/trunk-snapshot 2>/dev/null || true)
  CONFLICTING_COMMITS=$(git -C "$ACFW_TRUNK_ROOT" log "${MERGE_BASE}..${ACFW_TRUNK_BRANCH}" --pretty=format:'%H %s' 2>/dev/null || true)
  SOURCE_TASKS=$(grep -lE '^- \*\*Integrated-At\*\*:[[:space:]]*[0-9a-f]{7,}' "$ACFW_TRUNK_ROOT/.backlog/accepted/"*.md 2>/dev/null || true)
  CONFLICTED_FILES=$(git -C "$WORKTREE" diff --name-only --diff-filter=U 2>/dev/null || true)

  echo "ACFW-INTEGRATE: resolver-needed"
  echo "worktree: $WORKTREE"
  echo "branch: $BRANCH"
  echo "task_file: $TASK_FILE"
  echo "assigned_agent: $ASSIGNED_AGENT"
  echo "conflicting_commits:"
  echo "$CONFLICTING_COMMITS"
  echo "source_tasks:"
  echo "$SOURCE_TASKS"
  echo "conflicted_files:"
  echo "$CONFLICTED_FILES"
  exit 7
}

# Returns 0 if a rebase is in progress in the worktree (robust for linked worktrees,
# where $WORKTREE/.git is a file, not a directory).
rebase_in_progress() {
  local rb rba
  rb=$(git -C "$WORKTREE" rev-parse --git-path rebase-merge 2>/dev/null || true)
  rba=$(git -C "$WORKTREE" rev-parse --git-path rebase-apply 2>/dev/null || true)
  { [ -n "$rb" ] && [ -d "$rb" ]; } || { [ -n "$rba" ] && [ -d "$rba" ]; }
}

# Refresh refs/acfw/<slug> from the (possibly rebased) worktree branch and retry FF.
retry_ff() {
  git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" fetch . "${BRANCH}:refs/acfw/${SLUG}" --quiet --force >&2
  if git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" merge --ff-only "refs/acfw/${SLUG}" >&2; then
    TRUNK_SHA_AFTER=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)
    return 0
  fi
  return 1
}

# ================= post-resolver mode =================
if [ "$MODE" = "post-resolver" ]; then
  if rebase_in_progress; then
    do_resolver_failure   # resolver gave up or crashed mid-rebase
  fi
  if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
    do_resolver_failure   # working tree dirty: resolver did not finish cleanly
  fi
  if grep -qE '^\| .* FATAL:' "$TASK_FILE"; then
    do_resolver_failure   # explicit FATAL token from the resolver
  fi
  if retry_ff; then
    do_success
  fi
  do_resolver_failure
fi

# ================= initial mode =================
# ---- Step 2 pre-check: the worktree branch MUST exist. If it doesn't, this is a historical/
# pre-2.0.0 accepted task already on trunk (or a pruned branch) — nothing to fold in. Report and
# exit 4 (terminal; caller must NOT retry) instead of fetching a missing ref into an exit-10 retry
# loop. /go already filters these via hasWorktreeBranch; this keeps the script correct standalone.
if ! git -C "$ACFW_TRUNK_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "ACFW-INTEGRATE: skipped-historical (no branch $BRANCH; nothing to integrate)"
  exit 4
fi

# ---- Step 2 pre-check (I5B): the branch EXISTS but has NO commits ahead of trunk -> nothing to fold
# in. A read-only / gate / verification task (retro's verification-001) still gets a worktree/<slug>
# branch from clean-checkout but produces no code commit, so a plain FF would be a no-op that the
# post-flight guard turns into an exit-10 retry loop. Mark it terminal instead: write Integrated-At
# (= current trunk) and run the normal success cleanup, so it counts terminal and the worktree is reaped.
AHEAD=$(git -C "$ACFW_TRUNK_ROOT" rev-list --count "${ACFW_TRUNK_BRANCH}..${BRANCH}" 2>/dev/null || echo "")
if [ "$AHEAD" = "0" ]; then
  TRUNK_SHA_AFTER=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)
  echo "ACFW-INTEGRATE: empty-branch (no commits ahead of $ACFW_TRUNK_BRANCH; nothing to integrate, marking terminal)"
  do_success
fi

# ---- Step 2: Fetch the worktree branch into trunk's refs ----
if ! git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" fetch . "${BRANCH}:refs/acfw/${SLUG}" --quiet >&2; then
  rc=$?
  echo "WARN: fetch $BRANCH failed (exit $rc); will retry next iteration" >&2
  exit 10
fi

# ---- Step 3: Try fast-forward into trunk ----
TRUNK_SHA_BEFORE=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)

# Pre-flight: refs/acfw/<slug> MUST exist after the fetch. If it doesn't, the refspec
# was silently corrupted (historical zsh `:r` bug) and a FF here would commit an
# "integrated" marker on top of unchanged trunk, orphaning the worktree's commits.
if ! git -C "$ACFW_TRUNK_ROOT" rev-parse --verify "refs/acfw/${SLUG}" >/dev/null 2>&1; then
  echo "FATAL: refs/acfw/${SLUG} does not exist after fetch; aborting integration to prevent silent orphaning of worktree commits" >&2
  exit 10
fi

if git_with_lock_backoff -C "$ACFW_TRUNK_ROOT" merge --ff-only "refs/acfw/${SLUG}" >&2; then
  TRUNK_SHA_AFTER=$(git -C "$ACFW_TRUNK_ROOT" rev-parse HEAD)
  # Post-flight: HEAD must have advanced. A no-op FF means the branch was already an
  # ancestor — the task should not have been accepted-but-unintegrated.
  if [ "$TRUNK_SHA_AFTER" = "$TRUNK_SHA_BEFORE" ]; then
    echo "FATAL: FF reported success but HEAD did not advance ($TRUNK_SHA_BEFORE); refs/acfw/${SLUG} = $(git -C "$ACFW_TRUNK_ROOT" rev-parse refs/acfw/${SLUG})" >&2
    exit 10
  fi
  do_success
fi

# ---- Step 4: Rebase the worktree onto current trunk, then retry FF ----
git_with_lock_backoff -C "$WORKTREE" fetch "$ACFW_TRUNK_ROOT" "${ACFW_TRUNK_BRANCH}:refs/acfw/trunk-snapshot" --quiet >&2
if git_with_lock_backoff -C "$WORKTREE" rebase refs/acfw/trunk-snapshot >&2; then
  if retry_ff; then
    do_success
  fi
fi

# ---- Step 5: Conflict — assemble context and hand back to the caller ----
emit_resolver_needed
