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
# I4: status-folder-mismatch on an ACTIVE task is REPAIRABLE (folder is source of truth; --fix syncs
# Status), NOT FATAL — so a stale Status can never abort /go at its first transition.
check "status-folder-mismatch (active=REPAIRABLE)" "echo \"$OUT\" | grep -q '^REPAIRABLE|status-folder-mismatch|bad-status'"
check "status-folder-mismatch active NOT FATAL" "! echo \"$OUT\" | grep -q '^FATAL|status-folder-mismatch|bad-status'"
check "missing-worktree-slug (active=REPAIRABLE, not FATAL)" "echo \"$OUT\" | grep -q '^REPAIRABLE|missing-worktree-slug|bad-slug'"
check "missing-worktree-slug active NOT FATAL" "! echo \"$OUT\" | grep -q '^FATAL|missing-worktree-slug|bad-slug'"
check "explicit none is NOT flagged" "! echo \"$OUT\" | grep -q 'missing-worktree-slug|ok-noslug'"
check "unknown-agent" "echo \"$OUT\" | grep -q '^FATAL|unknown-agent|bad-agent'"
check "dangling-dep" "echo \"$OUT\" | grep -q '^FATAL|dangling-dep|dangle'"
check "cyclic-deps detected" "echo \"$OUT\" | grep -qE '^FATAL\|cyclic-deps\|cyc-[ab]'"

echo "== duplicate ID across files (LP-CAS: WARN/quarantine, NEVER a run-aborting FATAL) =="
cp .backlog/pending/h1.md .backlog/blocked/h1-copy.md   # same ID 'h1' inside, different stem -> duplicate-id
git add -A; git commit -qm dupid
OUT=$(bash "$DOC" "$REPO")
check "duplicate-id reported as WARN (advisory)" "echo \"$OUT\" | grep -q '^WARN|duplicate-id|h1'"
check "duplicate-id is NOT FATAL (no global abort, #6)" "! echo \"$OUT\" | grep -q '^FATAL|duplicate-id'"
rm .backlog/blocked/h1-copy.md; git add -A; git commit -qm undup
# Clean-backlog proof that a lone duplicate id keeps the gate GREEN (run proceeds, operator de-dups later).
echo "== duplicate ID on an otherwise-healthy backlog keeps ok=true / exit 0 =="
DUPWORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-dupid.XXXXXX")
git init -qb trunk "$DUPWORK"; git -C "$DUPWORK" config user.email t@t; git -C "$DUPWORK" config user.name t
mkdir -p "$DUPWORK"/.backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted} "$DUPWORK/.claude/agents"
: > "$DUPWORK/.claude/agents/go-engineer.md"
printf '# Task\n## Metadata\n- **ID**: dz\n- **Status**: pending\n- **Assigned Agent**: go-engineer\n- **Worktree**: none\n- **Dependencies**: none\n' > "$DUPWORK/.backlog/pending/d1.md"
printf '# Task\n## Metadata\n- **ID**: dz\n- **Status**: blocked\n- **Assigned Agent**: go-engineer\n- **Worktree**: none\n- **Dependencies**: none\n' > "$DUPWORK/.backlog/blocked/d1-copy.md"
DUP_OUT=$(bash "$DOC" "$DUPWORK"); DUP_RC=$?
rm -rf "$DUPWORK"
check "clean backlog + duplicate id: gate exit 0 (#6 fixed)" "[ $DUP_RC -eq 0 ]"
check "clean backlog + duplicate id: SUMMARY ok=true" "echo \"$DUP_OUT\" | grep -q 'ok=true'"

echo "== REPAIRABLE + --fix =="
# Clean slate of repairables
rm -f .backlog/pending/bad-*.md .backlog/pending/dangle.md .backlog/pending/cyc-*.md
mktask accepted r-integ alpha accepted go-engineer none "" 0           # terminal accepted (advisory only)
mktask pending r-stray-integ gg pending go-engineer none "abc1234" 0   # LP-CAS: Integrated-At is INERT — no finding
mktask pending r-rc gg2 pending go-engineer none "" 9                  # rc out of range
mktask in-progress r-status rst completed go-engineer none "" 0        # I4: Status 'completed' but in in-progress/
git add -A; git commit -qm repairables
OUT=$(bash "$DOC" "$REPO")
# LP-CAS (3.0.0): Integrated-At is inert (the ledger is the oracle), so the doctor no longer reconciles
# it — an Integrated-At on a non-accepted task produces NO finding and --fix leaves it untouched (#5 gone).
check "Integrated-At on non-accepted: NO finding (field is inert)" "! echo \"$OUT\" | grep -q 'integrated-at-on-non-accepted'"
check "rejection-count-out-of-range reported" "echo \"$OUT\" | grep -q '^REPAIRABLE|rejection-count-out-of-range|r-rc'"
check "I4: status-folder-mismatch reported REPAIRABLE" "echo \"$OUT\" | grep -q '^REPAIRABLE|status-folder-mismatch|r-status'"
bash "$DOC" --fix "$REPO" >/dev/null
check "Rejection Count clamped to 5 after --fix" "grep -qE '^- \*\*Rejection Count\*\*: 5' '$REPO/.backlog/pending/r-rc.md'"
check "I4: Status synced to folder after --fix (completed -> in-progress)" "grep -qE '^- \*\*Status\*\*: in-progress\$' '$REPO/.backlog/in-progress/r-status.md'"
rm -f .backlog/in-progress/r-status.md; git add -A; git commit -qm cleanup-rstatus

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

echo "== a PARKED task keeps its worktree (3.4.0 pause is a real state) =="
# The reaper's liveness census is built from the ACTIVE folders only, and draft/archive are not among
# them — so the supported way to park work (`/whip-move <task> draft`) made the task's slug look
# unowned, and the next bootstrap `doctor --fix` force-removed the worktree and -D'd the branch.
# /go runs that --fix with stdout discarded, so the deliverable went with nothing saying so.
mkdir -p "$REPO/.backlog/draft" "$REPO/.backlog/archive"
mktask draft parked parked draft go-engineer none "" 0; git add -A; git commit -qm parked
bash "$CC" "$REPO/.backlog/draft/parked.md" >/dev/null 2>&1 || \
  git -C "$REPO" worktree add -q "$REPO/.worktree/parked" -b worktree/parked trunk 2>/dev/null
OUT=$(bash "$DOC" "$REPO")
check "a paused task's worktree is NOT called orphaned" "! echo \"$OUT\" | grep -q 'orphaned-worktree|parked'"
check "...it is reported as parked instead, so it stays visible" "echo \"$OUT\" | grep -q '^WARN|parked-task-worktree|parked'"
bash "$DOC" --fix "$REPO" >/dev/null
check "...and it SURVIVES --fix (the whole point of pausing)" "[ -d '$REPO/.worktree/parked' ]"
check "...branch intact too" "git -C '$REPO' rev-parse --verify -q refs/heads/worktree/parked >/dev/null"

# Same protection for a retired task: archive is cancel, not 'destroy the only copy'.
git -C "$REPO" mv .backlog/draft/parked.md .backlog/archive/parked.md 2>/dev/null || \
  { mkdir -p "$REPO/.backlog/archive"; mv "$REPO/.backlog/draft/parked.md" "$REPO/.backlog/archive/parked.md"; }
sed -i '' -E 's/^- \*\*Status\*\*: .*/- **Status**: archive/' "$REPO/.backlog/archive/parked.md" 2>/dev/null || \
  sed -i -E 's/^- \*\*Status\*\*: .*/- **Status**: archive/' "$REPO/.backlog/archive/parked.md"
git add -A; git commit -qm archived
bash "$DOC" --fix "$REPO" >/dev/null
check "an archived task's worktree also survives --fix" "[ -d '$REPO/.worktree/parked' ]"
git -C "$REPO" worktree remove --force "$REPO/.worktree/parked" 2>/dev/null
git -C "$REPO" branch -D worktree/parked >/dev/null 2>&1
rm -f "$REPO/.backlog/archive/parked.md"; git add -A; git commit -qm cleanup-parked >/dev/null

echo "== ownership scoping: foreign worktrees under .worktree/ are left alone =="
# A user's own research/benchmark worktree parked under .worktree/, on a NON-namespace branch.
# acf-whip owns only the <prefix>/<slug> branch namespace, so this must be invisible to the
# doctor: no orphaned-worktree, no wrong-branch FATAL, and NOT removed by --fix.
git -C "$REPO" worktree add -q "$REPO/.worktree/research" -b bench/research trunk 2>/dev/null
mkdir -p "$REPO/.worktree/scratch"   # a plain (non-worktree) dir — also not ours
OUT=$(bash "$DOC" "$REPO")
check "foreign worktree NOT flagged orphan" "! echo \"$OUT\" | grep -q 'orphaned-worktree|research'"
check "foreign worktree NOT flagged wrong-branch" "! echo \"$OUT\" | grep -q 'worktree-wrong-branch|research'"
check "plain dir under .worktree NOT flagged" "! echo \"$OUT\" | grep -q 'scratch'"
bash "$DOC" --fix "$REPO" >/dev/null 2>&1
check "foreign worktree SURVIVES --fix" "[ -d '$REPO/.worktree/research' ]"
check "foreign branch SURVIVES --fix" "git -C '$REPO' show-ref --verify --quiet refs/heads/bench/research"
check "plain dir SURVIVES --fix" "[ -d '$REPO/.worktree/scratch' ]"
git -C "$REPO" worktree remove --force "$REPO/.worktree/research" 2>/dev/null
git -C "$REPO" branch -D bench/research >/dev/null 2>&1
rm -rf "$REPO/.worktree/scratch"

