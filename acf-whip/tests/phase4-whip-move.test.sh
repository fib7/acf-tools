#!/usr/bin/env bash
# phase4-whip-move.test.sh — verifies the BUG-6b operator command whip-move.sh:
#   - resolves a task by exact stem AND by unique prefix
#   - performs a validated state move via apply-transition.sh (Status synced, log row spliced, commit)
#   - --add-dep appends to Dependencies; --integrated-at sets Integrated-At; both land in the move commit
#   - in-place field edit (TO_STATE == current) commits without a move
#   - guards: ambiguous match, not-found, invalid state all exit 2 and do not mutate
# Run: bash acf-whip/tests/phase4-whip-move.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOVE="$ACF_WHIP/skills/whip-move/bin/whip-move.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p4move.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk

mktask(){ # <dir> <stem>
  cat > ".backlog/$1/$2.md" <<EOF
# Task: $2

- **ID**: $2
- **Status**: $1
- **Worktree**: none
- **Dependencies**: none
- **Rejection Count**: 0

## Transition Log

| Date | From | To | Agent | Notes |
|------|------|----|----|-------|
| 2026-06-01 00:00:00 | draft | pending | task-engineer | init |

## Notes
(none)
EOF
}
mktask pending test-041-promote
git add -A; git commit -qm task

# ---- move by exact stem, with --add-dep + --reason ----
bash "$MOVE" test-041-promote blocked --add-dep fixture-readiness --reason "needs fixture" >/dev/null
check "moved pending -> blocked (file relocated)" "[ -f .backlog/blocked/test-041-promote.md ] && [ ! -f .backlog/pending/test-041-promote.md ]"
check "Status synced to blocked" "grep -qE '^- \*\*Status\*\*: blocked' .backlog/blocked/test-041-promote.md"
# WHIP-19: the Dependencies line is a BARE comma list — the only format doctor.sh and scan-backlog.sh
# parse. The old JSON-style "[a, b]" made both ids unresolvable -> false FATAL|dangling-dep -> /go blocked.
check "dependency appended as a BARE id (no brackets)" "grep -qE '^- \*\*Dependencies\*\*: fixture-readiness\$' .backlog/blocked/test-041-promote.md"
check "no JSON-style brackets written" "! grep -qE '^- \*\*Dependencies\*\*:.*[][]' .backlog/blocked/test-041-promote.md"
check "transition row spliced into table" "grep -qE '\| blocked \| operator \| needs fixture \|' .backlog/blocked/test-041-promote.md"
check "move was committed (clean tree)" "[ -z \"\$(git status --porcelain)\" ]"

# ---- second --add-dep appends to the existing bare list, and parses back to exactly 2 ids ----
bash "$MOVE" test-041-promote blocked --add-dep second-dep >/dev/null
check "second dependency appends to the bare list" "grep -qE '^- \*\*Dependencies\*\*: fixture-readiness, second-dep\$' .backlog/blocked/test-041-promote.md"
NDEPS=$(grep -E '^- \*\*Dependencies\*\*:' .backlog/blocked/test-041-promote.md | sed -E 's/^- \*\*Dependencies\*\*:[[:space:]]*//' | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -c .)
check "parser (comma split) resolves exactly 2 clean ids" "[ \"$NDEPS\" -eq 2 ]"

# ---- legacy bracketed line found in the file is de-bracketed on the way through ----
sed -i.bak -E 's|^- \*\*Dependencies\*\*:.*|- **Dependencies**: [legacy-a]|' .backlog/blocked/test-041-promote.md && rm -f .backlog/blocked/test-041-promote.md.bak
git add -A; git commit -qm legacy-brackets
bash "$MOVE" test-041-promote blocked --add-dep legacy-b >/dev/null
check "legacy [a] is de-bracketed when appending" "grep -qE '^- \*\*Dependencies\*\*: legacy-a, legacy-b\$' .backlog/blocked/test-041-promote.md"
# restore a simple dep line for the rest of the suite
sed -i.bak -E 's|^- \*\*Dependencies\*\*:.*|- **Dependencies**: none|' .backlog/blocked/test-041-promote.md && rm -f .backlog/blocked/test-041-promote.md.bak
git add -A; git commit -qm restore-deps

