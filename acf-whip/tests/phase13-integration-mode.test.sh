#!/usr/bin/env bash
# phase13-integration-mode.test.sh — the machine pin for the /go integration mode, and the two
# behaviours that make override mode survivable rather than merely selectable.
#
#   A  resolution precedence: ACFW_INTEGRATION_MODE env > config key > "" (unpinned)
#   B  an unrecognized value is FATAL (exit 2) on EVERY subcommand — never a silent degrade to
#      unpinned, which would hand the decision back to the model the pin exists to replace.
#      Includes the trailing-comment case, which the config parser does NOT strip.
#   C  the doctor's cross-slug dep gate relaxes in override mode, matching the scheduler. When it
#      did not, /go dispatched the dependent and the next recheck FATAL'd on that same dispatch.
#   D  `--fix` does NOT reap an accepted task's worktree/branch in override mode: nothing landed and
#      nothing was pushed, so that branch is the operator's only copy of the deliverable.
#   E  env pin beats a config pin even though acfw_load_namespace SOURCES the config (which would
#      otherwise overwrite the inherited value and silently invert the documented precedence).
#   F  static: the Step 4.5 skip is an executable guard, not prose; the workflow exports the mode.
#
# Run: bash acf-whip/tests/phase13-integration-mode.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="$ACF_WHIP/skills/lib/bin/acfw-store"
DOC="$ACF_WHIP/skills/whip-doctor/bin/doctor.sh"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