echo "== configurable namespace (.acfw-config ACFW_WORKTREE_DIR / ACFW_BRANCH_PREFIX) =="
CN="$WORK/cnrepo"; git init -q -b main "$CN"
git -C "$CN" config user.email t@t; git -C "$CN" config user.name t
mkdir -p "$CN/.backlog"/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
mkdir -p "$CN/.claude/agents"; echo x > "$CN/.claude/agents/go-engineer.md"
printf 'ACFW_WORKTREE_DIR=.wt\nACFW_BRANCH_PREFIX=wtx\n' > "$CN/.backlog/.acfw-config"
echo seed > "$CN/seed"; git -C "$CN" add -A; git -C "$CN" commit -qm seed
cat > "$CN/.backlog/pending/c1.md" <<EOF
# Task: c1

## Metadata

- **ID**: c1
- **Status**: pending
- **Assigned Agent**: go-engineer
- **Worktree**: cslug
- **PR Group**: cslug
- **Dependencies**: none
- **Integrated-At**:
- **Rejection Count**: 0
- **Touches Globs**:

## Transition Log
EOF
git -C "$CN" add -A; git -C "$CN" commit -qm c1
OUT=$(ACFW_TRUNK_ROOT="$CN" ACFW_TRUNK_BRANCH=main bash "$CC" "$CN/.backlog/pending/c1.md" 2>/dev/null)
check "clean-checkout prints custom worktree path" "[ \"$OUT\" = '$CN/.wt/cslug' ]"
check "worktree created at custom dir .wt/cslug" "[ -d '$CN/.wt/cslug' ]"
check "branch created in custom namespace wtx/cslug" "git -C '$CN' show-ref --verify --quiet refs/heads/wtx/cslug"
check "default .worktree/ NOT created under custom namespace" "[ ! -d '$CN/.worktree' ]"
OUT=$(ACFW_TRUNK_ROOT="$CN" ACFW_TRUNK_BRANCH=main bash "$DOC" "$CN")
check "doctor ok under custom namespace" "echo \"$OUT\" | grep -q 'SUMMARY|.*|ok=true'"
check "live custom-namespace worktree NOT flagged orphan" "! echo \"$OUT\" | grep -q 'orphaned-worktree|cslug'"

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

cd "$REPO"
SCAN="$ACF_WHIP/skills/go/bin/scan-backlog.sh"

echo "== missing slug on ACTIVE task: REPAIRABLE, derived + written by --fix =="
mktask pending bug-201-make-thing "" pending go-engineer none "" 0 "src/c/**"
git add -A; git commit -qm slugderive
OUT=$(bash "$DOC" "$REPO")
check "active missing-slug REPAIRABLE" "echo \"\$OUT\" | grep -q '^REPAIRABLE|missing-worktree-slug|bug-201-make-thing'"
check "active missing-slug NOT FATAL" "! echo \"\$OUT\" | grep -q '^FATAL|missing-worktree-slug|bug-201-make-thing'"
bash "$DOC" --fix "$REPO" >/dev/null
check "slug derived (make-thing) + written by --fix" "grep -qE '^- \*\*Worktree\*\*: make-thing\$' '$REPO/.backlog/pending/bug-201-make-thing.md'"
rm -f .backlog/pending/bug-201-make-thing.md; git add -A; git commit -qm cleanup-slugderive

echo "== ACCEPTED tasks: structural defects are advisory (WARN), never FATAL =="
mktask accepted hist-noslug "" rejected ghost-engineer none "" 0   # empty slug + status!=folder + unknown agent, all on accepted
git add -A; git commit -qm histaccepted
OUT=$(bash "$DOC" "$REPO")
check "accepted missing-slug -> WARN" "echo \"\$OUT\" | grep -q '^WARN|missing-worktree-slug|hist-noslug'"
check "accepted status-mismatch -> WARN" "echo \"\$OUT\" | grep -q '^WARN|status-folder-mismatch|hist-noslug'"
check "accepted unknown-agent -> WARN" "echo \"\$OUT\" | grep -q '^WARN|unknown-agent|hist-noslug'"
check "accepted defects add NO FATAL" "! echo \"\$OUT\" | grep -qE '^FATAL\\|(missing-worktree-slug|status-folder-mismatch|unknown-agent)\\|hist-noslug'"
check "gate passes (ok=true) with only accepted advisories" "echo \"\$OUT\" | grep -q 'SUMMARY|.*|ok=true'"
check "BREAKDOWN line emitted" "echo \"\$OUT\" | grep -q '^BREAKDOWN|'"
rm -f .backlog/accepted/hist-noslug.md; git add -A; git commit -qm cleanup-histaccepted

echo "== branch-aware cross-slug dep: branchless historical accepted dep is satisfied =="
mktask accepted dep-201-base depslug accepted go-engineer none "" 0 "src/base/**"
mktask in-progress use-201-feat featslug in-progress go-engineer "dep-201-base" "" 0 "src/feat/**"
git add -A; git commit -qm crossslug
OUT=$(bash "$DOC" "$REPO")
check "cross-slug dep on branchless accepted: NOT FATAL" "! echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|use-201-feat'"
git -C "$REPO" worktree add -q "$REPO/.worktree/depslug" -b worktree/depslug trunk 2>/dev/null
OUT=$(bash "$DOC" "$REPO")
check "cross-slug dep with live branch + no integ: FATAL" "echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|use-201-feat'"
git -C "$REPO" worktree remove --force "$REPO/.worktree/depslug" 2>/dev/null
git -C "$REPO" branch -D worktree/depslug >/dev/null 2>&1
rm -f .backlog/accepted/dep-201-base.md .backlog/in-progress/use-201-feat.md; git add -A; git commit -qm cleanup-crossslug

echo "== accepted-only dangling/cyclic deps are WARN (not FATAL) =="
mktask accepted acc-dangle adslug accepted go-engineer "ghost-dep-xyz" "" 0 "src/d/**"
mktask accepted acc-cyc-a aca accepted go-engineer "acc-cyc-b" "" 0 "src/e/**"
mktask accepted acc-cyc-b acb accepted go-engineer "acc-cyc-a" "" 0 "src/f/**"
git add -A; git commit -qm accdeps
OUT=$(bash "$DOC" "$REPO")
check "accepted dangling-dep -> WARN" "echo \"\$OUT\" | grep -q '^WARN|dangling-dep|acc-dangle'"
check "accepted cyclic-deps -> WARN" "echo \"\$OUT\" | grep -qE '^WARN\\|cyclic-deps\\|acc-cyc-[ab]'"
check "accepted-only graph defects keep ok=true" "echo \"\$OUT\" | grep -q 'SUMMARY|.*|ok=true'"
rm -f .backlog/accepted/acc-dangle.md .backlog/accepted/acc-cyc-*.md; git add -A; git commit -qm cleanup-accdeps

echo "== scan-backlog working-set: branchless accepted collapses, live one is kept =="
mktask accepted sc-201-live livenow accepted go-engineer none "" 0 "src/live/**"
git add -A; git commit -qm scanlive
SNAP=$(bash "$SCAN" "$REPO")
# branchless accepted with no dependents = terminal-by-rule -> collapsed out of tasks[] (counted only)
check "branchless accepted collapsed from tasks[]" "! echo \"\$SNAP\" | grep -qE '\"stem\":\"sc-201-live\"'"
check "collapsed accepted still counted in runtimeTerminalDefault" "echo \"\$SNAP\" | grep -qE '\"runtimeTerminalDefault\":[1-9]'"
git -C "$REPO" worktree add -q "$REPO/.worktree/livenow" -b worktree/livenow trunk 2>/dev/null
SNAP=$(bash "$SCAN" "$REPO")
# now it has a live worktree branch -> non-terminal -> emitted with hasWorktreeBranch:true
check "live accepted kept with hasWorktreeBranch true" "echo \"\$SNAP\" | grep -qE '\"stem\":\"sc-201-live\"[^}]*\"hasWorktreeBranch\":true'"
git -C "$REPO" worktree remove --force "$REPO/.worktree/livenow" 2>/dev/null
git -C "$REPO" branch -D worktree/livenow >/dev/null 2>&1
rm -f .backlog/accepted/sc-201-live.md; git add -A; git commit -qm cleanup-scanlive

