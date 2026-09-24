#!/usr/bin/env bash
# whip-move.sh — safe, operator-facing wrapper around the apply-transition.sh writer primitive.
#
# WHY: after a crash or for any manual close-out, moving a task between .backlog/ folders by hand
# (git mv + rewriting "- **Status**:" + splicing a Transition Log row + writing Integrated-At with
# perl/sed) is fragile — one slip is a doctor FATAL. apply-transition.sh already does the move +
# atomic Status sync + log row + commit correctly, but it is an internal primitive that needs the
# task's FULL current path and does not touch Integrated-At / Dependencies. This wrapper surfaces it
# as a validated one-liner: resolve a task by stem/id, optionally set Integrated-At or add a
# Dependency, then perform the move. Run /whip-doctor afterwards to confirm the backlog is consistent.
#
# Usage:
#   whip-move.sh <TASK> <TO_STATE> [--reason "..."] [--integrated-at SHA] [--add-dep ID] [--agent NAME]
#     TASK            task stem, id, or a UNIQUE prefix; resolved across all .backlog/<state>/ folders
#     TO_STATE        pending|in-progress|completed|in-review|accepted|rejected|blocked|draft|archive
#                     (use the task's CURRENT state to apply field edits without moving)
#     --reason TEXT   transition-log note (default: "manual operator move")
#     --integrated-at SHA   set "- **Integrated-At**: SHA" on the task (typical with TO_STATE=accepted)
#     --add-dep ID    append ID to the task's "- **Dependencies**:" bare comma list
#     --agent NAME    transition-log actor (default: operator)
#
# All edits land in the SAME commit as the move (apply-transition.sh commits the moved file). When
# TO_STATE equals the current folder (field edits only, no move), the edits are committed directly.
#
# Exit codes: 0 success/no-op; 2 bad args / task not found / ambiguous; other = apply-transition's code.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY="$SCRIPT_DIR/../../go/bin/apply-transition.sh"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

# draft and archive (3.4.0) are the PAUSE and CANCEL states, and they are the supported way to park
# work on every backend. Both were already in the store vocabulary and both are already understood by
# the whole system — the scheduler never dispatches them, the enricher keeps them resolvable for
# dependency lookups without scheduling them, and the doctor reports a dependent as gated rather than
# dangling. What was missing was a way to REACH them without hand-editing a card.
#
# This matters because the alternatives people reach for are worse. Dropping a task from a run focus
# does not pause it: a scoped run pulls in unmet dependencies, so it comes straight back. Setting a
# native "blocked"/"cancelled" status on an API-backed board does not pause it either — whip reads its
# own metadata, not the native status — and until 3.4.0 `doctor --fix` would rewrite that native
# status back on the next bootstrap. Pausing is a STATE, and this is how you set it.
VALID_STATES="pending in-progress completed in-review accepted rejected blocked draft archive"

TASK=""
TO_STATE=""
REASON="manual operator move"
INTEGRATED_AT=""
ADD_DEP=""
AGENT="operator"

# positional: <TASK> <TO_STATE> first, then flags (order-tolerant)
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    # `shift 2` with only one argument left FAILS and shifts nothing, so $1 stays the flag and this
    # loop spins forever. Demand the value explicitly, the way doctor.sh does.
    --reason) [ $# -ge 2 ] || { echo "FATAL: --reason requires a value" >&2; exit 2; }; REASON="$2"; shift 2 ;;
    --integrated-at) [ $# -ge 2 ] || { echo "FATAL: --integrated-at requires a value" >&2; exit 2; }; INTEGRATED_AT="$2"; shift 2 ;;
    --add-dep) [ $# -ge 2 ] || { echo "FATAL: --add-dep requires a value" >&2; exit 2; }; ADD_DEP="$2"; shift 2 ;;
    --agent) [ $# -ge 2 ] || { echo "FATAL: --agent requires a value" >&2; exit 2; }; AGENT="$2"; shift 2 ;;
    --*) echo "FATAL: unknown flag: $1" >&2; exit 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done
TASK="${POS[0]:-}"
TO_STATE="${POS[1]:-}"

if [ -z "$TASK" ] || [ -z "$TO_STATE" ]; then
  echo "FATAL: usage: whip-move.sh <TASK> <TO_STATE> [--reason ..] [--integrated-at SHA] [--add-dep ID] [--agent NAME]" >&2
  echo "       TO_STATE is one of: $VALID_STATES   (draft pauses, archive cancels)" >&2
  exit 2
fi
case " $VALID_STATES " in *" $TO_STATE "*) : ;; *) echo "FATAL: invalid TO_STATE '$TO_STATE' (one of: $VALID_STATES)" >&2; exit 2 ;; esac

REPO_ROOT="${ACFW_TRUNK_ROOT:-$(git rev-parse --show-toplevel)}"

