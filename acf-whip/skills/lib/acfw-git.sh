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

# acfw_pending_code_commits <C> <upstream-ref> <branch-ref> — print the branch's GENUINE,
# not-yet-on-trunk code commits, oldest-first (apply order), one SHA per line.
#
# "Genuine code" = a commit that (a) is NOT already present on <upstream> by patch-id, AND
# (b) touches at least one path OUTSIDE .backlog/. This is the 2.5.0 primitive that makes
# integration patch-id-aware:
#   • EMPTY output  -> every code change on the branch is already on trunk (or the branch carries
#                      only .backlog phantom commits). The branch is done-modulo-stamp: the caller
#                      stamps Integrated-At and reaps, with NO rebase and NO conflict. This is the
#                      cure for the phantom-conflict reject-loop and the "done but not integrated"
#                      stall on long-lived repos.
#   • NON-empty     -> exactly the commits the caller must replay onto fresh trunk (cherry-pick),
#                      dropping the interleaved .backlog phantom commits that caused false conflicts.
#
# `git cherry <upstream> <branch>` marks each commit '-' (already upstream by patch-id) or '+'
# (new), oldest-first. We keep '+' commits that touch a non-.backlog path. A merge commit shows no
# diff-tree paths here and is skipped (code-only branches are linear; replaying a merge via
# cherry-pick would need -m anyway). Output order is git cherry's native apply order.
acfw_pending_code_commits() { # <C> <upstream-ref> <branch-ref>
  local C="$1" upstream="$2" branch="$3" mark sha names
  git -C "$C" cherry "$upstream" "$branch" 2>/dev/null | while read -r mark sha; do
    [ "$mark" = "+" ] || continue
    names=$(git -C "$C" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null)
    [ -n "$names" ] || continue
    if printf '%s\n' "$names" | grep -qv '^\.backlog/'; then
      printf '%s\n' "$sha"
    fi
  done
}

# acfw_load_namespace <repo-root> — resolve the worktree DIRECTORY and BRANCH PREFIX
# that acf-whip owns. Sets two globals:
#   ACFW_WORKTREE_DIR    per-task worktree dir, relative to repo root (default ".worktree")
#   ACFW_BRANCH_PREFIX   branch namespace acf-whip owns; trees live on <prefix>/<slug> (default "worktree")
#
# Why this matters: acf-whip must only ever create/remove/inspect worktrees inside its OWN
# namespace. A user may keep unrelated research/benchmark worktrees in the same repo (even under
# .worktree/) — those must be invisible to the doctor's orphan reaper. The branch prefix is the
# ownership signal; the dir is where new trees are placed.
#
# Precedence: .backlog/.acfw-config > inherited env var > built-in default. The committed config is
# the source of truth (sourcing it overwrites any inherited env value); an env var only fills in a
# key the config does not pin. This is order-independent — safe to call before OR after another code
# path has already sourced .acfw-config (e.g. the timeout block in doctor.sh / scan-backlog.sh).
# Idempotent.
acfw_load_namespace() { # <repo-root>
  [ -n "${1:-}" ] && [ -f "$1/.backlog/.acfw-config" ] && . "$1/.backlog/.acfw-config" >/dev/null 2>&1
  ACFW_WORKTREE_DIR="${ACFW_WORKTREE_DIR:-.worktree}"
  ACFW_BRANCH_PREFIX="${ACFW_BRANCH_PREFIX:-worktree}"
  # Strip any stray leading "./" or trailing "/" on the dir, and a trailing "/" on the prefix,
  # so downstream "$DIR/$SLUG" and "$PREFIX/$SLUG" concatenations are well-formed.
  ACFW_WORKTREE_DIR="${ACFW_WORKTREE_DIR#./}"; ACFW_WORKTREE_DIR="${ACFW_WORKTREE_DIR%/}"
  ACFW_BRANCH_PREFIX="${ACFW_BRANCH_PREFIX%/}"
  [ -z "$ACFW_WORKTREE_DIR" ] && ACFW_WORKTREE_DIR=".worktree"
  [ -z "$ACFW_BRANCH_PREFIX" ] && ACFW_BRANCH_PREFIX="worktree"
}

