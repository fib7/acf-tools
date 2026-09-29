#!/usr/bin/env bash
# acfw-git.sh — shared git helpers for acf-whip.
#
# Source this from any acf-whip bin/ script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "$SCRIPT_DIR/../../lib/acfw-git.sh"
#
# Single source of truth for the lock-backoff primitive used by clean-checkout.sh,
# integrate-lpcas.sh, apply-transition.sh, and the orchestrator's own trunk writes.
#
# Shell safety: every acf-whip script runs under bash (`#!/usr/bin/env bash`), never
# zsh. Refspecs like "${BRANCH}:refs/acfw/${SLUG}" place a ':' immediately after a
# parameter expansion; zsh applies `:r`/`:e`/`:h` modifiers to such constructs even
# inside double quotes and silently corrupts the refspec. bash has no such syntax.
# Brace form "${VAR}:..." is used at every adjacency as belt-and-suspenders.

# Store-resolution helpers (config location, backend selection, adapter discovery)
# live in the sibling lib so every acfw-git.sh consumer gets them for free.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/acfw-store.sh"

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
#
# THIS FUNCTION MUST NEVER BE ABLE TO SHRINK A FILE TO A LOG ROW. It used to. Field incident
# 2026-08-24: a 17507-byte task document was replaced by this function's own 267-byte transition
# row, and apply-transition.sh committed the corpse 25 lines later. awk run against a file another
# process had momentarily emptied emits ONLY the new row; `[ -s "$tmp" ]` passes (a row is
# non-empty); `cat "$tmp" > "$file"` writes the one-line result over the task. The `else` fallback
# was no safer — `printf >> "$file"` on an empty or absent file CREATES the same corpse.
#
# Note what is NOT the bug, because the field report guessed wrong and the guess implies a wrong
# fix: a table-LESS input is fine. Every non-table line reaches the unconditional `print`, so such
# a file is emitted in full with the row appended at EOF (pinned by tests/phase3-reliability I3).
# ONLY a zero-byte read produces a lone row. Guarding "no table" would fix nothing and break a
# tested behavior. Four defenses, all aimed at the empty/absent read rather than at any one racer
# (the emptier was never identified — candidates are a sibling append_log_row's own truncation
# window, git rewriting the file under us, and an agent Write, and the fix must survive all three):
#   (1) REFUSE an empty/blank/absent input up front, and again inside awk (END: NR==0 -> exit 3),
#       which closes the TOCTOU between the two checks.
#   (2) ATOMIC same-directory rename instead of `cat > "$file"`, which was itself a 0-byte window
#       for every other reader (doctor field(), scan-backlog, the token grep, git add). The temp
#       MUST be born in dirname "$FILE": $TMPDIR is a different filesystem from the repo on macOS,
#       where mv degrades to copy+truncate and reopens the very window we are closing. This is the
#       idiom every other task-file writer already uses (acfw-store-files set_field/create/update).
#   (3) A first-line compare before the rename. onetrueawk does NOT report a stdout write error, so
#       ENOSPC can yield rc=0 with a half-written temp; line 1 always reaches the fall-through
#       `print`, so comparing it can never false-reject.
#   (4) The EOF fallback runs ONLY on a file proven healthy by (1) and untouched since.
#
# Temp name: dot-prefixed and NOT *.md, so a leftover after SIGKILL is invisible to every consumer
# glob — doctor.sh `"$d"/*.md` and `find -name '*.md'`, scan-backlog.sh's folder globs, and
# acfw-store-files resolve_task_file's `*"$q"*.md`.
#
# Returns: 0 the row is in FILE · 3 REFUSED (FILE absent/empty/blank, or emptied mid-read; FILE
#          untouched) · 1 environmental failure (FILE intact, row NOT written). Never 2, so a
#          caller can never confuse a refusal with a usage error. Callers historically ignored the
#          return and no acf-whip script runs `set -e`, so adopting it is opt-in per call site.
#
# HEADING and CAP (3.5.0): `append_log_row FILE ROW [HEADING] [CAP]`. HEADING (default "Transition
# Log") is matched by STRING EQUALITY against the heading text after "## " (trailing whitespace
# ignored), never as a regex: a heading is user-visible prose, and a regex metachar in it must not
# widen the match. CAP defaults to $ACFW_LOG_ROW_CAP; the literal `none` means unlimited and is
# checked BEFORE the cap<1 -> 1 clamp, because `none`+0 is 0 and would otherwise clamp to ONE row.
# That sentinel exists for audit trails (a cycle's Plan Log) that a user's ACFW_LOG_ROW_CAP must
# never truncate. Every 2-arg caller is byte-identical to before: same heading, same cap.
ACFW_LOG_ROW_CAP="${ACFW_LOG_ROW_CAP:-80}"
append_log_row() {
  local file="$1" row="$2" heading="${3:-Transition Log}" cap="${4:-$ACFW_LOG_ROW_CAP}" dir tmp arc

  # (1) Refusal gate. `[ -s ]` alone is defeated by a file holding only newlines — the same corpse
  # class — so test for a non-space byte. grep short-circuits on the first match; this is free.
  if [ ! -f "$file" ]; then
    echo "WARN: append_log_row: no such file: $file — row not logged: $row" >&2
    return 3
  fi
  if ! grep -q '[^[:space:]]' "$file" 2>/dev/null; then
    echo "FATAL: append_log_row refuses to write into an empty/blank file: $file (row: $row)" >&2
    return 3
  fi

  dir=$(dirname "$file")
  tmp=$(mktemp "$dir/.acfw-log.XXXXXX" 2>/dev/null) || tmp=""

  if [ -n "$tmp" ]; then
    # mktemp creates 0600; a git-tracked task file must stay group/other readable. "a+r" is NOT
    # masked by umask (a bare "+r" would be), so this lands deterministically regardless of the
    # caller's umask, and it is applied BEFORE the rename so the live file never has a 0600 window.
    chmod a+r,u+w "$tmp" 2>/dev/null || true

    # awk receives ROW/CAP via ENVIRON (no interpolation, so notes with awk/shell metachars are safe).
    # A "separator" row is one whose inter-pipe cells are only dashes/spaces (the markdown header rule);
    # a data row always has alphanumerics in its first cell, so the two never collide.
    ACFW_ROW="$row" ACFW_CAP="$cap" ACFW_HEAD="$heading" awk '
      BEGIN { row=ENVIRON["ACFW_ROW"]; want=ENVIRON["ACFW_HEAD"]
              unlimited = (ENVIRON["ACFW_CAP"] == "none")         # sentinel BEFORE the clamp
              cap=ENVIRON["ACFW_CAP"]+0; if (cap<1) cap=1
              inLog=0; inserted=0; body=0; dropped=0; out=0 }
      /^##[[:space:]]/ { h=$0; sub(/^##[[:space:]]+/, "", h); sub(/[[:space:]]+$/, "", h); inLog = (h == want) ? 1 : 0 }
      {
        if (inLog && !inserted && $0 ~ /^\|[ -]+\|/) {          # the header separator row
          print; out++; print row; out++; inserted=1; body=0; next
        }
        if (inLog && inserted && $0 ~ /^\|/) {                   # an existing body row (newest-first)
          body++; if (unlimited || body < cap) { print; out++ } else dropped++; next
        }
        if (inLog && inserted && $0 !~ /^\|/) inLog=0            # left the table body
        print; out++
      }
      END { if (NR == 0) exit 3                                  # empty read -> refuse, never a lone row
            if (!inserted) { print row; out++ }                  # no table -> append at EOF
            # out == NR+1-dropped is an IDENTITY given the branches above (every record either
            # prints itself once or increments dropped, and exactly one row is inserted), so this
            # cannot false-reject — verified against a legacy 200-row body at cap 5, multiple
            # "## Transition Log" headings, a separator preceding the heading, CRLF, and a final
            # line with no trailing newline. It is a canary for a FUTURE edit that breaks the
            # print/count pairing, NOT a data-integrity check. Do not read it as one.
            if (out != NR + 1 - dropped) exit 4 }
    ' "$file" > "$tmp"
    arc=$?

    if [ "$arc" -eq 0 ] && [ -s "$tmp" ] \
       && [ "$(head -n 1 "$tmp")" = "$(head -n 1 "$file")" ]; then
      # rename(2): no reader can observe a partial or zero-byte file, which is what `cat >` allowed.
      if mv -f "$tmp" "$file"; then return 0; fi
      echo "FATAL: append_log_row could not replace $file (rename failed) — row not logged: $row" >&2
      rm -f "$tmp"; return 1
    fi

    rm -f "$tmp"
    if [ "$arc" -eq 3 ]; then
      echo "FATAL: append_log_row: $file went empty between the check and the read — refusing to write a one-row file over it (row: $row)" >&2
      return 3
    fi
    echo "WARN: append_log_row: splice failed on $file (awk rc=$arc) — appending the row at EOF instead" >&2
  else
    echo "WARN: append_log_row: cannot create a temp in $dir (not writable?) — appending the row at EOF, non-atomically" >&2
  fi

  # (4) Fallback. Reached ONLY with a file that passed the refusal gate and that nothing here has
  # touched since, so it is byte-for-byte what it was and an EOF append is exactly the documented
  # no-table behavior. This is why the old `printf >> "$file"` cemented the damage and this cannot:
  # on an empty or absent file we already returned 3 above.
  if printf '%s\n' "$row" >> "$file"; then return 0; fi
  echo "FATAL: append_log_row: could not append to $file — row LOST: $row" >&2
  return 1
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
# Precedence: committed config > inherited env var > built-in default. The committed config is
# the source of truth (sourcing it overwrites any inherited env value); an env var only fills in a
# key the config does not pin. This is order-independent — safe to call before OR after another code
# path has already sourced the config (e.g. the timeout block in doctor.sh / scan-backlog.sh).
# The config file location is resolved by acfw_resolve_config_file (.acfwhip/config, falling back
# to the legacy .backlog/.acfw-config). Idempotent.
acfw_load_namespace() { # <repo-root>
  local _acfw_cfg=""
  [ -n "${1:-}" ] && _acfw_cfg=$(acfw_resolve_config_file "$1")
  [ -n "$_acfw_cfg" ] && . "$_acfw_cfg" >/dev/null 2>&1
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
