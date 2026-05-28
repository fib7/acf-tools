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