# ============================================================================
# LP-CAS (3.0.0): Ledger-In-Tree Compare-And-Swap integration primitives.
#
# Integration truth is a fact about git, never a markdown field:
#   A task K is integrated  IFF  the in-tree marker .acfwhip/integrated/<shard>/<K>.json
#   is present in the tree of the live trunk tip.
# These helpers are the only sanctioned way to read/derive that fact. No caller may
# assert "integrated" any other way (no Integrated-At field, no folder location).
# ============================================================================

# acfw_marker_path <key> — print the sharded in-tree ledger marker path for a task key.
# Sharded by the first 2 hex of git's content hash of the key so a 600+ task backlog never
# becomes one flat directory. Pure function of the key (no repo access needed); git hash-object
# is used only as a stable, always-available hash. The key is the task id (already kebab-safe).
acfw_marker_path() { # <key>
  local key="$1" h
  h=$(printf '%s' "$key" | git hash-object --stdin 2>/dev/null)
  [ -n "$h" ] || h="00$(printf '%s' "$key" | cksum | tr -dc '0-9a-f')0"  # never-empty fallback
  printf '.acfwhip/integrated/%s/%s.json' "${h:0:2}" "$key"
}

# acfw_live_trunk <root> <trunk-branch> — print the current trunk commit OID; nonzero exit if
# the trunk is unobservable (detached/missing). NEVER cached: trunk is a live branch in the same
# repo as every linked worktree, so its objects are already shared — there is no snapshot to go
# stale. This is the keystone-defect (#1) cure by construction: nothing to freeze.
acfw_live_trunk() { # <root> <trunk-branch>
  git -C "$1" rev-parse --verify "$2^{commit}" 2>/dev/null
}

# acfw_is_integrated <root> <committish> <key> — exit 0 iff key's ledger marker exists in the
# tree of <committish>. O(1) tree-path lookup; no history scan, no cursor; survives any history
# rewrite that preserves the tree content. This is THE integration oracle.
acfw_is_integrated() { # <root> <committish> <key>
  local mp; mp=$(acfw_marker_path "$3")
  git -C "$1" cat-file -e "$2:$mp" 2>/dev/null
}

# acfw_publish_candidate <root> <worktree> <fork-base> <key> [msg] — the sanctioned PRODUCER primitive.
# Squashes the worktree's committed work into exactly ONE single-parent commit (tree = worktree HEAD's
# tree, parent = fork-base) and publishes it at refs/acfw/patch/<key>. The integrator consumes exactly
# this ref: a single-parent commit whose diff-vs-parent is the task's whole change, so cherry-pick's
# 3-way base is the fork-base — never a merge-base computed against trunk. The worktree's work must be
# committed (HEAD tree is read); the fork-base is the trunk tip the task forked from (need not be
# current trunk — the integrator applies onto the live tip regardless). Idempotent per (tree, base).
acfw_publish_candidate() { # <root> <worktree> <forkbase> <key> [msg]
  local root="$1" wt="$2" base="$3" key="$4" msg="${5:-acfw candidate: $4}" tree p
  tree=$(git -C "$wt" rev-parse "HEAD^{tree}" 2>/dev/null) || return 1
  p=$(printf '%s\n\nACFW-Task: %s\n' "$msg" "$key" | git -C "$wt" commit-tree "$tree" -p "$base" 2>/dev/null) || return 1
  git -C "$root" update-ref "refs/acfw/patch/$key" "$p"
}

# acfw_integrated_keys <root> <committish> — print every integrated task key present in the tree
# of <committish>, one per line. Used by the scanner to build the integrated-set and by the loop's
# external-epoch check. Lists the ledger tree; basenames minus .json are the keys.
acfw_integrated_keys() { # <root> <committish>
  git -C "$1" ls-tree -r --name-only "$2" -- .acfwhip/integrated/ 2>/dev/null \
    | sed -n 's#^\.acfwhip/integrated/[^/]*/\(.*\)\.json$#\1#p'
}