# ---- resolve by unique PREFIX, accepted + --integrated-at ----
bash "$MOVE" test-041 accepted --integrated-at a042d461 >/dev/null
check "prefix resolved + moved to accepted" "[ -f .backlog/accepted/test-041-promote.md ]"
check "Integrated-At set" "grep -qE '^- \*\*Integrated-At\*\*: a042d461' .backlog/accepted/test-041-promote.md"

# ---- idempotent: already accepted, no edits -> noop, no commit ----
BEFORE=$(git rev-parse HEAD)
bash "$MOVE" test-041-promote accepted >/dev/null
check "idempotent re-move makes no commit" "[ \"\$(git rev-parse HEAD)\" = \"$BEFORE\" ]"

# ---- in-place field edit (same state) commits without moving ----
bash "$MOVE" test-041-promote accepted --integrated-at 9f3c2aa9 >/dev/null
check "in-place Integrated-At updated" "grep -qE '^- \*\*Integrated-At\*\*: 9f3c2aa9' .backlog/accepted/test-041-promote.md"
check "in-place edit committed (clean tree)" "[ -z \"\$(git status --porcelain)\" ]"

# ---- guards ----
mktask pending dup-a; mktask pending dup-b; git add -A; git commit -qm dups
bash "$MOVE" dup accepted >/dev/null 2>&1; check "ambiguous match exits 2" "[ \$? -eq 2 ]"
check "ambiguous match did NOT move either file" "[ -f .backlog/pending/dup-a.md ] && [ -f .backlog/pending/dup-b.md ]"
bash "$MOVE" nope accepted >/dev/null 2>&1; check "not-found exits 2" "[ \$? -eq 2 ]"
bash "$MOVE" test-041-promote bogus >/dev/null 2>&1; check "invalid state exits 2" "[ \$? -eq 2 ]"

# ---- 3.5.0: the writer never stages docs/cycles/, even through an ancestor path ----
# apply-transition.sh is the writer behind every move above, and the one that stages a Worktree: none
# task's deliverables at the shared root. A human may be mid-amendment of an approved plan.md there,
# or drafting a new cycle. A deliverable listed as `docs`, `docs/` or `.` used to sweep both into the
# task's commit: the draft landed on trunk and the approval at HEAD was void with no /whip card behind
# it. Each case below leaves the human's edit and draft exactly where they were.
APPLY="$ACF_WHIP/skills/go/bin/apply-transition.sh"
PLAN=docs/cycles/20260101-app/plan.md
DRAFT=docs/cycles/20260102-new/plan.md
mkdir -p docs/cycles/20260101-app
printf '# Plan\n\n## Deliverables\n\n### D1: approved text\n' > "$PLAN"
git add -- "$PLAN"; git commit -qm "docs(plan): approve app"
# The human's state, reset before each case: an unstaged amendment and an untracked draft.
human_edits(){
  git checkout -q -- "$PLAN"
  printf '### D2: amendment in progress\n' >> "$PLAN"
  mkdir -p docs/cycles/20260102-new; printf '# Draft\n' > "$DRAFT"
}
human_intact(){ # <label>: the amendment is still unstaged, the draft still untracked, neither in HEAD's commit
  check "$1: HEAD's commit touches nothing under docs/cycles" "[ -z \"\$(git show --name-only --format= HEAD -- docs/cycles)\" ]"
  check "$1: the plan amendment is still in the working tree, unstaged" "grep -q 'amendment in progress' '$PLAN' && ! git diff --quiet -- '$PLAN' && git diff --cached --quiet -- docs/cycles"
  check "$1: the draft cycle is still untracked" "[ -f '$DRAFT' ] && ! git ls-files --error-unmatch '$DRAFT' >/dev/null 2>&1"
}
n=0
for anc in docs docs/ .; do
  n=$((n+1)); stem="cyc-00$n-anc"
  mktask pending "$stem"; git add -- ".backlog/pending/$stem.md"; git commit -qm "task $stem"
  human_edits
  mkdir -p docs/research; printf 'finding %s\n' "$n" > "docs/research/r$n.md"
  ERR=$(bash "$APPLY" --stage "$anc" "$REPO/.backlog/pending/$stem.md" completed go-engineer "x" 0 0 2>&1 >/dev/null); RC=$?
  check "--stage '$anc': the transition succeeds (rc=$RC${ERR:+, stderr: $ERR})" "[ $RC -eq 0 ] && [ -f .backlog/completed/$stem.md ]"
  check "--stage '$anc': the real deliverable is committed with the move" "git show --name-only --format= HEAD | grep -qx 'docs/research/r$n.md' && git show --name-only --format= HEAD | grep -qx '.backlog/completed/$stem.md'"
  human_intact "--stage '$anc'"
