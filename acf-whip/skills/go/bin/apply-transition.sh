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
#   apply-transition.sh <TASK_FILE> <TO_STATE> [AGENT] [NOTES] [REJECTION_INCREMENT]
#     TASK_FILE  absolute path to the task file in its CURRENT state folder
#     TO_STATE   target folder under .backlog/ (pending|in-progress|completed|
#                in-review|accepted|rejected|blocked)
#     AGENT      transition-log actor (default: orchestrator)
#     NOTES      transition-log reason (default: empty)
#     REJECTION_INCREMENT  "1" bumps Rejection Count (only when TO_STATE=rejected)
#
# Idempotent: if the file is already in TO_STATE (or the source is gone and the dest
# exists), it no-ops — so a re-applied batch after a workflow resume cannot double-move
# or double-commit.
#
# Exit codes: 0 success or no-op; 2 bad args / file not found; 99 lock contention.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

TASK_FILE="${1:-}"
TO_STATE="${2:-}"
AGENT="${3:-orchestrator}"
NOTES="${4:-}"
REJECTION_INCREMENT="${5:-0}"

if [ -z "$TASK_FILE" ] || [ -z "$TO_STATE" ]; then
  echo "FATAL: usage: apply-transition.sh <TASK_FILE> <TO_STATE> [AGENT] [NOTES] [REJECTION_INCREMENT]" >&2
  exit 2
fi

REPO_ROOT="${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}"
FNAME=$(basename "$TASK_FILE")
FROM_STATE=$(basename "$(dirname "$TASK_FILE")")
DEST="$REPO_ROOT/.backlog/$TO_STATE/$FNAME"

# Idempotency: already in the target folder -> no-op (safe re-apply after resume).
if [ "$FROM_STATE" = "$TO_STATE" ]; then
  echo "noop: $FNAME already in $TO_STATE"
  exit 0
fi
if [ ! -f "$TASK_FILE" ] && [ -f "$DEST" ]; then
  echo "noop: $FNAME already in $TO_STATE (source absent)"
  exit 0
fi
if [ ! -f "$TASK_FILE" ]; then
  echo "FATAL: task file not found: $TASK_FILE" >&2
  exit 2
fi

TS=$(date -u +"%Y-%m-%d %H:%M:%S")

if [ "$REJECTION_INCREMENT" = "1" ] && [ "$TO_STATE" = "rejected" ]; then
  RC=$(grep -E '^- \*\*Rejection Count\*\*:' "$TASK_FILE" | sed -E 's/.*Rejection Count\*\*:[[:space:]]*([0-9]+).*/\1/')
  RC=${RC:-0}
  sed -i.bak -E "s/^- \*\*Rejection Count\*\*:.*/- **Rejection Count**: $((RC + 1))/" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
fi

printf '| %s | %s | %s | %s | %s |\n' "$TS" "$FROM_STATE" "$TO_STATE" "$AGENT" "$NOTES" >> "$TASK_FILE"
mkdir -p "$REPO_ROOT/.backlog/$TO_STATE"
mv "$TASK_FILE" "$DEST"
git_with_lock_backoff -C "$REPO_ROOT" add ".backlog/$FROM_STATE/$FNAME" ".backlog/$TO_STATE/$FNAME"
git_with_lock_backoff -C "$REPO_ROOT" commit -m "task: $FNAME $FROM_STATE -> $TO_STATE" --quiet
echo "ok: $FNAME $FROM_STATE -> $TO_STATE"
exit 0
