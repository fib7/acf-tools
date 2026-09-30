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
  doctor)       printf '%s\n' "${STUB_DOCTOR:-SUMMARY|fatal=0|repairable=0|warn=0|ok=true}"; exit "${STUB_DOCTOR_RC:-0}" ;;
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
# The bare folders: `git add -- .backlog` stages the whole task store.
bash "$STORE" transition --stage .backlog conf-x completed >/dev/null 2>&1; RC=$?
check "--stage refuses a bare .backlog under compensation (exit 2)" "[ $RC -eq 2 ]"
bash "$STORE" transition --stage .//.acfwhip/ conf-x completed >/dev/null 2>&1; RC=$?
check "--stage refuses .acfwhip in another spelling under compensation (exit 2)" "[ $RC -eq 2 ]"

# ---- tasks never edit cycles, in any spelling git reads as docs/cycles ----
# A human mid-amendment of an approved plan.md at this root: the compensation commit must never
# carry it, or the approval at HEAD is voided with no /whip card behind it.
CY=docs/cycles/20260101-x
mkdir -p "$CY"; printf '# plan\n' > "$CY/plan.md"; git add "$CY/plan.md"; git commit -qm 'docs(plan): approve x'
printf '# plan\nhalf-written amendment\n' > "$CY/plan.md"
mkdir -p docs/cycles/20260102-draft; printf '# draft\n' > docs/cycles/20260102-draft/plan.md
CYC_HEAD=$(git rev-parse HEAD)
for sp in "docs//cycles/20260101-x/plan.md" "docs/./cycles" "././docs/cycles/" "docs/cycles"; do
  ERR=$(bash "$STORE" transition --stage "$sp" conf-x completed 2>&1 >/dev/null); RC=$?
  check "--stage '$sp' is skipped with a WARN, not refused (rc=$RC)" "[ $RC -eq 0 ] && printf '%s' \"\$ERR\" | grep -q 'WARN: not staging'"
done
check "no cycle spelling produced a commit" "[ \"\$(git rev-parse HEAD)\" = \"$CYC_HEAD\" ]"
echo "notes" > docs/notes.md
bash "$STORE" transition --stage docs conf-x completed >/dev/null 2>&1; RC=$?
check "--stage docs (an ancestor of the cycles folder) commits (rc=$RC)" "[ $RC -eq 0 ] && git log -1 --name-only --format= | grep -qx 'docs/notes.md'"
check "--stage docs leaves docs/cycles out of the commit" "! git log -1 --name-only --format= | grep -q '^docs/cycles/'"
check "the amendment and the draft are still uncommitted" "[ -n \"\$(git status --porcelain -- \"$CY/plan.md\")\" ] && [ -n \"\$(git status --porcelain -- docs/cycles/20260102-draft)\" ]"
check "nothing under docs/cycles was staged either" "[ -z \"\$(git diff --cached --name-only -- docs/cycles)\" ]"
# An exact untracked file under an untracked directory gets no exclude pathspec: with one present,
# git can skip that file silently and still exit 0.
mkdir -p docs/research; echo "r" > docs/research/new.md
bash "$STORE" transition --stage docs/research/new.md conf-x completed >/dev/null 2>&1; RC=$?
check "an exact untracked deliverable under an untracked directory is committed (rc=$RC)" "[ $RC -eq 0 ] && git log -1 --name-only --format= | grep -qx 'docs/research/new.md'"
# A STAGED amendment (git add) is the index, not the working tree: the compensation commit used to be a
# bare `git commit`, which took it along. It must name only the deliverables it staged.
git add -- "$CY/plan.md"; echo "more" > docs/research/new2.md
bash "$STORE" transition --stage docs/research/new2.md conf-x completed >/dev/null 2>&1; RC=$?
check "a staged plan amendment: the deliverable is committed (rc=$RC)" "[ $RC -eq 0 ] && git log -1 --name-only --format= | grep -qx 'docs/research/new2.md'"
check "...and the staged amendment is not, and stays staged" "! git log -1 --name-only --format= | grep -q '^docs/cycles/' && [ -n \"\$(git diff --cached --name-only -- \"$CY/plan.md\")\" ]"
H_STG=$(git rev-parse HEAD)
bash "$STORE" transition --stage docs/research/new2.md conf-x completed >/dev/null 2>&1; RC=$?
check "...a staged amendment alone never makes a deliverables commit look due (no new commit, rc=$RC)" "[ $RC -eq 0 ] && [ \"\$(git rev-parse HEAD)\" = '$H_STG' ]"
git reset -q -- "$CY/plan.md"; git checkout -q -- "$CY/plan.md"; rm -rf docs/cycles/20260102-draft

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

# ---- a battery that COULD NOT RUN must not read as a battery that found nothing -------------------
# Both halves of the non-doctor-complete merge used to discard failure. The adapter's exit status was
# the pipe's (grep's), and a failed snapshot became a WARN — so an unreachable backend, an expired
# token or a crashed adapter yielded fatal=0 ok=true exit 0, and /go's startup HARD GATE dispatched
# against a board nobody had read. Reproduced live against multica with no server configured.
# Line 158 removed the config to exercise the files backend; re-select the stub, because the merge
# path under test only runs for an adapter WITHOUT doctor-complete (files declares it and execs
# doctor.sh directly, so leaving the store as files would make every assertion below vacuous).
printf 'ACFW_STORE=stub\n' > .backlog/.acfw-config
check "store re-selected to the stub (guards against vacuous assertions below)" "bash \"\$STORE\" info | grep -q '\"store\":\"stub\"'"
export STUB_CAPS='{"backend":"stub","contractVersion":1,"commitsToGit":false,"capabilities":["snapshot","read","create","transition","doctor"]}'
export STUB_SNAPSHOT='{"tasks":[],"counts":{"pending":0},"raw":true}'

