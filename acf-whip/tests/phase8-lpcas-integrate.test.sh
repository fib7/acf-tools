#!/usr/bin/env bash
# phase8-lpcas-integrate.test.sh — verifies the LP-CAS integrator (3.0.0) prevents the production
# failure classes BY CONSTRUCTION. Creates a throwaway git repo under $TMPDIR and drives
# integrate-lpcas.sh through happy-path, idempotency, rewrite-survival (#1), no-stamp-drift (#16),
# same-file parallel (#17), parse-sanity attribution (#18), union gate (#8), and poison/quarantine.
#
# Run: bash acf-whip/tests/phase8-lpcas-integrate.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IW="$ACF_WHIP/skills/integrate-lpcas/bin/integrate-lpcas.sh"
LIB="$ACF_WHIP/skills/lib/acfw-git.sh"
. "$LIB"

PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p8.XXXXXX")
REPO="$WORK/repo"
trap 'rm -rf "$WORK"' EXIT

git init -q -b trunk "$REPO"
cd "$REPO"
git config user.email "test@acf.local"; git config user.name "ACF Test"
mkdir -p .backlog/accepted
echo "seed" > seed.txt
git add seed.txt && git commit -q -m "seed"

export ACFW_TRUNK_ROOT="$REPO"
export ACFW_TRUNK_BRANCH="trunk"

mktask() { # <key>
  cat > "$REPO/.backlog/accepted/$1.md" <<EOF
# Task: $1
## Metadata
- **Worktree**: $1
- **Assigned Agent**: nextjs-engineer
EOF
}
TF() { echo "$REPO/.backlog/accepted/$1.md"; }

# mkcand_path <key> <relpath> <content> [base] — single-parent candidate writing <content> to <relpath>.
mkcand_path() {
  local key="$1" rel="$2" content="$3" base="${4:-trunk}" wt="$WORK/cand-$1"
  rm -rf "$wt"
  git -C "$REPO" worktree add --detach -q "$wt" "$base"
  mkdir -p "$wt/$(dirname "$rel")"
  printf '%s' "$content" > "$wt/$rel"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "feat: $key"
  git -C "$REPO" update-ref "refs/acfw/patch/$key" "$(git -C "$wt" rev-parse HEAD)"
  git -C "$REPO" worktree remove --force "$wt"
}

run_iw() { OUT=$("$@" 2>"$WORK/iw.err"); RC=$?; }
trunk_tip() { git -C "$REPO" rev-parse trunk; }
on_trunk() { git -C "$REPO" cat-file -e "trunk:$1" 2>/dev/null; }       # <path>
trunk_content() { git -C "$REPO" show "trunk:$1" 2>/dev/null; }         # <path>

echo "== Test 1: happy path =="
mktask k1; mkcand_path k1 "featA.txt" "alpha"
run_iw "$IW" "$(TF k1)"
check "k1 exits 0"                 "[ $RC -eq 0 ]"
check "k1 verdict integrated"      "echo \"\$OUT\" | grep -q 'integrated key=k1'"
check "k1 feature on trunk"        "[ \"\$(trunk_content featA.txt)\" = alpha ]"
check "k1 marker on trunk"         "acfw_is_integrated \"$REPO\" trunk k1"

echo "== Test 2: #16 marker + feature co-committed (no stamp drift) =="
HEAD_FILES=$(git -C "$REPO" show --name-only --format= HEAD | sed '/^$/d')
MK1=$(acfw_marker_path k1)
check "#16 HEAD introduces the feature"  "echo \"\$HEAD_FILES\" | grep -qx 'featA.txt'"
check "#16 HEAD introduces the marker"   "echo \"\$HEAD_FILES\" | grep -qx '$MK1'"
check "#16 marker SHA == feature SHA (one commit)" "[ \"\$(git -C \"$REPO\" log -1 --format=%H -- featA.txt)\" = \"\$(git -C \"$REPO\" log -1 --format=%H -- '$MK1')\" ]"

echo "== Test 3: idempotency / already-integrated =="
BEFORE=$(trunk_tip)
run_iw "$IW" "$(TF k1)"
check "k1 re-run exits 0"           "[ $RC -eq 0 ]"
check "k1 re-run already-integrated" "echo \"\$OUT\" | grep -q 'already-integrated key=k1'"
check "k1 re-run trunk unchanged"   "[ \"\$(trunk_tip)\" = \"$BEFORE\" ]"

echo "== Test 4: #1 candidate forked from a STALE base still lands on live trunk (no cached snapshot) =="
STALE=$(trunk_tip)               # k2 forks here, BEFORE k_adv advances trunk
mktask k_adv; mkcand_path k_adv "advance.txt" "moved"
run_iw "$IW" "$(TF k_adv)"; check "k_adv lands" "[ $RC -eq 0 ]"
mktask k2; mkcand_path k2 "featB.txt" "beta" "$STALE"   # forked from the now-stale tip
run_iw "$IW" "$(TF k2)"
check "k2 exits 0 onto live trunk" "[ $RC -eq 0 ]"
check "k2 feature present"         "[ \"\$(trunk_content featB.txt)\" = beta ]"
check "k2 did NOT lose k_adv"      "[ \"\$(trunk_content advance.txt)\" = moved ]"
check "k2 did NOT lose k1"         "[ \"\$(trunk_content featA.txt)\" = alpha ]"

echo "== Test 5a: #17 same-file, disjoint regions -> clean union, both present =="
BASE5=$(trunk_tip)
SEED5=$'L1\nL2\nL3\nL4\nL5\nL6\nL7\nL8\nL9\nL10'
mktask k5a; mkcand_path k5a "shared.txt" "${SEED5/L1/A1}" "$BASE5"
mktask k5b; mkcand_path k5b "shared.txt" "${SEED5/L10/B10}" "$BASE5"
# seed shared.txt on trunk first so both candidates diff against a common base
mktask k5seed; mkcand_path k5seed "shared.txt" "$SEED5" "$BASE5"
run_iw "$IW" "$(TF k5seed)"; check "k5seed lands" "[ $RC -eq 0 ]"
# re-fork a and b from the seeded trunk so their base contains shared.txt
BASE5=$(trunk_tip)
mkcand_path k5a "shared.txt" "${SEED5/L1/A1}" "$BASE5"
mkcand_path k5b "shared.txt" "${SEED5/L10/B10}" "$BASE5"
run_iw "$IW" "$(TF k5a)"; check "k5a lands" "[ $RC -eq 0 ]"
run_iw "$IW" "$(TF k5b)"
check "k5b lands (disjoint auto-merge)" "[ $RC -eq 0 ]"
check "#17 A's edit present"  "trunk_content shared.txt | grep -q '^A1$'"
check "#17 B's edit present"  "trunk_content shared.txt | grep -q '^B10$'"

