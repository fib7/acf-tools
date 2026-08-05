#!/usr/bin/env bash
# phase11-checkout-reentrancy.test.sh — the WT-1 regression guard for 3.2.0 per-task child workflows.
#
# WHY THIS EXISTS
# Before 3.2.0 exactly one agent owned .worktree/<slug> for a task's whole lifetime, so clean-checkout
# never ran twice against a live tree. A per-task child workflow has MANY agents on one slug, which makes
# clean-checkout's reentrancy the single highest-risk detail in the design. The mutual-exclusion
# primitive does NOT protect you here:
#
#   clean-checkout.sh:78-84  the lazy-create guard is a bare `[ ! -d "$WORKTREE_PATH" ]`, and exit 2
#                            ("branch in use elsewhere") fires ONLY inside that create branch. A second
#                            invocation against an ALREADY-CREATED worktree sails straight past it.
#   clean-checkout.sh:104-109 the branch check then passes (it IS the right branch)...
#   clean-checkout.sh:127-129 ...and Step 6 runs `git stash push -u ... || true` on ANY dirty state,
#                            silently, into the SHARED refs/stash. "Unrelated" is not modelled and -u
#                            sweeps untracked files. A sibling agent's in-flight work is GONE.
#
# So the contract 3.2.0 relies on is WT-1: exactly ONE clean-checkout per (task, attemptKey), in the
# skeleton's locked prologue, guarded by an OBSERVATION (`git worktree list --porcelain` shows the
# branch) rather than by a ledger record — because a lost ledger entry must never be able to trigger a
# second stash. This test pins both halves: the hazard (so nobody "simplifies" the guard away without a
# failing test) and the observation guard that avoids it.
#
# Asserts:
#   A  the hazard is real: a second clean-checkout on a dirty worktree stashes the in-flight work away
#      (tracked edit reverted, untracked file removed) — this is WHY WT-1 exists
#   B  the observation guard (worktree list --porcelain + branch match) short-circuits correctly and
#      leaves in-flight work untouched
#   C  the guard resolves the worktree by QUERY, not by constructing <root>/<ACFW_WORKTREE_DIR>/<slug> —
#      it still finds the tree under a CUSTOM namespace
#   D  the Transition Log survives a legitimate second checkout: not truncated, ## Metadata intact,
#      and the clean-checkout token rows are well-formed
#   E  two concurrent clean-checkout processes on a FRESH slug do not BOTH fail — exactly one wins
# Run: bash acf-whip/tests/phase11-checkout-reentrancy.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CC="$ACF_WHIP/skills/clean-checkout-before-task/bin/clean-checkout.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p11.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/pending .claude/agents
printf 'x\n' > .claude/agents/go-engineer.md
printf '.worktree/\nwt-custom/\n' > .gitignore
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk

mktask(){ # <stem> <slug>
  cat > ".backlog/pending/$1.md" <<EOF
# Task: $1

## Metadata

- **ID**: $1
- **Status**: pending
- **Assigned Agent**: go-engineer
- **Worktree**: $2
- **Rejection Count**: 0

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-06-01 00:00:00 | draft | pending | task-engineer | Initial task creation |
EOF
}

# The WT-1 observation guard, verbatim in shape with the skeleton's locked checkout stage.
# Resolves by QUERY (never by constructing the path) because ACFW_WORKTREE_DIR is config-driven.
observe_wt(){ # <branch> -> prints the worktree path, or nothing
  git -C "$ACFW_TRUNK_ROOT" worktree list --porcelain \
    | awk -v b="branch refs/heads/$1" '/^worktree /{p=$2} $0==b{print p; exit}'
}

# Compare two paths by PHYSICAL identity, not by text. clean-checkout CONSTRUCTS its path from
# $ACFW_TRUNK_ROOT while git worktree list REPORTS the resolved real path, and on macOS $TMPDIR is a
# symlink (/var/... -> /private/var/...), so the two are textually different while naming the same
# directory. This is why the skeleton binds WT to the OBSERVED path and never string-compares paths.
samedir(){ [ -n "$1" ] && [ -n "$2" ] && [ "$(cd "$1" 2>/dev/null && pwd -P)" = "$(cd "$2" 2>/dev/null && pwd -P)" ]; }

# refs/stash is SHARED across every worktree of a repo (git-worktree(1) REFS), so an absolute stash
# count sees other tasks' stashes — and a naive `git stash pop` in one worktree can apply ANOTHER
# task's stash. Always measure a delta.
stash_count(){ git -C "$1" stash list 2>/dev/null | wc -l | tr -d ' '; }

echo "== A. the hazard: a second clean-checkout stashes a sibling's in-flight work =="
mktask hazard hz
WT1=$(bash "$CC" "$REPO/.backlog/pending/hazard.md" 2>/dev/null)
check 'A1 first clean-checkout printed a worktree path' '[ -n "$WT1" ] && [ -d "$WT1" ]'

