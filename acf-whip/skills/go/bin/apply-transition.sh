#!/usr/bin/env bash
# apply-transition.sh — the single .backlog writer primitive.
#
# Moves one task file between state folders at the repo root on the trunk branch,
# appends a transition-log line, and commits. This is the ONLY place .backlog state
# moves are committed; callers (legacy /go orchestrator, or the whip-go workflow's
# backlog-writer agent) invoke it SEQUENTIALLY so the single-writer invariant holds
# with no extra locking.
#
# Usage:
#   apply-transition.sh [--stage PATH]... <TASK_FILE> <TO_STATE> [AGENT] [NOTES] [REJECTION_INCREMENT] [BLOCK_INCREMENT]
#     --stage PATH  repo-relative deliverable file to commit ALONGSIDE this transition (repeatable).
#                   A "Worktree: none" task writes standalone deliverables (docs/research/*.md) into
#                   the ROOT tree; the specialist may not commit, and nothing else ever staged those
#                   paths, so the next checkout/stash wiped them (permanent loss). The single writer
#                   stages them by EXPLICIT path in the SAME commit as the folder move. State
#                   namespaces are refused: .backlog/ is this writer's own business, .acfwhip/ is the
#                   integrator's ledger. Non-existent paths are skipped with a note.
#     TASK_FILE  absolute path to the task file in its CURRENT state folder
#     TO_STATE   target folder under .backlog/ (pending|in-progress|completed|
#                in-review|accepted|rejected|blocked)
#     AGENT      transition-log actor (default: orchestrator)
#     NOTES      transition-log reason (default: empty)
#     REJECTION_INCREMENT  "1" bumps Rejection Count (only when TO_STATE=rejected)
#     BLOCK_INCREMENT      "1" bumps Block-Count (only when TO_STATE=blocked) — the per-task
#                          re-block counter that breaks the specialist re-dispatch livelock (I2)
#
# The folder is the source of truth for state: this mover rewrites the "- **Status**:" frontmatter
# line to TO_STATE atomically with the mv, so a transition can never leave Status stale (which the
# doctor flags status-folder-mismatch FATAL and aborts /go at its first transition — retro I4).
#
# Idempotent: if the file is already in TO_STATE (or the source is gone and the dest
# exists), it no-ops — so a re-applied batch after a workflow resume cannot double-move
# or double-commit.
#
# Exit codes: 0 success or no-op; 2 bad args / file not found; 3 invoked off-trunk (would
# poison a code-only branch); 4 the task document is collapsed (no ID/Status) — nothing was
# moved, staged or committed; 99 lock contention.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