# Baseline: a healthy adapter still passes, or the assertions below prove nothing.
unset STUB_DOCTOR_RC
D_OK=$(bash "$STORE" doctor 2>/dev/null); D_OK_RC=$?
check "healthy adapter doctor: ok=true, exit 0" "[ \$D_OK_RC -eq 0 ] && printf '%s' \"\$D_OK\" | grep -q 'ok=true'"

# Contract exit 1 = 'ran, found FATALs'. Those are real findings, not a could-not-run.
export STUB_DOCTOR='FATAL|some-real-defect|t1|a genuine finding'
# The env var goes INSIDE the substitution. `STUB_DOCTOR_RC=1 D_F=$(...)` is two assignments in one
# command, not a prefixed command: the stub never sees STUB_DOCTOR_RC, exits 0, and this asserted
# "exit 0 with FATAL lines is not doctor-unavailable" - which was never the contract branch at issue.
# The exit-1 arm went untested, so a regression merging the contract's 1 (ran, found FATALs) into the
# could-not-run class would ship green and abort every /go on a board that has a real FATAL.
D_F=$(STUB_DOCTOR_RC=1 bash "$STORE" doctor 2>/dev/null) || true
check "adapter exit 1 (FATAL findings) is NOT reported as doctor-unavailable" "! printf '%s' \"\$D_F\" | grep -q 'doctor-unavailable'"

# Contract exit 5 = backend unavailable. The battery did not run.
export STUB_DOCTOR='' STUB_DOCTOR_RC=5
D_U=$(bash "$STORE" doctor 2>/dev/null); D_U_RC=$?
check "adapter that could not run -> FATAL|doctor-unavailable" "printf '%s' \"\$D_U\" | grep -q '^FATAL|doctor-unavailable|'"
check "adapter that could not run -> ok=false" "printf '%s' \"\$D_U\" | grep -q 'ok=false'"
check "adapter that could not run -> exit 1 (the gate refuses)" "[ \$D_U_RC -eq 1 ]"
check "the finding names the adapter exit code" "printf '%s' \"\$D_U\" | grep -q 'exit 5'"


# ---- --quiet must reach the GENERIC half too --------------------------------------------------
# The flag was forwarded to the adapter and nowhere else: acfw-doctor-generic.sh was invoked with no
# flags and the merge awk printed every line it produced. On an override-mode board that is hundreds
# of advisory WARNs per iteration, through the scan agent, against the bound workflow.md states as a
# requirement. Semantics are doctor.sh's: FATAL always flows, BREAKDOWN and SUMMARY always print,
# and the counts are taken over the unfiltered set so the gate decision cannot change.
unset STUB_DOCTOR_RC
export STUB_DOCTOR='FATAL|stub-fatal|t1|a real finding
WARN|stub-warn-a|t2|advisory one
WARN|stub-warn-b|t3|advisory two
REPAIRABLE|stub-rep|t4|advisory three'
Q_V=$(bash "$STORE" doctor 2>/dev/null) || true
Q_Q=$(bash "$STORE" doctor --quiet 2>/dev/null) || true
check "verbose really does carry advisories (guards against a vacuous compare)" \
  "[ \$(printf '%s\n' \"\$Q_V\" | grep -cE '^(WARN|REPAIRABLE)\|') -ge 2 ]"
check "--quiet suppresses the advisory dump on the merged path" \
  "[ \$(printf '%s\n' \"\$Q_Q\" | grep -cE '^(WARN|REPAIRABLE)\|') -eq 0 ]"
check "--quiet keeps every FATAL (the gate decision)" \
  "[ \$(printf '%s\n' \"\$Q_Q\" | grep -c '^FATAL|') -eq \$(printf '%s\n' \"\$Q_V\" | grep -c '^FATAL|') ]"
check "--quiet still emits the SUMMARY" "printf '%s\n' \"\$Q_Q\" | grep -q '^SUMMARY|'"
check "--quiet counts advisories it did not print (counts over the unfiltered set)" \
  "[ \"\$(printf '%s\n' \"\$Q_Q\" | sed -n 's/^SUMMARY|fatal=[0-9]*|repairable=\\([0-9]*\\)|.*/\\1/p')\" = \"\$(printf '%s\n' \"\$Q_V\" | sed -n 's/^SUMMARY|fatal=[0-9]*|repairable=\\([0-9]*\\)|.*/\\1/p')\" ]"
check "--quiet and verbose agree on ok=" \
  "[ \"\$(printf '%s\n' \"\$Q_Q\" | sed -n 's/.*|ok=\\(.*\\)/\\1/p' | tail -1)\" = \"\$(printf '%s\n' \"\$Q_V\" | sed -n 's/.*|ok=\\(.*\\)/\\1/p' | tail -1)\" ]"
unset STUB_DOCTOR

# A snapshot the dispatcher cannot obtain means the GRAPH invariants are unverified, not clean.
unset STUB_DOCTOR_RC; export STUB_DOCTOR='SUMMARY|fatal=0|repairable=0|warn=0|ok=true'
cat > "$WORK/nosnap" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  capabilities) printf '%s\n' "$STUB_CAPS" ;;
  snapshot)     echo "backend unreachable" >&2; exit 5 ;;
  doctor)       printf 'SUMMARY|fatal=0|repairable=0|warn=0|ok=true\n' ;;
  *)            printf '{"stub":true}\n' ;;
