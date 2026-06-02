#!/usr/bin/env bash
# acfw-git.sh — shared git helpers for acf-whip.
#
# Source this from any acf-whip bin/ script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/../../lib/acfw-git.sh"
#
# Single source of truth for the lock-backoff primitive used by clean-checkout.sh,
# integrate-worktree.sh, apply-transition.sh, and the orchestrator's own trunk writes.
#
# Shell safety: every acf-whip script runs under bash (`#!/usr/bin/env bash`), never
# zsh. Refspecs like "${BRANCH}:refs/acfw/${SLUG}" place a ':' immediately after a
# parameter expansion; zsh applies `:r`/`:e`/`:h` modifiers to such constructs even
# inside double quotes and silently corrupts the refspec. bash has no such syntax.
# Brace form "${VAR}:..." is used at every adjacency as belt-and-suspenders.

# git_with_lock_backoff — run git, retrying only on .git/index.lock contention.
# The lock file is NEVER removed; we sleep and let the holding process finish.
# Backoff: 1s -> 2s -> 4s, three attempts (~7s worst case).
# Exit codes: 0 success; git's own rc for non-lock errors; 99 when lock contention
# persisted past backoff (callers treat 99 as transient and retry next iteration).
#
# FOOTGUN FIX (vs the historical inline version): the captured stderr goes to a
# per-invocation mktemp file, NOT a fixed /tmp/acfw-git-err. Two concurrent worktree
# agents sharing one fixed path would clobber each other's error text and corrupt the
# lock-vs-real-error classification.
git_with_lock_backoff() {
  local attempt=0 max=3 delay=1 rc errf
  errf=$(mktemp "${TMPDIR:-/tmp}/acfw-git-err.$$.XXXXXX") || {
    echo "FATAL: mktemp failed for acfw-git error capture" >&2
    return 1
  }
  while [ $attempt -lt $max ]; do
    # Capture git's exit status DIRECTLY. Do NOT read $? after an `if git …; then …; fi`
    # block: a bash `if` whose condition is false and which has no `else` exits 0, so
    # `rc=$?` there would mask a real git failure as success (the original inline helper's
    # latent bug — it returned 0 even when git failed for non-lock reasons).
    git "$@" 2>"$errf"
    rc=$?
    if [ $rc -eq 0 ]; then
      rm -f "$errf"
      return 0
    fi
    if grep -qE 'index\.lock|Unable to create.*lock' "$errf"; then
      attempt=$((attempt + 1))
      [ $attempt -ge $max ] && break
      sleep $delay
      delay=$((delay * 2))
      continue
    fi
    cat "$errf" >&2
    rm -f "$errf"
    return $rc
  done
  echo "FATAL: git lock contention persisted; another process holds .git/index.lock" >&2
  cat "$errf" >&2
  rm -f "$errf"
  return 99
}

# append_log_row <FILE> <ROW> — splice a transition-log row INTO the "## Transition Log"
# markdown table instead of dangling it after the last heading (retro I3). The row is inserted
# immediately after the table's header separator (newest-first), so the file stays valid
# section-structured markdown no matter how many transitions churn. The table BODY is then capped
# to the most recent ACFW_LOG_ROW_CAP rows (default 80) so a pathological loop can never balloon a
# task file to hundreds of KB. If no Transition Log table is found, the row is appended at EOF
# (legacy behavior) so a row is never silently lost. ROW must be the full "| ... |" line, no newline.
ACFW_LOG_ROW_CAP="${ACFW_LOG_ROW_CAP:-80}"
append_log_row() {
  local file="$1" row="$2" tmp
  [ -f "$file" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/acfw-log.XXXXXX") || { printf '%s\n' "$row" >> "$file"; return 0; }
  # awk receives ROW/CAP via ENVIRON (no interpolation, so notes with awk/shell metachars are safe).
  # A "separator" row is one whose inter-pipe cells are only dashes/spaces (the markdown header rule);
  # a data row always has alphanumerics in its first cell, so the two never collide.
  if ACFW_ROW="$row" ACFW_CAP="$ACFW_LOG_ROW_CAP" awk '
    BEGIN { row=ENVIRON["ACFW_ROW"]; cap=ENVIRON["ACFW_CAP"]+0; if (cap<1) cap=1; inLog=0; inserted=0; body=0 }
    /^##[[:space:]]/ { inLog = ($0 ~ /^##[[:space:]]+Transition Log[[:space:]]*$/) ? 1 : 0 }
    {
      if (inLog && !inserted && $0 ~ /^\|[ -]+\|/) {        # the header separator row
        print; print row; inserted=1; body=0; next
      }
      if (inLog && inserted && $0 ~ /^\|/) {                 # an existing body row (newest-first)
        body++; if (body < cap) print; next                 # keep newest (cap-1) old rows + the new one
      }
      if (inLog && inserted && $0 !~ /^\|/) inLog=0          # left the table body
      print
    }
    END { if (!inserted) print row }                         # no table -> append at EOF
  ' "$file" > "$tmp" && [ -s "$tmp" ]; then
    cat "$tmp" > "$file"
  else
    printf '%s\n' "$row" >> "$file"   # awk failed -> never drop the row
  fi
  rm -f "$tmp"
}