# --stage PATH... — validated up-front (before any file mutation) so a bad path never leaves a
# half-applied transition. Refusal is exit 2: a caller that hands us a state path has a bug.
STAGE_PATHS=()
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --stage)
      [ $# -ge 2 ] || { echo "FATAL: --stage requires a PATH" >&2; exit 2; }
      p="${2#./}"
      case "$p" in
        "") echo "FATAL: --stage path is empty" >&2; exit 2 ;;
        /*) echo "FATAL: --stage path must be repo-relative, got absolute: $p" >&2; exit 2 ;;
        *..*) echo "FATAL: --stage path must not traverse '..': $p" >&2; exit 2 ;;
        .backlog/*|.acfwhip/*) echo "FATAL: --stage refuses state paths (.backlog/, .acfwhip/): $p" >&2; exit 2 ;;
      esac
      STAGE_PATHS[${#STAGE_PATHS[@]}]="$p"
      shift 2 ;;
    --) shift; break ;;
    -*) echo "FATAL: unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

TASK_FILE="${1:-}"
TO_STATE="${2:-}"
AGENT="${3:-orchestrator}"
NOTES="${4:-}"
REJECTION_INCREMENT="${5:-0}"
BLOCK_INCREMENT="${6:-0}"

if [ -z "$TASK_FILE" ] || [ -z "$TO_STATE" ]; then
  echo "FATAL: usage: apply-transition.sh <TASK_FILE> <TO_STATE> [AGENT] [NOTES] [REJECTION_INCREMENT]" >&2
  exit 2
fi

REPO_ROOT="${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}"

# Invariant: .backlog/ state lives on TRUNK ONLY. This writer must run at the trunk root on the
# trunk branch — never inside a worktree/<slug> checkout — or a task-transition commit would land on
# a code-only branch and contaminate it (the integrate reject-loop). Assert it defensively when /go
# has told us which branch trunk is; a mismatch means a caller bug, so refuse rather than poison.
if [ -n "${ACFW_TRUNK_BRANCH:-}" ]; then
  HEAD_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || true)
  if [ -n "$HEAD_BRANCH" ] && [ "$HEAD_BRANCH" != "$ACFW_TRUNK_BRANCH" ]; then
    echo "FATAL: apply-transition.sh must run on trunk ($ACFW_TRUNK_BRANCH) at $REPO_ROOT, but HEAD is $HEAD_BRANCH. Refusing to commit .backlog state off-trunk." >&2
    exit 3
  fi
fi

FNAME=$(basename "$TASK_FILE")
FROM_STATE=$(basename "$(dirname "$TASK_FILE")")
DEST="$REPO_ROOT/.backlog/$TO_STATE/$FNAME"

# On a no-op re-apply, the move already happened but a crash between `mv` and `commit` would have
# left the deliverables uncommitted — the exact loss this flag exists to prevent. Commit whatever of
# them is still uncommitted, then no-op. Nothing to commit -> git commit is skipped, so this is inert
# on the common path.
rescue_deliverables() {
  [ ${#STAGE_PATHS[@]} -gt 0 ] || return 0
  local dirty=0 p
  for p in "${STAGE_PATHS[@]}"; do
    [ -e "$REPO_ROOT/$p" ] || continue
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$p" 2>/dev/null)" ]; then
      git_with_lock_backoff -C "$REPO_ROOT" add -- "$p"; dirty=1
    fi
  done
  [ "$dirty" = "1" ] || return 0
  if ! git_with_lock_backoff -C "$REPO_ROOT" commit -m "task: $FNAME deliverables" --quiet; then
    rc=$?
    echo "FATAL: commit failed (rc=$rc) while sweeping deliverables for $FNAME - they are STAGED but NOT committed." >&2
    echo "       Anything that can make \`git commit\` fail at the trunk root does it here: a signing key that is not" >&2
    echo "       usable (commit.gpgsign), a pre-commit hook from husky/lint-staged or core.hooksPath, an unset" >&2
    echo "       user.name/user.email, or an index.lock held past the backoff. Fix that, then re-run /go." >&2
    exit "$rc"
  fi
  echo "ok: committed uncommitted deliverables for $FNAME"
}

# assert_task_intact <phase> — the task document must still BE a task document. Checked TWICE:
# on entry (before any sed touches it) and again immediately before mv/add/commit, because the
# window between them is exactly where a concurrent emptier lands. Field incident 2026-08-24: a
# 17507-byte task file was emptied by something in the ~9 minutes it sat dispatched, this script's
# own append_log_row wrote its transition row into the void, and `git add` + `git commit` twenty
# lines later published the 267-byte corpse. That the writer commits whatever is on disk, with no
# content assertion anywhere, is what made the loss SILENT — the single worst property of the bug.
# append_log_row now refuses the empty read; this is the second, independent line: even if some
# future writer hands us a wreck, it never reaches trunk.
#
# The two phases are diagnostically distinct and worth keeping apart: "on-entry" means someone
# else broke the file before we touched it; "pre-commit" means it broke UNDER this writer, which
# is a live concurrency fault worth chasing.
#
# Deliberately NOT auto-repaired. `git checkout HEAD -- <path>` would discard the clean-checkout
# token row, which is uncommitted BY DESIGN (clean-checkout.sh leaves it for the next transition
# to commit), so the recovery is printed and never run. Same posture as doctor.sh's control-bytes:
# a torn write must never be silently committed as "healed".
assert_task_intact() { # <phase>
  if [ -s "$TASK_FILE" ] \
     && grep -qE '^- \*\*ID\*\*:' "$TASK_FILE" \
     && grep -qE '^- \*\*Status\*\*:' "$TASK_FILE"; then
    return 0
  fi
  echo "FATAL: $FNAME is not a task document ($1): no '- **ID**:' and/or '- **Status**:' line." >&2
  echo "       Refusing to move or commit a collapsed task file. Nothing was staged or committed." >&2
  echo "       Recover the last committed copy, then re-run this transition:" >&2
  echo "         git -C $REPO_ROOT checkout HEAD -- .backlog/$FROM_STATE/$FNAME" >&2
  echo "       Then run /whip-doctor. (Note: this discards any uncommitted clean-checkout token row.)" >&2
  # WHIP-08: --stage deliverables are the specialist's only copy and the next checkout/stash would
  # sweep them. Commit them even though the state move is refused — rescue_deliverables is already
  # the sanctioned path for exactly this "crashed between mv and commit" case.
  rescue_deliverables
  exit 4
}

# Idempotency: already in the target folder -> no-op (safe re-apply after resume).
if [ "$FROM_STATE" = "$TO_STATE" ]; then
  rescue_deliverables
  echo "noop: $FNAME already in $TO_STATE"
  exit 0
fi
if [ ! -f "$TASK_FILE" ] && [ -f "$DEST" ]; then
  rescue_deliverables
  echo "noop: $FNAME already in $TO_STATE (source absent)"
  exit 0
fi
if [ ! -f "$TASK_FILE" ]; then
  echo "FATAL: task file not found: $TASK_FILE" >&2
  exit 2
fi

# The file must be a task document before we mutate it (see assert_task_intact).
assert_task_intact on-entry

TS=$(date -u +"%Y-%m-%d %H:%M:%S")

if [ "$REJECTION_INCREMENT" = "1" ] && [ "$TO_STATE" = "rejected" ]; then
  RC=$(grep -E '^- \*\*Rejection Count\*\*:' "$TASK_FILE" | sed -E 's/.*Rejection Count\*\*:[[:space:]]*([0-9]+).*/\1/')
  RC=${RC:-0}
  sed -i.bak -E "s/^- \*\*Rejection Count\*\*:.*/- **Rejection Count**: $((RC + 1))/" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