esac
EOF
chmod +x "$WORK/nosnap"; cp "$WORK/nosnap" "$WORK/override/acfw-store-stub"
D_S=$(ACFW_STORE_ADAPTER_PATH="$WORK/override" bash "$STORE" doctor 2>/dev/null); D_S_RC=$?
check "unobtainable snapshot -> FATAL|snapshot-unavailable (was WARN)" "printf '%s' \"\$D_S\" | grep -q '^FATAL|snapshot-unavailable|'"
check "unobtainable snapshot -> ok=false, exit 1" "[ \$D_S_RC -eq 1 ] && printf '%s' \"\$D_S\" | grep -q 'ok=false'"
check "the finding says the graph invariants are UNVERIFIED" "printf '%s' \"\$D_S\" | grep -q 'UNVERIFIED'"
unset STUB_DOCTOR STUB_SNAPSHOT

# ---- doctor --snapshot: one store enumeration, not two -------------------------------------------
# On a backend without doctor-complete every `doctor` walks the store TWICE — once in the adapter's own
# battery, once more for the generic graph battery. A caller that already holds a full snapshot can
# hand it over. The refusals matter more than the saving: a NARROWED or DIGEST snapshot cannot answer
# the graph invariants (dangling-dep, cyclic-deps, duplicate-id, cross-slug-dep-not-integrated are
# whole-graph properties), and computing them over a subset returns a confidently green report while
# two worktrees race. Refuse as a typed USAGE error, never as a finding.
export STUB_CAPS='{"backend":"stub","contractVersion":1,"commitsToGit":false,"capabilities":["snapshot","read","create","transition","doctor"]}'
export STUB_SNAPSHOT='{"tasks":[],"counts":{"pending":0},"raw":true}'
unset STUB_DOCTOR STUB_DOCTOR_RC
printf 'ACFW_STORE=stub\n' > .backlog/.acfw-config