echo "== scan-backlog working-set: terminal accepted KEPT when something depends on it (anti-hang) =="
# integrated (terminal) accepted, referenced by a pending task -> must stay in tasks[] or depsSatisfied hangs
mktask accepted dep-target-acc dta accepted go-engineer none "abc1234" 0
mktask pending dep-consumer dcs pending go-engineer "dep-target-acc" "" 0 "src/dc/**"
# prefix dep: token "dep-target" is a prefix of stem "dep-target-acc" (mirrors indexTasks.resolve)
mktask accepted prefixacc-full pfa accepted go-engineer none "beef999" 0
mktask pending dep-consumer-pfx dcp pending go-engineer "prefixacc" "" 0 "src/dp/**"
git add -A; git commit -qm deptarget
SNAP=$(bash "$SCAN" "$REPO")
check "terminal accepted retained as EXACT dep target" "echo \"\$SNAP\" | grep -qE '\"stem\":\"dep-target-acc\"'"
check "terminal accepted retained as PREFIX dep target" "echo \"\$SNAP\" | grep -qE '\"stem\":\"prefixacc-full\"'"
# retained dep targets are SLIM (only the fields depsSatisfied/idx.resolve read): slim:true present,
# and the heavy full-object fields (status/agent/priority) are dropped — the slim layout puts
# deps/touchesGlobs immediately after slug, which a full object never does.
check "dep-target accepted emitted with slim:true" "echo \"\$SNAP\" | grep -qE '\"stem\":\"dep-target-acc\"[^}]*\"slim\":true'"
# LP-CAS: hasIntegratedAt now reflects the git ledger, not the (inert) Integrated-At field. This
# dep-target is terminal via no worktree branch (already on trunk the old way) and has no ledger marker.
check "slim dep-target drops full-only fields (deps right after slug)" "echo \"\$SNAP\" | grep -qE '\"stem\":\"dep-target-acc\",\"id\":\"[^\"]*\",\"folder\":\"accepted\",\"slug\":\"dta\",\"deps\":\[\],\"touchesGlobs\":\[\],\"hasIntegratedAt\":false'"
rm -f .backlog/accepted/dep-target-acc.md .backlog/accepted/prefixacc-full.md .backlog/pending/dep-consumer.md .backlog/pending/dep-consumer-pfx.md
git add -A; git commit -qm cleanup-deptarget

echo "== scan-backlog working-set: large historical backlog stays small =="
i=1; while [ $i -le 200 ]; do mktask accepted "hist-$i" "" accepted go-engineer none "" 0; i=$((i+1)); done
mktask pending live-1 livea pending go-engineer none "" 0 "src/x/**"
mktask pending live-2 liveb pending go-engineer none "" 0 "src/y/**"
git add -A; git commit -qm largebacklog
SNAP=$(bash "$SCAN" "$REPO")
NTASKS=$(printf '%s' "$SNAP" | grep -oE '"stem":' | wc -l | tr -d ' ')
NBYTES=$(printf '%s' "$SNAP" | wc -c | tr -d ' ')
TOTAL=$(printf '%s' "$SNAP" | grep -oE '"total":[0-9]+' | sed 's/.*://')
check "working-set tasks[] small (<30, not ~200)" "[ \"$NTASKS\" -lt 30 ]"
check "counts.total reflects full backlog (>=200)" "[ \"$TOTAL\" -ge 200 ]"
check "snapshot well under 20KB (was ~138KB)" "[ \"$NBYTES\" -lt 20000 ]"
i=1; while [ $i -le 200 ]; do rm -f ".backlog/accepted/hist-$i.md"; i=$((i+1)); done
rm -f .backlog/pending/live-1.md .backlog/pending/live-2.md
git add -A; git commit -qm cleanup-largebacklog

echo "== scan-backlog runtimeTerminal counts =="
# no worktree/* branches exist at this point -> every accepted is branchless -> all terminal-by-rule
mktask accepted rt-hist-1 "" accepted go-engineer none "" 0
mktask accepted rt-integ-1 rti accepted go-engineer none "deadbee" 0
mktask blocked rt-blk-1 rtb blocked go-engineer none "" 0
mktask pending rt-pend-1 rtp pending go-engineer none "" 0 "src/z/**"
git add -A; git commit -qm rtcounts
SNAP=$(bash "$SCAN" "$REPO")
RTD=$(printf '%s' "$SNAP" | grep -oE '"runtimeTerminalDefault":[0-9]+' | sed 's/.*://')
RTO=$(printf '%s' "$SNAP" | grep -oE '"runtimeTerminalOverride":[0-9]+' | sed 's/.*://')
BLK=$(printf '%s' "$SNAP" | grep -oE '"blocked":[0-9]+' | sed 's/.*://')
ACC=$(printf '%s' "$SNAP" | grep -oE '"accepted":[0-9]+' | sed 's/.*://')
check "runtimeTerminalOverride == blocked + accepted" "[ \"$RTO\" -eq $((BLK + ACC)) ]"
check "runtimeTerminalDefault == blocked + accepted (all branchless => terminal)" "[ \"$RTD\" -eq $((BLK + ACC)) ]"
check "runtimeTerminalDefault <= runtimeTerminalOverride" "[ \"$RTD\" -le \"$RTO\" ]"
rm -f .backlog/accepted/rt-hist-1.md .backlog/accepted/rt-integ-1.md .backlog/blocked/rt-blk-1.md .backlog/pending/rt-pend-1.md
git add -A; git commit -qm cleanup-rtcounts

echo "== scan-backlog: blocked emitted in tasks[] + inProgressTimeoutHours (env > config > 8) =="
# blocked tasks MUST be in the working set (the workflow now unblocks blocked->pending); the timeout
# threshold MUST be emitted so /go's in-progress->blocked timeout uses the operator's setting.
mktask blocked tb-blk tbb blocked go-engineer none "" 0
mktask in-progress tb-ip tbi in-progress go-engineer none "" 0
git add -A; git commit -qm tbtimeout
SNAP=$(bash "$SCAN" "$REPO")
check "blocked task emitted in tasks[] (drives unblock)" "echo \"\$SNAP\" | grep -qE '\"stem\":\"tb-blk\"[^}]*\"folder\":\"blocked\"'"
check "in-progress task emitted in tasks[]" "echo \"\$SNAP\" | grep -qE '\"stem\":\"tb-ip\"'"
check "inProgressTimeoutHours present (default 8)" "echo \"\$SNAP\" | grep -qE '\"inProgressTimeoutHours\":8'"
SNAP24=$(ACFW_INPROGRESS_TIMEOUT_HOURS=24 bash "$SCAN" "$REPO")
check "inProgressTimeoutHours honors env override (24)" "echo \"\$SNAP24\" | grep -qE '\"inProgressTimeoutHours\":24'"
printf 'ACFW_INPROGRESS_TIMEOUT_HOURS=12\n' > .backlog/.acfw-config
SNAPCFG=$(bash "$SCAN" "$REPO")
check "inProgressTimeoutHours honors .acfw-config (12)" "echo \"\$SNAPCFG\" | grep -qE '\"inProgressTimeoutHours\":12'"
check "scan stdout stays single JSON object despite .acfw-config" "echo \"\$SNAPCFG\" | grep -cE '^\\{' | grep -qx 1"
rm -f .backlog/.acfw-config .backlog/blocked/tb-blk.md .backlog/in-progress/tb-ip.md
git add -A; git commit -qm cleanup-tbtimeout

echo "== doctor --quiet: only FATAL + BREAKDOWN + SUMMARY =="
mktask accepted q-adv-1 "" accepted go-engineer none "" 0   # accepted missing slug -> WARN advisory
git add -A; git commit -qm quietadv
VERB=$(bash "$DOC" "$REPO"); QUI=$(bash "$DOC" --quiet "$REPO")
check "quiet SUMMARY identical to verbose" "[ \"\$(echo \"\$QUI\" | grep '^SUMMARY|')\" = \"\$(echo \"\$VERB\" | grep '^SUMMARY|')\" ]"
check "quiet keeps BREAKDOWN lines" "echo \"\$QUI\" | grep -q '^BREAKDOWN|'"
check "quiet suppresses per-WARN finding lines" "! echo \"\$QUI\" | grep -q '^WARN|'"
check "verbose still emits per-WARN finding lines" "echo \"\$VERB\" | grep -q '^WARN|'"
rm -f .backlog/accepted/q-adv-1.md; git add -A; git commit -qm cleanup-quietadv