fi

# Block-Count: bump the per-task re-block counter when a specialist re-blocks a dispatched task.
# The counter caps specialist re-dispatch (the orchestrator's unblock gate stops re-queueing a task
# past the cap), breaking the unmodeled-blocker livelock (retro I2). Insert the field if a pre-2.1.0
# task lacks it (after Rejection Count, else after Status).
if [ "$BLOCK_INCREMENT" = "1" ] && [ "$TO_STATE" = "blocked" ]; then
  if grep -qE '^- \*\*Block-Count\*\*:' "$TASK_FILE"; then
    BC=$(grep -E '^- \*\*Block-Count\*\*:' "$TASK_FILE" | sed -E 's/.*Block-Count\*\*:[[:space:]]*([0-9]+).*/\1/')
    BC=${BC:-0}
    sed -i.bak -E "s/^- \*\*Block-Count\*\*:.*/- **Block-Count**: $((BC + 1))/" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
  elif grep -qE '^- \*\*Rejection Count\*\*:' "$TASK_FILE"; then
    sed -i.bak -E "/^- \*\*Rejection Count\*\*:/a\\
- **Block-Count**: 1" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
  else
    sed -i.bak -E "/^- \*\*Status\*\*:/a\\
- **Block-Count**: 1" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
  fi
fi