echo "== Test 5b: #17 same-file, OVERLAP -> surfaced conflict, never silent loss =="
BASEO=$(trunk_tip)
mktask k_o_a; mkcand_path k_o_a "code.ts" $'function f(){\n  return 1;\n}\n' "$BASEO"
mktask k_o_b; mkcand_path k_o_b "code.ts" $'function f(){\n  return 2;\n}\n' "$BASEO"
run_iw "$IW" "$(TF k_o_a)"; check "k_o_a lands" "[ $RC -eq 0 ]"
run_iw "$IW" "$(TF k_o_b)"
check "k_o_b conflict -> exit 7 resolver-needed" "[ $RC -eq 7 ]"
check "k_o_b verdict resolver-needed"            "echo \"\$OUT\" | grep -q 'resolver-needed key=k_o_b'"
check "#17 k_o_b NOT marked integrated"          "! acfw_is_integrated \"$REPO\" trunk k_o_b"
check "#17 trunk still has A's value"            "trunk_content code.ts | grep -q 'return 1;'"

echo "== Test 6: #18 botched resolution (unbalanced brace) -> mechanism, not coverage regression =="
# continue from 5b's mid-conflict integration worktree for k_o_b
acfw_load_namespace "$REPO"
INTEG="$REPO/$ACFW_WORKTREE_DIR/_integrate/k_o_b"
check "#18 integration worktree exists" "[ -d \"$INTEG\" ]"
# resolver writes a syntactically broken result (drops the closing brace) and stages it
printf 'function f(){\n  return 2;\n' > "$INTEG/code.ts"
git -C "$INTEG" add code.ts
BEFORE6=$(trunk_tip)
run_iw env ACFW_PARSE_SANITY_CMD='test "$(tr -cd "{" < code.ts | wc -c)" = "$(tr -cd "}" < code.ts | wc -c)"' "$IW" --post-resolver "$(TF k_o_b)"
check "#18 exits 9 (mechanism)"                 "[ $RC -eq 9 ]"
check "#18 verdict resolution-syntax-broken"    "echo \"\$OUT\" | grep -q 'resolution-syntax-broken'"
check "#18 NOT a quality-fault"                 "! echo \"\$OUT\" | grep -q 'quality-fault'"
check "#18 marker NOT landed"                   "! acfw_is_integrated \"$REPO\" trunk k_o_b"
check "#18 trunk unchanged"                     "[ \"\$(trunk_tip)\" = \"$BEFORE6\" ]"

echo "== Test 6b: trunk that MOVES across the resolver window must lose the CAS, not overwrite it =="
# THE defect this pins. In --post-resolver mode OBSERVED was re-read from the LIVE trunk tip, but the
# integration worktree is still detached at the tip the FIRST process saw (cherry-pick --no-commit and
# --quit both leave HEAD alone). So the candidate commit was parented on the OLD tip while land()
# compare-and-swapped against the NEW one - and update-ref's 3-arg form only checks that trunk still
# EQUALS the value handed to it, never that the new commit descends from it. The CAS therefore
# SUCCEEDED and force-moved trunk to a commit whose ancestry skipped everything committed while the
# resolver agent worked: other tasks' integrations, their ledger markers, and every .backlog
# transition (apply-transition.sh commits to trunk on a different serialization chain than integrate).
# land()'s own resync then deleted those files from the working tree as "changed paths". No warning.
#
# The resolver window is an LLM agent run, so trunk moving inside it is ordinary.
BASEM=$(trunk_tip)
mktask k_move; mkcand_path k_move "movefile.txt" $'shared\nv1\n'          "$BASEM"
mktask k_conf; mkcand_path k_conf "movefile.txt" $'shared\nv2-conflict\n' "$BASEM"
run_iw "$IW" "$(TF k_move)"; check "#6b the first candidate lands" "[ $RC -eq 0 ]"
run_iw "$IW" "$(TF k_conf)"                          # same file, same base -> conflict, exit 7
INTEG_MV="$REPO/$ACFW_WORKTREE_DIR/_integrate/k_conf"
if [ "$RC" -eq 7 ] && [ -d "$INTEG_MV" ]; then
  WT_BASE=$(git -C "$INTEG_MV" rev-parse HEAD)
  # a CONCURRENT writer advances trunk while the "resolver" works - exactly what apply-transition.sh
  # does on the files store, on its own chain, during the same dispatch wave
  echo "concurrent" > "$REPO/concurrent-work.txt"
  git -C "$REPO" add concurrent-work.txt
  git -C "$REPO" commit -q -m "task: someone-else completed -> in-review"
  MOVED=$(trunk_tip)
  check "#6b trunk really moved under the resolver" "[ \"$MOVED\" != \"$WT_BASE\" ]"
  # resolver resolves the conflict and stages it
  printf 'v2-resolved\n' > "$INTEG_MV/movefile.txt"
  git -C "$INTEG_MV" add movefile.txt
  run_iw "$IW" --post-resolver "$(TF k_conf)"
  check "#6b a moved trunk loses the CAS (exit 11 cas-lost), it does not silently win" "[ $RC -eq 11 ]"
  check "#6b the concurrent commit is STILL trunk" "[ \"\$(trunk_tip)\" = \"$MOVED\" ]"
  check "#6b the concurrent commit's file survives on trunk" "on_trunk concurrent-work.txt"
  check "#6b ...and on disk (land's resync never ran)" "[ -f \"$REPO/concurrent-work.txt\" ]"
  check "#6b k_conf did NOT land behind everyone's back" "! acfw_is_integrated \"$REPO\" trunk k_conf"
else
  echo "  SKIP: #6b needs the initial attempt to exit 7 with a worktree (got rc=$RC)"
fi