done

# An exact cycle path is skipped with a WARN by name, never refused: exit 2 would strand the move.
mktask pending cyc-004-exact; git add -- .backlog/pending/cyc-004-exact.md; git commit -qm "task cyc-004-exact"
human_edits
ERR=$(bash "$APPLY" --stage "$PLAN" --stage ./docs/cycles "$REPO/.backlog/pending/cyc-004-exact.md" completed go-engineer "x" 0 0 2>&1 >/dev/null); RC=$?
check "an exact cycle path: the transition still succeeds" "[ $RC -eq 0 ] && [ -f .backlog/completed/cyc-004-exact.md ]"
check "...each skipped path is WARNed by name" "printf '%s\n' \"\$ERR\" | grep -qF \"WARN: not staging '$PLAN': tasks never edit cycles\" && printf '%s\n' \"\$ERR\" | grep -qF \"WARN: not staging 'docs/cycles': tasks never edit cycles\""
human_intact "an exact cycle path"

# git reads each of these as a docs/cycles path or as the docs ancestor. The guard used to match the
# literal spelling, so all five committed the human's amendment with the task.
n=6
for form in "docs//cycles/20260101-app/plan.md" "docs/./cycles/20260101-app/plan.md" "././docs/cycles/20260101-app/plan.md" "docs/./cycles" "././docs"; do
  n=$((n+1)); stem="cyc-0$n-form"
  mktask pending "$stem"; git add -- ".backlog/pending/$stem.md"; git commit -qm "task $stem"
  human_edits
  mkdir -p docs/research; printf 'finding %s\n' "$n" > "docs/research/f$n.md"
  ERR=$(bash "$APPLY" --stage "$form" --stage "docs/research/f$n.md" "$REPO/.backlog/pending/$stem.md" completed go-engineer "x" 0 0 2>&1 >/dev/null); RC=$?
  check "--stage '$form': the transition succeeds (rc=$RC${ERR:+, stderr: $ERR})" "[ $RC -eq 0 ] && [ -f .backlog/completed/$stem.md ]"
  check "--stage '$form': the real deliverable is committed with the move" "git show --name-only --format= HEAD | grep -qx 'docs/research/f$n.md'"
  human_intact "--stage '$form'"
done

# A state path is refused (exit 2, nothing touched) in every spelling, the bare folder included:
# `git add -- .backlog` stages the whole task store.
mktask pending cyc-012-state; git add -- .backlog/pending/cyc-012-state.md; git commit -qm "task cyc-012-state"
for form in ".backlog" ".backlog/" "././.backlog/pending/cyc-012-state.md" ".acfwhip//run"; do
  BEFORE=$(git rev-parse HEAD)
  bash "$APPLY" --stage "$form" "$REPO/.backlog/pending/cyc-012-state.md" completed go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
  check "--stage '$form' is refused with exit 2 and nothing moves or commits" "[ $RC -eq 2 ] && [ -f .backlog/pending/cyc-012-state.md ] && [ \"\$(git rev-parse HEAD)\" = '$BEFORE' ]"
done

# docs/ holding only cycle changes: the exclude filters everything the positive path matched, which
# git accepts (rc 0), so the move is never stranded and the commit carries just the task file.
mktask pending cyc-005-only; git add -- .backlog/pending/cyc-005-only.md; git commit -qm "task cyc-005-only"
human_edits
bash "$APPLY" --stage docs "$REPO/.backlog/pending/cyc-005-only.md" completed go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
check "--stage docs with only cycle changes under it: the move still commits" "[ $RC -eq 0 ] && [ \"\$(git show --name-only --format= HEAD | grep -v '^\.backlog/' | grep -c .)\" -eq 0 ] && [ -f .backlog/completed/cyc-005-only.md ]"
human_intact "--stage docs, only cycles dirty"