# Non-files task store (3.1.0): route the same operator surface through the acfw-store dispatcher.
# The files path below stays exactly as it always was (direct file resolution + apply-transition).
STORE_BACKEND=$(acfw_resolve_store "$REPO_ROOT")
if [ "$STORE_BACKEND" != "files" ]; then
  STORE_BIN="$SCRIPT_DIR/../../lib/bin/acfw-store"
  RD=$(bash "$STORE_BIN" read "$TASK") || { echo "FATAL: no task matching '$TASK' in the '$STORE_BACKEND' store" >&2; exit 2; }
  STEM=$(printf '%s' "$RD" | sed -n 's/.*"stem":"\([^"]*\)".*/\1/p')
  FROM_STATE=$(printf '%s' "$RD" | sed -n 's/.*"folder":"\([^"]*\)".*/\1/p')
  FNAME="$STEM.md"
  EDITED=0
  if [ -n "$INTEGRATED_AT" ]; then
    bash "$STORE_BIN" update-field "$STEM" --set "Integrated-At=$INTEGRATED_AT" >/dev/null || exit 2
    EDITED=1
  fi
  if [ -n "$ADD_DEP" ]; then
    bash "$STORE_BIN" update-field "$STEM" --add-dep "$ADD_DEP" >/dev/null || exit 2
    EDITED=1
  fi
  if [ "$FROM_STATE" = "$TO_STATE" ]; then
    if [ "$EDITED" = "1" ]; then echo "ok: $FNAME edited in place ($FROM_STATE)"; else echo "noop: $FNAME already in $TO_STATE (no edits requested)"; fi
    exit 0
  fi
  exec bash "$STORE_BIN" transition "$STEM" "$TO_STATE" "$AGENT" "$REASON" 0 0
fi

[ -d "$REPO_ROOT/.backlog" ] || { echo "FATAL: no .backlog/ at $REPO_ROOT (run /whip-init)" >&2; exit 2; }

# ---- resolve TASK -> a single file under an active state folder ----
# Prefer an exact stem match (<TASK>.md); else fall back to unique-prefix/substring match.
MATCHES=()
for st in $VALID_STATES; do
  f="$REPO_ROOT/.backlog/$st/$TASK.md"
  [ -f "$f" ] && MATCHES+=("$f")
done
if [ "${#MATCHES[@]}" -eq 0 ]; then
  while IFS= read -r f; do [ -n "$f" ] && MATCHES+=("$f"); done < <(
    for st in $VALID_STATES; do
      ls "$REPO_ROOT/.backlog/$st/"*"$TASK"*.md 2>/dev/null || true
    done
  )
fi
if [ "${#MATCHES[@]}" -eq 0 ]; then
  echo "FATAL: no task matching '$TASK' under $REPO_ROOT/.backlog/" >&2; exit 2
fi
if [ "${#MATCHES[@]}" -gt 1 ]; then
  echo "FATAL: '$TASK' is ambiguous — matches:" >&2
  for f in "${MATCHES[@]}"; do echo "  $f" >&2; done
  echo "Re-run with a more specific stem." >&2; exit 2
fi
TASK_FILE="${MATCHES[0]}"
FROM_STATE=$(basename "$(dirname "$TASK_FILE")")
FNAME=$(basename "$TASK_FILE")

# ---- optional field edits (applied to the file in its CURRENT folder, before the move) ----
EDITED=0
if [ -n "$INTEGRATED_AT" ]; then
  if grep -qE '^- \*\*Integrated-At\*\*:' "$TASK_FILE"; then
    sed -i.bak -E "s|^- \*\*Integrated-At\*\*:.*|- **Integrated-At**: $INTEGRATED_AT|" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
  else
    sed -i.bak -E "/^- \*\*Status\*\*:/a\\
- **Integrated-At**: $INTEGRATED_AT" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
  fi
  EDITED=1
fi
# Dependencies is a BARE comma list ("a, b") — the format /task authors and the ONLY format the doctor
# and scanner parse (both split on commas without stripping brackets). Writing JSON-style "[a, b]" here
# made both ids unresolvable and raised a false dangling-dep FATAL that blocked /go. Any legacy bracket
# wrapping found in the file is dropped on the way through (doctor --fix repairs the rest).
if [ -n "$ADD_DEP" ]; then
  if grep -qE '^- \*\*Dependencies\*\*:' "$TASK_FILE"; then
    CUR=$(grep -E '^- \*\*Dependencies\*\*:' "$TASK_FILE" | head -1 | sed -E 's/^- \*\*Dependencies\*\*:[[:space:]]*//; s/^\[//; s/\]$//; s/[[:space:]]+$//')
    case "$CUR" in
      none|\"none\"|"") NEW="$ADD_DEP" ;;
      *) NEW="$CUR, $ADD_DEP" ;;
    esac
    sed -i.bak -E "s|^- \*\*Dependencies\*\*:.*|- **Dependencies**: $NEW|" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
  else
    sed -i.bak -E "/^- \*\*Status\*\*:/a\\
- **Dependencies**: $ADD_DEP" "$TASK_FILE" && rm -f "$TASK_FILE.bak"
  fi
  EDITED=1
fi

# ---- move (or, if no state change, commit field edits directly) ----
if [ "$FROM_STATE" = "$TO_STATE" ]; then
  if [ "$EDITED" = "1" ]; then
    git_with_lock_backoff -C "$REPO_ROOT" add ".backlog/$FROM_STATE/$FNAME"
    git_with_lock_backoff -C "$REPO_ROOT" commit -m "task: $FNAME field edit (operator)" --quiet
    echo "ok: $FNAME edited in place ($FROM_STATE)"
  else
    echo "noop: $FNAME already in $TO_STATE (no edits requested)"
  fi
  exit 0
fi

exec bash "$APPLY" "$TASK_FILE" "$TO_STATE" "$AGENT" "$REASON" 0 0