echo "== Test 7: #8 union gate failure blocks the land =="
mktask k7; mkcand_path k7 "g7.txt" "g7"
BEFORE7=$(trunk_tip)
run_iw env ACFW_GATE_CMD='exit 1' "$IW" "$(TF k7)"
check "k7 exits 6 (quality)"        "[ $RC -eq 6 ]"
check "k7 verdict quality-fault"    "echo \"\$OUT\" | grep -q 'quality-fault key=k7'"
check "#8 k7 NOT on trunk"          "! on_trunk g7.txt"
check "#8 trunk unchanged"          "[ \"\$(trunk_tip)\" = \"$BEFORE7\" ]"
check "k7 marker NOT landed"        "! acfw_is_integrated \"$REPO\" trunk k7"

echo "== Test 8: poison candidate (writes the ledger namespace) -> quarantine =="
mktask k8; mkcand_path k8 ".acfwhip/integrated/zz/forged.json" '{"forged":true}'
run_iw "$IW" "$(TF k8)"
check "k8 exits 3 (quarantine)"     "[ $RC -eq 3 ]"
check "k8 verdict poison"           "echo \"\$OUT\" | grep -q 'poison-ledger-write key=k8'"

echo "== Test 9: missing candidate ref -> no-candidate (terminal skip) =="
mktask k9
run_iw "$IW" "$(TF k9)"
check "k9 exits 4 (no-candidate)"   "[ $RC -eq 4 ]"

echo "== Test 10: producer primitive — squash multi-commit worktree to single-parent candidate, integrate =="
FORK=$(trunk_tip)
WT10="$WORK/wt-k10"
git -C "$REPO" worktree add -q -b worktree/k10 "$WT10" "$FORK"
printf 'one\n' > "$WT10/multi.txt"; git -C "$WT10" add -A; git -C "$WT10" commit -q -m "wip 1"
printf 'one\ntwo\n' > "$WT10/multi.txt"; git -C "$WT10" add -A; git -C "$WT10" commit -q -m "wip 2"
acfw_publish_candidate "$REPO" "$WT10" "$FORK" k10 "feat: k10"
CAND10=$(git -C "$REPO" rev-parse refs/acfw/patch/k10)
NP10=$(git -C "$REPO" rev-list --parents -n1 "$CAND10" | wc -w | tr -d ' ')
check "candidate is single-parent"          "[ \"$NP10\" = 2 ]"
check "candidate parent == fork base"        "[ \"\$(git -C \"$REPO\" rev-parse $CAND10^)\" = \"$FORK\" ]"
git -C "$REPO" worktree remove --force "$WT10"
mktask k10
run_iw "$IW" "$(TF k10)"
check "k10 squashed candidate integrates"    "[ $RC -eq 0 ]"
check "k10 final content present"            "[ \"\$(trunk_content multi.txt)\" = \$'one\ntwo' ]"
check "k10 marker on trunk"                   "acfw_is_integrated \"$REPO\" trunk k10"

echo "== Test 11: integrated-set enumeration =="
KEYS=$(acfw_integrated_keys "$REPO" trunk | sort | tr '\n' ' ')
check "integrated keys include k1 and k10"   "echo \"$KEYS\" | grep -q 'k1 ' && echo \"$KEYS\" | grep -q 'k10'"
check "non-integrated k_o_b absent from set" "! echo \"$KEYS\" | grep -qw 'k_o_b'"

echo "== Test 12 (WHIP-23): the root resync applies deletions and spares uncommitted .backlog =="
# land() used to resync ROOT with `git reset --hard "$TRUNK"`, which had two defects:
#   (a) it rewrote .backlog/ too, discarding uncommitted task state at the root — the clean-checkout
#       token row (uncommitted BY DESIGN) and any operator repair made between runs; and
#   (b) it ran AFTER update-ref with its failure swallowed, so a failed resync left ROOT's index on
#       the OLD tree while HEAD was on the new one — and the next .backlog commit built from that
#       index would silently revert the whole integration.
# The replacement is `checkout --no-overlay <trunk> -- . ':(exclude).backlog'` then `reset --mixed`.
# ORDER MATTERS: reset --mixed first would untrack a deleted path, after which checkout can no
# longer remove it and the file is resurrected as an invisible untracked leftover.
mkdir -p "$REPO/.backlog/accepted"
printf 'delete-me\n' > "$REPO/doomed.txt"; printf 'v1\n' > "$REPO/kept.txt"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "seed resync fixture" >/dev/null 2>&1
mktask k_resync
# a candidate that MODIFIES one file and DELETES another
RWT="$WORK/cand-k_resync"; rm -rf "$RWT"
git -C "$REPO" worktree add --detach -q "$RWT" trunk
printf 'v2\n' > "$RWT/kept.txt"; rm -f "$RWT/doomed.txt"
git -C "$RWT" add -A; git -C "$RWT" commit -q -m "feat: k_resync"
git -C "$REPO" update-ref "refs/acfw/patch/k_resync" "$(git -C "$RWT" rev-parse HEAD)"
git -C "$REPO" worktree remove --force "$RWT"
# dirty .backlog at the root exactly the way clean-checkout does: uncommitted, never committed by us
printf '| 2026-06-01 00:00:00 | clean-checkout | ok | a | k_resync | worktree/k_resync |\n' \
  >> "$REPO/.backlog/accepted/k_resync.md"
run_iw bash "$IW" "$(TF k_resync)"
check "k_resync integrates"                          "[ $RC -eq 0 ]"
check "k_resync: modified file synced into the root worktree" \
  "[ \"\$(cat '$REPO/kept.txt')\" = 'v2' ]"
check "k_resync: DELETED file actually removed from the root worktree (--no-overlay)" \
  "[ ! -e '$REPO/doomed.txt' ]"
check "k_resync: no untracked resurrection of the deleted path" \
  "! git -C '$REPO' status --porcelain | grep -q '^?? doomed.txt'"
check "k_resync: the uncommitted clean-checkout token SURVIVED the resync" \
  "grep -q 'clean-checkout | ok' '$REPO/.backlog/accepted/k_resync.md'"
# The index must match trunk for code, or the next .backlog commit forges a tree-reverting commit.
check "k_resync: root index is NOT desynced from trunk" \
  "[ -z \"\$(git -C '$REPO' diff --cached --name-only -- . ':(exclude).backlog')\" ]"