# bounded <seconds> <cmd...> — run a command with a hard wall-clock cap and return its exit code
# (or 137 when the watchdog kills it). GNU `timeout` is NOT on stock macOS, which this suite targets
# (pure bash 3.2), and it appears nowhere else in the repo, so do not introduce it as a dependency.
bounded(){
  local secs="$1"; shift
  "$@" >/dev/null 2>&1 & local p=$!
  ( sleep "$secs"; kill -9 "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return "$rc"
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p13mode.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
mkdir -p .backlog/{pending,in-progress,completed,in-review,blocked,rejected,accepted}
mkdir -p .claude/agents; echo x > .claude/agents/go-engineer.md
# whip-init gitignores the worktree dir in real projects; without it the fixture's `git add -A`
# tries to stage .worktree/<slug> as an embedded repo and buries the results in git advice.
printf '.worktree/\n' > .gitignore
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk
unset ACFW_STORE ACFW_CONFIG_FILE ACFW_INTEGRATION_MODE 2>/dev/null || true

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

echo "== A: pin resolution =="
INFO=$(bash "$STORE" info)
check "no pin -> integrationMode is empty" "printf '%s' \"\$INFO\" | grep -q '\"integrationMode\":\"\"'"

mkdir -p .acfwhip; printf 'ACFW_INTEGRATION_MODE=override\n' > .acfwhip/config
INFO=$(bash "$STORE" info)
check "config pins override" "printf '%s' \"\$INFO\" | grep -q '\"integrationMode\":\"override\"'"

INFO=$(ACFW_INTEGRATION_MODE=default bash "$STORE" info)
check "env beats config" "printf '%s' \"\$INFO\" | grep -q '\"integrationMode\":\"default\"'"

GOT=$(bash "$STORE" info | sed -E 's/.*"integrationMode":"([^"]*)".*/\1/')
check "SKILL extraction snippet reads the pin" "[ \"\$GOT\" = override ]"

echo "== B: an unrecognized value is FATAL, never a silent degrade =="
ERR="$WORK/err"
OUT=$(ACFW_INTEGRATION_MODE=oevrride bash "$STORE" info 2>"$ERR"); RC=$?
check "typo -> exit 2" "[ $RC -eq 2 ]"
check "typo -> FATAL on stderr" "grep -q 'FATAL: unrecognized ACFW_INTEGRATION_MODE' \"$ERR\""
check "typo -> no JSON on stdout (no usable degraded answer)" "[ -z \"\$OUT\" ]"

# The parser strips surrounding quotes and trailing whitespace, NOT a trailing comment. This is the
# most likely first-use mistake, and under a warn-and-degrade rule it read as "pinned to override"
# while behaving as unpinned.
printf 'ACFW_INTEGRATION_MODE=override   # PR per group, never fold to trunk\n' > .acfwhip/config
bash "$STORE" info >/dev/null 2>&1; RC=$?
check "trailing comment is part of the value -> exit 2" "[ $RC -eq 2 ]"

# Validation must not be a property of `info`: any subcommand is the first call of some run.
bash "$STORE" snapshot >/dev/null 2>&1; RC=$?
check "snapshot also refuses a bad pin (exit 2)" "[ $RC -eq 2 ]"
printf 'ACFW_INTEGRATION_MODE=override\n' > .acfwhip/config
bash "$STORE" snapshot >/dev/null 2>&1; RC=$?
check "snapshot works again once the pin is valid" "[ $RC -eq 0 ]"

echo "== C: cross-slug dep gate agrees with the scheduler =="
# accepted dep + live branch + no marker, with a dispatched cross-slug dependent. In default mode
# that is genuinely pending integration -> FATAL. In override mode it is every task's end state.
mktask accepted dep-base depslug accepted go-engineer none "" 0 "src/base/**"
mktask in-progress use-feat featslug in-progress go-engineer "dep-base" "" 0 "src/feat/**"
git add -A; git commit -qm crossslug
git -C "$REPO" worktree add -q "$REPO/.worktree/depslug" -b worktree/depslug trunk 2>/dev/null

OUT=$(ACFW_INTEGRATION_MODE=default bash "$DOC" "$REPO")
check "default: cross-slug dep with live branch + no marker -> FATAL" "echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|use-feat'"
OUT=$(ACFW_INTEGRATION_MODE=override bash "$DOC" "$REPO")
check "override: same fixture -> no cross-slug FATAL" "! echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|'"
check "override: gate passes (ok=true), so /go does not abort mid-run" "echo \"\$OUT\" | grep -q 'SUMMARY|.*|ok=true'"
OUT=$(bash "$DOC" --mode override "$REPO")
check "override via --mode flag -> no cross-slug FATAL" "! echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|'"
OUT=$(bash "$DOC" --mode=override "$REPO")
check "--mode=override (equals form) also honored" "! echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|'"
bash "$DOC" --mode sideways "$REPO" >/dev/null 2>&1; RC=$?
check "--mode with a bogus value -> exit 2" "[ $RC -eq 2 ]"
# `--mode` as the final argument: `shift 2` with one arg left fails and shifts nothing, so an
# unguarded arg loop spins forever. Bounded so a regression fails the suite instead of hanging it.
bounded 10 bash "$DOC" --mode; RC=$?
check "--mode with no value -> exit 2, does not hang" "[ $RC -eq 2 ]"

# The dispatcher + adapter hop is the call /go actually makes (`acfw-store doctor --quiet
# --active-only`), not doctor.sh directly. The mode reaches doctor.sh only because the dispatcher
# exports it into the adapter env contract, so assert it survives that hop rather than assuming.
OUT=$(ACFW_INTEGRATION_MODE=default bash "$STORE" doctor --quiet --active-only 2>&1)
check "dispatcher path, default: FATAL present (ok=false)" "echo \"\$OUT\" | grep -q 'SUMMARY|.*|ok=false'"
OUT=$(ACFW_INTEGRATION_MODE=override bash "$STORE" doctor --quiet --active-only 2>&1)
check "dispatcher path, override: no cross-slug FATAL" "! echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|'"
check "dispatcher path, override: ok=true (the abort that killed override runs)" "echo \"\$OUT\" | grep -q 'SUMMARY|.*|ok=true'"

echo "== D: --fix must not reap an accepted worktree in override mode =="
# The dependent is gone; only the accepted task holds slug depslug, so it is an orphan by the
# default-mode rule. Override is checked FIRST because the default run below is destructive.
rm -f .backlog/in-progress/use-feat.md; git add -A; git commit -qm droppeddependent
OUT=$(bash "$DOC" --mode override --fix "$REPO")
check "override --fix: worktree/depslug branch survives" "git -C '$REPO' show-ref --verify --quiet refs/heads/worktree/depslug"
check "override --fix: the worktree dir survives" "[ -d '$REPO/.worktree/depslug' ]"
check "override --fix: not reported as an orphan at all" "! echo \"\$OUT\" | grep -q 'orphaned-worktree|depslug'"

OUT=$(bash "$DOC" --mode default --fix "$REPO")
check "default --fix: accepted worktree IS reaped (unchanged behavior)" "! git -C '$REPO' show-ref --verify --quiet refs/heads/worktree/depslug"
check "default --fix: reap is reported" "echo \"\$OUT\" | grep -q 'orphaned-worktree|depslug'"
rm -f .backlog/accepted/dep-base.md; git add -A; git commit -qm cleanupcrossslug

echo "== E: env pin survives acfw_load_namespace sourcing the config =="
# acfw_load_namespace SOURCES the config file, so a mode resolved after it would read the config's
# value out of the env and silently invert env > config. Config says default, env says override.
printf 'ACFW_INTEGRATION_MODE=default\nACFW_WORKTREE_DIR=.worktree\nACFW_BRANCH_PREFIX=worktree\n' > .acfwhip/config
mktask accepted dep2 dep2slug accepted go-engineer none "" 0 "src/g/**"
mktask in-progress use2 use2slug in-progress go-engineer "dep2" "" 0 "src/h/**"
git add -A; git commit -qm envprec
git -C "$REPO" worktree add -q "$REPO/.worktree/dep2slug" -b worktree/dep2slug trunk 2>/dev/null
OUT=$(bash "$DOC" "$REPO")
check "config-only pin (default) still FATALs" "echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|use2'"
OUT=$(ACFW_INTEGRATION_MODE=override bash "$DOC" "$REPO")
check "env override beats config default in the doctor" "! echo \"\$OUT\" | grep -q '^FATAL|cross-slug-dep-not-integrated|'"

echo "== F: the override skip is executable, and the workflow propagates the mode =="
SK="$ACF_WHIP/skills/go/SKILL.md"
check "Step 4.5 is wrapped in an executable ACFW_INTEGRATION_OVERRIDE guard" \
  "grep -q 'if \[ \"\${ACFW_INTEGRATION_OVERRIDE:-}\" = \"1\" \]; then' '$SK'"
check "pre-loop derives the switch with if/fi, not '[ ... ] && export'" \
  "! grep -q '\\] && export ACFW_INTEGRATION_OVERRIDE=1' '$SK'"
check "pre-loop sets the switch from the pin" "grep -q 'export ACFW_INTEGRATION_OVERRIDE=1' '$SK'"
check "workflow exports ACFW_INTEGRATION_MODE to every agent" \
  "grep -q 'export ACFW_INTEGRATION_MODE=\${sq(mode)}' '$ACF_WHIP/workflows/whip-go.workflow.js'"
check "dispatcher exports the mode in the adapter env contract" \
  "grep -q 'export ACFW_INTEGRATION_MODE=\"\$MODE\"' '$STORE'"

echo
echo "phase13-integration-mode: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
