#!/usr/bin/env bash
# phase11-checkout-reentrancy.test.sh — the WT-1 regression guard for 3.2.0 per-task child workflows.
#
# WHY THIS EXISTS
# Before 3.2.0 exactly one agent owned .worktree/<slug> for a task's whole lifetime, so clean-checkout
# never ran twice against a live tree. A per-task child workflow has MANY agents on one slug, which makes
# clean-checkout's reentrancy the single highest-risk detail in the design. The mutual-exclusion
# primitive does NOT protect you here:
#
#   clean-checkout.sh:88-179 the lazy-create guard is a bare `[ ! -d "$WORKTREE_PATH" ]`, and exit 2
#                            ("branch in use elsewhere") fires ONLY inside that create/re-attach
#                            branch. A second invocation against an ALREADY-CREATED worktree sails
#                            straight past it.
#   clean-checkout.sh:195-201 the branch check then passes (it IS the right branch)...
#   clean-checkout.sh:218-222 ...and Step 6 runs `git stash push -u ... || true` on ANY dirty state,
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
#   F  a branch that OUTLIVED its worktree directory is re-attached, not refused: whip-go re-records a
#      lost token only by re-running clean-checkout, so the old exit 2 here livelocked the task. The
#      branch keeps its commits, and the fork-base is the real fork point, never today's trunk tip
#   G  a branch checked out in ANOTHER worktree still exits 2, and stderr names that worktree
#   H  only the FIRST `- **Worktree**:` line is the slug: a store comment restating the field no longer
#      glues a second slug on (`api` + `api` = `apiapi`)
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
# WHIP-23: this block has ALWAYS run two concurrent append_log_row calls against race.md (both
# checkouts log their token into the same root task file) and asserted only exit codes — the suite
# executed the corruption scenario and looked away from the file. A 2026-08-24 field incident
# turned that blind spot into a destroyed 17KB task document. Assert the file itself now.
RF="$REPO/.backlog/pending/race.md"
check 'E4 race.md survived two concurrent append_log_row calls (metadata intact)' \
  'grep -q "^- \*\*ID\*\*:" "$RF" && grep -q "^- \*\*Status\*\*:" "$RF"'
check 'E5 race.md was NOT collapsed to a bare log row' \
  '[ "$(grep -c "^#" "$RF")" -gt 0 ]'
check 'E6 the seed transition row was not lost to the race' \
  'grep -q "Initial task creation" "$RF"'
check 'E7 no .acfw-log temp left behind by the losing writer' \
  '[ -z "$(ls -a "$REPO/.backlog/pending" | grep "^\.acfw-log\." || true)" ]'

echo "== F. a branch that outlived its worktree directory is re-attached, untouched =="
# The field livelock: the worktree directory was gone, the branch survived, and `add -b` cannot create
# a branch that exists — exit 2 "another agent owns branch", on every re-dispatch, for a branch nobody
# had checked out.
mktask reattach ra
RAF="$REPO/.backlog/pending/reattach.md"
WTF=$(bash "$CC" "$RAF" 2>/dev/null)
FORK0=$(git -C "$REPO" rev-parse trunk)
echo "ra work" > "$WTF/ra-work.txt"; git -C "$WTF" add ra-work.txt; git -C "$WTF" commit -qm "feat: ra work"
RA_SHA=$(git -C "$REPO" rev-parse worktree/ra)
# Trunk moves on, so "the fork point" and "today's trunk tip" are different commits.
echo adv > trunk-adv; git add trunk-adv; git commit -qm "trunk advances"
# The reaper removes the worktree (directory AND registration); the branch survives. Drop the fork-base
# too, as for a worktree made before 3.0.0, so the re-attach has to derive one.
git -C "$REPO" worktree remove --force "$WTF"
git -C "$REPO" update-ref -d refs/acfw/forkbase/ra
# A re-attached tree is a fresh checkout, so hydration must run on it like on a created one.
echo cfg > local.cfg; echo local.cfg >> .git/info/exclude; printf 'copy: local.cfg\n' > .worktreeinclude
OUT=$(bash "$CC" "$RAF" 2>"$WORK/f.err"); rc=$?
rm -f .worktreeinclude
check 'F1 re-attach exits 0 (it used to exit 2 for a branch nobody had checked out)' '[ "$rc" = "0" ]'
check 'F2 stdout is exactly the worktree path and nothing else' '[ "$OUT" = "$REPO/.worktree/ra" ]'
check 'F3 the re-attached worktree is on the task branch' \
  '[ "$(git -C "$OUT" branch --show-current)" = worktree/ra ]'
check 'F4 the branch was NOT reset or rebased (its tip is still the task commit)' \
  '[ "$(git -C "$REPO" rev-parse worktree/ra)" = "$RA_SHA" ]'
check 'F5 the committed task work is in the re-attached tree' '[ -f "$OUT/ra-work.txt" ]'
check 'F6 fork-base backfilled to the real fork point (merge-base), NOT the current trunk tip' \
  '[ "$(git -C "$REPO" rev-parse refs/acfw/forkbase/ra)" = "$FORK0" ] && [ "$FORK0" != "$(git -C "$REPO" rev-parse trunk)" ]'