# ---- (12) The resync must not revert work the landing never touched --------------------------
# whip-go starts the prior-integrate pass as a floating promise and awaits it only AFTER the
# dispatch barrier that runs directQ, so a `Worktree: none` task is editing tracked files in the
# trunk root WHILE this runs. `checkout --no-overlay -- .` reverted all of it: the writer then
# staged an unchanged file and the task was reported accepted with none of its content anywhere.
# The pathspec is now the landing's own OBSERVED..NEW diff, so a concurrent edit elsewhere lives.
printf 'committed\n' > "$REPO/untouched.txt"; printf 'v1\n' > "$REPO/landed.txt"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "seed concurrency fixture" >/dev/null 2>&1
mktask k_concurrent
CWT="$WORK/cand-k_concurrent"; rm -rf "$CWT"
git -C "$REPO" worktree add --detach -q "$CWT" trunk
printf 'v2\n' > "$CWT/landed.txt"
git -C "$CWT" add -A; git -C "$CWT" commit -q -m "feat: k_concurrent"
git -C "$REPO" update-ref "refs/acfw/patch/k_concurrent" "$(git -C "$CWT" rev-parse HEAD)"
git -C "$REPO" worktree remove --force "$CWT"
# A direct (Worktree: none) task's in-flight edit to a tracked root file this landing does not touch.
printf 'DIRECT TASK DELIVERABLE\n' > "$REPO/untouched.txt"
run_iw bash "$IW" "$(TF k_concurrent)"
check "k_concurrent integrates"                      "[ $RC -eq 0 ]"
check "k_concurrent: a concurrent direct task's uncommitted work SURVIVES the resync" \
  "[ \"\$(cat '$REPO/untouched.txt')\" = 'DIRECT TASK DELIVERABLE' ]"
check "k_concurrent: the landing's own change still reached the root worktree" \
  "[ \"\$(cat '$REPO/landed.txt')\" = 'v2' ]"
check "k_concurrent: root index is NOT desynced from trunk" \
  "[ -z \"\$(git -C '$REPO' diff --cached --name-only -- . ':(exclude).backlog')\" ]"

# ---- (13) The residual same-file case is reported and recoverable, never silent ---------------
git -C "$REPO" checkout -q -- untouched.txt 2>/dev/null || true
printf 'l1\nl2\nl3\nl4\nl5\n' > "$REPO/contended.txt"; printf 'a0\n' > "$REPO/landed-too.txt"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "seed contended fixture" >/dev/null 2>&1
mktask k_contended
DWT="$WORK/cand-k_contended"; rm -rf "$DWT"
git -C "$REPO" worktree add --detach -q "$DWT" trunk
printf 'LANDED\nl2\nl3\nl4\nl5\n' > "$DWT/contended.txt"
# more paths the landing changes and the operator never touched: the recovery must not revert them
printf 'a1\n' > "$DWT/landed-too.txt"; printf 'new\n' > "$DWT/added-too.txt"
git -C "$DWT" add -A; git -C "$DWT" commit -q -m "feat: k_contended"
git -C "$REPO" update-ref "refs/acfw/patch/k_contended" "$(git -C "$DWT" rev-parse HEAD)"
git -C "$REPO" worktree remove --force "$DWT"
printf 'l1\nl2\nl3\nl4\nUNCOMMITTED ON THE CONTENDED PATH\n' > "$REPO/contended.txt"
run_iw bash "$IW" "$(TF k_contended)"
check "k_contended integrates"                       "[ $RC -eq 0 ]"
check "k_contended: the overwrite is REPORTED, not silent" \
  "grep -q 'overwrote uncommitted work' '$WORK/iw.err'"
check "k_contended: the WARN carries a recoverable snapshot oid" \
  "grep -qE 'Snapshot: [0-9a-f]{7,}' '$WORK/iw.err'"
check "k_contended: the snapshot object really holds the overwritten content" \
  "git -C '$REPO' show \"\$(grep -oE 'Snapshot: [0-9a-f]{7,}' '$WORK/iw.err' | head -1 | cut -d' ' -f2):contended.txt\" 2>/dev/null | grep -q UNCOMMITTED"
check "k_contended: the snapshot did NOT touch refs/stash (a sibling stage's stack is untouched)" \
  "! git -C '$REPO' rev-parse --verify -q refs/stash >/dev/null"
# The printed recovery is what an operator will actually run, so run it. It used to be
# `stash apply <snap>`: the snapshot was taken with HEAD already at NEW and the index still at
# OBSERVED, so applying it replayed NEW -> OBSERVED+edits and reverted, in the root worktree, every
# other path this landing changed. Committing that tree would un-land the integration.
RECOVER=$(sed -n 's/.*Recover: //p' "$WORK/iw.err" | head -1)
check "k_contended: the WARN prints a recovery command"  "[ -n \"\$RECOVER\" ]"
( eval "$RECOVER" ) >"$WORK/recover.out" 2>&1; RRC=$?
check "k_contended: the recovery merges cleanly (rc=$RRC; edits on different lines)" "[ $RRC -eq 0 ]"
check "k_contended: the recovery restores the operator's uncommitted edit" \
  "grep -qx 'UNCOMMITTED ON THE CONTENDED PATH' '$REPO/contended.txt'"
check "k_contended: ...on top of the landed edit to the same file, not instead of it" \
  "grep -qx LANDED '$REPO/contended.txt' && ! grep -q '^<<<<<<<' '$REPO/contended.txt'"
check "k_contended: ...and does NOT revert a landed path the operator never touched" \
  "[ \"\$(cat '$REPO/landed-too.txt')\" = a1 ]"
check "k_contended: ...and does NOT delete a path the landing added" \
  "[ \"\$(cat '$REPO/added-too.txt' 2>/dev/null)\" = new ]"
check "k_contended: ...and does NOT remove the landed ledger marker from the root" \
  "[ -f '$REPO/$(acfw_marker_path k_contended)' ]"
check "k_contended: after recovery the ONLY difference from trunk is the operator's path" \
  "[ \"\$(git -C '$REPO' diff --name-only trunk -- . ':(exclude).backlog')\" = contended.txt ]"
git -C "$REPO" reset -q -- contended.txt 2>/dev/null; git -C "$REPO" checkout -q -- contended.txt 2>/dev/null

