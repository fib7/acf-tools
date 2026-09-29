#!/usr/bin/env bash
# run-all.sh — run every acf-whip test and exit non-zero if ANY of them fails.
#
# The suite had no runner, so each phase was invoked by hand from its own header comment. That works
# until a phase is added and quietly never run again — which is the same silent-coverage-loss failure
# the individual suites are written to prevent. Adding a test now means adding one line here.
#
# Run: bash acf-whip/tests/run-all.sh
# Env: ADAPTER=<path>  runs the store-conformance suite against a specific adapter (default: files)

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.." || exit 1

# Optional suites: these skip themselves unless their backend is reachable, and a SKIP is not a
# failure. phase9-adapter-multica is NOT here any more: it drives the adapter through an offline fake
# of the multica CLI (injected at the ACFW_MULTICA_BIN seam), so it runs everywhere and must pass.
# tests/perf-doctor.sh is deliberately absent from both lists: it is a timing harness, not a
# pass/fail suite, so a slow machine would turn it into a flaky gate. Run it by hand.
OPTIONAL="phase9-adapter-beads"

SUITES_SH="
phase0-extraction
phase1-doctor-hydrate
phase3-reliability
phase4-whip-move
phase6-worktree-codeonly
phase8-lpcas-integrate
phase9-store-conformance
phase9-dispatcher
phase10-validate-child
phase11-checkout-reentrancy
phase12-multica-transition-log
phase13-integration-mode
phase18-artifact-provenance
phase18-focus
phase19-files-only
phase19-doctor-graph
phase19-research-preflight
phase9-adapter-multica
phase9-adapter-linear
$OPTIONAL
"
SUITES_MJS="
phase2-scheduler
phase4-scan-degrade
phase5-streaming
phase10-child-skeleton
phase11-escalation
phase14-go-scope
phase19-relay
phase19-quarantine
phase19-routing
phase15-first-run-autoreject
phase16-gate-legibility
phase17-template-drift
"

TOTAL_PASS=0 TOTAL_FAIL=0 FAILED_SUITES="" SKIPPED=""

# Pull "N passed, M failed" or "PASS=N FAIL=M" out of a suite's tail, whichever it prints.
tally() { # <output>
  printf '%s' "$1" | grep -Eo '[0-9]+ passed, [0-9]+ failed|PASS=[0-9]+ FAIL=[0-9]+' | tail -1
}

run_one() { # <runner> <name>
  local runner="$1" name="$2" file
  case "$runner" in
    bash) file="tests/$name.test.sh" ;;
    node) file="tests/$name.test.mjs" ;;
  esac
  if [ ! -f "$file" ]; then
    echo "  MISSING  $name  (listed in run-all.sh but not on disk)"
    FAILED_SUITES="$FAILED_SUITES $name(missing)"
    return
  fi
  local out rc line p f
  out=$("$runner" "$file" 2>&1); rc=$?
  line=$(tally "$out")
  # A suite counts as SKIPPED only if it printed a SKIP: line AND ran no assertions. Matching
  # `^SKIP:` ANYWHERE used to swallow the whole suite, so a suite that skipped one optional section
  # (the linear emulator suite skips only its live-server half) was reported as skipped entirely and
  # COULD NOT FAIL THE BUILD no matter what its assertions said. Silent-coverage-loss, which is the
  # exact failure this runner exists to prevent.
  if printf '%s' "$out" | grep -q '^SKIP:' && [ -z "$line" ]; then
    # Only a suite listed in OPTIONAL may skip. Any other suite that skips has lost its coverage —
    # masking a missing interpreter or a renamed fixture behind a green run, which is the
    # silent-coverage-loss this runner exists to prevent. Measured: masking python3 gave
    # "ALL GREEN, 882 passed" with 62 assertions gone, including all of phase18.
    case " $OPTIONAL " in
      *" $name "*)
        SKIPPED="$SKIPPED $name"
        printf '  %-34s SKIP\n' "$name"
        return ;;
    esac
    FAILED_SUITES="$FAILED_SUITES $name(skipped)"
    printf '  %-34s FAIL  (skipped, but not in OPTIONAL — coverage lost)\n' "$name"
    printf '%s' "$out" | grep '^SKIP:' | head -2 | sed 's/^/      /'
    return
  fi
  p=$(printf '%s' "$line" | grep -Eo '[0-9]+' | head -1)
  f=$(printf '%s' "$line" | grep -Eo '[0-9]+' | tail -1)
  [ -n "$p" ] || p=0
  [ -n "$f" ] || f=0
  TOTAL_PASS=$((TOTAL_PASS + p))
  TOTAL_FAIL=$((TOTAL_FAIL + f))
  if [ "$rc" -ne 0 ] || [ "$f" -ne 0 ]; then
    FAILED_SUITES="$FAILED_SUITES $name"
    printf '  %-34s FAIL  (%s)\n' "$name" "${line:-exit $rc}"
    # Show what actually failed — a runner that hides the failure lines is a runner nobody trusts.
    printf '%s' "$out" | grep -E '^\s*FAIL:|^FATAL' | head -12 | sed 's/^/      /'
  else
    printf '  %-34s ok    (%s)\n' "$name" "${line:-no tally}"
  fi
}

