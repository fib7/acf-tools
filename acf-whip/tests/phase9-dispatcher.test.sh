#!/usr/bin/env bash
# phase9-dispatcher.test.sh — verifies skills/lib/bin/acfw-store (the store dispatcher):
#   - backend resolution precedence: ACFW_STORE env > .acfwhip/config > .backlog/.acfw-config > files
#   - adapter discovery: $ACFW_STORE_ADAPTER_PATH > <root>/.acfwhip/adapters/ > plugin adapters/ > PATH
#   - run-lock path: files -> .backlog/.acfw-run.json, others -> .acfwhip/run/acfw-run.json
#   - `info` output; env contract exported to adapters
#   - snapshot "store" field injection
#   - transition --stage compensation for adapters without the `stage` capability
#     (deliverables committed to trunk by the dispatcher; state refusals preserved)
# Run: bash acf-whip/tests/phase9-dispatcher.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="$ACF_WHIP/skills/lib/bin/acfw-store"

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p9disp.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; git init -q -b trunk "$REPO"; cd "$REPO"
git config user.email t@t; git config user.name t
echo seed > seed; git add -A; git commit -qm seed
export ACFW_TRUNK_ROOT="$REPO" ACFW_TRUNK_BRANCH=trunk
unset ACFW_STORE ACFW_CONFIG_FILE ACFW_STORE_ADAPTER_PATH 2>/dev/null || true

# ---- resolution precedence ----
INFO=$(bash "$STORE" info)
check "no config -> files backend" "printf '%s' \"\$INFO\" | grep -q '\"store\":\"files\"'"
check "files run lock is .backlog/.acfw-run.json" "printf '%s' \"\$INFO\" | grep -q '.backlog/.acfw-run.json'"

mkdir -p .backlog; printf 'ACFW_STORE=stub\n' > .backlog/.acfw-config
INFO=$(bash "$STORE" info)
check "legacy .backlog/.acfw-config selects its backend" "printf '%s' \"\$INFO\" | grep -q '\"store\":\"stub\"'"
check "non-files run lock is .acfwhip/run/acfw-run.json" "printf '%s' \"\$INFO\" | grep -q '.acfwhip/run/acfw-run.json'"

mkdir -p .acfwhip; printf 'ACFW_STORE=stub2\n' > .acfwhip/config
INFO=$(bash "$STORE" info)
check ".acfwhip/config beats the legacy config" "printf '%s' \"\$INFO\" | grep -q '\"store\":\"stub2\"'"

INFO=$(ACFW_STORE=envstore bash "$STORE" info)
check "ACFW_STORE env beats both configs" "printf '%s' \"\$INFO\" | grep -q '\"store\":\"envstore\"'"

rm .acfwhip/config; printf 'ACFW_STORE=stub\n' > .backlog/.acfw-config

# ---- unknown backend -> typed unavailable ----
bash "$STORE" snapshot >/dev/null 2>&1; RC=$?
check "missing adapter for configured backend exits 5" "[ $RC -eq 5 ]"

# ---- project-local adapter discovery + env contract + arg passthrough ----
mkdir -p .acfwhip/adapters
STUB=".acfwhip/adapters/acfw-store-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
# stub adapter: logs every invocation's argv + selected env, emits canned JSON.
echo "ARGS:$*" >> "$STUB_LOG"
echo "ENV:root=$ACFW_TRUNK_ROOT branch=$ACFW_TRUNK_BRANCH lib=${ACFW_PLUGIN_LIB:+set} cfg=${ACFW_STORE_CONFIG}" >> "$STUB_LOG"
case "${1:-}" in
  capabilities) printf '%s\n' "${STUB_CAPS:?}" ;;
  snapshot)     if [ -n "${STUB_SNAPSHOT:-}" ]; then printf '%s\n' "$STUB_SNAPSHOT"
                else printf '{"tasks":[],"counts":{"pending":0}}\n'; fi ;;
  doctor)       printf '%s\n' "${STUB_DOCTOR:-SUMMARY|fatal=0|repairable=0|warn=0|ok=true}" ;;
  transition)   shift; printf 'ok: stub transition %s\n' "$*" ;;
  *)            printf '{"stub":true}\n' ;;
esac
EOF
chmod +x "$STUB"
export STUB_LOG="$WORK/stub.log"
export STUB_CAPS='{"backend":"stub","contractVersion":1,"commitsToGit":false,"capabilities":["snapshot","snapshot-enriched","read","create","transition"]}'

