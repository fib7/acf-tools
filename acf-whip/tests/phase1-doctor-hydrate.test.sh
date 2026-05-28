#!/usr/bin/env bash
# phase1-doctor-hydrate.test.sh — verifies doctor.sh invariants/repairs and hydrate-worktree.sh.
# Run: bash acf-whip/tests/phase1-doctor-hydrate.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ACF_WHIP/skills/whip-doctor/bin/doctor.sh"
HYD="$ACF_WHIP/skills/clean-checkout-before-task/bin/hydrate-worktree.sh"
CC="$ACF_WHIP/skills/clean-checkout-before-task/bin/clean-checkout.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p1.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
mkdir -p .claude/agents; echo x > .claude/agents/go-engineer.md
echo seed>seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk

mktask(){ # <dir> <stem> <slug> <status> <agent> <deps> <integ> <rc> [globs]
  cat > ".backlog/$1/$2.md" <<EOF
# Task: $2

## Metadata

- **ID**: $2
- **Status**: $4
- **Assigned Agent**: $5
- **Worktree**: $3
- **PR Group**: $3
- **Dependencies**: $6
- **Integrated-At**: $7
- **Rejection Count**: $8
- **Touches Globs**: ${9:-}

## Transition Log
EOF
}

echo "== healthy backlog -> no FATAL =="
mktask pending h1 alpha pending go-engineer none "" 0 "src/a/**"
mktask pending h2 beta pending go-engineer none "" 0 "src/b/**"
git add -A; git commit -qm seedtasks
OUT=$(bash "$DOC" "$REPO"); RC=$?
check "doctor exits 0 on healthy" "[ $RC -eq 0 ]"
check "summary ok=true" "echo \"$OUT\" | grep -q 'SUMMARY|.*|ok=true'"
check "no FATAL lines" "! echo \"$OUT\" | grep -q '^FATAL'"

echo "== FATAL invariants =="
mktask pending bad-status alpha2 in-progress go-engineer none "" 0   # status != folder
mktask pending bad-slug "" pending go-engineer none "" 0             # empty slug
mktask pending ok-noslug none pending go-engineer none "" 0          # explicit none -> ok
mktask pending bad-agent gx pending ghost-engineer none "" 0         # unknown agent
mktask pending dangle dd pending go-engineer "does-not-exist" "" 0   # dangling dep
mktask pending cyc-a ca pending go-engineer "cyc-b" "" 0             # cycle
mktask pending cyc-b cb pending go-engineer "cyc-a" "" 0
git add -A; git commit -qm badtasks
OUT=$(bash "$DOC" "$REPO"); RC=$?
check "doctor exits 1 when FATAL present" "[ $RC -eq 1 ]"
check "status-folder-mismatch" "echo \"$OUT\" | grep -q '^FATAL|status-folder-mismatch|bad-status'"
check "missing-worktree-slug" "echo \"$OUT\" | grep -q '^FATAL|missing-worktree-slug|bad-slug'"
check "explicit none is NOT flagged" "! echo \"$OUT\" | grep -q 'missing-worktree-slug|ok-noslug'"
check "unknown-agent" "echo \"$OUT\" | grep -q '^FATAL|unknown-agent|bad-agent'"
check "dangling-dep" "echo \"$OUT\" | grep -q '^FATAL|dangling-dep|dangle'"
check "cyclic-deps detected" "echo \"$OUT\" | grep -qE '^FATAL\|cyclic-deps\|cyc-[ab]'"

echo "== duplicate ID across files =="
cp .backlog/pending/h1.md .backlog/blocked/h1-copy.md   # same ID 'h1' inside, different stem -> duplicate-id
git add -A; git commit -qm dupid
OUT=$(bash "$DOC" "$REPO")
check "duplicate-id" "echo \"$OUT\" | grep -q '^FATAL|duplicate-id|h1'"
rm .backlog/blocked/h1-copy.md; git add -A; git commit -qm undup

echo "== REPAIRABLE + --fix =="
# Clean slate of repairables
rm -f .backlog/pending/bad-*.md .backlog/pending/dangle.md .backlog/pending/cyc-*.md
mktask accepted r-integ alpha accepted go-engineer none "" 0           # we'll add bad integ below in non-accepted
mktask pending r-stray-integ gg pending go-engineer none "abc1234" 0   # integ on non-accepted -> repairable
mktask pending r-rc gg2 pending go-engineer none "" 9                  # rc out of range
git add -A; git commit -qm repairables
OUT=$(bash "$DOC" "$REPO")
check "integrated-at-on-non-accepted reported" "echo \"$OUT\" | grep -q '^REPAIRABLE|integrated-at-on-non-accepted|r-stray-integ'"
check "rejection-count-out-of-range reported" "echo \"$OUT\" | grep -q '^REPAIRABLE|rejection-count-out-of-range|r-rc'"
bash "$DOC" --fix "$REPO" >/dev/null
check "stray Integrated-At cleared after --fix" "! grep -qE '^- \*\*Integrated-At\*\*: abc1234' '$REPO/.backlog/pending/r-stray-integ.md'"
check "Rejection Count clamped to 5 after --fix" "grep -qE '^- \*\*Rejection Count\*\*: 5' '$REPO/.backlog/pending/r-rc.md'"

