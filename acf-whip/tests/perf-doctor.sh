#!/usr/bin/env bash
# perf-doctor.sh — measure the doctor on a synthetic board of N tasks.
#
# WHY. No board above 337 tasks has ever been measured against this plugin, so "the doctor takes more
# than ten minutes" could not be attributed to anything: the two superlinear graph passes and the
# per-file process-spawn storm are different shapes with different fixes, and guessing wrong means
# rewriting the wrong loop. This lands GREEN on the current tree so the pre-fix number is a recorded
# artifact of a real run rather than a claim.
#
# Usage: bash acf-whip/tests/perf-doctor.sh [N] [--keep]
#   N        board size (default 600)
#   --keep   leave the generated repo in place for profiling
#
# Not part of run-all.sh: it is a measurement, not an assertion, and it takes minutes at N=600.
#
# RECORDED BASELINE — N=600 (420 accepted / 120 pending / 60 completed), arm64 macOS, bash 3.2-compatible
# script run under bash 5.3. First numbers ever taken above 337 tasks.
#
#   run                              before 3.3.0   after 3.3.0
#   doctor --quiet (full pass)          30.39s         29.34s
#   doctor --quiet --active-only         8.66s          8.36s
#   glob-overlap advisories emitted        541            121
#   total WARN lines (--active-only)       961            120
#   FATAL set                               54             54     (identical, both)
#
# Two things that measurement settled, and they point opposite ways to the intuition:
#
# 1. The two "superlinear" graph passes are NOT the bottleneck. Memoising the dependency resolver and
#    inverting the glob loop from pairwise to indexed moved wall-clock by ~3% — within noise. What they
#    DID fix is the output: a quadratic wall of advisories (541 lines for 120 pending tasks) that an
#    operator has to read past to find a real finding, now bounded by task count.
#
# 2. The win is --active-only: 3.5x, from one word. doctor.sh's own header has documented since 2.x
#    that it leaves the FATAL set and the ok flag UNCHANGED — and the numbers above confirm it, same 54
#    FATALs either way. /go's bootstrap re-scan simply never passed it.
#
# The remaining 8.4s is the per-file pass: ~9 field() extractions per task file, each a
# grep|head|sed|sed pipeline. Batching that is the next real win if a board ever needs it; it was
# deliberately NOT attempted here, because a rewrite of the extraction layer earns its risk only
# against a measured need, and 8s at 600 tasks is not one yet.

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="${1:-600}"
case "$N" in ''|*[!0-9]*) N=600 ;; esac
KEEP=0; [ "${2:-}" = "--keep" ] && KEEP=1

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-perf.XXXXXX")
[ "$KEEP" -eq 1 ] || trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"

echo "== generating a synthetic board of $N tasks =="
mkdir -p "$REPO" && cd "$REPO" || exit 1
git init -q -b trunk . && git config user.email p@p && git config user.name p
mkdir -p .backlog/{draft,pending,in-progress,completed,in-review,blocked,rejected,accepted,archive}
mkdir -p .claude/agents && printf 'x\n' > .claude/agents/go-engineer.md

# Shape mirrors a lived-in backlog: most work finished, a working set in flight, a few globs each so
# the cross-slug overlap pass has real pairs to compare. Dependencies chain within each decade so the
# graph pass has edges to resolve rather than a flat list.
gen() { # <folder> <count> <startindex>
  local folder="$1" count="$2" start="$3" i id stem dep
  for i in $(seq "$start" $((start + count - 1))); do
    id=$(printf 'feature-%04d' "$i")
    stem="$id-task"
    dep="none"
    [ $((i % 10)) -ne 0 ] && dep="feature-$(printf '%04d' $((i - 1)))-task"
    cat > ".backlog/$folder/$stem.md" <<TASK
# Task: $stem

## Metadata

- **ID**: $id
- **Status**: $folder
- **Priority**: medium
- **Assigned Agent**: go-engineer
- **Worktree**: slug-$i
- **PR Group**: slug-$i
- **Touches Globs**: src/mod$((i % 40))/**, docs/d$((i % 15))/**
- **Dependencies**: $dep
- **Rejection Count**: 0
- **Block-Count**: 0

## Acceptance Criteria

- [ ] does the thing

## Transition Log

| Timestamp | From | To | Agent | Notes |
|---|---|---|---|---|
| 2026-01-01 00:00:00 | pending | $folder | orchestrator | dispatch |
TASK
  done
}

ACC=$(( N * 70 / 100 )); PEND=$(( N * 20 / 100 )); REST=$(( N - ACC - PEND ))
gen accepted "$ACC" 1
gen pending "$PEND" $((ACC + 1))
gen completed "$REST" $((ACC + PEND + 1))
git add -A >/dev/null && git commit -qm "synthetic board of $N tasks"
echo "   accepted=$ACC pending=$PEND completed=$REST"

run() { # <label> <cmd...>
  local label="$1"; shift
  local s e
  s=$(python3 -c 'import time;print(time.time())')
  "$@" >/dev/null 2>&1
  e=$(python3 -c 'import time;print(time.time())')
  printf '   %-46s %6.2fs\n' "$label" "$(python3 -c "print($e-$s)")"
}

echo
echo "== timings (N=$N, $(uname -m), bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}) =="
run "doctor (full, report-only)"          bash "$ACF_WHIP/skills/whip-doctor/bin/doctor.sh" "$REPO"
run "doctor --quiet"                      bash "$ACF_WHIP/skills/whip-doctor/bin/doctor.sh" --quiet "$REPO"
run "doctor --quiet --active-only"        bash "$ACF_WHIP/skills/whip-doctor/bin/doctor.sh" --quiet --active-only "$REPO"
run "scan-backlog --digest"               bash "$ACF_WHIP/skills/go/bin/scan-backlog.sh" --digest "$REPO"
run "acfw-store doctor (dispatcher)"      env ACFW_TRUNK_ROOT="$REPO" bash "$ACF_WHIP/skills/lib/bin/acfw-store" doctor --quiet

echo
echo "== where the time goes =="
printf '   %-46s %s\n' "task files" "$(find "$REPO/.backlog" -name '*.md' | wc -l | tr -d ' ')"
printf '   %-46s %s\n' "pending pairs for the glob-overlap pass" "$(( PEND * (PEND - 1) / 2 ))"
[ "$KEEP" -eq 1 ] && echo && echo "board kept at: $REPO"
exit 0