# The no-op re-apply sweeps uncommitted deliverables (rescue_deliverables). Its dirty probe must
# exclude cycles too: a `docs` dirty only under docs/cycles/ read as dirty, staged nothing, and the
# commit then failed with "nothing to commit", turning a no-op into a FATAL.
BEFORE=$(git rev-parse HEAD)
bash "$APPLY" --stage docs "$REPO/.backlog/completed/cyc-005-only.md" completed go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
check "no-op re-apply with only cycles dirty under docs: exit 0 and no commit" "[ $RC -eq 0 ] && [ \"\$(git rev-parse HEAD)\" = '$BEFORE' ]"
human_intact "no-op re-apply"
printf 'late finding\n' > docs/research/late.md
bash "$APPLY" --stage docs "$REPO/.backlog/completed/cyc-005-only.md" completed go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
check "no-op re-apply rescues a real deliverable under the same ancestor" "[ $RC -eq 0 ] && git show --name-only --format= HEAD | grep -qx 'docs/research/late.md'"
human_intact "rescue sweep"

# Exact paths and ancestors are staged by separate calls, and the exclude rides only the ancestor's.
# With an exclude present, git 2.51 can silently skip an exact untracked file whose parent directory
# is untracked (rc 0). These cases use exactly those paths: a new deliverable under a new directory,
# and a move into a state folder that holds no tracked file yet. Every one must land.
mktask pending cyc-006-fresh; git add -- .backlog/pending/cyc-006-fresh.md; git commit -qm "task cyc-006-fresh"
human_edits
mkdir -p src/fresh/deep; printf 'code\n' > src/fresh/deep/new.ts; printf 'note\n' > docs/research/r6.md
[ -z "$(git ls-files .backlog/in-review)" ] || bad "fixture: .backlog/in-review/ must hold no tracked file for this case"
bash "$APPLY" --stage src/fresh/deep/new.ts "$REPO/.backlog/pending/cyc-006-fresh.md" in-review go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
check "exact untracked deliverable, move into an untracked state folder: both committed" \
  "[ $RC -eq 0 ] && git show --name-only --format= HEAD | grep -qx '.backlog/in-review/cyc-006-fresh.md' && git show --name-only --format= HEAD | grep -qx 'src/fresh/deep/new.ts' && git ls-files --error-unmatch .backlog/in-review/cyc-006-fresh.md >/dev/null 2>&1"
mkdir -p src/fresh2; printf 'more\n' > src/fresh2/b.ts
bash "$APPLY" --stage docs --stage src/fresh2/b.ts "$REPO/.backlog/in-review/cyc-006-fresh.md" rejected go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
check "an ancestor next to an exact untracked path, move into another untracked folder: all three committed" \
  "[ $RC -eq 0 ] && git show --name-only --format= HEAD | grep -qx '.backlog/rejected/cyc-006-fresh.md' && git show --name-only --format= HEAD | grep -qx 'src/fresh2/b.ts' && git show --name-only --format= HEAD | grep -qx 'docs/research/r6.md'"
human_intact "ancestor next to an exact path"
# The rescue sweep adds one path per call, which is the shape git gets wrong: an exclude on the exact
# path's add would stage nothing and leave it uncommitted with rc 0.
mkdir -p src/fresh3/deep; printf 'rescued\n' > src/fresh3/deep/c.ts; printf 'rescued note\n' > docs/research/r7.md
bash "$APPLY" --stage docs --stage src/fresh3/deep/c.ts "$REPO/.backlog/rejected/cyc-006-fresh.md" rejected go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
check "no-op re-apply sweeps an exact untracked path next to an ancestor: both committed" \
  "[ $RC -eq 0 ] && git show --name-only --format= HEAD | grep -qx 'src/fresh3/deep/c.ts' && git show --name-only --format= HEAD | grep -qx 'docs/research/r7.md'"
human_intact "rescue: ancestor next to an exact path"

