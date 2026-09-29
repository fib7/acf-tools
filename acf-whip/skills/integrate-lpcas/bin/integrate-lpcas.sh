#!/usr/bin/env bash
# integrate-lpcas.sh — LP-CAS (Ledger-In-Tree Compare-And-Swap) integrator (acf-whip 3.0.0).
#
# Lands ONE accepted task's changeset onto the live trunk so that the faults of the old
# rebase-into-cached-snapshot engine cannot arise by construction:
#   • no cached base ref (always observes the live trunk tip)           -> kills #1,#9,#10
#   • applies exactly ONE single-parent candidate, no rebase/replay      -> kills #3
#   • integration truth is an in-tree marker co-committed WITH the change -> kills #5,#7,#11,#16
#   • the union quality gate runs on the candidate tree before landing    -> kills #8
#   • conflicts are surfaced (resolver) not silently dropped; gated tree  -> kills #17
#   • a botched resolution fails a parse-sanity check as MECHANISM        -> kills #18 attribution
#   • CAS land via update-ref <new> <observed> rejects an external move   -> mechanism, not data loss
#
# Usage:
#   integrate-lpcas.sh <TASK_FILE>                  # initial attempt
#   integrate-lpcas.sh --post-resolver <TASK_FILE>  # resume after the caller dispatched a resolver
#
# Env (set by /go):
#   ACFW_TRUNK_ROOT      absolute path to the repo-root checkout (trunk lives here)
#   ACFW_TRUNK_BRANCH    the branch checked out at ACFW_TRUNK_ROOT
#   ACFW_GATE_CMD        (optional) union quality gate, run with CWD = candidate worktree; empty = pass
#   ACFW_PARSE_SANITY_CMD (optional) cheap parse/lint check on the candidate, run before the heavy
#                        gate (esp. after conflict resolution); empty = skip
#
# The worker must publish its change as a single-parent commit at refs/acfw/patch/<key>
# (key = task-id = TASK_FILE basename without .md). The integrator never reads markdown state.
#
# Outcomes are emitted as a machine-readable line on stdout: "ACFW-INTEGRATE: <verdict> ...".
# This script mutates ONLY git (trunk ref + an integration worktree) — never the .backlog markdown;
# deriving folder/views from git is the scanner/loop's job. A candidate's .backlog/ and docs/cycles/
# deltas are stripped before the fold (the latter with a WARN on stderr naming each path, and a second
# WARN when nothing but the marker is left to land): task state and plan cycles are never a task's
# deliverable.
#
# Exit codes:
#   0   integrated (marker+change now reachable from trunk) OR already-integrated (idempotent skip)
#   1   bad invocation / missing env
#   3   quarantine: malformed candidate (not single-parent) or poison (touches the ledger namespace)
#   4   no candidate ref refs/acfw/patch/<key> -> nothing to integrate (terminal skip)
#   6   quality-fault: the union gate failed on the candidate tree (NOT a mechanism failure)
#   7   resolver-needed: cherry-pick conflict; integration worktree left mid-cherry-pick for the resolver
#   9   mechanism fault: resolution-syntax-broken / unresolved conflict / worktree error (NOT a quality reject)
#   11  cas-lost: trunk moved/rewound under us between observe and land -> transient, caller re-observes
#   12  stall: trunk unobservable

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../../lib/acfw-git.sh"

# ---- Args ----
MODE="initial"
if [ "${1:-}" = "--post-resolver" ]; then MODE="post-resolver"; shift; fi
TASK_FILE="${1:-}"
[ -n "$TASK_FILE" ] || { echo "FATAL: integrate-lpcas.sh requires a TASK_FILE argument." >&2; exit 1; }
if [ -z "${ACFW_TRUNK_ROOT:-}" ] || [ -z "${ACFW_TRUNK_BRANCH:-}" ]; then
  echo "FATAL: ACFW_TRUNK_ROOT / ACFW_TRUNK_BRANCH must be set by /go before integration." >&2
  exit 1
fi