echo "== shell suites =="
for s in $SUITES_SH; do [ -n "$s" ] && run_one bash "$s"; done
echo "== node suites =="
for s in $SUITES_MJS; do [ -n "$s" ] && run_one node "$s"; done

echo
echo "== static gates =="
STATIC_FAIL=0
for f in workflows/whip-go.workflow.js workflows/whip-task.workflow.js; do
  # NOT `node --check`: the runtime compiles a workflow body inside an async function, where top-level
  # await and top-level return are legal, so --check false-positives on every valid workflow file.
  if node -e '
      const fs=require("fs");
      const s=fs.readFileSync(process.argv[1],"utf8").replace(/^export const meta/m,"const meta");
      new Function("agent","parallel","pipeline","phase","log","args","budget","workflow","return (async()=>{\n"+s+"\n})()");
    ' "$f" 2>/dev/null; then
    printf '  %-34s ok    (compiles as a workflow body)\n' "$(basename "$f")"
  else
    printf '  %-34s FAIL  (does not compile)\n' "$(basename "$f")"; STATIC_FAIL=1
  fi
done
for b in skills/lib/bin/acfw-child-scaffold skills/lib/bin/acfw-child-validate skills/lib/bin/acfw-child-ledger; do
  if [ -x "$b" ] && bash -n "$b" 2>/dev/null; then
    printf '  %-34s ok    (syntax + executable)\n' "$(basename "$b")"
  else
    printf '  %-34s FAIL  (syntax error or not chmod +x)\n' "$(basename "$b")"; STATIC_FAIL=1
  fi
done
# Adapters were outside every static gate: a syntax error in one is invisible until a run
# hits that backend, and three of the four have no offline suite at all.
for a in adapters/*/acfw-store-*; do
  if [ -x "$a" ] && bash -n "$a" 2>/dev/null; then
    printf '  %-34s ok    (syntax + executable)\n' "$(basename "$a")"
  else
    printf '  %-34s FAIL  (syntax error or not chmod +x)\n' "$(basename "$a")"; STATIC_FAIL=1
  fi
done
# Every adapter that shells out to a backend CLI must resolve it through an ENV SEAM, not from PATH
# directly. That seam is the whole reason multica's suite could stop being green-by-absence in 3.3.0:
# a fake CLI injected at ACFW_MULTICA_BIN runs the frozen conformance spec with no server. beads had
# no seam, which is why it is still the one backend that cannot be exercised offline at all.
SEAM_FAIL=0
for a in adapters/*/acfw-store-*; do
  case "$(basename "$a")" in
    *-files) continue ;;   # no external CLI: it reads .backlog/ directly
  esac
  if ! grep -qE '\$\{ACFW_[A-Z]+_(BIN|TRANSPORT)' "$a" 2>/dev/null; then
    printf '  %-34s FAIL  (%s resolves its backend CLI with no ACFW_*_BIN seam — it cannot be tested offline)\n' \
      'adapter-binary-seam' "$(basename "$a")"; SEAM_FAIL=1; STATIC_FAIL=1
  fi
done
[ "$SEAM_FAIL" -eq 0 ] && printf '  %-34s ok    (every API adapter resolves its CLI through an env seam)\n' 'adapter-binary-seam'
# The legacy loops in the SKILL.md files are shell a model executes verbatim, and they are the ONLY
# path when the Workflow tool is unavailable or refused — so they must run on the oldest bash we
# support. macOS ships 3.2, where `declare -A` fails outright with "declare: -A: invalid option" and
# takes the whole loop with it. Also catch an array that is appended to but never read: DIRECT_DISPATCH
# was collected and never consumed, silently dropping every non-code task from every iteration.
SH_FAIL=0
# Both legacy loops write .backlog/ directly, so both must say they are files-backend only. /go's
# fallback stated it; /task's did not — and this release made /task's fallback MORE reachable by
# routing a refusal into it, so a non-files project could be told to hand-write task files the store
# will never see, while the run reports success. Pattern allows the backtick/hyphen variants in use.
for sk in go task; do
  if ! grep -qiE 'files.?.?backend only' "skills/$sk/SKILL.md" 2>/dev/null; then
    printf '  %-34s FAIL  (skills/%s/SKILL.md legacy loop has no files-backend fence)\n' 'skill-shell-portability' "$sk"; SH_FAIL=1
  fi