# (13c) a SAME-LINE clash: the recovery must keep both sides as conflict markers, never pick one, and
# still leave every other landed path alone.
mktask k_clash
KWT="$WORK/cand-k_clash"; rm -rf "$KWT"
git -C "$REPO" worktree add --detach -q "$KWT" trunk
printf 'LANDED\nl2\nLANDED-C\nl4\nl5\n' > "$KWT/contended.txt"; printf 'a2\n' > "$KWT/landed-too.txt"
git -C "$KWT" add -A; git -C "$KWT" commit -q -m "feat: k_clash"
git -C "$REPO" update-ref "refs/acfw/patch/k_clash" "$(git -C "$KWT" rev-parse HEAD)"
git -C "$REPO" worktree remove --force "$KWT"
printf 'LANDED\nl2\nOPERATOR-C\nl4\nl5\n' > "$REPO/contended.txt"
run_iw bash "$IW" "$(TF k_clash)"
check "13c: integrates"                                         "[ $RC -eq 0 ]"
RECOVER=$(sed -n 's/.*Recover: //p' "$WORK/iw.err" | head -1)
( eval "$RECOVER" ) >"$WORK/recover.out" 2>&1; RRC=$?
check "13c: a same-line clash is NOT applied silently (rc=$RRC)" "[ $RRC -ne 0 ]"
check "13c: ...it leaves conflict markers holding BOTH sides" \
  "grep -q '^<<<<<<<' '$REPO/contended.txt' && grep -qx OPERATOR-C '$REPO/contended.txt' && grep -qx LANDED-C '$REPO/contended.txt'"
check "13c: ...and the other landed path stays landed"          "[ \"\$(cat '$REPO/landed-too.txt')\" = a2 ]"
git -C "$REPO" reset -q -- contended.txt 2>/dev/null; git -C "$REPO" checkout -q -- contended.txt 2>/dev/null

# (13b) an UNTRACKED file sitting on a path the landing adds is overwritten too, and the WARN counts
# it, so the snapshot must hold its content as well.
mktask k_untracked
UWT="$WORK/cand-k_untracked"; rm -rf "$UWT"
git -C "$REPO" worktree add --detach -q "$UWT" trunk
printf 'from the task\n' > "$UWT/fresh.txt"
git -C "$UWT" add -A; git -C "$UWT" commit -q -m "feat: k_untracked"
git -C "$REPO" update-ref "refs/acfw/patch/k_untracked" "$(git -C "$UWT" rev-parse HEAD)"
git -C "$REPO" worktree remove --force "$UWT"
printf 'OPERATOR SCRATCH, NEVER ADDED\n' > "$REPO/fresh.txt"
run_iw bash "$IW" "$(TF k_untracked)"
check "13b: integrates"                                         "[ $RC -eq 0 ]"
check "13b: the overwrite of an untracked file is reported"     "grep -q 'overwrote uncommitted work in .* on 1 path(s)' '$WORK/iw.err'"
check "13b: the snapshot holds the untracked file's content" \
  "git -C '$REPO' show \"\$(grep -oE 'Snapshot: [0-9a-f]{7,}' '$WORK/iw.err' | head -1 | cut -d' ' -f2):fresh.txt\" 2>/dev/null | grep -q 'OPERATOR SCRATCH'"
check "13b: the snapshot holds ONLY the overwritten path (diff from the pre-land trunk is fresh.txt)" \
  "[ \"\$(git -C '$REPO' diff --name-only trunk~1 \"\$(grep -oE 'Snapshot: [0-9a-f]{7,}' '$WORK/iw.err' | head -1 | cut -d' ' -f2)\")\" = fresh.txt ]"
git -C "$REPO" checkout -q -- fresh.txt 2>/dev/null

# ---- (14) Tasks never edit cycles: docs/cycles/ is stripped from every candidate, with a WARN ------
# A cycle folder is the human's plan.md plus acfw-cycle's record.md, and approval is bound to their
# exact bytes at HEAD. A task that landed an edit there re-arms or forges an approval, and land()'s
# resync would overwrite a human's uncommitted amendment at the root. So the edit is dropped, never
# landed, and the drop is named on stderr (a specialist can reach docs/cycles/ by an honest mistake).
echo "== Test 14: a candidate's docs/cycles/ edits never land, and are warned =="
git -C "$REPO" checkout -q -- . 2>/dev/null || true
CYC="docs/cycles/20260928-seat-notice"
# (a) trunk has NO docs/cycles/ yet: an added cycle file is removed, the code still lands
mktask k_cyc0
C0="$WORK/cand-k_cyc0"; rm -rf "$C0"; git -C "$REPO" worktree add --detach -q "$C0" trunk
mkdir -p "$C0/$CYC"; printf 'forged plan\n' > "$C0/$CYC/plan.md"; printf 'code0\n' > "$C0/cyc0.txt"
git -C "$C0" add -A; git -C "$C0" commit -q -m "feat: k_cyc0"
git -C "$REPO" update-ref refs/acfw/patch/k_cyc0 "$(git -C "$C0" rev-parse HEAD)"; git -C "$REPO" worktree remove --force "$C0"
run_iw bash "$IW" "$(TF k_cyc0)"
check "14a: integrates (exit 0)"                               "[ $RC -eq 0 ]"
check "14a: the task's code landed"                            "[ \"\$(trunk_content cyc0.txt)\" = code0 ]"
check "14a: the ADDED cycle file did not land (trunk had none)" "! on_trunk '$CYC/plan.md'"
check "14a: the drop is WARNed, naming the path"               "grep -q '^WARN: k_cyc0: dropped.*$CYC/plan.md' '$WORK/iw.err'"
check "14a: the WARN says how to see the dropped change"       "grep -q 'refs/acfw/patch/k_cyc0' '$WORK/iw.err'"
check "14a: the integration commit touches nothing under docs/cycles/" \
  "[ -z \"\$(git -C '$REPO' show --name-only --format= trunk -- docs/cycles)\" ]"
check "14a: the marker still landed with the code"             "acfw_is_integrated \"$REPO\" trunk k_cyc0"
check "14a: code landed too, so no 'delivers nothing' WARN"          "! grep -q 'delivers nothing' '$WORK/iw.err'"