# ---- 3.5.0: a STAGED plan amendment is never committed by a root writer ----
# Every writer above used to end in a bare `git commit`, which takes the whole index. A human who had
# `git add`ed an amendment of an approved plan.md (while /go ran in the background) got it committed
# under a "task: ..." subject: unapproved bytes at HEAD, and `acfw-cycle check` refusing 6 from then on.
# Each writer now names its paths, so the amendment stays staged and out of every commit.
staged_amend(){
  git reset -q -- "$PLAN"; git checkout -q -- "$PLAN"
  printf '### D3: staged amendment\n' >> "$PLAN"; git add -- "$PLAN"
}
staged_intact(){ # <label>
  check "$1: HEAD's commit does not carry the staged plan.md amendment" "[ -z \"\$(git show --name-only --format= HEAD -- docs/cycles)\" ]"
  check "$1: the amendment is still staged, as the human left it" "! git diff --cached --quiet -- '$PLAN' && grep -q 'staged amendment' '$PLAN'"
}
STORE="$ACF_WHIP/skills/lib/bin/acfw-store"
mktask pending stg-001-plain; git add -- .backlog/pending/stg-001-plain.md; git commit -qm "task stg-001-plain"
staged_amend; H=$(git rev-parse HEAD)
bash "$APPLY" "$REPO/.backlog/pending/stg-001-plain.md" in-progress orchestrator dispatch 0 0 >/dev/null 2>&1; RC=$?
check "transition with a staged amendment: rc 0 and a new commit" "[ $RC -eq 0 ] && [ \"\$(git rev-parse HEAD)\" != '$H' ] && [ -f .backlog/in-progress/stg-001-plain.md ]"
check "...the move is committed (old path gone at HEAD, new path present)" "git cat-file -e HEAD:.backlog/in-progress/stg-001-plain.md && ! git cat-file -e HEAD:.backlog/pending/stg-001-plain.md 2>/dev/null"
staged_intact "transition"
staged_amend; mkdir -p src/stg; printf 'x\n' > src/stg/a.ts; printf 'finding s\n' > docs/research/rs.md
bash "$APPLY" --stage src/stg/a.ts --stage docs "$REPO/.backlog/in-progress/stg-001-plain.md" completed go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
check "transition with deliverables (exact + ancestor) and a staged amendment: both deliverables committed" \
  "[ $RC -eq 0 ] && git show --name-only --format= HEAD | grep -qx 'src/stg/a.ts' && git show --name-only --format= HEAD | grep -qx 'docs/research/rs.md'"
staged_intact "transition with deliverables"
staged_amend; printf 'rescued\n' > src/stg/b.ts
bash "$APPLY" --stage src/stg/b.ts "$REPO/.backlog/completed/stg-001-plain.md" completed go-engineer "x" 0 0 >/dev/null 2>&1; RC=$?
check "no-op re-apply sweeps its deliverable with a staged amendment present" "[ $RC -eq 0 ] && git show --name-only --format= HEAD | grep -qx 'src/stg/b.ts'"
staged_intact "rescue sweep"
staged_amend; bash "$MOVE" stg-001-plain completed --add-dep stg-000-base >/dev/null 2>&1; RC=$?
check "whip-move in-place field edit with a staged amendment: committed" "[ $RC -eq 0 ] && git show HEAD:.backlog/completed/stg-001-plain.md | grep -q 'stg-000-base'"
staged_intact "whip-move field edit"
printf '# Task: stg-002-new\n\n- **ID**: stg-002-new\n- **Status**: pending\n- **Worktree**: none\n- **Dependencies**: none\n' > "$WORK/stg2.md"
staged_amend; bash "$STORE" create --file "$WORK/stg2.md" --stem stg-002-new --folder pending >/dev/null 2>&1; RC=$?
check "files create with a staged amendment: committed" "[ $RC -eq 0 ] && git cat-file -e HEAD:.backlog/pending/stg-002-new.md"
staged_intact "files create"
staged_amend; bash "$STORE" update-field stg-002-new --set Priority=high >/dev/null 2>&1; RC=$?
check "files update-field with a staged amendment: committed" "[ $RC -eq 0 ] && git show HEAD:.backlog/pending/stg-002-new.md | grep -q 'Priority'"
staged_intact "files update-field"
staged_amend; { cat .backlog/pending/stg-002-new.md; printf '\n## Notes\nbody edit\n'; } > "$WORK/stg2b.md"
bash "$STORE" update-body stg-002-new < "$WORK/stg2b.md" >/dev/null 2>&1; RC=$?
check "files update-body with a staged amendment: committed" "[ $RC -eq 0 ] && git show HEAD:.backlog/pending/stg-002-new.md | grep -q 'body edit'"
staged_intact "files update-body"
git reset -q -- "$PLAN"; git checkout -q -- "$PLAN"

echo
echo "phase4-whip-move: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