ROOT="$ACFW_TRUNK_ROOT"
TRUNK="$ACFW_TRUNK_BRANCH"
KEY="$(basename "$TASK_FILE" .md)"
SLUG=$(grep -E '^- \*\*Worktree\*\*:' "$TASK_FILE" 2>/dev/null | sed -E 's/.*Worktree\*\*:[[:space:]]*//' | tr -d '[:space:]')
[ -n "$SLUG" ] || SLUG="$KEY"
ASSIGNED_AGENT=$(grep -E '^- \*\*Assigned Agent\*\*:' "$TASK_FILE" 2>/dev/null | sed -E 's/.*Assigned Agent\*\*:[[:space:]]*//' | tr -d '[:space:]')

acfw_load_namespace "$ROOT"
MARKER="$(acfw_marker_path "$KEY")"
PATCH_REF="refs/acfw/patch/$KEY"
INTEG_WT="$ROOT/$ACFW_WORKTREE_DIR/_integrate/$KEY"
GATE_CMD="${ACFW_GATE_CMD:-}"
SANITY_CMD="${ACFW_PARSE_SANITY_CMD:-}"

emit() { echo "ACFW-INTEGRATE: $*"; }
cleanup_wt() { git -C "$ROOT" worktree remove --force "$INTEG_WT" >/dev/null 2>&1 || true; }

# Deterministic PRODUCER: publish the task's single-parent candidate from its worktree branch tip.
# This is the sanctioned worker emission point — it runs in the integrator (not an LLM specialist) so
# the candidate is a pure, reproducible function of (branch tree, fork-base) with no agent in the loop.
# candidate = commit-tree(branch^{tree}, parent=fork-base); cherry-pick of it applies exactly
# diff(fork-base, branch-tree) = the task's edits, onto the live trunk. No-op when no branch exists
# (a historical task already on trunk -> no candidate -> terminal skip). Idempotent per (tree, base).
publish_from_branch() {
  local branch="$ACFW_BRANCH_PREFIX/$SLUG" tree fb p
  git -C "$ROOT" show-ref --verify --quiet "refs/heads/$branch" || return 0
  tree=$(git -C "$ROOT" rev-parse --verify "$branch^{tree}" 2>/dev/null) || return 0
  fb=$(git -C "$ROOT" rev-parse --verify "refs/acfw/forkbase/$SLUG" 2>/dev/null) \
    || fb=$(git -C "$ROOT" merge-base "$branch" "$OBSERVED" 2>/dev/null) || return 0
  p=$(printf 'acfw candidate: %s\n\nACFW-Task: %s\n' "$KEY" "$KEY" \
      | git -C "$ROOT" commit-tree "$tree" -p "$fb" 2>/dev/null) || return 0
  git -C "$ROOT" update-ref "$PATCH_REF" "$p"
}

# Strip any .backlog/ delta from the staged candidate before commit: the integrated commit carries
# CODE + the ledger marker only. Normal candidates never touch .backlog (specialists are forbidden to
# commit it); this is a safety net for a legacy branch that imported trunk's .backlog history pre-3.0.0,
# so such a phantom can never ride into trunk via the fold. Restores .backlog to the observed trunk tree.
strip_backlog_from_index() {
  [ -e "$INTEG_WT/.backlog" ] || git -C "$INTEG_WT" cat-file -e "$OBSERVED:.backlog" 2>/dev/null || return 0
  # --no-overlay is REQUIRED. `git checkout <tree> -- <paths>` defaults to OVERLAY mode, which
  # "never removes files from the index or the working tree" — so a candidate that ADDS a
  # .backlog/X.md absent from OBSERVED survives this "strip", gets picked up by the `git add -A`
  # below, and rides into trunk. That is precisely the phantom this function exists to stop:
  # deletions and modifications were reverted, additions leaked.
  if ! git -C "$INTEG_WT" checkout --no-overlay "$OBSERVED" -- .backlog >/dev/null 2>&1; then
    # Not swallowed: a failed strip means the branch's whole .backlog delta is about to be folded
    # into trunk and overwrite live task state. Refuse the candidate instead (mechanism fault).
    emit "stall backlog-strip-failed key=$KEY"
    cleanup_wt
    exit 12
  fi
}