# seed a real, approved-looking cycle on trunk for the remaining cases
mkdir -p "$REPO/$CYC"
printf '# Plan\n\n## Deliverables\n\n### D1: seat notice\n' > "$REPO/$CYC/plan.md"
printf '# Cycle Record\n\n## Tasks\n\n| Deliverable | Tasks |\n' > "$REPO/$CYC/record.md"
git -C "$REPO" add -- "$CYC" >/dev/null; git -C "$REPO" commit -qm "docs(plan): approve seat-notice" >/dev/null
PLAN_BLOB=$(git -C "$REPO" rev-parse "trunk:$CYC/plan.md")
REC_BLOB=$(git -C "$REPO" rev-parse "trunk:$CYC/record.md")

# (b) MODIFY + ADD under an existing cycle, while a human's uncommitted amendment sits at the root
mktask k_cyc1
C1="$WORK/cand-k_cyc1"; rm -rf "$C1"; git -C "$REPO" worktree add --detach -q "$C1" trunk
printf '# Plan\n\n## Deliverables\n\n### D1: seat notice\n- [x] done\n' > "$C1/$CYC/plan.md"
printf 'forged\n' > "$C1/$CYC/retro.md"; printf 'code1\n' > "$C1/cyc1.txt"
git -C "$C1" add -A; git -C "$C1" commit -q -m "feat: k_cyc1"
git -C "$REPO" update-ref refs/acfw/patch/k_cyc1 "$(git -C "$C1" rev-parse HEAD)"; git -C "$REPO" worktree remove --force "$C1"
printf '# Plan\n\nHUMAN AMENDMENT IN PROGRESS\n' > "$REPO/$CYC/plan.md"
run_iw bash "$IW" "$(TF k_cyc1)"
check "14b: integrates (exit 0)"                                "[ $RC -eq 0 ]"
check "14b: the task's code landed"                             "[ \"\$(trunk_content cyc1.txt)\" = code1 ]"
check "14b: trunk plan.md is byte-identical (the edit was dropped)" \
  "[ \"\$(git -C '$REPO' rev-parse 'trunk:$CYC/plan.md')\" = '$PLAN_BLOB' ]"
check "14b: trunk record.md is byte-identical"                  "[ \"\$(git -C '$REPO' rev-parse 'trunk:$CYC/record.md')\" = '$REC_BLOB' ]"
check "14b: the ADDED retro.md did not land"                    "! on_trunk '$CYC/retro.md'"
check "14b: the WARN names the modified path"                   "grep -q '$CYC/plan.md' '$WORK/iw.err'"
check "14b: the WARN names the added path"                      "grep -q '$CYC/retro.md' '$WORK/iw.err'"
check "14b: the human's uncommitted amendment at the root SURVIVED the landing" \
  "grep -q 'HUMAN AMENDMENT IN PROGRESS' '$REPO/$CYC/plan.md'"
check "14b: ...and was not reported as overwritten (the landing never touched it)" \
  "! grep -q 'overwrote uncommitted work' '$WORK/iw.err'"
git -C "$REPO" checkout -q -- "$CYC/plan.md"

# (c) no false alarm: a candidate that does not touch docs/cycles/ warns about nothing
mktask k_cyc2; mkcand_path k_cyc2 "cyc2.txt" "code2"
run_iw bash "$IW" "$(TF k_cyc2)"
check "14c: a cycle-free candidate integrates"                  "[ $RC -eq 0 ]"
check "14c: ...with no cycle WARN"                              "! grep -q 'docs/cycles' '$WORK/iw.err'"
# land() used `git status --porcelain` to find uncommitted work on the paths it resyncs, but by then
# the CAS has moved HEAD to NEW while the index still holds OBSERVED, so status called every landed
# path "staged" and EVERY integration printed "overwrote uncommitted work" with a snapshot of nothing.
check "14c: a landing over a clean root reports NO overwritten work (false-positive WARN)" \
  "! grep -q 'overwrote uncommitted work' '$WORK/iw.err'"

# (d) no false alarm either for a branch that CARRIES trunk's own newer cycle commit: its patch diff
# includes the plan change, but that change is already on trunk, so nothing is dropped
OLDBASE=$(trunk_tip)
printf '# Plan\n\n## Deliverables\n\n### D1: seat notice, reworded\n' > "$REPO/$CYC/plan.md"
git -C "$REPO" commit -qm "docs(plan): approve seat-notice (amended)" -- "$CYC/plan.md" >/dev/null
mktask k_cyc3
C3="$WORK/cand-k_cyc3"; rm -rf "$C3"; git -C "$REPO" worktree add --detach -q "$C3" "$OLDBASE"
git -C "$REPO" show "trunk:$CYC/plan.md" > "$C3/$CYC/plan.md"; printf 'code3\n' > "$C3/cyc3.txt"
git -C "$C3" add -A; git -C "$C3" commit -q -m "feat: k_cyc3 (merged trunk's plan)"
git -C "$REPO" update-ref refs/acfw/patch/k_cyc3 "$(git -C "$C3" rev-parse HEAD)"; git -C "$REPO" worktree remove --force "$C3"
run_iw bash "$IW" "$(TF k_cyc3)"
check "14d: integrates"                                         "[ $RC -eq 0 ]"
check "14d: no cycle WARN for a change trunk already has"       "! grep -q 'dropped this task' '$WORK/iw.err'"

# (e) a conflict CONFINED to docs/cycles/ needs no resolver: stripped, then a clean apply
BASEE=$(trunk_tip)
PLAN_E=$(git -C "$REPO" show "trunk:$CYC/plan.md")
mktask k_cyc4
C4="$WORK/cand-k_cyc4"; rm -rf "$C4"; git -C "$REPO" worktree add --detach -q "$C4" "$BASEE"
printf '%s\nTASK EDIT\n' "$PLAN_E" > "$C4/$CYC/plan.md"; printf 'code4\n' > "$C4/cyc4.txt"
git -C "$C4" add -A; git -C "$C4" commit -q -m "feat: k_cyc4"
git -C "$REPO" update-ref refs/acfw/patch/k_cyc4 "$(git -C "$C4" rev-parse HEAD)"; git -C "$REPO" worktree remove --force "$C4"
printf '%s\nHUMAN EDIT COMMITTED\n' "$PLAN_E" > "$REPO/$CYC/plan.md"      # same region -> conflict
git -C "$REPO" commit -qm "docs(plan): approve seat-notice (again)" -- "$CYC/plan.md" >/dev/null
PLAN_E_BLOB=$(git -C "$REPO" rev-parse "trunk:$CYC/plan.md")
run_iw bash "$IW" "$(TF k_cyc4)"
check "14e: a cycle-only conflict is NOT resolver-needed (exit 0)"  "[ $RC -eq 0 ]"
check "14e: ...no resolver block was printed"                     "! echo \"\$OUT\" | grep -q 'resolver-needed'"
check "14e: the task's code landed"                               "[ \"\$(trunk_content cyc4.txt)\" = code4 ]"
check "14e: the human's committed plan is untouched"              "[ \"\$(git -C '$REPO' rev-parse 'trunk:$CYC/plan.md')\" = '$PLAN_E_BLOB' ]"
check "14e: the drop is WARNed"                                    "grep -q 'dropped this task.*$CYC/plan.md' '$WORK/iw.err'"
check "14e: code landed too (conflict path), so no 'delivers nothing' WARN" "! grep -q 'delivers nothing' '$WORK/iw.err'"