echo "== doctor --active-only: same FATAL/ok as full, skips accepted advisories, no false dangling =="
AOR="$WORK/ao-repo"; git init -q -b trunk "$AOR" >/dev/null; (
  cd "$AOR"; git config user.email t@t; git config user.name t
  mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted} .claude/agents
  echo x > .claude/agents/go-engineer.md
  mkao(){ # <dir> <stem> <slug> <status> <deps> <integ>
    printf '# Task: %s\n\n## Metadata\n\n- **ID**: %s\n- **Status**: %s\n- **Assigned Agent**: go-engineer\n- **Worktree**: %s\n- **Dependencies**: %s\n- **Integrated-At**: %s\n- **Rejection Count**: 0\n\n## Transition Log\n' "$2" "$2" "$4" "$3" "$5" "$6" > ".backlog/$1/$2.md"
  }
  mkao accepted a-term alpha accepted none abc1234def        # terminal accepted (integrated) dep target
  mkao accepted a-cand charlie accepted none ""              # accepted, has branch, unintegrated (candidate)
  mkao pending p-deps-term pp pending "a-term" ""            # pending depends on TERMINAL accepted -> NO dangling
  mkao in-progress ip-fatal india in-progress "a-cand" ""   # cross-slug dep on unintegrated accepted -> FATAL
  printf '| 2026-06-02 10:00:00 | clean-checkout | ok |\n' >> .backlog/in-progress/ip-fatal.md
  mkao pending p-dangle echoslug pending "ghost-x" ""        # dangling dep -> FATAL
  git add -A; git commit -qm aofix >/dev/null
  git branch worktree/charlie; git branch worktree/india
)
AO_FULL=$(bash "$DOC" --quiet "$AOR"); AO_ACT=$(bash "$DOC" --quiet --active-only "$AOR")
check "active-only FATAL lines identical to full" \
  "[ \"\$(echo \"\$AO_FULL\"|grep '^FATAL|'|sort)\" = \"\$(echo \"\$AO_ACT\"|grep '^FATAL|'|sort)\" ]"
check "active-only same ok flag as full" \
  "[ \"\$(echo \"\$AO_FULL\"|grep -oE 'ok=(true|false)')\" = \"\$(echo \"\$AO_ACT\"|grep -oE 'ok=(true|false)')\" ]"
check "active-only catches active-folder dangling-dep FATAL" "echo \"\$AO_ACT\" | grep -q '^FATAL|dangling-dep|p-dangle'"
check "active-only catches cross-slug-dep-not-integrated against accepted dep" "echo \"\$AO_ACT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|ip-fatal'"
check "active-only: NO false dangling-dep for pending->terminal-accepted" "! echo \"\$AO_ACT\" | grep -q '^FATAL|dangling-dep|p-deps-term'"
check "active-only suppresses accepted advisory WARNs (fewer warns than full)" \
  "[ \"\$(echo \"\$AO_ACT\"|sed -nE 's/.*warn=([0-9]+).*/\1/p')\" -lt \"\$(echo \"\$AO_FULL\"|sed -nE 's/.*warn=([0-9]+).*/\1/p')\" ]"

echo "== WHIP-22: a raw NUL byte is ONE clear FATAL, not a cascade of phantom findings =="
# grep treats a NUL-bearing file as binary, so every field() lookup returns nothing and a perfectly
# well-formed task reports unparseable-frontmatter AND missing-worktree-slug. Detect the byte instead.
NB="$WORK/nul-repo"; git init -q -b trunk "$NB" >/dev/null
git -C "$NB" config user.email t@t; git -C "$NB" config user.name t
mkdir -p "$NB"/.backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted} "$NB/.claude/agents"
: > "$NB/.claude/agents/go-engineer.md"
printf '# Task\n\n- **ID**: nul-1\n- **Status**: pending\n- **Assigned Agent**: go-engineer\n- **Worktree**: nulslug\n- **Dependencies**: none\n' > "$NB/.backlog/pending/nul-1.md"
printf 'note: a literal \000 byte here\n' >> "$NB/.backlog/pending/nul-1.md"
git -C "$NB" add -A >/dev/null 2>&1; git -C "$NB" commit -qm nul >/dev/null 2>&1
NUL_OUT=$(bash "$DOC" "$NB"); NUL_RC=$?
check "control-bytes FATAL emitted" "echo \"\$NUL_OUT\" | grep -q '^FATAL|control-bytes|nul-1'"
check "control-bytes makes the gate fail (exit 1)" "[ $NUL_RC -eq 1 ]"
check "NO phantom unparseable-frontmatter for the same stem" "! echo \"\$NUL_OUT\" | grep -q 'unparseable-frontmatter|nul-1'"
check "NO phantom missing-worktree-slug for the same stem" "! echo \"\$NUL_OUT\" | grep -q 'missing-worktree-slug|nul-1'"
check "exactly one finding for the corrupted stem" "[ \"\$(echo \"\$NUL_OUT\" | grep -c '|nul-1|')\" -eq 1 ]"
# --fix must NOT silently 'heal' it: a NUL usually marks a torn write.
bash "$DOC" --fix "$NB" >/dev/null 2>&1
check "--fix does NOT strip the NUL (no silent heal of a torn write)" "[ \"\$(LC_ALL=C tr -dc '\\000' < '$NB/.backlog/pending/nul-1.md' | wc -c | tr -d '[:space:]')\" -gt 0 ]"
# the documented recipe actually clears it
LC_ALL=C tr -d '\000' < "$NB/.backlog/pending/nul-1.md" > "$NB/t" && mv "$NB/t" "$NB/.backlog/pending/nul-1.md"
FIXED_OUT=$(bash "$DOC" "$NB"); FIXED_RC=$?
check "runbook strip recipe clears the FATAL (exit 0)" "[ $FIXED_RC -eq 0 ]"
rm -rf "$NB"

echo "== WHIP-23: a COLLAPSED task file is its own FATAL, not generic unparseable-frontmatter =="
# Field incident 2026-08-24: an unlocked read-modify-write in append_log_row let a 17507-byte task
# document be replaced by its own 267-byte transition row, and the writer committed it. The doctor
# then reported it as unparseable-frontmatter + missing-worktree-slug — which reads as "someone
# fat-fingered the metadata" and sends the operator to re-type two fields, when in fact the whole
# document is gone and is sitting one commit back in git. Same shape as WHIP-22 above: name the
# real defect once, carry the recovery command, and do NOT let --fix silently "heal" a torn write.
CL="$WORK/collapse-repo"; git init -q -b trunk "$CL" >/dev/null
git -C "$CL" config user.email t@t; git -C "$CL" config user.name t
mkdir -p "$CL"/.backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted} "$CL/.claude/agents"
: > "$CL/.claude/agents/go-engineer.md"
# the corpse, verbatim from the incident
printf '| 2026-08-25 01:41:36 | pending | completed | nextjs-engineer | note |\n' \
  > "$CL/.backlog/in-progress/dead-1.md"
# a merely field-less file must KEEP the old code — this is the discriminator's other half
printf '# Task: prose-1\n\nno metadata bullets at all\n' > "$CL/.backlog/pending/prose-1.md"
git -C "$CL" add -A >/dev/null 2>&1; git -C "$CL" commit -qm seed >/dev/null 2>&1
CL_OUT=$(bash "$DOC" "$CL"); CL_RC=$?
check "collapsed-task-file FATAL emitted" "echo \"\$CL_OUT\" | grep -q '^FATAL|collapsed-task-file|dead-1'"
check "collapsed-task-file makes the gate fail (exit 1)" "[ $CL_RC -eq 1 ]"
check "NOT reported as unparseable-frontmatter" "! echo \"\$CL_OUT\" | grep -q 'unparseable-frontmatter|dead-1'"
check "NO phantom missing-worktree-slug for the same stem" "! echo \"\$CL_OUT\" | grep -q 'missing-worktree-slug|dead-1'"
# exactly one FATAL: a later mtime-based pass may still add a stale-in-progress WARN, which is
# correct and unrelated — what must not happen is a FATAL cascade.
check "exactly one FATAL for the collapsed stem (no cascade)" \
  "[ \"\$(echo \"\$CL_OUT\" | grep -c '^FATAL|.*|dead-1|')\" -eq 1 ]"
check "the finding carries the literal restore command" \
  "echo \"\$CL_OUT\" | grep -q 'checkout HEAD -- .backlog/in-progress/dead-1.md'"
check "a merely field-less file KEEPS unparseable-frontmatter" \
  "echo \"\$CL_OUT\" | grep -q '^FATAL|unparseable-frontmatter|prose-1'"
check "prose is NOT misclassified as collapsed" "! echo \"\$CL_OUT\" | grep -q 'collapsed-task-file|prose-1'"
# Deliberately not repairable, for WHIP-22's reason: restoring from HEAD would discard the
# clean-checkout token row, which is uncommitted by design.
bash "$DOC" --fix "$CL" >/dev/null 2>&1
check "--fix does NOT heal the collapse (no silent commit of a torn write)" \
  "[ \"\$(wc -l < '$CL/.backlog/in-progress/dead-1.md' | tr -d '[:space:]')\" -eq 1 ]"