# Strip any docs/cycles/ delta the same way (3.5.0): TASKS NEVER EDIT CYCLES. A cycle folder is the
# human's spec (plan.md) plus acfw-cycle's stamp and audit trail (record.md), and approval is bound to
# the exact bytes of both at HEAD. A task that landed an edit there would re-arm an approval nobody
# asked to re-arm, forge a `## Tasks` row coverage is computed from, or renumber a D-id — and because
# land() resyncs every path a landing changed, it would also overwrite a human's uncommitted amendment
# to plan.md at the trunk root. So the candidate's cycle edits are DROPPED, never landed.
#
# Unlike .backlog (which a specialist is forbidden to commit, so a delta there is a legacy phantom),
# docs/cycles/ is reachable by an honest mistake ("tick the plan's checklist", "update the spec"), so
# the drop is REPORTED: one WARN on stderr naming every stripped path, next to land()'s own WARN. The
# content is not lost — refs/acfw/patch/<key> still holds it, and the WARN prints the diff to recover.
#
# The path list is taken against OBSERVED (worktree AND index AND untracked), not from the patch's own
# diff: a branch that merged trunk carries trunk's newer cycle commits in diff(fork-base, tip), and
# those are already on trunk — naming them would be a false alarm on every such task.
# Untracked files are cleaned too: the `git add -A` in build_gate_land would otherwise sweep a stray
# new file a resolver left under docs/cycles/ straight into the integration commit.
CYCLES_DIR="docs/cycles"
cycles_delta() { # paths under docs/cycles/ where INTEG_WT (worktree, index or untracked) differs from OBSERVED
  { git -C "$INTEG_WT" diff --name-only "$OBSERVED" -- "$CYCLES_DIR"
    git -C "$INTEG_WT" diff --cached --name-only "$OBSERVED" -- "$CYCLES_DIR"
    git -C "$INTEG_WT" ls-files --others --exclude-standard -- "$CYCLES_DIR"
  } 2>/dev/null | sort -u
}
strip_cycles_from_index() {
  local _paths
  _paths=$(cycles_delta)
  [ -n "$_paths" ] || return 0
  # First drop every UNMERGED cycle entry that OBSERVED does not have: the modify/delete conflict where
  # the task edited docs/cycles/<ID>/plan.md and trunk git rm'd that cycle meanwhile. `checkout
  # <tree> -- <path>` resolves an unmerged path only by writing the tree's version over it; with no
  # version in the tree it refuses the WHOLE call ("path ... is unmerged"), so without this every
  # attempt stalled with cycles-strip-failed (exit 12), /go retried it as transient forever, and the
  # task's code never landed. Removing the entry from the index is the drop itself (trunk has no such
  # file); the leftover worktree copy becomes untracked and the clean below deletes it. NUL-separated
  # and literal: a quoted (non-ASCII) name or a glob character would otherwise miss the entry and
  # bring the stall back for exactly that file.
  git -C "$INTEG_WT" diff --name-only -z --diff-filter=U -- "$CYCLES_DIR" 2>/dev/null \
    | while IFS= read -r -d '' _u; do
        git -C "$INTEG_WT" cat-file -e "$OBSERVED:$_u" 2>/dev/null \
          || git -C "$INTEG_WT" --literal-pathspecs rm -q --cached -f -- "$_u" >/dev/null 2>&1
      done
  # Restore tracked state to OBSERVED. --no-overlay for the same reason as the .backlog strip (an ADDED
  # file must be removed, not kept), and it also resolves an unmerged cycle path OBSERVED has, in
  # place. Guarded: with nothing under docs/cycles/ in OBSERVED or the index, the pathspec matches
  # nothing and git refuses, which here only means there is no tracked delta to restore.
  if git -C "$INTEG_WT" cat-file -e "$OBSERVED:$CYCLES_DIR" 2>/dev/null \
     || [ -n "$(git -C "$INTEG_WT" ls-files -- "$CYCLES_DIR" 2>/dev/null | head -1)" ]; then
    git -C "$INTEG_WT" checkout --no-overlay "$OBSERVED" -- "$CYCLES_DIR" >/dev/null 2>&1 || true
  fi
  git -C "$INTEG_WT" clean -fdq -- "$CYCLES_DIR" >/dev/null 2>&1 || true
  # Verified, not assumed: a strip that silently failed would fold a plan edit into trunk. Refuse the
  # candidate instead (mechanism fault, retried later), exactly like backlog-strip-failed.
  if [ -n "$(cycles_delta)" ]; then
    emit "stall cycles-strip-failed key=$KEY"
    cleanup_wt
    exit 12
  fi
  echo "WARN: $KEY: dropped this task's edits under $CYCLES_DIR/ (tasks never edit cycles; a plan changes only through /whip and acfw-cycle): $(printf '%s\n' "$_paths" | tr '\n' ' ')" >&2
  echo "WARN: $KEY: the dropped change is still in $PATCH_REF. See it: git -C $ROOT diff ${PATCH_PARENT:-<parent>} ${PATCH:-$PATCH_REF} -- $CYCLES_DIR" >&2
  # A candidate whose ONLY change was under docs/cycles/ now delivers nothing, yet still lands (the
  # marker alone) and still counts as integrated, so its deliverable reads done. The script can tell,
  # so it says so unconditionally instead of leaving the reader to infer it from the drop WARN.
  # "Nothing left" is measured against OBSERVED across index, worktree AND untracked files: after a
  # resolver the change can sit unstaged, and build_gate_land's `add -A` would still fold it in. In
  # the conflict path unmerged code paths differ from OBSERVED, so a code conflict never trips this.
  # The integration itself is not refused: exit 0 is what every caller already maps to "integrated",
  # and a new verdict would be an interface change for a case the WARN makes visible.
  if git -C "$INTEG_WT" diff --cached --quiet "$OBSERVED" 2>/dev/null \
     && git -C "$INTEG_WT" diff --quiet "$OBSERVED" 2>/dev/null \
     && [ -z "$(git -C "$INTEG_WT" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]; then
    echo "WARN: $KEY: after dropping $CYCLES_DIR/ this task delivers nothing: trunk gets its ledger marker and no content, so its deliverable reads done while nothing was built. If the plan itself needed the change, make it with /whip; if the work is still owed, create a task for it." >&2
  fi
}

# ---- Observe the live trunk tip (never cached). ----
OBSERVED=$(acfw_live_trunk "$ROOT" "$TRUNK") || { emit "stall trunk-unobservable"; exit 12; }

# snapshot_overwritten <path>... — print a commit whose tree is OBSERVED with exactly these paths as they
# sit on disk in ROOT right now (a path missing on disk is recorded as deleted). Built in a throwaway
# index, so it touches neither ROOT's index, its working tree nor refs/stash, and cannot race a
# sibling stage the way clean-checkout.sh's `stash push -u` would, or fail on a held index.lock the
# way `stash create` (which rewrites the real index) does. It replaced `stash create` for the
# recovery's sake: that snapshot was taken with HEAD already at NEW while the index still held
# OBSERVED, so its only obvious use, `stash apply`, replayed NEW -> OBSERVED+edits and reverted, in
# the root worktree, every OTHER path this landing changed (committing that tree un-lands the
# integration). Here diff(OBSERVED, snapshot) is precisely the overwritten work and nothing else, so
# the printed recovery is one pipe with no path list to quote. update-index (plumbing), not add:
# literal paths with no pathspec magic, no .gitignore refusal, and a missing file becomes a removal.
snapshot_overwritten() {
  local _td _t _c=""
  _td=$(mktemp -d "${TMPDIR:-/tmp}/acfw-preland.XXXXXX") || return 1
  if GIT_INDEX_FILE="$_td/index" git -C "$ROOT" read-tree "$OBSERVED" >/dev/null 2>&1; then
    printf '%s\0' "$@" | GIT_INDEX_FILE="$_td/index" git -C "$ROOT" update-index --add --remove -z --stdin >/dev/null 2>&1
    _t=$(GIT_INDEX_FILE="$_td/index" git -C "$ROOT" write-tree 2>/dev/null) \
      && _c=$(printf 'acf-whip pre-land snapshot: %s\n' "$KEY" | git -C "$ROOT" commit-tree "$_t" -p "$OBSERVED" 2>/dev/null)
  fi
  rm -rf "$_td"
  [ -n "$_c" ] && echo "$_c"
}

# ---- CAS land: advance trunk from OBSERVED to NEW atomically, then resync ROOT's working tree. ----
# update-ref's 3-arg form is the compare-and-swap: it succeeds ONLY if trunk is still exactly
# OBSERVED, rejecting both a concurrent advance and an external rewind (the latter would otherwise
# be masked by a fast-forward). On success ROOT (the trunk checkout) is resynced to the new tip.
land() { # <new-oid>
  local NEW="$1" _p _snap
  local -a _dirty
  if git -C "$ROOT" update-ref "refs/heads/$TRUNK" "$NEW" "$OBSERVED" 2>/dev/null; then
    # Resync ROOT in TWO steps, and never with `reset --hard`. Two defects motivated the split:
    #
    # (a) INDEX DESYNC (trunk corrupter). Between the update-ref above and the resync, ROOT's index
    #     still holds OBSERVED's tree while HEAD already points at NEW. A concurrent
    #     apply-transition.sh `git commit` builds from that index, producing a commit whose parent
    #     is NEW and whose tree is OBSERVED — silently reverting every code change we just landed.
    #     The old `>/dev/null 2>&1 || true` made this permanent whenever the resync itself failed
    #     (git_with_lock_backoff returns 99 on persistent lock contention) with nothing to repair
    #     it. The index repair is now unconditional and its failure is fatal rather than swallowed.
    #
    # (b) `reset --hard` rewrote .backlog/ too, discarding uncommitted task-file state at the root:
    #     the clean-checkout token row (which acfw-store-files calls uncommitted BY DESIGN, so this
    #     is the token-loss class whip-go.workflow.js already works around), and any operator repair
    #     made between runs. Excluding .backlog is a no-op on COMMITTED content by construction:
    #     strip_backlog_from_index restores .backlog to OBSERVED, and the 3-arg CAS above only lands
    #     if trunk is still exactly OBSERVED — so NEW's .backlog tree IS OBSERVED's. Excluding it
    #     can therefore only spare uncommitted work, never skip a real update.
    #
    # --no-overlay on the worktree step is REQUIRED: plain `checkout -- .` never removes files, so
    # every integration that deleted or renamed a path would leave a resurrected untracked copy —
    # invisible, since `git status` shows it as `??` and doctor.sh's dirty-trunk-root check skips
    # `??`. Floors: exclude pathspec >= git 1.9.0 (2014), --no-overlay >= 2.22 (2019).
    # ORDER MATTERS AND IS NOT THE OBVIOUS ONE. The checkout must run BEFORE the reset. Run
    # `reset --mixed` first and a path the integration DELETED becomes untracked at that instant;
    # `checkout` only manages tracked paths, so it can no longer remove it and the file is
    # resurrected on disk as an invisible `??` (doctor.sh's dirty-trunk-root check skips `??`).
    # Doing the checkout first — while the deleted path is still tracked at OBSERVED — lets
    # --no-overlay actually delete it. Verified: a rename lands as one file, not two.
    #
    # (c) THE PATHSPEC IS THIS LANDING'S OWN DIFF, not `.`, and that is correctness rather than
    #     economy. `-- .` reverts the ENTIRE root working tree, and a `Worktree: none` task edits
    #     tracked files in that very tree by design. Those agents run CONCURRENTLY with this code:
    #     whip-go.workflow.js starts the prior-integrate pass as a floating promise and awaits it
    #     only AFTER the dispatch barrier that runs directQ, so a direct task's uncommitted work was
    #     reverted mid-flight; the writer then staged an unchanged file, the committed-deliverable
    #     check passed against the file's pre-existing history, and the task was reported accepted
    #     with none of its content anywhere. Restricting the checkout to the paths OBSERVED..NEW
    #     actually touched resyncs everything this landing changed and nothing it did not.
    CHANGED_PATHS=()
    while IFS= read -r -d '' _p; do CHANGED_PATHS+=("$_p"); done < <(
      git -C "$ROOT" diff --name-only -z "$OBSERVED" "$NEW" -- . ':(exclude).backlog' 2>/dev/null)
    # An EMPTY pathspec means `-- .`, i.e. (c) restored in full, so the guard is structural. It is a
    # shell test and not an `xargs -r` pipeline because BSD xargs has no -r and would run git anyway.
    if [ ${#CHANGED_PATHS[@]} -gt 0 ]; then
      # Snapshot uncommitted work on the paths about to be overwritten — the residual same-file case
      # (c) cannot avoid — with snapshot_overwritten above. Reported, never auto-applied: the
      # operator owns the merge.
      # "Uncommitted" means different from what the root held BEFORE this landing, i.e. from OBSERVED.
      # It was `git status --porcelain`, which compares against HEAD: the CAS above has already moved
      # HEAD to NEW while the index still holds OBSERVED, so status listed EVERY path this landing
      # changed as staged and the WARN fired on every integration, with a snapshot of work that never
      # existed. Worktree-vs-OBSERVED sees staged and unstaged edits alike; an untracked file sitting
      # on a path the landing adds is overwritten by the checkout below too, so it counts. The two
      # lists are disjoint (tracked vs untracked), so no de-dup; NUL-separated so a non-ASCII name
      # reaches the snapshot as itself rather than core.quotePath's quoted form.
      _dirty=()
      while IFS= read -r -d '' _p; do _dirty+=("$_p"); done < <(
        { git -C "$ROOT" diff --name-only -z "$OBSERVED" -- "${CHANGED_PATHS[@]}"
          git -C "$ROOT" ls-files -z --others --exclude-standard -- "${CHANGED_PATHS[@]}"
        } 2>/dev/null)
      if [ ${#_dirty[@]} -gt 0 ]; then
        _snap=$(snapshot_overwritten "${_dirty[@]}" || true)
        # The recovery re-applies ONLY the overwritten edits on top of the landed content, as a 3-way
        # merge (a same-line clash leaves conflict markers, never a silent pick); -3 implies --index,
        # so the recovered edits come back staged. Quoted with %q: ROOT can contain spaces.
        if [ -n "$_snap" ]; then
          echo "WARN: landing $KEY overwrote uncommitted work in $ROOT on ${#_dirty[@]} path(s) it also changed. Snapshot: $_snap; one path as it was: git show $_snap:<path>. The command below re-applies only your edits on top of the landed content, 3-way (a clash leaves conflict markers) and staged. Recover: git -C $(printf '%q' "$ROOT") diff --binary $OBSERVED $_snap | git -C $(printf '%q' "$ROOT") apply -3" >&2
        else
          echo "WARN: landing $KEY overwrote uncommitted work in $ROOT on ${#_dirty[@]} path(s) it also changed. Snapshot: UNAVAILABLE (the pre-land snapshot could not be written); that work is not recoverable from git." >&2
        fi
      fi
      git_with_lock_backoff -C "$ROOT" checkout --no-overlay -q "$TRUNK" -- "${CHANGED_PATHS[@]}" >/dev/null 2>&1 \
        || echo "WARN: root worktree resync incomplete after landing $KEY (the index is still repaired below). Run: git -C $ROOT checkout --no-overlay -q $TRUNK -- \$(git -C $ROOT diff --name-only $OBSERVED $NEW -- . ':(exclude).backlog')" >&2
    fi
    # The index repair is the one that must not be skipped, so it runs unconditionally and its
    # failure is fatal: a stale index is what forges a tree-reverting commit (a) above.
    if ! git_with_lock_backoff -C "$ROOT" reset --mixed "$TRUNK" >/dev/null 2>&1; then
      emit "stall root-index-desync key=$KEY trunk=$NEW — ROOT's index still holds $OBSERVED while HEAD is $NEW; the next .backlog commit would revert this integration. Run: git -C $ROOT reset --mixed $TRUNK"
      cleanup_wt
      exit 12
    fi
    cleanup_wt
    emit "integrated key=$KEY trunk=$NEW"
    exit 0
  fi
  cleanup_wt
  emit "cas-lost key=$KEY observed=$OBSERVED now=$(git -C "$ROOT" rev-parse "$TRUNK" 2>/dev/null)"
  exit 11
}

# ---- Build (marker co-commit) + sanity + union gate + land. Called when the candidate worktree
#      INTEG_WT holds the applied changeset staged/clean (no commit yet). ----
build_gate_land() {
  strip_backlog_from_index
  strip_cycles_from_index
  mkdir -p "$INTEG_WT/$(dirname "$MARKER")"
  printf '{"key":"%s","patch":"%s","patch_parent":"%s","observed_trunk":"%s","slug":"%s"}\n' \
    "$KEY" "$PATCH" "$PATCH_PARENT" "$OBSERVED" "$SLUG" > "$INTEG_WT/$MARKER"
  git -C "$INTEG_WT" add -A

  # Parse/lint sanity BEFORE the heavy gate: a botched conflict resolution (e.g. unbalanced braces)
  # surfaces here as a MECHANISM fault (resolution-syntax-broken), never as a coverage regression (#18).
  if [ -n "$SANITY_CMD" ]; then
    if ! ( cd "$INTEG_WT" && set -o pipefail; eval "$SANITY_CMD" ) >/dev/null 2>&1; then
      cleanup_wt; emit "mechanism resolution-syntax-broken key=$KEY"; exit 9
    fi
  fi

  # The change AND its ledger marker enter trunk in ONE single-parent commit (parent = OBSERVED):
  # "marker reachable IFF change reachable" — a bookkeeping commit can never become the integration
  # point and the feature can never be silently absent while marked done (#16).
  git -C "$INTEG_WT" commit -q -m "integrate: $KEY" -m "ACFW-Task: $KEY" -m "ACFW-Patch: $PATCH" \
    || { cleanup_wt; emit "mechanism empty-commit key=$KEY"; exit 9; }
  local NEW; NEW=$(git -C "$INTEG_WT" rev-parse HEAD)

  # Union gate on the actual candidate tree (trunk + change), via direct exec with pipefail so a
  # gate's non-zero exit is the verdict and can never be masked by a display pipe (#12). Fail =
  # QUALITY fault (not mechanism): the merged result is bad code.
  if [ -n "$GATE_CMD" ]; then
    if ! ( cd "$INTEG_WT" && set -o pipefail; eval "$GATE_CMD" ) >/dev/null 2>&1; then
      cleanup_wt; emit "quality-fault key=$KEY"; exit 6
    fi
  fi

  land "$NEW"
}

# ================= post-resolver mode =================
# Resolver protocol: the dispatched agent resolves conflict markers and `git add`s the files in
# INTEG_WT (it does NOT run cherry-pick --continue/commit — the integrator owns the commit). The
# signal of an unfinished resolution is therefore UNMERGED PATHS, not the lingering CHERRY_PICK_HEAD
# that `cherry-pick --no-commit` always leaves after a conflict. Any remaining unmerged path = the
# resolver gave up -> mechanism (never a quality reject). Otherwise clear the sequencer state and
# proceed to the SAME build/sanity/gate/land path as a clean apply.
if [ "$MODE" = "post-resolver" ]; then
  [ -d "$INTEG_WT" ] || { emit "mechanism no-integration-worktree key=$KEY"; exit 9; }
  # RE-PIN THE CAS BASE to the base this candidate was actually BUILT on.
  #
  # OBSERVED was read at the top of THIS process, from the live trunk tip. But INTEG_WT was detached
  # at the tip the PREVIOUS process saw (the initial attempt, before the conflict), and nothing since
  # has moved it: `cherry-pick --no-commit` does not move HEAD, and neither does `--quit`. So the
  # commit build_gate_land is about to create is parented on the OLD tip, while land() would
  # compare-and-swap against the NEW one.
  #
  # Those are different refs, and the CAS would SUCCEED — update-ref's 3-arg form checks only that
  # trunk still equals the value handed to it, not that the new commit descends from it. Trunk would
  # be force-moved to a commit whose ancestry skips every commit made while the resolver agent
  # worked: other tasks' integrations, their ledger markers, and (on the files store, where
  # apply-transition.sh commits to trunk on a different serialization chain than integrate) every
  # .backlog state transition in that window. They leave trunk with nothing said about it, and
  # land()'s own resync then deletes their files from the working tree as "changed paths".
  #
  # The resolver window is an LLM agent run, so trunk moving inside it is ordinary, not exotic.
  # Taking the base from the worktree makes the CAS ask the right question: a moved trunk now fails
  # it and exits 11 cas-lost, which the caller already treats as transient and retries.
  OBSERVED=$(git -C "$INTEG_WT" rev-parse --verify HEAD 2>/dev/null) \
    || { emit "mechanism integration-worktree-headless key=$KEY"; exit 9; }
  if [ -n "$(git -C "$INTEG_WT" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    cleanup_wt; emit "mechanism conflict-unresolved key=$KEY"; exit 9
  fi
  git -C "$INTEG_WT" cherry-pick --quit >/dev/null 2>&1 || true   # clear sequencer, keep staged index
  PATCH=$(git -C "$ROOT" rev-parse --verify "$PATCH_REF^{commit}" 2>/dev/null || echo "")
  PATCH_PARENT=$(git -C "$ROOT" rev-parse "$PATCH^" 2>/dev/null || echo "")
  build_gate_land
fi

# ================= initial mode =================
# O(1) already-integrated check — idempotent skip (covers re-runs and re-queued integrated work, #4).
if acfw_is_integrated "$ROOT" "$OBSERVED" "$KEY"; then
  emit "already-integrated key=$KEY"; exit 0
fi

# Publish the candidate deterministically from the task's worktree branch (the producer step).
publish_from_branch

# Candidate must exist. Absent ref = nothing to integrate (historical / not-yet-built) -> terminal skip.
PATCH=$(git -C "$ROOT" rev-parse --verify "$PATCH_REF^{commit}" 2>/dev/null) || { emit "no-candidate key=$KEY"; exit 4; }

# Candidate must be single-parent (so cherry-pick's 3-way base is the candidate's own parent, never
# a merge-base computed against trunk). rev-list --parents -n1 prints "<commit> <p1> [<p2>...]".
NPARENTS=$(git -C "$ROOT" rev-list --parents -n1 "$PATCH" | wc -w | tr -d ' ')
if [ "$NPARENTS" != "2" ]; then
  emit "quarantine malformed-candidate key=$KEY parents=$((NPARENTS-1))"; exit 3
fi
PATCH_PARENT=$(git -C "$ROOT" rev-parse "$PATCH^")

# Poison guard: a candidate may never write the ledger namespace (only the integrator does).
if git -C "$ROOT" diff --name-only "$PATCH_PARENT" "$PATCH" | grep -q '^\.acfwhip/integrated/'; then
  emit "quarantine poison-ledger-write key=$KEY"; exit 3
fi

# Fresh integration worktree at the OBSERVED live trunk tip.
cleanup_wt
mkdir -p "$(dirname "$INTEG_WT")"
git -C "$ROOT" worktree add --detach -q "$INTEG_WT" "$OBSERVED" \
  || { emit "mechanism worktree-add-failed key=$KEY"; exit 9; }

# Apply EXACTLY ONE changeset onto live trunk. cherry-pick of a single-parent commit uses that
# commit's own parent as the 3-way base — no rebase, no replay, no merge-base vs trunk.
if git -C "$INTEG_WT" cherry-pick --no-commit "$PATCH" >/dev/null 2>&1; then
  build_gate_land
else
  # Genuine conflict (e.g. another task already touched these lines, #17): SURFACE it as a mechanism
  # event for the resolver — never a silent drop, never a quality reject. Leave the worktree
  # mid-cherry-pick so the caller can dispatch the assigned agent into it and re-invoke --post-resolver.
  CONFLICTED=$(git -C "$INTEG_WT" diff --name-only --diff-filter=U 2>/dev/null || true)
  # A conflict inside docs/cycles/ is not worth an agent: build_gate_land drops every cycle path, so a
  # resolver would be dispatched to merge text that is then thrown away (and handed a human's plan to
  # edit). Strip first. If nothing else conflicts, this is a clean apply after all; otherwise the
  # resolver only ever sees the code conflicts.
  if printf '%s\n' "$CONFLICTED" | grep -q "^$CYCLES_DIR/"; then
    strip_cycles_from_index
    CONFLICTED=$(git -C "$INTEG_WT" diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -z "$CONFLICTED" ]; then
      git -C "$INTEG_WT" cherry-pick --quit >/dev/null 2>&1 || true   # clear sequencer, keep staged index
      build_gate_land
    fi
  fi
  emit "resolver-needed key=$KEY"
  echo "worktree: $INTEG_WT"
  echo "assigned_agent: $ASSIGNED_AGENT"
  echo "conflicted_files:"
  echo "$CONFLICTED"
  exit 7
fi