done
BASH4=$(grep -rn 'declare -A' skills/*/SKILL.md 2>/dev/null | grep -v '^\s*#' | grep -v 'declare -A` is a bash 4' || true)
if [ -n "$BASH4" ]; then
  printf '  %-34s FAIL  (bash 4 syntax; macOS ships 3.2)\n' 'skill-shell-portability'
  printf '%s\n' "$BASH4" | sed 's/^/      /'; SH_FAIL=1
fi
# Boolean tests, not counts. `grep -c` prints its count AND exits 1 on zero matches, so
# `R=$(grep -c ... || echo 0)` yields the two-line string "0\n0"; `[ "$R" -eq 0 ]` then aborts with
# status 2 and the FAIL branch below became unreachable for every input. Verified against the live
# tree: with the only read of DIRECT_DISPATCH deleted — the exact regression this guards — the gate
# did not fire. Dropping `|| echo 0` alone is not enough either: an absent or renamed SKILL.md would
# leave R empty and short-circuit the same way.
# The name list is DERIVED from the skill, not enumerated here. Enumerating it is how the gate missed
# the defect it exists to catch: INTEGRATE_QUEUE was filled and never read while Step 4.5b iterated
# SORTED_QUEUE, which nothing assigned — so the legacy fallback loop, the one operators are routed
# into when the Workflow tool is unavailable, integrated nothing at all, silently, and every
# deliverable stayed on an unmerged branch. A gate that only looks at the two names someone happened
# to write down can never see the third.
for sk in skills/go/SKILL.md skills/task/SKILL.md; do
  [ -f "$sk" ] || continue
  for v in $(grep -oE '\b[A-Z_][A-Z0-9_]*\+=\(' "$sk" 2>/dev/null | sed 's/+=(//' | sort -u); do
    if ! grep -q "\${$v\[@\]" "$sk" 2>/dev/null; then
      printf '  %-34s FAIL  (%s is appended to but never read in %s)\n' 'skill-shell-portability' "$v" "$sk"; SH_FAIL=1
    fi
  done
done
[ "$SH_FAIL" -eq 0 ] && printf '  %-34s ok    (bash 3.2 safe; no write-only arrays)\n' 'skill-shell-portability'
[ "$SH_FAIL" -eq 0 ] || STATIC_FAIL=1

# `if ! cmd; then rc=$?` captures the status of the NEGATION, which is always 0 inside the branch -
# so the handler reports SUCCESS for the failure it exists to surface. This has now shipped twice in
# this codebase: clean-checkout's exit 99 was unreachable for releases, and the very commit that
# fixed it introduced the same shape into apply-transition.sh, where `exit "$rc"` exited 0 while a
# commit had failed and deliverables sat staged. It is invisible in review and in testing (the happy
# path is identical), so it gets a grep.
NEG_FAIL=0
for f in $(git ls-files '*.sh' 'skills/lib/bin/*' 'adapters/*/acfw-store-*' 2>/dev/null); do
  [ -f "$f" ] || continue
  HIT=$(awk 'prev ~ /^[[:space:]]*if[[:space:]]*!/ && $0 ~ /(rc|RC)=\$\?/ {print NR} {prev=$0}' "$f" 2>/dev/null)
  if [ -n "$HIT" ]; then
    printf '  %-34s FAIL  (%s:%s reads $? inside `if !` - always 0, so the failure reports success)\n' \
      'shell-negated-status' "$f" "$(printf '%s' "$HIT" | tr '\n' ',' | sed 's/,$//')"
    NEG_FAIL=1
  fi
done
[ "$NEG_FAIL" -eq 0 ] && printf '  %-34s ok    (no handler reads $? inside an `if !` branch)\n' 'shell-negated-status'
[ "$NEG_FAIL" -eq 0 ] || STATIC_FAIL=1

# Workflow launch identity, checked in BOTH directions. A skill launching `acf-whip:<x>` that no
# workflow `meta` declares fails exactly like the plugin-cache scriptPath it replaced — silently, at
# the moment a user runs /go. The reciprocal check is the one with teeth: it fails when someone
# renames a meta.name and forgets the skill. Launch name = <plugin.json name>:<meta.name>.
PLUGIN_NAME=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .claude-plugin/plugin.json | head -1)
WF_FAIL=0
for f in workflows/*.workflow.js; do
  MN=$(sed -n "s/^[[:space:]]*name:[[:space:]]*'\([^']*\)'.*/\1/p" "$f" | head -1)
  if [ -z "$MN" ]; then
    printf '  %-34s FAIL  (%s declares no meta.name)\n' 'workflow-launch-names' "$f"; WF_FAIL=1; continue
  fi
  grep -rqF "name: \"$PLUGIN_NAME:$MN\"" skills/ || {
    printf '  %-34s FAIL  (%s:%s declared by %s, launched by no skill)\n' 'workflow-launch-names' "$PLUGIN_NAME" "$MN" "$f"; WF_FAIL=1
  }