check "--fix leaves the FATAL standing" "! bash '$DOC' '$CL' >/dev/null 2>&1"
# the documented recipe actually clears it
git -C "$CL" checkout HEAD -- .backlog/in-progress/dead-1.md >/dev/null 2>&1
printf '# Task\n\n- **ID**: dead-1\n- **Status**: in-progress\n- **Assigned Agent**: go-engineer\n- **Worktree**: deadslug\n- **Dependencies**: none\n' > "$CL/.backlog/in-progress/dead-1.md"
check "restoring the document clears collapsed-task-file" \
  "! bash '$DOC' '$CL' 2>&1 | grep -q 'collapsed-task-file'"

echo "== WHIP-23: a leftover append_log_row temp is invisible to every *.md consumer =="
# The atomic write-back leaves .acfw-log.XXXXXX in the task's own directory if it is SIGKILLed
# mid-splice. It is dot-prefixed AND non-.md so no consumer glob can mistake it for a task.
: > "$CL/.backlog/pending/.acfw-log.decoy"
DEC_OUT=$(bash "$DOC" "$CL" 2>&1)
check "the doctor emits no finding for the temp" "! echo \"\$DEC_OUT\" | grep -q 'acfw-log'"
check "scan-backlog does not list the temp as a task" \
  "! bash '$ACF_WHIP/skills/go/bin/scan-backlog.sh' '$CL' 2>/dev/null | grep -q 'acfw-log'"
rm -rf "$CL"

echo "== WHIP-19: legacy JSON-style Dependencies is REPAIRABLE and --fix clears the false dangling-dep =="
BD="$WORK/brackets-repo"; git init -q -b trunk "$BD" >/dev/null
git -C "$BD" config user.email t@t; git -C "$BD" config user.name t
mkdir -p "$BD"/.backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted} "$BD/.claude/agents"
: > "$BD/.claude/agents/go-engineer.md"
mkbd(){ printf '# Task\n\n- **ID**: %s\n- **Status**: pending\n- **Assigned Agent**: go-engineer\n- **Worktree**: %s\n- **Dependencies**: %s\n' "$1" "$2" "$3" > "$BD/.backlog/pending/$1.md"; }
mkbd bd-a aslug '[bd-b]'
mkbd bd-b bslug none
git -C "$BD" add -A >/dev/null 2>&1; git -C "$BD" commit -qm bd >/dev/null 2>&1
BD_OUT=$(bash "$DOC" "$BD"); BD_RC=$?
check "bracketed-deps reported REPAIRABLE" "echo \"\$BD_OUT\" | grep -q '^REPAIRABLE|bracketed-deps|bd-a'"
check "brackets DO cause the false dangling-dep FATAL today" "echo \"\$BD_OUT\" | grep -q '^FATAL|dangling-dep|bd-a'"
check "false dangling-dep blocks the gate (exit 1)" "[ $BD_RC -eq 1 ]"
bash "$DOC" --fix "$BD" >/dev/null 2>&1
check "--fix rewrites the line to a bare comma list" "grep -qE '^- \*\*Dependencies\*\*: bd-b\$' '$BD/.backlog/pending/bd-a.md'"
BD_OUT2=$(bash "$DOC" "$BD"); BD_RC2=$?
check "after --fix the dangling-dep FATAL is gone" "! echo \"\$BD_OUT2\" | grep -q '^FATAL|dangling-dep|bd-a'"
check "after --fix the gate passes (exit 0)" "[ $BD_RC2 -eq 0 ]"
rm -rf "$BD"

echo "== WHIP-26: a DIRTY orphan worktree is never force-removed =="
mktask pending wghost2 wghost2 pending go-engineer none "" 0; git add .backlog; git commit -qm wghost2
git -C "$REPO" worktree add -q "$REPO/.worktree/dirtyghost" -b worktree/dirtyghost trunk 2>/dev/null
echo "one-of-a-kind findings" > "$REPO/.worktree/dirtyghost/findings.md"   # untracked = still precious
rm -f .backlog/pending/wghost2.md; git add .backlog; git commit -qm orphan-it   # no live task on the slug
OUT=$(bash "$DOC" "$REPO")
check "dirty orphan reported as orphaned-worktree-dirty WARN" "echo \"\$OUT\" | grep -q '^WARN|orphaned-worktree-dirty|dirtyghost'"
check "dirty orphan NOT offered as a REPAIRABLE removal" "! echo \"\$OUT\" | grep -q '^REPAIRABLE|orphaned-worktree|dirtyghost'"
bash "$DOC" --fix "$REPO" >/dev/null 2>&1
check "dirty orphan SURVIVES --fix" "[ -d '$REPO/.worktree/dirtyghost' ]"
check "its uncommitted work SURVIVES --fix" "[ -f '$REPO/.worktree/dirtyghost/findings.md' ]"
# clean it, and the reaper takes it
rm -f "$REPO/.worktree/dirtyghost/findings.md"
bash "$DOC" --fix "$REPO" >/dev/null 2>&1
check "a CLEAN orphan is still reaped by --fix" "[ ! -d '$REPO/.worktree/dirtyghost' ]"
git -C "$REPO" branch -D worktree/dirtyghost >/dev/null 2>&1

echo "== WHIP-07: accepted + no branch + no ledger marker -> advisory, never silent =="
AB="$WORK/branchless-repo"; git init -q -b trunk "$AB" >/dev/null
git -C "$AB" config user.email t@t; git -C "$AB" config user.name t
mkdir -p "$AB"/.backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted} "$AB/.claude/agents"
: > "$AB/.claude/agents/go-engineer.md"
mkab(){ printf '# Task\n\n- **ID**: %s\n- **Status**: accepted\n- **Assigned Agent**: go-engineer\n- **Worktree**: %s\n- **Dependencies**: none\n- **Integrated-At**: %s\n' "$1" "$2" "$3" > "$AB/.backlog/accepted/$1.md"; }
mkab ab-unverified uslug ""      # accepted, no branch, no marker, no stamp -> WARN
mkab ab-stamped sslug abc1234    # legacy operator ack -> silent
mkab ab-marked mslug ""          # ledger marker present -> silent
# lay down the real ledger marker for ab-marked exactly where the integrator would
MP=$(cd "$AB" && . "$ACF_WHIP/skills/lib/acfw-git.sh" && acfw_marker_path ab-marked)
mkdir -p "$AB/$(dirname "$MP")"; printf '{"key":"ab-marked"}\n' > "$AB/$MP"
git -C "$AB" add -A >/dev/null 2>&1; git -C "$AB" commit -qm ab >/dev/null 2>&1
AB_OUT=$(bash "$DOC" "$AB"); AB_RC=$?
check "branchless accepted with no marker -> WARN" "echo \"\$AB_OUT\" | grep -q '^WARN|accepted-branchless-unverified|ab-unverified'"
check "WARN names the whip-move ack" "echo \"\$AB_OUT\" | grep -q 'accepted-branchless-unverified|ab-unverified|.*--integrated-at'"
check "operator-stamped accepted stays silent" "! echo \"\$AB_OUT\" | grep -q 'accepted-branchless-unverified|ab-stamped'"
check "ledger-marked accepted stays silent (oracle consulted)" "! echo \"\$AB_OUT\" | grep -q 'accepted-branchless-unverified|ab-marked'"
check "it stays TERMINAL: advisory only, gate still passes (exit 0)" "[ $AB_RC -eq 0 ]"
rm -rf "$AB"

echo "== oracle agreement: an LEDGER-integrated dep with an unreaped branch must NOT FATAL =="
# Nothing reaps worktree/<slug> right after integration, and Integrated-At is inert in 3.0.0. So a dep
# whose change IS on trunk (marker present) used to read as "not integrated" to the doctor's cross-slug
# gate while the SCHEDULER (which asks the ledger) had already dispatched the dependent -> the next
# per-iteration `doctor --quiet --active-only` recheck FATAL'd and aborted the whole run.
OA="$WORK/oracle-repo"; git init -q -b trunk "$OA" >/dev/null
git -C "$OA" config user.email t@t; git -C "$OA" config user.name t
mkdir -p "$OA"/.backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted} "$OA/.claude/agents"
: > "$OA/.claude/agents/go-engineer.md"
mkoa(){ printf '# T\n\n- **ID**: %s\n- **Status**: %s\n- **Assigned Agent**: go-engineer\n- **Worktree**: %s\n- **Dependencies**: %s\n- **Integrated-At**:\n- **Rejection Count**: 0\n' "$1" "$2" "$3" "$4" > "$OA/.backlog/$2/$1.md"; }
mkoa oa-dep accepted oaslug none
mkoa oa-use in-progress obslug oa-dep
printf '| 2026-06-02 10:00:00 | clean-checkout | ok |\n' >> "$OA/.backlog/in-progress/oa-use.md"
OMP=$(cd "$OA" && . "$ACF_WHIP/skills/lib/acfw-git.sh" && acfw_marker_path oa-dep)
mkdir -p "$OA/$(dirname "$OMP")"; printf '{}\n' > "$OA/$OMP"     # dep IS integrated: marker on trunk
git -C "$OA" add -A >/dev/null 2>&1; git -C "$OA" commit -qm oa >/dev/null 2>&1
git -C "$OA" branch worktree/oaslug; git -C "$OA" branch worktree/obslug   # branch NOT yet reaped
OA_FULL=$(bash "$DOC" "$OA"); OA_FRC=$?
OA_ACT=$(bash "$DOC" --quiet --active-only "$OA"); OA_ARC=$?
check "full pass: ledger-integrated dep does NOT FATAL" "! echo \"\$OA_FULL\" | grep -q '^FATAL|cross-slug-dep-not-integrated|oa-use'"
check "full pass: gate green (exit 0)" "[ $OA_FRC -eq 0 ]"
check "active-only (the mid-run recheck): no FATAL" "! echo \"\$OA_ACT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|oa-use'"
check "active-only: gate green -> run is not aborted" "[ $OA_ARC -eq 0 ]"
# and the gate STILL fires when the dep genuinely has not landed (no marker, live branch)
rm -f "$OA/$OMP"; git -C "$OA" add -A >/dev/null 2>&1; git -C "$OA" commit -qm unintegrate >/dev/null 2>&1
OA_NEG=$(bash "$DOC" --quiet --active-only "$OA")
check "no marker + live branch: cross-slug FATAL still fires (gate not defanged)" "echo \"\$OA_NEG\" | grep -q '^FATAL|cross-slug-dep-not-integrated|oa-use'"
rm -rf "$OA"