: > "$STUB_LOG"
OUT=$(bash "$STORE" snapshot --digest)
check "project-local .acfwhip/adapters/ adapter is discovered" "grep -q 'ARGS:snapshot --digest' \"\$STUB_LOG\""
check "env contract reaches the adapter" "grep -q \"ENV:root=$REPO branch=trunk lib=set\" \"\$STUB_LOG\""
check "dispatcher injects the store field into snapshots" "printf '%s' \"\$OUT\" | grep -q '^{\"store\":\"stub\",'"

# ---- ACFW_STORE_ADAPTER_PATH beats the project-local drop-in ----
mkdir -p "$WORK/override"
cp "$STUB" "$WORK/override/acfw-store-stub"
cat >> "$WORK/override/acfw-store-stub" <<'EOF'
# marker: override copy
EOF
INFO=$(ACFW_STORE_ADAPTER_PATH="$WORK/override" bash "$STORE" info)
check "ACFW_STORE_ADAPTER_PATH wins adapter discovery" "printf '%s' \"\$INFO\" | grep -q 'override/acfw-store-stub'"

# ---- transition --stage compensation (adapter lacks the stage capability) ----
mkdir -p docs; echo "deliverable" > docs/report.md
: > "$STUB_LOG"
OUT=$(bash "$STORE" transition --stage docs/report.md conf-x completed specialist "done" 0 0)
check "stage-less adapter receives transition WITHOUT --stage" "grep -q 'ARGS:transition conf-x completed specialist done 0 0' \"\$STUB_LOG\""
check "dispatcher committed the deliverable itself" "git log --oneline -1 --name-only | grep -q 'docs/report.md'"
check "deliverable commit is labeled with the task stem" "git log --oneline | grep -q 'task: conf-x deliverables'"
check "dispatcher reported the compensation commit" "printf '%s' \"\$OUT\" | grep -q 'committed deliverables for conf-x'"

# ---- --stage passthrough (adapter HAS the stage capability) ----
export STUB_CAPS='{"backend":"stub","contractVersion":1,"commitsToGit":false,"capabilities":["snapshot","snapshot-enriched","transition","stage"]}'
: > "$STUB_LOG"
echo "more" >> docs/report.md
bash "$STORE" transition --stage docs/report.md conf-x completed >/dev/null
check "stage-capable adapter receives --stage intact" "grep -q 'ARGS:transition --stage docs/report.md conf-x completed' \"\$STUB_LOG\""
check "dispatcher did not commit when the adapter owns staging" "[ -n \"\$(git status --porcelain docs/report.md)\" ]"
git add docs/report.md; git commit -qm cleanup

# ---- --stage refusals are preserved under compensation ----
export STUB_CAPS='{"backend":"stub","contractVersion":1,"commitsToGit":false,"capabilities":["transition"]}'
bash "$STORE" transition --stage .backlog/pending/x.md conf-x completed >/dev/null 2>&1; RC=$?
check "--stage refuses .backlog/ paths under compensation (exit 2)" "[ $RC -eq 2 ]"
bash "$STORE" transition --stage /etc/passwd conf-x completed >/dev/null 2>&1; RC=$?
check "--stage refuses absolute paths under compensation (exit 2)" "[ $RC -eq 2 ]"
bash "$STORE" transition --stage ../escape conf-x completed >/dev/null 2>&1; RC=$?
check "--stage refuses .. traversal under compensation (exit 2)" "[ $RC -eq 2 ]"