done
# ...and no skill may name a workflow that does not exist.
for n in $(grep -rhoE 'name: "'"$PLUGIN_NAME"':[a-z0-9-]+"' skills/ | sed 's/.*://; s/"//g' | sort -u); do
  grep -rqE "^[[:space:]]*name: '$n'," workflows/*.workflow.js || {
    printf '  %-34s FAIL  (a skill launches %s:%s — no workflow meta declares it)\n' 'workflow-launch-names' "$PLUGIN_NAME" "$n"; WF_FAIL=1
  }
done
# A scriptPath launch under the plugin root is refused on every normal install; never reintroduce one.
if grep -rn 'scriptPath: *"<PLUGIN_ROOT>' skills/ >/dev/null 2>&1; then
  printf '  %-34s FAIL  (a skill launches by plugin-cache path — use the registered name)\n' 'workflow-launch-names'; WF_FAIL=1
fi
[ "$WF_FAIL" -eq 0 ] && printf '  %-34s ok    (skills and workflow meta agree, both ways)\n' 'workflow-launch-names'
[ "$WF_FAIL" -eq 0 ] || STATIC_FAIL=1

# No skill may INVOKE a per-backend battery by path. doctor.sh is the `files` engine and now refuses
# on any other store, so a skill that shells out to it directly hands non-files operators a hard
# refusal where the dispatcher would have produced a real report. Matches `bash .../doctor.sh` only —
# prose references and the whip-init existence probe (`[ -f ... ]`) are legitimate.
BYPATH=$(grep -rn 'bash "\?\${\?CLAUDE_PLUGIN_ROOT}\?/skills/whip-doctor/bin/doctor\.sh' skills/ 2>/dev/null || true)
if [ -z "$BYPATH" ]; then
  printf '  %-34s ok    (no skill invokes a battery by path)\n' 'doctor-entrypoint'
else
  printf '  %-34s FAIL  (invoke via skills/lib/bin/acfw-store doctor)\n' 'doctor-entrypoint'
  printf '%s\n' "$BYPATH" | sed 's/^/      /'; STATIC_FAIL=1
fi
if node --check skills/lib/bin/acfw-child-validate.mjs 2>/dev/null; then
  printf '  %-34s ok    (syntax)\n' 'acfw-child-validate.mjs'
else
  printf '  %-34s FAIL  (syntax)\n' 'acfw-child-validate.mjs'; STATIC_FAIL=1
fi
if command -v jq >/dev/null 2>&1; then
  BADJSON=""
  for j in .claude-plugin/plugin.json; do
    jq . "$j" >/dev/null 2>&1 || BADJSON="$BADJSON $j"
  done
  [ -z "$BADJSON" ] && printf '  %-34s ok    (valid)\n' 'plugin.json' || { printf '  %-34s FAIL (%s)\n' 'plugin.json' "$BADJSON"; STATIC_FAIL=1; }
fi

echo
echo "──────────────────────────────────────────────────────────"
echo "acf-whip suite: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ -n "$SKIPPED" ] && echo "skipped (backend unavailable):$SKIPPED"
if [ -n "$FAILED_SUITES" ] || [ "$TOTAL_FAIL" -ne 0 ] || [ "$STATIC_FAIL" -ne 0 ]; then
  [ -n "$FAILED_SUITES" ] && echo "FAILING SUITES:$FAILED_SUITES"
  [ "$STATIC_FAIL" -ne 0 ] && echo "STATIC GATES FAILED"
  exit 1
fi
echo "ALL GREEN"