echo "== WHIP-25 / WHIP-06: repo-level advisories (dirty trunk root, unpushed trunk) =="
RL="$WORK/repolevel"; git init -q -b trunk "$RL" >/dev/null
git -C "$RL" config user.email t@t; git -C "$RL" config user.name t
mkdir -p "$RL"/.backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted} "$RL/.claude/agents"
printf 'seed\n' > "$RL/src.txt"; git -C "$RL" add -A >/dev/null 2>&1; git -C "$RL" commit -qm seed >/dev/null 2>&1
RL_OUT=$(bash "$DOC" "$RL")
check "clean root: no dirty-trunk-root WARN" "! echo \"\$RL_OUT\" | grep -q 'dirty-trunk-root'"
check "no origin ref: no trunk-unpushed WARN" "! echo \"\$RL_OUT\" | grep -q 'trunk-unpushed'"
printf 'untracked scratch\n' > "$RL/scratch.txt"
RL_OUT=$(bash "$DOC" "$RL")
check "UNTRACKED root file is not flagged (operator scratch is legitimate)" "! echo \"\$RL_OUT\" | grep -q 'dirty-trunk-root'"
printf 'escaped worktree write\n' >> "$RL/src.txt"
RL_OUT=$(bash "$DOC" "$RL")
check "TRACKED dirty root file -> dirty-trunk-root WARN" "echo \"\$RL_OUT\" | grep -q '^WARN|dirty-trunk-root|'"
git -C "$RL" checkout -- src.txt; rm -f "$RL/scratch.txt"
printf 'bl\n' > "$RL/.backlog/marker.txt"; git -C "$RL" add -A >/dev/null 2>&1; git -C "$RL" commit -qm bl >/dev/null 2>&1
printf 'state churn\n' >> "$RL/.backlog/marker.txt"
RL_OUT=$(bash "$DOC" "$RL")
check "dirty .backlog/ alone is NOT flagged (that is the writer's business)" "! echo \"\$RL_OUT\" | grep -q 'dirty-trunk-root'"
git -C "$RL" checkout -- .backlog/marker.txt
# simulate an origin that is 2 commits behind (no network, no remote needed)
BEHIND=$(git -C "$RL" rev-parse HEAD)
printf 'a\n' >> "$RL/src.txt"; git -C "$RL" commit -qam c1 >/dev/null 2>&1
printf 'b\n' >> "$RL/src.txt"; git -C "$RL" commit -qam c2 >/dev/null 2>&1
git -C "$RL" update-ref refs/remotes/origin/trunk "$BEHIND"
RL_OUT=$(bash "$DOC" "$RL"); RL_RC=$?
check "local trunk ahead of origin -> trunk-unpushed WARN with the count" "echo \"\$RL_OUT\" | grep -qE '^WARN\\|trunk-unpushed\\|.*2 commit'"
check "repo-level advisories never block the gate (exit 0)" "[ $RL_RC -eq 0 ]"
git -C "$RL" update-ref refs/remotes/origin/trunk "$(git -C "$RL" rev-parse HEAD)"
RL_OUT=$(bash "$DOC" "$RL")
check "in sync with origin -> no trunk-unpushed WARN" "! echo \"\$RL_OUT\" | grep -q 'trunk-unpushed'"
rm -rf "$RL"

# ---------------------------------------------------------------------------------------------------
# --active-only MUST NOT CHANGE THE GATE VERDICT. Its contract, stated in doctor.sh's own header and
# relied on by /go's bootstrap re-scan, is that it suppresses accepted-folder ADVISORIES while leaving
# the FATAL set and the ok flag untouched. That was false for the two content-loss checks: they are
# emitted from the per-file pass, which --active-only skips for accepted/, so a task document
# destroyed by a torn write (the 2026-08-24 incident collapsed-task-file exists for) passed the gate
# as ok=true. The equivalence below is the assertion that keeps the contract honest.
AO=$(mktemp -d); ( cd "$AO" && git init -q -b trunk . && git config user.email t@t && git config user.name t )
mkdir -p "$AO"/.backlog/{draft,pending,in-progress,completed,in-review,blocked,rejected,accepted} "$AO/.claude/agents"
echo x > "$AO/.claude/agents/go-engineer.md"
printf -- '# T\n\n- **ID**: feature-001\n- **Status**: pending\n- **Assigned Agent**: go-engineer\n- **Worktree**: sa\n- **Dependencies**: none\n' > "$AO/.backlog/pending/feature-001-ok.md"
# An ACCEPTED document collapsed to bare transition-log rows.
printf -- '| 2026-01-01 | pending | accepted | x | y |\n| 2026-01-02 | a | b | c | d |\n' > "$AO/.backlog/accepted/feature-002-collapsed.md"
( cd "$AO" && echo s > s && git add -A && git commit -qm s ) >/dev/null 2>&1

AO_FULL=$(bash "$DOC" --quiet "$AO" 2>/dev/null); AO_FULL_RC=$?
AO_FAST=$(bash "$DOC" --quiet --active-only "$AO" 2>/dev/null); AO_FAST_RC=$?
check "collapsed ACCEPTED document is FATAL on the full pass" \
  "printf '%s\n' \"\$AO_FULL\" | grep -q '^FATAL|collapsed-task-file|feature-002-collapsed'"
check "...and --active-only finds it too (the bootstrap gate runs that)" \
  "printf '%s\n' \"\$AO_FAST\" | grep -q '^FATAL|collapsed-task-file|feature-002-collapsed'"
check "--active-only reaches the same ok verdict as the full pass" \
  "[ \"\$(printf '%s\n' \"\$AO_FULL\" | sed -n 's/.*|ok=\(.*\)/\1/p')\" = \"\$(printf '%s\n' \"\$AO_FAST\" | sed -n 's/.*|ok=\(.*\)/\1/p')\" ]"
check "...and the same exit status" "[ $AO_FULL_RC -eq $AO_FAST_RC ]"

# A raw NUL in an accepted document: the other content-loss signature, same requirement.
printf -- '# T\n\n- **ID**: feature-003\n- **Status**: accepted\n\000\n' > "$AO/.backlog/accepted/feature-003-nul.md"
AO_N_FULL=$(bash "$DOC" --quiet "$AO" 2>/dev/null | grep -c '^FATAL|control-bytes|' || true)
AO_N_FAST=$(bash "$DOC" --quiet --active-only "$AO" 2>/dev/null | grep -c '^FATAL|control-bytes|' || true)
check "a NUL in an accepted document is FATAL on both paths" \
  "[ \"\${AO_N_FULL//[^0-9]/}\" -ge 1 ] && [ \"\${AO_N_FAST//[^0-9]/}\" -eq \"\${AO_N_FULL//[^0-9]/}\" ]"

# And the flag must still do its actual job: suppress accepted ADVISORIES.
printf -- '# T\n\n- **ID**: feature-004\n- **Status**: accepted\n- **Assigned Agent**: ghost-agent\n- **Worktree**: sd\n- **Dependencies**: none\n' > "$AO/.backlog/accepted/feature-004-adv.md"
AO_W_FULL=$(bash "$DOC" "$AO" 2>/dev/null | grep -c '^WARN|' || true)
AO_W_FAST=$(bash "$DOC" --active-only "$AO" 2>/dev/null | grep -c '^WARN|' || true)
check "--active-only still suppresses accepted advisories (that is what it is for)" \
  "[ \"\${AO_W_FAST//[^0-9]/}\" -lt \"\${AO_W_FULL//[^0-9]/}\" ]"
