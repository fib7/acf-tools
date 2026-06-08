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
mktask in-progress r-status rst completed go-engineer none "" 0        # I4: Status 'completed' but in in-progress/
git add -A; git commit -qm repairables
OUT=$(bash "$DOC" "$REPO")
check "integrated-at-on-non-accepted reported" "echo \"$OUT\" | grep -q '^REPAIRABLE|integrated-at-on-non-accepted|r-stray-integ'"
check "rejection-count-out-of-range reported" "echo \"$OUT\" | grep -q '^REPAIRABLE|rejection-count-out-of-range|r-rc'"
check "I4: status-folder-mismatch reported REPAIRABLE" "echo \"$OUT\" | grep -q '^REPAIRABLE|status-folder-mismatch|r-status'"
bash "$DOC" --fix "$REPO" >/dev/null
check "stray Integrated-At cleared after --fix" "! grep -qE '^- \*\*Integrated-At\*\*: abc1234' '$REPO/.backlog/pending/r-stray-integ.md'"
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
check "slim dep-target drops full-only fields (deps right after slug)" "echo \"\$SNAP\" | grep -qE '\"stem\":\"dep-target-acc\",\"id\":\"[^\"]*\",\"folder\":\"accepted\",\"slug\":\"dta\",\"deps\":\[\],\"touchesGlobs\":\[\],\"hasIntegratedAt\":true'"
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

echo ""
echo "==================================================="
echo "Phase 1 doctor+hydrate test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