: > "$STUB_LOG"
bash "$STORE" doctor --quiet >/dev/null 2>&1
N_NOSNAP=$(grep -c '^ARGS:snapshot' "$STUB_LOG" || true); N_NOSNAP=${N_NOSNAP//[^0-9]/}

bash "$STORE" snapshot > "$WORK/full.json" 2>/dev/null
: > "$STUB_LOG"
bash "$STORE" doctor --quiet --snapshot "$WORK/full.json" >/dev/null 2>&1
N_SNAP=$(grep -c '^ARGS:snapshot' "$STUB_LOG" || true); N_SNAP=${N_SNAP//[^0-9]/}

check "doctor without --snapshot enumerates the store for the generic battery" "[ \"\${N_NOSNAP:-0}\" -ge 1 ]"
check "doctor --snapshot reuses the caller's snapshot instead (fewer enumerations)" "[ \"\${N_SNAP:-0}\" -lt \"\${N_NOSNAP:-0}\" ]"

V1=$(bash "$STORE" doctor --quiet 2>/dev/null | tail -1)
V2=$(bash "$STORE" doctor --quiet --snapshot "$WORK/full.json" 2>/dev/null | tail -1)
check "the verdict is identical either way" "[ \"\$V1\" = \"\$V2\" ]"

printf '{"scopeApplied":true,"tasks":[],"counts":{}}\n' > "$WORK/narrow.json"
NOUT=$(bash "$STORE" doctor --snapshot "$WORK/narrow.json" 2>&1); NRC=$?
check "a NARROWED snapshot is refused (exit 2)" "[ $NRC -eq 2 ]"
check "...as a usage error, emitting no report line a caller could read as clean" \
  "! printf '%s\n' \"\$NOUT\" | grep -qE '^(SUMMARY|FATAL)\|'"
check "...and says why a subset cannot answer graph invariants" "printf '%s' \"\$NOUT\" | grep -q 'whole-graph'"

printf '{"digest":true,"tasks":[],"counts":{}}\n' > "$WORK/dig.json"
DRC=0; bash "$STORE" doctor --snapshot "$WORK/dig.json" >/dev/null 2>&1 || DRC=$?
check "a DIGEST snapshot is refused too (bounded working set)" "[ $DRC -eq 2 ]"

MRC=0; bash "$STORE" doctor --snapshot "$WORK/does-not-exist" >/dev/null 2>&1 || MRC=$?
check "an unreadable --snapshot file is a usage error" "[ $MRC -eq 2 ]"
unset STUB_SNAPSHOT

# ---- the graph battery asks the DISPATCH-PATH question, not "is it accepted?" -----------------------
# 118ab4d fixed that tier in the per-task battery and missed the graph pass, so a draft or archived
# card still produced board-blocking FATALs on every backend that lists them — which is exactly where
# this release's defects were found. A draft naming a not-yet-created dependency is explicitly blessed
# by CONTRACT.md, so it must never gate a run.
GEN="$ACF_WHIP/skills/lib/bin/acfw-doctor-generic.sh"
GREPO="$WORK/graph"; git init -q -b trunk "$GREPO" 2>/dev/null
( cd "$GREPO" && git config user.email t@t && git config user.name t && echo s > s && git add -A && git commit -qm s ) >/dev/null 2>&1

G_DRAFT=$(printf '%s' '{"tasks":[{"stem":"p-1","id":"p-1","status":"pending","folder":"pending","slug":"sp","deps":[],"agent":"none"}],"inactive":[{"stem":"d-9","id":"d-9","status":"draft","folder":"draft","slug":"none","deps":["nope"],"agent":"none"}],"counts":{}}' | bash "$GEN" "$GREPO" 2>/dev/null)
check "a DRAFT naming a nonexistent dep is a WARN, not a gate FATAL" \
  "printf '%s\n' \"\$G_DRAFT\" | grep -q '^WARN|dangling-dep|d-9'"
check "...and produces no dangling FATAL at all" \
  "! printf '%s\n' \"\$G_DRAFT\" | grep -q '^FATAL|dangling-dep'"

G_PEND=$(printf '%s' '{"tasks":[{"stem":"p-1","id":"p-1","status":"pending","folder":"pending","slug":"sp","deps":["nope"],"agent":"none"}],"counts":{}}' | bash "$GEN" "$GREPO" 2>/dev/null)
check "a PENDING task naming the same dep still gates the run" \
  "printf '%s\n' \"\$G_PEND\" | grep -q '^FATAL|dangling-dep|p-1'"

# An out-of-vocabulary state is inert for the same reason and must be treated the same way.
G_ODD=$(printf '%s' '{"tasks":[{"stem":"x-1","id":"x-1","status":"in-external-review","folder":"in-external-review","slug":"sx","deps":["nope"],"agent":"none"}],"counts":{}}' | bash "$GEN" "$GREPO" 2>/dev/null)
check "an out-of-vocabulary state is inert too (no gate FATAL)" \
  "! printf '%s\n' \"\$G_ODD\" | grep -q '^FATAL|dangling-dep'"

# A cycle among drafts is likewise not a gate concern.
G_CYC=$(printf '%s' '{"tasks":[],"inactive":[{"stem":"a","id":"a","status":"draft","folder":"draft","slug":"none","deps":["b"],"agent":"none"},{"stem":"b","id":"b","status":"draft","folder":"draft","slug":"none","deps":["a"],"agent":"none"}],"counts":{}}' | bash "$GEN" "$GREPO" 2>/dev/null)
check "a cycle among DRAFT tasks does not gate the run" \
  "! printf '%s\n' \"\$G_CYC\" | grep -q '^FATAL|cyclic-deps'"

# ---- the enricher's ACTIVE/INACTIVE split -----------------------------------------------------------
# 3.3.0's largest new concept, and it shipped with zero behavioural assertions: reverting the
# `map(select(isactive))` filter with one token left the whole suite green. The split is load-bearing
# in three places — a scoped run counts tasks[] as its denominator and isTerminal is false for both
# inactive states, the per-task doctor battery raises findings against every entry, and inactive[] is
# still unioned into the dependency index so a task depending on a draft reports dep-inactive rather
# than the lie dangling-dep.
ENR="$ACF_WHIP/skills/lib/bin/acfw-enrich-snapshot.sh"
if command -v jq >/dev/null 2>&1; then
  ENR_IN='{"raw":true,"tasks":[
    {"stem":"e-pend","id":"e-pend","folder":"pending","slug":"sp","deps":["e-draft"]},
    {"stem":"e-blk","id":"e-blk","folder":"blocked","slug":"sb","deps":[]},
    {"stem":"e-acc","id":"e-acc","folder":"accepted","slug":"sa","deps":[]},
    {"stem":"e-draft","id":"e-draft","folder":"draft","slug":"none","deps":[]},
    {"stem":"e-arch","id":"e-arch","folder":"archive","slug":"none","deps":[]}],"counts":{}}'
  ENR_OUT=$(printf '%s' "$ENR_IN" | bash "$ENR" "$REPO" 2>/dev/null)

  check "enricher: draft and archive are OUT of tasks[]" \
    "[ \"\$(printf '%s' \"\$ENR_OUT\" | jq -r '[.tasks[].stem] | sort | join(\",\")')\" = 'e-acc,e-blk,e-pend' ]"
  check "enricher: they are in inactive[], not dropped" \
    "[ \"\$(printf '%s' \"\$ENR_OUT\" | jq -r '[.inactive[].stem] | sort | join(\",\")')\" = 'e-arch,e-draft' ]"
  check "enricher: counts.total spans the ACTIVE set only (3, not 5)" \
    "[ \"\$(printf '%s' \"\$ENR_OUT\" | jq -r '.counts.total')\" = '3' ]"
  check "enricher: an inactive task never appears in both arrays" \
    "[ \"\$(printf '%s' \"\$ENR_OUT\" | jq -r '[.tasks[].stem] as \$a | [.inactive[].stem] | map(select(. as \$s | \$a | index(\$s))) | length')\" = '0' ]"
  check "enricher: inactive entries still carry the git-derived facts deps need" \
    "[ \"\$(printf '%s' \"\$ENR_OUT\" | jq -r '.inactive[0] | has(\"hasIntegratedAt\") and has(\"hasWorktreeBranch\")')\" = 'true' ]"

  # And the consequence that matters: the graph battery must resolve the draft dep rather than call it
  # dangling. This is what fails if the split is reverted AND inactive[] stops being emitted.
  ENR_DOC=$(printf '%s' "$ENR_OUT" | bash "$ACF_WHIP/skills/lib/bin/acfw-doctor-generic.sh" "$REPO" 2>/dev/null)
  check "a pending task depending on a draft reports dep-inactive, not dangling-dep" \
    "printf '%s\n' \"\$ENR_DOC\" | grep -q '^WARN|dep-inactive|e-pend' && ! printf '%s\n' \"\$ENR_DOC\" | grep -q 'dangling-dep|e-pend'"
else
  ok "jq absent (enricher split assertions skipped)"
fi