rm -rf "$AO"

# ---------------------------------------------------------------------------------------------------
# DERIVED-SLUG COLLISION. Two ids with the same descriptive tail derive the same worktree slug, and
# --fix would write it onto both — two tasks on one branch, which is the single thing a per-task slug
# exists to prevent. The registry that detects this MUST be a file: derive_slug_unique is invoked as
# `derived=$(derive_slug_unique "$id")`, a SUBSHELL, so a shell variable assigned inside it is
# discarded and the check can never fire. It shipped that way once; this is what catches it.
DS=$(mktemp -d); ( cd "$DS" && git init -q -b trunk . && git config user.email t@t && git config user.name t )
mkdir -p "$DS"/.backlog/{draft,pending,in-progress,completed,in-review,blocked,rejected,accepted} "$DS/.claude/agents"
echo x > "$DS/.claude/agents/go-engineer.md"
dmk(){ printf -- '# T\n\n- **ID**: %s\n- **Status**: pending\n- **Assigned Agent**: go-engineer\n- **Worktree**:\n- **Dependencies**: none\n- **Touches Globs**: none\n' "$1" > "$DS/.backlog/pending/$1-x.md"; }
dmk feature-001-auth   # -> auth
dmk bug-002-auth       # -> auth  (same tail, different category and number)
dmk feature-003-solo   # -> solo  (must be unaffected)
( cd "$DS" && echo s > s && git add -A && git commit -qm s ) >/dev/null 2>&1

DS_OUT=$(bash "$DOC" "$DS" 2>/dev/null)
check "two ids deriving one slug is a FATAL" \
  "printf '%s\n' \"\$DS_OUT\" | grep -q '^FATAL|duplicate-derived-slug|'"
check "exactly ONE of the pair is reported (the second claimant, not both)" \
  "[ \"\$(printf '%s\n' \"\$DS_OUT\" | grep -c '^FATAL|duplicate-derived-slug|')\" -eq 1 ]"
check "the collided task gets no contradictory repair promise" \
  "! printf '%s\n' \"\$DS_OUT\" | grep -q \"will derive '' from the id\""
check "a task with a unique tail is still offered its repair" \
  "printf '%s\n' \"\$DS_OUT\" | grep -q \"missing-worktree-slug|feature-003-solo-x|no Worktree slug; --fix will derive 'solo'\""