# (f) a conflict in code AND docs/cycles/: the resolver is handed the code conflict only
BASEF=$(trunk_tip)
printf 'line\n' > "$REPO/both.txt"; git -C "$REPO" add both.txt; git -C "$REPO" commit -qm "seed both" >/dev/null
BASEF=$(trunk_tip); PLAN_F=$(git -C "$REPO" show "trunk:$CYC/plan.md")
mktask k_cyc5
C5="$WORK/cand-k_cyc5"; rm -rf "$C5"; git -C "$REPO" worktree add --detach -q "$C5" "$BASEF"
printf 'task side\n' > "$C5/both.txt"; printf '%s\nTASK F\n' "$PLAN_F" > "$C5/$CYC/plan.md"
git -C "$C5" add -A; git -C "$C5" commit -q -m "feat: k_cyc5"
git -C "$REPO" update-ref refs/acfw/patch/k_cyc5 "$(git -C "$C5" rev-parse HEAD)"; git -C "$REPO" worktree remove --force "$C5"
printf 'trunk side\n' > "$REPO/both.txt"; printf '%s\nHUMAN F\n' "$PLAN_F" > "$REPO/$CYC/plan.md"
git -C "$REPO" commit -qm "trunk moves both" -- both.txt "$CYC/plan.md" >/dev/null
PLAN_F_BLOB=$(git -C "$REPO" rev-parse "trunk:$CYC/plan.md")
run_iw bash "$IW" "$(TF k_cyc5)"
check "14f: a code conflict still needs the resolver (exit 7)"    "[ $RC -eq 7 ]"
check "14f: conflicted_files names the code file"                  "echo \"\$OUT\" | grep -qx 'both.txt'"
check "14f: ...and NOT the cycle file (the resolver never edits a plan)" "! echo \"\$OUT\" | grep -q 'docs/cycles'"
INTEG_F="$REPO/$ACFW_WORKTREE_DIR/_integrate/k_cyc5"
if [ "$RC" -eq 7 ] && [ -d "$INTEG_F" ]; then
  # the resolver resolves the code AND leaves a stray untracked file under docs/cycles/
  printf 'resolved\n' > "$INTEG_F/both.txt"; git -C "$INTEG_F" add both.txt
  printf 'stray\n' > "$INTEG_F/$CYC/stray.md"
  run_iw bash "$IW" --post-resolver "$(TF k_cyc5)"
  check "14f: post-resolver integrates"                            "[ $RC -eq 0 ]"
  check "14f: the resolved code landed"                            "[ \"\$(trunk_content both.txt)\" = resolved ]"
  check "14f: the resolver's stray cycle file did NOT ride in via add -A" "! on_trunk '$CYC/stray.md'"
  check "14f: ...and was WARNed"                                    "grep -q '$CYC/stray.md' '$WORK/iw.err'"
  check "14f: the committed plan is untouched"                      "[ \"\$(git -C '$REPO' rev-parse 'trunk:$CYC/plan.md')\" = '$PLAN_F_BLOB' ]"
  check "14f: resolved code is a real delivery: no 'delivers nothing' WARN" "! grep -q 'delivers nothing' '$WORK/iw.err'"
else
  bad "14f: needed exit 7 with an integration worktree (got rc=$RC)"
fi

# (g) a candidate whose ONLY change is under docs/cycles/ (the "tick D2 off in plan.md" task). After
# the strip nothing is left but the marker. That still lands and still exits 0 (every caller maps 0 to
# integrated), so the one honest signal is a distinct, UNCONDITIONAL WARN that it delivered nothing.
PLAN_G_BLOB=$(git -C "$REPO" rev-parse "trunk:$CYC/plan.md")
REC_G_BLOB=$(git -C "$REPO" rev-parse "trunk:$CYC/record.md")
mktask k_cyc6
C6="$WORK/cand-k_cyc6"; rm -rf "$C6"; git -C "$REPO" worktree add --detach -q "$C6" trunk
printf '%s\n- [x] D1 done\n' "$(git -C "$REPO" show "trunk:$CYC/plan.md")" > "$C6/$CYC/plan.md"
printf 'forged retro\n' > "$C6/$CYC/retro.md"
git -C "$C6" add -A; git -C "$C6" commit -q -m "docs: tick D1 in the plan"
git -C "$REPO" update-ref refs/acfw/patch/k_cyc6 "$(git -C "$C6" rev-parse HEAD)"; git -C "$REPO" worktree remove --force "$C6"
run_iw bash "$IW" "$(TF k_cyc6)"
check "14g: a cycles-only candidate still exits 0 (integrated)"   "[ $RC -eq 0 ] && echo \"\$OUT\" | grep -q 'integrated key=k_cyc6'"
check "14g: the landed commit's ONLY path is the ledger marker" \
  "[ \"\$(git -C '$REPO' show --name-only --format= trunk | sed '/^\$/d')\" = '$(acfw_marker_path k_cyc6)' ]"
check "14g: trunk plan.md is byte-identical"                     "[ \"\$(git -C '$REPO' rev-parse 'trunk:$CYC/plan.md')\" = '$PLAN_G_BLOB' ]"
check "14g: trunk record.md is byte-identical"                   "[ \"\$(git -C '$REPO' rev-parse 'trunk:$CYC/record.md')\" = '$REC_G_BLOB' ]"
check "14g: the added retro.md did not land"                     "! on_trunk '$CYC/retro.md'"
check "14g: the drop WARN names both paths" \
  "grep -q '^WARN: k_cyc6: dropped.*$CYC/plan.md' '$WORK/iw.err' && grep -q '^WARN: k_cyc6: dropped.*$CYC/retro.md' '$WORK/iw.err'"
