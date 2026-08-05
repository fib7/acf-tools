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

# Optional suites: these skip themselves unless their backend is reachable, and a SKIP is not a failure.
OPTIONAL="phase9-adapter-beads phase9-adapter-linear phase9-adapter-multica"

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
$OPTIONAL
"
SUITES_MJS="
phase2-scheduler
phase4-scan-degrade
phase5-streaming
phase10-child-skeleton
phase11-escalation
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
  if printf '%s' "$out" | grep -q '^SKIP:'; then
    SKIPPED="$SKIPPED $name"
    printf '  %-34s SKIP\n' "$name"
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
