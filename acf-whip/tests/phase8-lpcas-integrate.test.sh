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

echo ""
echo "phase8-lpcas-integrate: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