# ============================================================================================
# 3.4.0: snapshot --only / --full-to / relay header (dispatcher post-stage)
# ============================================================================================
# The failure being prevented: a raw adapter emits EVERY card (accepted, archive, draft and all),
# /go's shell-runner has to echo that through one schema string, and a shortened-but-valid echo is
# indistinguishable from a real board — so a scoped run reports that its ids "do not exist".
if command -v jq >/dev/null 2>&1; then
  RAWCAPS='{"backend":"stub","contractVersion":1,"commitsToGit":false,"capabilities":["snapshot","read","create","transition"]}'
  # A board shaped like the real hazard: a seed, a BLOCKED dep of that seed, a terminal-accepted dep
  # of THAT, one unrelated card, one terminal-accepted card nothing depends on, and an archived card.
  SCOPE_SNAP='{"raw":true,"generatedAt":"2026-09-22 00:00:00","counts":{"pending":2,"blocked":1,"accepted":2,"total":6},"tasks":[
    {"stem":"ui-021-login","id":"ui-021-login","backendId":"MUL-4821","folder":"pending","slug":"ui","deps":["api-014-token"],"touchesGlobs":[]},
    {"stem":"api-014-token","id":"api-014-token","backendId":"MUL-100","folder":"blocked","slug":"api","deps":["db-001-schema"],"touchesGlobs":[]},
    {"stem":"db-001-schema","id":"db-001-schema","backendId":"MUL-101","folder":"accepted","slug":"none","deps":[],"touchesGlobs":[]},
    {"stem":"unrelated-777","id":"unrelated-777","backendId":"MUL-777","folder":"pending","slug":"other","deps":[],"touchesGlobs":[]},
    {"stem":"solo-500-acc","id":"solo-500-acc","backendId":"MUL-500","folder":"accepted","slug":"none","deps":[],"touchesGlobs":[]},
    {"stem":"old-300-arch","id":"old-300-arch","backendId":"MUL-300","folder":"archive","slug":"none","deps":[],"touchesGlobs":[]}]}'

  : > "$STUB_LOG"
  S_ONLY=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot --only ui-021-login --mode default)

  # --only must NEVER reach an adapter that does not declare snapshot-only: a raw adapter that
  # narrowed its own walk would make both the closure and the store-wide counts wrong, silently.
  check "--only is not forwarded to an adapter without snapshot-only" "! grep -q 'ARGS:snapshot.*--only' \"\$STUB_LOG\""
  check "...and the adapter is still asked for the full walk" "grep -q 'ARGS:snapshot' \"\$STUB_LOG\""

  check "--only narrows tasks[] to the closure" \
    "[ \"\$(printf '%s' \"\$S_ONLY\" | jq -r '[.tasks[].stem]|sort|join(\",\")')\" = 'api-014-token,ui-021-login' ]"
  # A BLOCKED dep is retryable, not done: leaving it outside the scope means it can never be
  # unblocked, so the seed can never dispatch and the run exits no-progress with nothing done.
  check "...pulling in a BLOCKED dependency" \
    "printf '%s' \"\$S_ONLY\" | jq -e '.scope.added|index(\"api-014-token\")' >/dev/null"
  check "...and stopping at a terminal-accepted one" \
    "! printf '%s' \"\$S_ONLY\" | jq -e '[.tasks[].stem]|index(\"db-001-schema\")' >/dev/null"
  # Stopping is not dropping. api-014-token still depends on it, and a token the payload cannot resolve
  # is dangling to the scheduler, which never dispatches past one.
  check "...while carrying it in satisfiedDeps, so the task that depends on it can resolve it" \
    "printf '%s' \"\$S_ONLY\" | jq -e '[.satisfiedDeps[].stem]|index(\"db-001-schema\")' >/dev/null"
  check "...never touching an unrelated task" \
    "! printf '%s' \"\$S_ONLY\" | jq -e '[.tasks[].stem]|index(\"unrelated-777\")' >/dev/null"
  check "--only sets scopeApplied" "printf '%s' \"\$S_ONLY\" | jq -e '.scopeApplied == true' >/dev/null"
  check "--only records what each seed resolved to" \
    "[ \"\$(printf '%s' \"\$S_ONLY\" | jq -r '.scope.resolved[\"ui-021-login\"]')\" = 'ui-021-login' ]"
  # The store-wide counts must survive narrowing: the doctor, the report and an unscoped completion
  # test all read them, and a narrowed count would understate the board.
  # 6 cards, one archived: the enricher's counts span the ACTIVE set, so 5 — and crucially NOT the 2
  # the scoped view holds. Narrowing must never reach the number the report and the doctor read.
  check "store-wide counts are NOT narrowed" "printf '%s' \"\$S_ONLY\" | jq -e '.counts.total == 5' >/dev/null"
  check "...and a scoped count is reported alongside" "printf '%s' \"\$S_ONLY\" | jq -e '.scopeCounts.total == 2' >/dev/null"

  # relay: the consumer must be able to PROVE it received everything the producer emitted.
  check "relay header is emitted" "printf '%s' \"\$S_ONLY\" | jq -e '.relay.n == 3' >/dev/null"
  check "relay is the FIRST key (a tail-elided echo still carries the expectation)" \
    "printf '%s' \"\$S_ONLY\" | grep -q '^{\"relay\":'"
  check "relay counts each array separately (a short payload names which one)" \
    "printf '%s' \"\$S_ONLY\" | jq -e '.relay.tasks == 2 and .relay.inactive == 0 and .relay.sat == 1' >/dev/null"
  check "relay.bytes is the stem byte sum over every array" \
    "[ \"\$(printf '%s' \"\$S_ONLY\" | jq -r '.relay.bytes')\" = \"\$(printf '%s' \"\$S_ONLY\" | jq -r '[(.tasks[],.inactive[],.satisfiedDeps[]).stem|utf8bytelength]|add')\" ]"

  # An unscoped snapshot carries the header too — the relay hop is the same on every path.
  S_PLAIN=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot)
  check "an unscoped snapshot still carries relay" "printf '%s' \"\$S_PLAIN\" | jq -e '.relay.n > 0' >/dev/null"
  check "...and is not marked scopeApplied" "! printf '%s' \"\$S_PLAIN\" | jq -e '.scopeApplied == true' >/dev/null"

  # Seed resolution: native id, unknown, ambiguous prefix, inactive.
  S_BID=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot --only MUL-4821)
  check "a native backend id resolves to its stem" \
    "[ \"\$(printf '%s' \"\$S_BID\" | jq -r '.scope.resolved[\"MUL-4821\"]')\" = 'ui-021-login' ]"
  # MUL-4 must NOT prefix-match MUL-4821: backend ids resolve EXACTLY, or `/go MUL-4` would silently
  # run someone else's card.
  S_BID2=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot --only MUL-4)
  check "a partial backend id does NOT prefix-match" "printf '%s' \"\$S_BID2\" | jq -e '.scope.unresolved|index(\"MUL-4\")' >/dev/null"

  S_NOPE=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot --only nope-404); RC=$?
  check "an unresolvable seed is reported, not an error" "[ $RC -eq 0 ]"
  check "...and named in scope.unresolved" "printf '%s' \"\$S_NOPE\" | jq -e '.scope.unresolved|index(\"nope-404\")' >/dev/null"
  check "...leaving the view empty rather than falling back to the whole board" \
    "printf '%s' \"\$S_NOPE\" | jq -e '(.tasks|length) == 0' >/dev/null"

  AMB_SNAP=$(printf '%s' "$SCOPE_SNAP" | jq -c '.tasks += [{"stem":"ui-021-logout","id":"ui-021-logout","backendId":"MUL-999","folder":"pending","slug":"ui2","deps":[],"touchesGlobs":[]}]')
  S_AMB=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$AMB_SNAP" bash "$STORE" snapshot --only ui-021)
  check "an ambiguous prefix is reported, never guessed" \
    "printf '%s' \"\$S_AMB\" | jq -e '.scope.ambiguous[0].tok == \"ui-021\"' >/dev/null"
  check "...with the candidates named" \
    "printf '%s' \"\$S_AMB\" | jq -e '(.scope.ambiguous[0].candidates|length) == 2' >/dev/null"
  check "...and nothing dispatched on the guess" "printf '%s' \"\$S_AMB\" | jq -e '(.tasks|length) == 0' >/dev/null"

  S_ARCH=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot --only old-300-arch)
  check "an archived seed is reported as inactive, not unresolvable" \
    "printf '%s' \"\$S_ARCH\" | jq -e '.scope.inactiveSeeds[0].stem == \"old-300-arch\"' >/dev/null"

  # ---- real --digest for a raw adapter (it used to be a documented no-op) ----
  S_DG=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot --digest --mode default)
  check "--digest collapses a terminal-accepted DEP TARGET into satisfiedDeps" \
    "printf '%s' \"\$S_DG\" | jq -e '[.satisfiedDeps[].stem]|index(\"db-001-schema\")' >/dev/null"
  check "...carrying its backendId for display" \
    "printf '%s' \"\$S_DG\" | jq -e '.satisfiedDeps[]|select(.stem==\"db-001-schema\")|.backendId == \"MUL-101\"' >/dev/null"
  check "--digest DROPS a terminal-accepted task nothing depends on" \
    "! printf '%s' \"\$S_DG\" | jq -e '[.tasks[].stem,.satisfiedDeps[].stem]|index(\"solo-500-acc\")' >/dev/null"
  check "...but it survives in the store-wide counts" "printf '%s' \"\$S_DG\" | jq -e '.counts.total == 5' >/dev/null"
  check "--digest marks itself" "printf '%s' \"\$S_DG\" | jq -e '.digest == true' >/dev/null"

  # Mode sensitivity: an accepted code task with a live branch and no ledger marker still has to be
  # INTEGRATED in default mode, so it must stay a full record there and collapse only under override.
  BR_SNAP=$(printf '%s' "$SCOPE_SNAP" | jq -c '(.tasks[]|select(.stem=="solo-500-acc")|.slug) = "solo"')
  mkdir -p "$REPO/.worktree" 2>/dev/null || true
  S_DEF=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$BR_SNAP" bash "$STORE" snapshot --digest --mode default)
  S_OVR=$(STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$BR_SNAP" bash "$STORE" snapshot --digest --mode override)
  check "override collapses an accepted code task that default would keep" \
    "[ \"\$(printf '%s' \"\$S_OVR\" | jq -r '[.tasks[].stem]|index(\"solo-500-acc\")//\"gone\"')\" = 'gone' ]"

  # ---- a narrowed view never refers to a task it does not carry (3.6.1) ----
  # The post-stage narrowed tasks[] to the unfinished closure and only THEN chose which finished tasks
  # to keep as satisfiedDeps, from what was left. A finished task the scope named, or depended on, was
  # therefore in neither array. The header was computed after the drop, so the relay verified; the
  # scheduler refused the run because its own seed had vanished, or never dispatched the dependent
  # because its token dangled. Driven on the script directly: the enricher recomputes the ledger and
  # branch facts from git, and each variant below needs them set.
  SCOPE="$ACF_WHIP/skills/lib/bin/acfw-scope-snapshot.sh"
  # I1: every stem the store resolved is in the payload (the scheduler's own check).
  # I2: every dependency token of every emitted record resolves within the payload, by the scheduler's
  #     rules: exact id, exact stem, then stem prefix, over records and satisfiedDeps alike.
  INV_I1='. as $p | [($p.scope.resolved // {})[]] | all(. as $s | [($p.tasks[],$p.inactive[],$p.satisfiedDeps[]) | .stem] | index($s) != null)'
  INV_I2='. as $p | [($p.tasks[],$p.inactive[]) | (.deps // [])[]] | all(. as $k | [$p.tasks[],$p.inactive[],$p.satisfiedDeps[]] | any((.id // "") == $k or (.stem // "") == $k or ((.stem // "") | startswith($k))))'
  # A (API-14) is finished three ways; B (UI-21) is pending and depends on it by id.
  for VAR in live none integrated; do
    case "$VAR" in
      live)       A_SLUG=api;  A_IA=false; A_WB=true ;;   # accepted, branch unmerged: default must still integrate it
      none)       A_SLUG=none; A_IA=false; A_WB=false ;;
      integrated) A_SLUG=api;  A_IA=true;  A_WB=true ;;
    esac
    BOARD='{"counts":{},"inactive":[],"satisfiedDeps":[],"tasks":[
      {"stem":"api-014-token","id":"API-14","backendId":"MUL-14","folder":"accepted","slug":"'"$A_SLUG"'","hasIntegratedAt":'"$A_IA"',"hasWorktreeBranch":'"$A_WB"',"deps":[]},
      {"stem":"ui-021-login","id":"UI-21","backendId":"MUL-21","folder":"pending","slug":"ui","hasIntegratedAt":false,"hasWorktreeBranch":false,"deps":["API-14"]}]}'
    for M in override default; do
      for DG in "" --digest; do
        for SEEDS in "API-14 UI-21" "UI-21"; do
          OA=(); for s in $SEEDS; do OA+=(--only "$s"); done
          OUT=$(printf '%s' "$BOARD" | bash "$SCOPE" --mode "$M" $DG "${OA[@]}")
          CELL="[$VAR/$M/${DG:-full}/${SEEDS// /+}]"
          check "$CELL I1 every resolved seed is in the payload" "printf '%s' \"\$OUT\" | jq -e '$INV_I1' >/dev/null"
          check "$CELL I2 every dependency token resolves in the payload" "printf '%s' \"\$OUT\" | jq -e '$INV_I2' >/dev/null"
          # Where A must be: a full record while it still has to be integrated (default, live branch,
          # no marker), otherwise a satisfiedDeps entry. Never in tasks[] once it is finished, or the
          # scoped view would carry work nobody may dispatch.
          if [ "$VAR" = live ] && [ "$M" = default ]; then WANT=tasks; else WANT=satisfiedDeps; fi
          check "$CELL the finished task is carried in $WANT" \
            "printf '%s' \"\$OUT\" | jq -e '[.${WANT}[].stem]|index(\"api-014-token\")' >/dev/null"
          check "$CELL ...and tasks[] holds only what the scope may schedule" \
            "printf '%s' \"\$OUT\" | jq -e '.scopeCounts.total == (.tasks|length) and (.tasks|map(.stem)|index(\"ui-021-login\")) != null' >/dev/null"
        done
      done
    done
  done
  # Unscoped --digest had the same gap for a dependency token that is a stem PREFIX: the scheduler
  # resolves it, but the digest kept a finished target only on an exact stem or id match.
  PFX='{"counts":{},"inactive":[],"satisfiedDeps":[],"tasks":[
    {"stem":"db-001-schema","id":"db-001-schema","folder":"accepted","slug":"none","hasIntegratedAt":false,"hasWorktreeBranch":false,"deps":[]},
    {"stem":"ui-021-login","id":"ui-021-login","folder":"pending","slug":"ui","hasIntegratedAt":false,"hasWorktreeBranch":false,"deps":["db-001"]}]}'
  OUT=$(printf '%s' "$PFX" | bash "$SCOPE" --mode default --digest)
  check "unscoped --digest keeps a finished target named by a stem prefix" \
    "printf '%s' \"\$OUT\" | jq -e '$INV_I2' >/dev/null"

  # ---- --full-to: one store walk feeds BOTH the scheduler and the doctor ----
  FULLF="$WORK/full-snap.json"
  STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot --digest --only ui-021-login --full-to "$FULLF" >/dev/null
  check "--full-to writes a file" "[ -s \"\$FULLF\" ]"
  check "...holding the FULL board, not the narrowed view" "[ \"\$(jq -r '.tasks|length' \"\$FULLF\")\" = '5' ]"
  check "...unmarked by the narrowing that followed it" "! jq -e '.scopeApplied == true' \"\$FULLF\" >/dev/null"
  # This is the point of the tee: doctor --snapshot refuses a narrowed/digest file by design, so the
  # file must be the pre-collapse one or the dispatcher would have to walk the store a second time.
  STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" doctor --snapshot "$FULLF" >/dev/null 2>&1; RC=$?
  check "doctor --snapshot ACCEPTS the tee'd full file" "[ $RC -le 1 ]"
  NARROWF="$WORK/narrow-snap.json"
  STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" snapshot --only ui-021-login > "$NARROWF"
  STUB_CAPS="$RAWCAPS" STUB_SNAPSHOT="$SCOPE_SNAP" bash "$STORE" doctor --snapshot "$NARROWF" >/dev/null 2>&1; RC=$?
  check "...while the narrowed stdout snapshot is still refused (exit 2)" "[ $RC -eq 2 ]"