check 'F7 the re-attached tree was hydrated from .worktreeinclude' '[ -f "$OUT/local.cfg" ]'
check 'F8 the re-attach logged its clean-checkout token (the whole point of re-dispatching)' \
  '[ "$(grep -c "| clean-checkout | ok | clean-checkout-before-task | ra | worktree/ra |" "$RAF")" = "2" ]'

# The directory is deleted by hand WITHOUT a prune: the registration survives and names THIS path, and
# git refuses a plain add there ("missing but already registered worktree").
FB_BEFORE=$(git -C "$REPO" rev-parse refs/acfw/forkbase/ra)
rm -rf "$REPO/.worktree/ra"
OUT=$(bash "$CC" "$RAF" 2>"$WORK/f2.err"); rc=$?
check 'F9 a dead registration of the SAME path is re-attached too' \
  '[ "$rc" = "0" ] && [ "$OUT" = "$REPO/.worktree/ra" ] && [ "$(git -C "$OUT" branch --show-current)" = worktree/ra ]'
check 'F10 ...with the branch tip untouched' '[ "$(git -C "$REPO" rev-parse worktree/ra)" = "$RA_SHA" ]'
check 'F11 the branch is registered exactly once afterwards (the dead registration was dropped)' \
  '[ "$(git -C "$REPO" worktree list --porcelain | grep -cx "branch refs/heads/worktree/ra")" = "1" ]'
check 'F12 a recorded fork-base that IS an ancestor of the branch is kept' \
  '[ "$(git -C "$REPO" rev-parse refs/acfw/forkbase/ra)" = "$FB_BEFORE" ]'

# A fork-base that is NOT an ancestor of the branch belongs to an earlier branch of the slug; used as
# the candidate's parent it would carry changes that are not this branch's.
git -C "$REPO" worktree remove --force "$REPO/.worktree/ra"
git -C "$REPO" update-ref refs/acfw/forkbase/ra trunk
bash "$CC" "$RAF" >/dev/null 2>&1; rc=$?
check 'F13 a non-ancestor fork-base is replaced by the merge-base on re-attach' \
  '[ "$rc" = "0" ] && [ "$(git -C "$REPO" rev-parse refs/acfw/forkbase/ra)" = "$FORK0" ]'

echo "== G. a branch checked out in ANOTHER worktree still exits 2, and says where =="
mktask owned ow
OWF="$REPO/.backlog/pending/owned.md"
OTHER="$WORK/other place/ow"   # a space in the path: the porcelain parse must keep the whole line
git -C "$REPO" worktree add -q "$OTHER" -b worktree/ow trunk
OTHER_PHYS=$(cd "$OTHER" && pwd -P)
OUT=$(bash "$CC" "$OWF" 2>"$WORK/g.err"); rc=$?
check 'G1 exit 2 (the branch really is in use elsewhere)' '[ "$rc" = "2" ]'
check 'G2 nothing on stdout' '[ -z "$OUT" ]'
check 'G3 stderr names the worktree that holds the branch, spaces and all' \
  'grep -qF "checked out in the worktree at $OTHER_PHYS." "$WORK/g.err"'
check 'G4 no second worktree was created for the slug' '[ ! -e "$REPO/.worktree/ow" ]'
# That directory is then deleted without a prune. Still exit 2 (the registration is not this path), but
# the message now says what clears it; after the prune the branch re-attaches normally.
rm -rf "$WORK/other place"
bash "$CC" "$OWF" >/dev/null 2>"$WORK/g2.err"; rc=$?
check 'G5 a dead registration ELSEWHERE exits 2 and names the remedy' \
  '[ "$rc" = "2" ] && grep -q "git worktree prune" "$WORK/g2.err"'
git -C "$REPO" worktree prune
OUT=$(bash "$CC" "$OWF" 2>/dev/null); rc=$?
check 'G6 after the prune the branch is re-attached at the slug path' \
  '[ "$rc" = "0" ] && [ "$OUT" = "$REPO/.worktree/ow" ]'

echo "== H. only the FIRST Worktree: line is the slug =="
# A materialized non-files spec appends the store's comments after the task document, and a comment can
# repeat the field. Every match used to be concatenated into one slug.
mktask doubled dbl
DBF="$REPO/.backlog/pending/doubled.md"
printf '\n## Store Comments\n\n- **Worktree**: api\n' >> "$DBF"
OUT=$(bash "$CC" "$DBF" 2>/dev/null); rc=$?
check 'H1 exit 0 and the worktree is the first line slug' '[ "$rc" = "0" ] && [ "$OUT" = "$REPO/.worktree/dbl" ]'
check 'H2 it is on the first line branch' '[ "$(git -C "$OUT" branch --show-current)" = worktree/dbl ]'
check 'H3 neither the glued slug (dblapi) nor the comment slug (api) got a branch' \
  '! git -C "$REPO" show-ref --verify --quiet refs/heads/worktree/dblapi && ! git -C "$REPO" show-ref --verify --quiet refs/heads/worktree/api'
check 'H4 the token row carries the first line slug' 'grep -q "| dbl | worktree/dbl |" "$DBF"'

echo
echo "phase11-checkout-reentrancy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