check "14g: a distinct WARN says plainly that the task delivers nothing" \
  "grep -q '^WARN: k_cyc6: after dropping docs/cycles/ this task delivers nothing' '$WORK/iw.err'"
check "14g: ...exactly once"                                      "[ \$(grep -c 'delivers nothing' '$WORK/iw.err') -eq 1 ]"

# mkcand_cyc <key> <base> <cmds> — a candidate built from <base> by running <cmds> (eval'd with CWD in
# the candidate worktree), committed as one single-parent commit and published at refs/acfw/patch/<key>.
mkcand_cyc() {
  local wt="$WORK/cand-$1"; rm -rf "$wt"; git -C "$REPO" worktree add --detach -q "$wt" "$2"
  ( cd "$wt" && eval "$3" ) >/dev/null 2>&1
  git -C "$wt" add -A; git -C "$wt" commit -q -m "feat: $1"
  git -C "$REPO" update-ref "refs/acfw/patch/$1" "$(git -C "$wt" rev-parse HEAD)"; git -C "$REPO" worktree remove --force "$wt"
}

# (h) MODIFY/DELETE: the task edited a cycle's plan.md, and trunk git rm'd that whole cycle meanwhile
# (other cycles still on trunk). The cherry-pick leaves plan.md unmerged, and OBSERVED no longer has
# it, so `checkout --no-overlay OBSERVED -- docs/cycles` refused ("path is unmerged") and the strip
# stalled with exit 12. /go maps 12 to transient, so every run retried the same stall and the task's
# code never landed.
CYC_H="docs/cycles/20260928-doomed-cycle"
mkdir -p "$REPO/$CYC_H"; printf '# Plan\n\n### D1: doomed\n' > "$REPO/$CYC_H/plan.md"
git -C "$REPO" add -- "$CYC_H" >/dev/null; git -C "$REPO" commit -qm "docs(plan): approve doomed-cycle" >/dev/null
mktask k_cyc7
mkcand_cyc k_cyc7 trunk "printf '# Plan\n\n### D1: doomed, edited by the task\n' > '$CYC_H/plan.md'; printf 'code7\n' > cyc7.txt"
git -C "$REPO" rm -rq -- "$CYC_H"; git -C "$REPO" commit -qm "docs(plan): drop doomed-cycle" >/dev/null
run_iw bash "$IW" "$(TF k_cyc7)"
check "14h: modify/delete on a cycle path integrates (exit 0, not a cycles-strip-failed stall)" \
  "[ $RC -eq 0 ] && ! echo \"\$OUT\" | grep -q 'cycles-strip-failed'"
check "14h: ...and is not handed to a resolver"                  "! echo \"\$OUT\" | grep -q 'resolver-needed'"
check "14h: the task's code landed"                              "[ \"\$(trunk_content cyc7.txt)\" = code7 ]"
check "14h: the deleted cycle stays deleted on trunk"            "! on_trunk '$CYC_H/plan.md'"
check "14h: the other cycle is untouched on trunk"               "[ \"\$(git -C '$REPO' rev-parse 'trunk:$CYC/plan.md')\" = '$PLAN_G_BLOB' ]"
check "14h: the drop is WARNed, naming the path"                 "grep -q '^WARN: k_cyc7: dropped.*$CYC_H/plan.md' '$WORK/iw.err'"
check "14h: nothing is resurrected under the deleted cycle at the root" "[ ! -e '$REPO/$CYC_H' ]"
check "14h: the integration worktree was removed"                "[ ! -d '$REPO/$ACFW_WORKTREE_DIR/_integrate/k_cyc7' ]"

# (j) DELETE/MODIFY, the other direction: the task deleted a cycle file that trunk then amended. OBSERVED
# has the path, so the strip restores trunk's version and the deletion is dropped.
mktask k_cyc8
mkcand_cyc k_cyc8 trunk "git rm -q -- '$CYC/record.md'; printf 'code8\n' > cyc8.txt"
printf '%s\n| D1 | amended |\n' "$(git -C "$REPO" show "trunk:$CYC/record.md")" > "$REPO/$CYC/record.md"
git -C "$REPO" commit -qm "docs(plan): record amended" -- "$CYC/record.md" >/dev/null
REC_J_BLOB=$(git -C "$REPO" rev-parse "trunk:$CYC/record.md")
run_iw bash "$IW" "$(TF k_cyc8)"
check "14j: delete/modify on a cycle path integrates (exit 0)"   "[ $RC -eq 0 ]"
check "14j: the task's code landed"                              "[ \"\$(trunk_content cyc8.txt)\" = code8 ]"
check "14j: trunk's amended record.md survives the task's deletion" \
  "[ \"\$(git -C '$REPO' rev-parse 'trunk:$CYC/record.md')\" = '$REC_J_BLOB' ]"
check "14j: the drop is WARNed, naming the path"                 "grep -q '^WARN: k_cyc8: dropped.*$CYC/record.md' '$WORK/iw.err'"

# (i) modify/delete again, with NO cycles left on trunk at all: OBSERVED has no docs/cycles/ tree, so
# the strip's tracked-restore guard must still see (and drop) the unmerged entry.
mktask k_cyc9
mkcand_cyc k_cyc9 trunk "printf 'last task edit\n' >> '$CYC/plan.md'; printf 'code9\n' > cyc9.txt"
git -C "$REPO" rm -rq -- docs/cycles; git -C "$REPO" commit -qm "docs(plan): drop every cycle" >/dev/null
run_iw bash "$IW" "$(TF k_cyc9)"
check "14i: modify/delete with no cycles on trunk integrates (exit 0)" "[ $RC -eq 0 ]"
check "14i: the task's code landed"                              "[ \"\$(trunk_content cyc9.txt)\" = code9 ]"
check "14i: trunk still has no docs/cycles/"                     "! on_trunk docs/cycles"
check "14i: the drop is WARNed, naming the path"                 "grep -q '^WARN: k_cyc9: dropped.*$CYC/plan.md' '$WORK/iw.err'"
echo ""
echo "phase8-lpcas-integrate: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