bash "$DOC" --fix "$DS" >/dev/null 2>&1
DS_AUTH=$(grep -l '^- \*\*Worktree\*\*: auth$' "$DS"/.backlog/pending/*.md 2>/dev/null | wc -l | tr -d ' ')
check "--fix writes the contended slug to exactly one task, never both" "[ \"\${DS_AUTH:-0}\" -eq 1 ]"
check "--fix still repairs the uncontended task" \
  "grep -q '^- \*\*Worktree\*\*: solo$' \"$DS/.backlog/pending/feature-003-solo-x.md\""

# DURABILITY. The finding was one-shot: run 1 gave the slug to the first claimant and refused the
# second; run 2 saw the first holding an EXPLICIT slug (so it never entered the derive path), found an
# empty registry, and handed the same slug to the second — producing exactly the duplicate the FATAL
# had reported. The registry is seeded from slugs already claimed, so the refusal survives re-runs.
bash "$DOC" --fix "$DS" >/dev/null 2>&1
bash "$DOC" --fix "$DS" >/dev/null 2>&1
DS_AUTH2=$(grep -l '^- \*\*Worktree\*\*: auth$' "$DS"/.backlog/pending/*.md 2>/dev/null | wc -l | tr -d ' ')
check "the refusal is DURABLE: three --fix runs still leave the slug on exactly one task" "[ \"\${DS_AUTH2:-0}\" -eq 1 ]"
DS_RPT=$(bash "$DOC" "$DS" 2>/dev/null)
check "...and the collision is still reported after those runs" \
  "printf '%s\n' \"\$DS_RPT\" | grep -q '^FATAL|duplicate-derived-slug|'"

# A derived slug must also lose to an EXPLICIT holder, not just to another derived one.
dmk feature-004-solo   # derives 'solo', which feature-003 now holds explicitly
( cd "$DS" && git add -A && git commit -qm x ) >/dev/null 2>&1
DS_EXP=$(bash "$DOC" "$DS" 2>/dev/null)
check "a derived slug colliding with an EXPLICIT holder is also a FATAL" \
  "printf '%s\n' \"\$DS_EXP\" | grep -q 'duplicate-derived-slug|feature-004-solo-x'"
rm -rf "$DS"

# ---------------------------------------------------------------------------------------------------
# CROSS-SLUG GLOB OVERLAP. Nothing asserted this at all, which is how it stayed a pairwise double loop:
# O(P^2) comparisons emitting one WARN per overlapping PAIR, so a handful of tasks sharing one glob
# buried every real finding under a quadratic wall of advisories. It is an index — group by glob, count
# distinct slugs — and the output must be bounded by the number of TASKS, not pairs.
GO=$(mktemp -d); ( cd "$GO" && git init -q -b trunk . && git config user.email t@t && git config user.name t )
mkdir -p "$GO"/.backlog/{draft,pending,in-progress,completed,in-review,blocked,rejected,accepted} "$GO/.claude/agents"
echo x > "$GO/.claude/agents/go-engineer.md"
gmk(){ printf -- '# T\n\n- **ID**: feature-%s\n- **Status**: pending\n- **Assigned Agent**: go-engineer\n- **Worktree**: %s\n- **Dependencies**: none\n- **Touches Globs**: %s\n' "$1" "$2" "$3" > "$GO/.backlog/pending/feature-$1-t.md"; }
for gi in 1 2 3 4 5 6; do gmk "00$gi" "slug-$gi" "src/shared/**"; done
gmk 020 slug-20 "src/private/**"
( cd "$GO" && echo s > s && git add -A && git commit -qm s ) >/dev/null 2>&1

GO_OUT=$(bash "$DOC" "$GO" 2>/dev/null)
GO_N=$(printf '%s\n' "$GO_OUT" | grep -c '^WARN|cross-slug-glob-overlap|' || true); GO_N=${GO_N//[^0-9]/}
check "contended glob is reported once per TASK (6), not once per PAIR (15)" "[ \"\${GO_N:-0}\" -eq 6 ]"
check "a task whose globs are its own is NOT flagged" \
  "! printf '%s\n' \"\$GO_OUT\" | grep -q 'cross-slug-glob-overlap|feature-020-t'"
check "the finding names the contended glob" \
  "printf '%s\n' \"\$GO_OUT\" | grep -q 'cross-slug-glob-overlap|feature-001-t|declares glob(s) src/shared/\*\*'"
check "overlap stays a WARN and never gates the run" \
  "! printf '%s\n' \"\$GO_OUT\" | grep -q '^FATAL|cross-slug-glob-overlap'"

# Same slug sharing a glob is BY DESIGN (one worktree, serialized) and must produce nothing.
for gf in "$GO"/.backlog/pending/*.md; do perl -i -pe 's/^- \*\*Worktree\*\*: slug-\d+$/- **Worktree**: slug-same/' "$gf"; done
GO_SAME=$(bash "$DOC" "$GO" 2>/dev/null | grep -c '^WARN|cross-slug-glob-overlap|' || true); GO_SAME=${GO_SAME//[^0-9]/}
check "tasks sharing a glob in the SAME slug are not flagged (that is the design)" "[ \"\${GO_SAME:-0}\" -eq 0 ]"
rm -rf "$GO"

# ---------------------------------------------------------------------------------------------------
# STORE GUARD. doctor.sh is the `files` engine: every check it owns is gated on a .backlog/<state>/
# directory, so on another backend it used to skip all of them in silence and print ok=true. Worse,
# the worktree pass is NOT gated — it built its live-slug set from the (empty) TSV, called every
# acf-whip worktree an orphan, and under --fix force-removed the worktree and force-deleted the
# branch. In override mode that branch is the only copy of an accepted-but-unintegrated deliverable.
# A refusal must therefore be loud, non-zero, and MUST NOT emit a parseable SUMMARY line.
SG=$(mktemp -d); ( cd "$SG" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$SG/.acfwhip" && echo 'ACFW_STORE=multica' > "$SG/.acfwhip/config"

# A worktree + branch in acf-whip's namespace: exactly what --fix used to destroy.
( cd "$SG" && git branch worktree/sg1 >/dev/null 2>&1 && \
  git worktree add -q .worktree/sg1 worktree/sg1 >/dev/null 2>&1 ) || true

SG_OUT=$(bash "$DOC" "$SG" 2>&1); SG_RC=$?
check "non-files store: doctor.sh refuses (exit 2)" "[ $SG_RC -eq 2 ]"
check "non-files store: does NOT report ok=true" "! echo \"\$SG_OUT\" | grep -q 'ok=true'"
check "non-files store: emits NO SUMMARY line a caller could parse as a report" "! echo \"\$SG_OUT\" | grep -q '^SUMMARY|'"
check "non-files store: names the store it found" "echo \"\$SG_OUT\" | grep -q \"multica\""
check "non-files store: names acfw-store as the correct entry point" "echo \"\$SG_OUT\" | grep -q 'acfw-store\" doctor'"

SG_FIX_OUT=$(bash "$DOC" --fix "$SG" 2>&1); SG_FIX_RC=$?
check "non-files store: --fix refuses too (exit 2)" "[ $SG_FIX_RC -eq 2 ]"
check "non-files store: --fix did NOT remove the worktree" "[ -d \"$SG/.worktree/sg1\" ]"
check "non-files store: --fix did NOT delete the branch" "git -C \"$SG\" show-ref --verify --quiet refs/heads/worktree/sg1"

# Resolution honours the env var as well as the config key.
SG_ENV_RC=0; ACFW_STORE=beads bash "$DOC" "$SG" >/dev/null 2>&1 || SG_ENV_RC=$?
check "non-files store via ACFW_STORE env: refuses" "[ $SG_ENV_RC -eq 2 ]"

# files store with no .backlog/ is the same absence-equals-health inference, and refuses the same way.
rm -f "$SG/.acfwhip/config"
SG_NB_OUT=$(bash "$DOC" "$SG" 2>&1); SG_NB_RC=$?
check "files store with no .backlog/: refuses (exit 2)" "[ $SG_NB_RC -eq 2 ]"
check "files store with no .backlog/: does NOT report ok=true" "! echo \"\$SG_NB_OUT\" | grep -q 'ok=true'"

# And the files path itself is unchanged: a healthy board still reports ok=true and exits 0.
mkdir -p "$SG/.backlog/pending" "$SG/.backlog/accepted"
SG_OK_OUT=$(bash "$DOC" "$SG" 2>&1); SG_OK_RC=$?
check "files store WITH .backlog/: unchanged (exit 0, ok=true)" "[ $SG_OK_RC -eq 0 ] && echo \"\$SG_OK_OUT\" | grep -q 'ok=true'"

( cd "$SG" && git worktree remove --force .worktree/sg1 >/dev/null 2>&1 ) || true
rm -rf "$SG"

# ---- ACFW_INPROGRESS_TIMEOUT_HOURS: env must beat config ---------------------------------------
# acfw_load_namespace SOURCES the config into the caller's shell, so an inherited env var was
# overwritten by the config's own value before the old code read it — config beat env, inverting the
# precedence the header documents. The result on a whip-init'd project: the scheduler timed a task
# out at the configured hour while the same iteration's doctor, still on the 8h default, emitted no
# stale-in-progress at all, so the two halves of one run disagreed about whether a task was stuck.
echo "== in-progress timeout precedence =="
TMO="$WORK/tmorepo"; git init -q -b trunk "$TMO"
( cd "$TMO" && git config user.email t@t && git config user.name t \
  && mkdir -p .backlog/in-progress .acfwhip .claude/agents \
  && echo x > .claude/agents/go-engineer.md && echo seed > seed )
FOUR_H_AGO=$(date -u -v-4H +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -u -d "4 hours ago" +"%Y-%m-%d %H:%M:%S")
cat > "$TMO/.backlog/in-progress/stale-probe.md" <<EOF
# Task: stale-probe

## Metadata

- **ID**: stale-probe
- **Status**: in-progress
- **Assigned Agent**: go-engineer
- **Worktree**: stale-probe
- **Dependencies**: none
- **Rejection Count**: 0

## Transition Log

| $FOUR_H_AGO | pending | in-progress | orchestrator | dispatch |
EOF
( cd "$TMO" && git add -A >/dev/null && git commit -qm tmo >/dev/null )
tmo_warn() { bash "$DOC" "$TMO" 2>/dev/null | grep -c '^WARN|stale-in-progress|' || true; }

printf 'ACFW_INPROGRESS_TIMEOUT_HOURS=1\n' > "$TMO/.acfwhip/config"
T_CFG_ONLY=$(tmo_warn)
T_ENV_WINS=$(ACFW_INPROGRESS_TIMEOUT_HOURS=9 tmo_warn)
printf 'ACFW_INPROGRESS_TIMEOUT_HOURS=9\n' > "$TMO/.acfwhip/config"
T_ENV_WINS_LOW=$(ACFW_INPROGRESS_TIMEOUT_HOURS=1 tmo_warn)
rm -f "$TMO/.acfwhip/config"
T_DEFAULT=$(tmo_warn)

check "config alone sets the timeout (1h: a 4h task is stale)"        "[ \"${T_CFG_ONLY:-0}\" -ge 1 ]"
check "env BEATS config upward (config 1h, env 9h: not stale)"        "[ \"${T_ENV_WINS:-0}\" -eq 0 ]"
check "env BEATS config downward (config 9h, env 1h: stale)"          "[ \"${T_ENV_WINS_LOW:-0}\" -ge 1 ]"
check "neither set falls back to the 8h default (a 4h task is fine)"  "[ \"${T_DEFAULT:-0}\" -eq 0 ]"
printf 'ACFW_INPROGRESS_TIMEOUT_HOURS=8h\n' > "$TMO/.acfwhip/config"
T_BOGUS=$(bash "$DOC" "$TMO" 2>&1 >/dev/null | grep -c 'not a whole number' || true)
check "a non-numeric config value is named, not carried into the arithmetic" "[ \"${T_BOGUS:-0}\" -ge 1 ]"
rm -f "$TMO/.acfwhip/config"

# ---- dup-folder repair: it must never delete every copy ---------------------------------------
# `keep` is a raw field read of the FIRST-listed copy's Status. When that read yields "" — an
# unparseable Status line, or a detail string the sed could not match — the old repair compared it
# against every ACTIVE folder, matched none, and `git rm`'d all of them; the `|| rm -f` fallback
# then unlinked an untracked copy outright. /go runs `doctor --fix` at bootstrap with its output
# discarded, so this also erased the FATAL that should have stopped the run.
echo "== dup-folder --fix =="
DUPR="$WORK/duprepo"; git init -q -b trunk "$DUPR"
( cd "$DUPR" && git config user.email t@t && git config user.name t \
  && mkdir -p .backlog/pending .backlog/completed .claude/agents \
  && echo x > .claude/agents/go-engineer.md && echo seed > seed )
dupmk(){ # <repo> <folder> <stem> <status>
  cat > "$1/.backlog/$2/$3.md" <<EOF
# Task: $3

## Metadata

- **ID**: $3
- **Status**: $4
- **Assigned Agent**: go-engineer
- **Worktree**: $3
- **Dependencies**: none
- **Rejection Count**: 0

## Transition Log
EOF
}
# (a) UNRESOLVABLE: no copy's Status names a folder the stem is actually in.
dupmk "$DUPR" pending   dbad ""
dupmk "$DUPR" completed dbad ""
# (b) RESOLVABLE: the ordinary duplicate the repair exists for.
dupmk "$DUPR" pending   dok  pending
dupmk "$DUPR" completed dok  pending
( cd "$DUPR" && git add -A >/dev/null && git commit -qm dupseed >/dev/null )
DUP_OUT=$(bash "$DOC" --fix "$DUPR" 2>&1)
check "dup-folder: unresolvable keeper refuses with a typed FATAL" \
  "echo \"\$DUP_OUT\" | grep -q '^FATAL|dup-folder-unresolvable|dbad|'"
check "dup-folder: BOTH copies survive when the keeper cannot be identified" \
  "[ -f '$DUPR/.backlog/pending/dbad.md' ] && [ -f '$DUPR/.backlog/completed/dbad.md' ]"
check "dup-folder: the refusal is counted in the summary (the gate can see it)" \
  "echo \"\$DUP_OUT\" | grep -q 'ok=false'"
check "dup-folder: a resolvable duplicate is still deduped to one copy" \
  "[ \$(ls '$DUPR/.backlog/pending/dok.md' '$DUPR/.backlog/completed/dok.md' 2>/dev/null | wc -l) -eq 1 ]"

# (c) An UNTRACKED duplicate is never unlinked: git rm refusing means there is no history to
# recover it from, so the old `|| rm -f` fallback destroyed the only copy that existed.
dupmk "$DUPR" pending dunt pending
( cd "$DUPR" && git add .backlog/pending/dunt.md >/dev/null && git commit -qm dunt >/dev/null )
dupmk "$DUPR" completed dunt completed   # Status already matches its folder, so the status-sync
                                         # repair does not fire and git-add it first; stays untracked.
DUP2_OUT=$(bash "$DOC" --fix "$DUPR" 2>&1)
check "dup-folder: an untracked duplicate is left in place, with a WARN" \
  "[ -f '$DUPR/.backlog/completed/dunt.md' ] && echo \"\$DUP2_OUT\" | grep -q '^WARN|dup-folder-untracked|dunt|'"

echo ""
echo "==================================================="
echo "Phase 1 doctor+hydrate test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