# ---- raw snapshot enrichment (adapter without snapshot-enriched) ----
if command -v jq >/dev/null 2>&1; then
  printf 'ACFW_STORE=stub\n' > .backlog/.acfw-config
  export STUB_CAPS='{"backend":"stub","contractVersion":1,"commitsToGit":false,"capabilities":["snapshot","transition","doctor"]}'
  # Seed a real LP-CAS ledger marker for conf-acc so the enricher's oracle has a hit.
  . "$ACF_WHIP/skills/lib/acfw-git.sh"
  MP=$(acfw_marker_path conf-acc)
  mkdir -p "$(dirname "$MP")"; printf '{"key":"conf-acc"}\n' > "$MP"
  git add "$MP"; git commit -qm "ledger: conf-acc"
  export STUB_SNAPSHOT='{"raw":true,"generatedAt":"2026-07-15 12:00:00","counts":{},"tasks":[
    {"stem":"conf-acc","id":"conf-acc","folder":"accepted","status":"accepted","slug":"slug-acc","agent":"","priority":"high","deps":[],"touchesGlobs":[],"rejectionCount":0,"blockCount":0,"lastTransitionTs":"2026-07-15 00:00:00","hasCleanCheckoutToken":true},
    {"stem":"conf-run","id":"conf-run","folder":"in-progress","status":"in-progress","slug":"slug-run","agent":"","priority":"medium","deps":["conf-acc"],"touchesGlobs":[],"rejectionCount":0,"blockCount":0,"lastTransitionTs":"2026-07-01 00:00:00","hasCleanCheckoutToken":false}]}'
  ESNAP=$(bash "$STORE" snapshot)
  jq_of(){ printf '%s' "$ESNAP" | jq -r "$1"; }
  check "enriched snapshot keeps the store field" "[ \"\$(jq_of '.store')\" = 'stub' ]"
  check "enricher adds trunk identity" "[ \"\$(jq_of '.trunkSha')\" = \"\$(git rev-parse HEAD)\" ]"
  check "ledger marker flips hasIntegratedAt on" "[ \"\$(jq_of '.tasks[]|select(.stem==\"conf-acc\").hasIntegratedAt')\" = 'true' ]"
  check "unmarked task stays hasIntegratedAt=false" "[ \"\$(jq_of '.tasks[]|select(.stem==\"conf-run\").hasIntegratedAt')\" = 'false' ]"
  check "isCodeMutating derived from slug" "[ \"\$(jq_of '.tasks[]|select(.stem==\"conf-run\").isCodeMutating')\" = 'true' ]"
  check "ageHours computed from lastTransitionTs" "[ \"\$(jq_of '.tasks[]|select(.stem==\"conf-run\").ageHours')\" -ge 0 ]"
  check "counts recomputed: integrated=1" "[ \"\$(jq_of '.counts.integrated')\" = '1' ]"
  check "counts recomputed: runtimeTerminalDefault=1 (integrated accepted is terminal)" "[ \"\$(jq_of '.counts.runtimeTerminalDefault')\" = '1' ]"
  check "counts recomputed: total spans active states" "[ \"\$(jq_of '.counts.total')\" = '2' ]"
  check "worktrees array present" "[ \"\$(jq_of '.worktrees|type')\" = 'array' ]"
  check "raw flag removed after enrichment" "[ \"\$(jq_of 'has(\"raw\")')\" = 'false' ]"

  # ---- merged doctor (adapter without doctor-complete) ----
  export STUB_DOCTOR='FATAL|stub-native|conf-acc|store-native defect
SUMMARY|fatal=1|repairable=0|warn=0|ok=false'
  DOC=$(bash "$STORE" doctor 2>/dev/null); RC=$?
  check "merged doctor keeps the adapter's native finding" "printf '%s\n' \"\$DOC\" | grep -q 'FATAL|stub-native|conf-acc'"
  check "merged doctor adds generic-battery findings (stale-in-progress)" "printf '%s\n' \"\$DOC\" | grep -q '|stale-in-progress|conf-run|'"
  check "merged doctor recomputes one SUMMARY with the FATAL" "printf '%s\n' \"\$DOC\" | grep -qE '^SUMMARY\|fatal=[1-9]' && [ \$(printf '%s\n' \"\$DOC\" | grep -c '^SUMMARY|') -eq 1 ]"
  check "merged doctor exits 1 on FATAL" "[ $RC -eq 1 ]"
  export STUB_DOCTOR='SUMMARY|fatal=0|repairable=0|warn=0|ok=true'
  bash "$STORE" doctor >/dev/null 2>&1; RC=$?
  check "merged doctor exits 0 when no FATAL remains" "[ $RC -eq 0 ]"
  unset STUB_SNAPSHOT STUB_DOCTOR
  git rm -q "$MP"; git commit -qm "unledger"
else
  ok "jq unavailable (enrichment/doctor-merge sections skipped)"
fi

# ---- files fast path end-to-end through the dispatcher ----
rm .backlog/.acfw-config
bash "$STORE" init >/dev/null
cat > "$WORK/t1.md" <<'EOF'
# Task: t1

- **ID**: disp-001-t1
- **Status**: pending
- **Worktree**: none
- **Dependencies**: none
- **Rejection Count**: 0

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-07-15 00:00:00 | draft | pending | task-engineer | init |
EOF
cp "$WORK/t1.md" "$REPO/disp-001-t1.md"
bash "$STORE" create --file "$REPO/disp-001-t1.md" >/dev/null && rm "$REPO/disp-001-t1.md"
bash "$STORE" transition disp-001-t1 in-progress >/dev/null
SNAP=$(bash "$STORE" snapshot --counts-only)
check "dispatcher routes files backend end-to-end" "printf '%s' \"\$SNAP\" | grep -q '\"store\":\"files\"' && printf '%s' \"\$SNAP\" | grep -q '\"in-progress\":1'"

echo
echo "phase9-dispatcher: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