else
  ok "jq absent (3.4.0 scope/digest/relay assertions skipped)"
fi

# ============================================================================================
# An UNKNOWN clean-checkout token (null) survives the whole raw path and gates nothing
# ============================================================================================
# linear and multica report hasCleanCheckoutToken: null when the read that answers it failed. The
# review gate parks a task on `=== false`, so a null coerced to false anywhere between the adapter and
# the workflow turns one rate-limited request into a park -> unblock -> re-dispatch -> park livelock.
# The enricher used `// false`, which in jq maps null to false exactly as it maps a missing key, and
# the generic doctor rendered the field the same way. Each hop is asserted, with a false-token control
# so the "no finding" assertions cannot pass vacuously.
if command -v jq >/dev/null 2>&1; then
  TOKCAPS='{"backend":"stub","contractVersion":1,"commitsToGit":false,"capabilities":["snapshot","read","create","transition","doctor","token-all-states"]}'
  TOK_SNAP='{"raw":true,"generatedAt":"2026-09-29 00:00:00","counts":{},"tasks":[
    {"stem":"k-rev-unk","id":"k-rev-unk","folder":"in-review","status":"in-review","slug":"sk1","agent":"","deps":[],"touchesGlobs":[],"hasCleanCheckoutToken":null},
    {"stem":"k-acc-unk","id":"k-acc-unk","folder":"accepted","status":"accepted","slug":"none","agent":"","deps":[],"touchesGlobs":[],"hasCleanCheckoutToken":null},
    {"stem":"k-acc-no","id":"k-acc-no","folder":"accepted","status":"accepted","slug":"none","agent":"","deps":[],"touchesGlobs":[],"hasCleanCheckoutToken":false},
    {"stem":"k-rev-omit","id":"k-rev-omit","folder":"in-review","status":"in-review","slug":"sk4","agent":"","deps":[],"touchesGlobs":[]}]}'
  tok_of(){ printf '%s' "$1" | jq -r --arg s "$2" '.tasks[] | select(.stem==$s) | .hasCleanCheckoutToken | tostring'; }

  TE=$(printf '%s' "$TOK_SNAP" | bash "$ENR" "$REPO" 2>/dev/null)
  check "enricher: an explicit null token survives (not coerced to false)" "[ \"\$(tok_of \"\$TE\" k-rev-unk)\" = 'null' ]"
  check "enricher: a MISSING token key still defaults to false (adapters that omit it are unchanged)" \
    "[ \"\$(tok_of \"\$TE\" k-rev-omit)\" = 'false' ]"
  check "enricher: a definite false is still false" "[ \"\$(tok_of \"\$TE\" k-acc-no)\" = 'false' ]"

  # Through the dispatcher: adapter -> enrich -> relay post-stage, plain and narrowed.
  TS=$(ACFW_STORE=stub STUB_CAPS="$TOKCAPS" STUB_SNAPSHOT="$TOK_SNAP" bash "$STORE" snapshot 2>/dev/null)
  check "dispatcher snapshot: null survives enrichment and the relay post-stage" "[ \"\$(tok_of \"\$TS\" k-rev-unk)\" = 'null' ]"
  check "...and the relay header still adds up" \
    "printf '%s' \"\$TS\" | jq -e '.relay.tasks == (.tasks|length) and .relay.bytes == ([.tasks[].stem|utf8bytelength]|add)' >/dev/null"
  TSO=$(ACFW_STORE=stub STUB_CAPS="$TOKCAPS" STUB_SNAPSHOT="$TOK_SNAP" bash "$STORE" snapshot --only k-rev-unk 2>/dev/null)
  check "dispatcher snapshot --only: null survives narrowing" "[ \"\$(tok_of \"\$TSO\" k-rev-unk)\" = 'null' ]"

  # The generic doctor, on its own and merged by the dispatcher. tokenAllStates=true is the only
  # configuration in which it raises a token finding at all, so it is the one that proves anything.
  TD=$(printf '%s' "$TE" | jq -c '. + {tokenAllStates: true}' | bash "$GEN" "$REPO" 2>/dev/null)
  check "generic doctor: the control (accepted, token false) still WARNs" \
    "printf '%s\n' \"\$TD\" | grep -q '^WARN|missing-clean-checkout-token|k-acc-no|'"
  check "generic doctor: an unknown token draws no token finding" \
    "! printf '%s\n' \"\$TD\" | grep -qE '\\|missing-clean-checkout-token\\|k-(acc|rev)-unk\\|'"
  check "generic doctor: ...and nothing FATAL or REPAIRABLE against either unknown task" \
    "! printf '%s\n' \"\$TD\" | grep -qE '^(FATAL|REPAIRABLE)\\|[^|]*\\|k-(acc|rev)-unk\\|'"
  TM=$(ACFW_STORE=stub STUB_CAPS="$TOKCAPS" STUB_SNAPSHOT="$TOK_SNAP" bash "$STORE" doctor 2>/dev/null)
  check "merged doctor: the control WARNs, the unknown does not" \
    "printf '%s\n' \"\$TM\" | grep -q '^WARN|missing-clean-checkout-token|k-acc-no|' && ! printf '%s\n' \"\$TM\" | grep -q '|missing-clean-checkout-token|k-acc-unk|'"
else
  ok "jq absent (unknown-token assertions skipped)"
fi

echo
echo "phase9-dispatcher: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