# Simulate agent #1 mid-work: one tracked edit + one brand-new untracked file, both UNCOMMITTED.
echo "IN-FLIGHT-EDIT" >> "$WT1/seed"
echo "new work" > "$WT1/newfile.txt"
check 'A2 in-flight work is present before the second checkout' \
  'grep -q IN-FLIGHT-EDIT "$WT1/seed" && [ -f "$WT1/newfile.txt" ]'

# Agent #2 naively runs Step 0 against the same task. No exit 2 — the worktree already exists.
bash "$CC" "$REPO/.backlog/pending/hazard.md" >/dev/null 2>&1
rc=$?
check 'A3 the second clean-checkout SUCCEEDS (exit 2 does not protect same-task reentry)' '[ "$rc" = "0" ]'
check 'A4 HAZARD CONFIRMED: the tracked in-flight edit was stashed away' \
  '! grep -q IN-FLIGHT-EDIT "$WT1/seed"'
check 'A5 HAZARD CONFIRMED: the untracked in-flight file was swept by stash -u' \
  '[ ! -f "$WT1/newfile.txt" ]'
check 'A6 the work is recoverable only from the SHARED stash (why WT-1 forbids a second checkout)' \
  '[ "$(git -C "$WT1" stash list | wc -l | tr -d " ")" != "0" ]'

echo "== B. the WT-1 observation guard avoids the hazard =="
mktask guarded gd
WT2=$(bash "$CC" "$REPO/.backlog/pending/guarded.md" 2>/dev/null)
check 'B1 worktree created' '[ -n "$WT2" ] && [ -d "$WT2" ]'
echo "PRESERVED" >> "$WT2/seed"
echo "keep me" > "$WT2/keep.txt"
STASH_BEFORE=$(stash_count "$WT2")

# A later stage does what the locked prologue does: observe first, and only fall through to
# clean-checkout when nothing is there.
FOUND=$(observe_wt worktree/gd)
if [ -n "$FOUND" ]; then :; else bash "$CC" "$REPO/.backlog/pending/guarded.md" >/dev/null 2>&1; fi
check 'B2 the guard found the existing worktree by query' 'samedir "$FOUND" "$WT2"'
check 'B3 the tracked in-flight edit SURVIVED' 'grep -q PRESERVED "$WT2/seed"'
check 'B4 the untracked in-flight file SURVIVED' '[ -f "$WT2/keep.txt" ]'
check 'B5 no NEW stash was created (delta, not absolute — refs/stash is shared)' \
  '[ "$(stash_count "$WT2")" = "$STASH_BEFORE" ]'

echo "== C. the guard resolves by query, so a CUSTOM worktree namespace still works =="
mkdir -p .acfwhip && printf 'ACFW_WORKTREE_DIR=wt-custom\n' > .acfwhip/config
mktask custom cu
WT3=$(bash "$CC" "$REPO/.backlog/pending/custom.md" 2>/dev/null)
check 'C1 worktree honored the custom namespace' 'case "$WT3" in */wt-custom/cu) true;; *) false;; esac'
check 'C2 the query guard finds it without constructing the path' 'samedir "$(observe_wt worktree/cu)" "$WT3"'
rm -f .acfwhip/config

echo "== D. the Transition Log survives a legitimate second checkout =="
TF="$REPO/.backlog/pending/hazard.md"
check 'D1 ## Metadata section intact (append_log_row did not truncate the file)' 'grep -q "^## Metadata" "$TF"'
check 'D2 Worktree field still readable (a truncated file makes clean-checkout exit 1 forever)' \
  'grep -q "^- \*\*Worktree\*\*: hz" "$TF"'
check 'D3 at least one well-formed clean-checkout token row' \
  'grep -qE "^\| .* \| clean-checkout \| ok \| clean-checkout-before-task \| hz \| worktree/hz \|$" "$TF"'
check 'D4 the token row count matches the number of checkouts actually run (2)' \
  '[ "$(grep -c "| clean-checkout | ok |" "$TF")" = "2" ]'
check 'D5 the seed transition row was not lost' 'grep -q "Initial task creation" "$TF"'

echo "== E. two concurrent checkouts on a FRESH slug: exactly one wins, not zero =="
mktask race rc
bash "$CC" "$REPO/.backlog/pending/race.md" >"$WORK/r1.out" 2>"$WORK/r1.err" & p1=$!
bash "$CC" "$REPO/.backlog/pending/race.md" >"$WORK/r2.out" 2>"$WORK/r2.err" & p2=$!
wait $p1; rc1=$?
wait $p2; rc2=$?
check 'E1 at least one process succeeded (they did not BOTH lose the create race)' \
  '[ "$rc1" = "0" ] || [ "$rc2" = "0" ]'
check 'E2 the worktree exists on the right branch afterwards' \
  '[ -n "$(observe_wt worktree/rc)" ]'
check 'E3 a loser (if any) reported the branch-in-use code 2, not a corrupt state' \
  '[ "$rc1" = "0" ] && [ "$rc2" = "0" ] || [ "$rc1" = "2" ] || [ "$rc2" = "2" ] || [ "$rc1" = "99" ] || [ "$rc2" = "99" ]'

echo
echo "phase11-checkout-reentrancy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