echo "== orphaned + wrong-branch worktree =="
mktask pending wlive wlive pending go-engineer none "" 0; git add -A; git commit -qm wlive
bash "$CC" "$REPO/.backlog/pending/wlive.md" >/dev/null 2>&1   # creates .worktree/wlive (live)
# orphan: create a worktree whose slug has no live task
git -C "$REPO" worktree add -q "$REPO/.worktree/ghost" -b worktree/ghost trunk 2>/dev/null
OUT=$(bash "$DOC" "$REPO")
check "orphaned-worktree reported" "echo \"$OUT\" | grep -q '^REPAIRABLE|orphaned-worktree|ghost'"
check "live worktree NOT flagged orphan" "! echo \"$OUT\" | grep -q 'orphaned-worktree|wlive'"
bash "$DOC" --fix "$REPO" >/dev/null
check "orphan worktree removed after --fix" "[ ! -d '$REPO/.worktree/ghost' ]"

echo "== WARN: lingering in-review =="
mktask in-review wr wr in-review go-engineer none "" 0; git add -A; git commit -qm wr
OUT=$(bash "$DOC" "$REPO")
check "lingering-in-review WARN" "echo \"$OUT\" | grep -q '^WARN|lingering-in-review|wr'"

echo "== hydrate-worktree.sh =="
HR="$WORK/hydrepo"; git init -q -b trunk "$HR"; cd "$HR"; git config user.email t@t; git config user.name t
printf '.env\nnode_modules/\nsecrets/\nlocalcfg/\n' > .gitignore
git add .gitignore; git commit -qm gi
echo "SECRET=1" > .env
mkdir -p node_modules/pkg; echo m > node_modules/pkg/index.js
mkdir -p secrets; echo "key" > secrets/api.key
mkdir -p localcfg; echo "c" > localcfg/dev.json
echo "tracked" > tracked.txt; git add tracked.txt; git commit -qm tracked
WT="$HR/.worktree/x"; mkdir -p "$WT"
printf '# manifest\n.env\nlink: node_modules\nsecret: secrets/api.key\ncopy: localcfg\n' > "$HR/.worktreeinclude"
OUT=$(bash "$HYD" "$HR" "$WT"); RC=$?
check "hydrate exit 0" "[ $RC -eq 0 ]"
check ".env copied (not symlink)" "[ -f '$WT/.env' ] && [ ! -L '$WT/.env' ]"
check "node_modules symlinked" "[ -L '$WT/node_modules' ]"
check "secret copied + perms stripped" "[ -f '$WT/secrets/api.key' ] && [ ! -L '$WT/secrets/api.key' ]"
check "localcfg copied" "[ -f '$WT/localcfg/dev.json' ]"
# idempotency
OUT2=$(bash "$HYD" "$HR" "$WT")
check "idempotent re-run skips" "echo \"$OUT2\" | grep -qi 'skip (exists)'"

echo "== hydrate secret-safety: link of secret forced to copy =="
WT2="$HR/.worktree/y"; mkdir -p "$WT2"
printf 'link: .env\n' > "$HR/.worktreeinclude"
OUT=$(bash "$HYD" "$HR" "$WT2" 2>&1)
check ".env link downgraded to copy" "[ -f '$WT2/.env' ] && [ ! -L '$WT2/.env' ]"
check "downgrade warned" "echo \"$OUT\" | grep -qi 'forcing copy'"

echo "== hydrate hard errors: tracked + non-ignored path =="
WT3="$HR/.worktree/z"; mkdir -p "$WT3"
printf 'tracked.txt\n' > "$HR/.worktreeinclude"
bash "$HYD" "$HR" "$WT3" >/dev/null 2>&1; RC=$?
check "tracked path -> exit 3" "[ $RC -eq 3 ]"
echo "untracked-not-ignored" > "$HR/loose.txt"
printf 'loose.txt\n' > "$HR/.worktreeinclude"
bash "$HYD" "$HR" "$WT3" >/dev/null 2>&1; RC=$?
check "non-ignored path -> exit 3" "[ $RC -eq 3 ]"

echo ""
echo "==================================================="
echo "Phase 1 doctor+hydrate test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