# Folder is the source of truth: sync Status to the destination state atomically with the mv (I4).
sed -i.bak -E "s/^- \*\*Status\*\*:.*/- **Status**: $TO_STATE/" "$TASK_FILE" && rm -f "$TASK_FILE.bak"

# A lost transition ROW must not strand a state MOVE — assert_task_intact below is what decides
append_log_row "$TASK_FILE" "$(printf '| %s | %s | %s | %s | %s |' "$TS" "$FROM_STATE" "$TO_STATE" "$AGENT" "$NOTES")" \
  || echo "WARN: transition row not logged for $FNAME (append_log_row rc=$?)" >&2
# ...and still be one after every mutation, before anything is moved, staged or committed.
assert_task_intact pre-commit
mkdir -p "$REPO_ROOT/.backlog/$TO_STATE"
mv "$TASK_FILE" "$DEST"

# Deliverables ride the SAME commit as the state move: one atomic record of "this task produced
# these files and reached this state". A listed path that does not exist is a specialist bookkeeping
# slip, not a reason to strand the transition — skip it and say so.
STAGE_ADD=()
STAGE_MSG=""
if [ ${#STAGE_PATHS[@]} -gt 0 ]; then
  for p in "${STAGE_PATHS[@]}"; do
    if [ -e "$REPO_ROOT/$p" ]; then
      STAGE_ADD[${#STAGE_ADD[@]}]="$p"
    else
      echo "warn: --stage path not found, skipped: $p" >&2
    fi
  done
  [ ${#STAGE_ADD[@]} -gt 0 ] && STAGE_MSG=" (+${#STAGE_ADD[@]} deliverable file(s))"
fi

# PROPAGATE BOTH STATUSES. `ok:` used to print unconditionally, so a failed add or commit was
# reported to the orchestrator as an applied transition: the task file had already been MOVED on
# disk by the mv above, /go read the move and believed the state change was durable, and the whole
# run's board progress existed only as uncommitted working-tree state. The next clean-checkout or
# resync could then discard it with nothing anywhere saying a write had failed. This is what the
# header's documented exit 99 was always for; it was simply never reachable.
if [ ${#STAGE_ADD[@]} -gt 0 ]; then
  git_with_lock_backoff -C "$REPO_ROOT" add -- ".backlog/$FROM_STATE/$FNAME" ".backlog/$TO_STATE/$FNAME" "${STAGE_ADD[@]}"
else
  git_with_lock_backoff -C "$REPO_ROOT" add -- ".backlog/$FROM_STATE/$FNAME" ".backlog/$TO_STATE/$FNAME"
fi
rc=$?
if [ $rc -ne 0 ]; then
  echo "FATAL: git add failed (rc=$rc); $FNAME was moved to $TO_STATE on disk but is NOT staged." >&2
  echo "       The move is real and the commit is not - reconcile with /whip-doctor before re-running /go." >&2
  exit "$rc"
fi
git_with_lock_backoff -C "$REPO_ROOT" commit -m "task: $FNAME $FROM_STATE -> $TO_STATE$STAGE_MSG" --quiet
rc=$?
if [ $rc -ne 0 ]; then
  echo "FATAL: commit failed (rc=$rc); $FNAME was moved to $TO_STATE on disk but is NOT committed." >&2
  echo "       Anything that can make \`git commit\` fail at the trunk root does it here: a signing key that is not" >&2
  echo "       usable (commit.gpgsign), a pre-commit hook from husky/lint-staged or core.hooksPath, an unset" >&2
  echo "       user.name/user.email, or an index.lock held past the backoff. Fix that, then re-run /go -" >&2
  echo "       the move is on disk and staged, so the re-run reconciles rather than repeating work." >&2
  exit "$rc"
fi
echo "ok: $FNAME $FROM_STATE -> $TO_STATE$STAGE_MSG"
exit 0
