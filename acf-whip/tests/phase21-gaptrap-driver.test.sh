#!/usr/bin/env bash
# phase21-gaptrap-driver.test.sh — the GapTrap spec-tool driver (acf-whip 3.5.0), offline.
#
# WHAT THIS GUARDS. The driver talks to a paid remote reviewer, so its failure modes cost money or
# leak a credential, and none of them is visible from a green review:
#   - a timeout, kill or `failed` analysis that re-creates the spec on the next card bills again
#     (Solo is 15 units a month), so resume and the failed memo are pinned with zero-create counts;
#   - a create_spec whose reply was lost (000, 502, SIGKILL, TERM) may already be billed, so it is
#     never resent blind: the next run finds it with the free list_specs. Only a request that never
#     left (connect refused) or a create carrying an idempotencyKey is resent;
#   - trusting write-1's verdict turns a template NO-GO into a GO, so the contractStatus flip is pinned,
#     and so is the escape when write-2 never lands at all;
#   - a per-run uuid as fp makes every finding "new" every round, so fp stability is pinned across
#     revisions whose gap_ids, offsets, case and line wrapping all differ;
#   - byte arithmetic on a codepoint offset shifts L<n> after an em dash, so a fixture discriminates;
#   - HTTP 401/403 and HTTP 200 + isError (quota_exceeded, spec_too_large) are different layers and
#     both must read as "unavailable" (exit 3), never as a verdict;
#   - the key must never be in any process's argv or in any output. The REAL curl path is exercised
#     through a slow fake curl on PATH while ps looks, with no transport seam in the way;
#   - VERBS is static (acfw-spec caches it), and pull/from stay "not offered yet" until GapTrap lists
#     get_spec / list_answers.
#
# Fixtures (tests/fixtures/gaptrap/*.http) are JSON-RPC replies in the envelopes GapTrap's MCP
# endpoint returns (ok/error envelopes, status/report/list results, the report shape); values are
# synthetic. They are replayed by fixtures/gaptrap/fake-transport through ACFW_GAPTRAP_TRANSPORT.
# Nothing here reaches the network: every run sets the seam or puts the fake curl first on PATH, and
# the fake-curl runs point at a .invalid host.
#
# Run: bash acf-whip/tests/phase21-gaptrap-driver.test.sh
set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$ACF_WHIP/spec-tools/gaptrap/acfw-spec-gaptrap"
EXAMPLE="$ACF_WHIP/spec-tools/gaptrap/gaptrap.example"
GTREADME="$ACF_WHIP/spec-tools/gaptrap/README.md"
FIX="$ACF_WHIP/tests/fixtures/gaptrap"
BASH32=/bin/bash; [ -x "$BASH32" ] || BASH32=bash   # macOS /bin/bash is 3.2: the floor the driver must hold

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }
if ! command -v jq >/dev/null 2>&1; then
  echo "FATAL: jq is required by the gaptrap driver and by this suite"; echo "phase21-gaptrap-driver: 0 passed, 1 failed"; exit 1
fi

# Never let a real credential or endpoint from the caller's shell reach a run.
unset GAPTRAP_API_KEY GAPTRAP_MCP_URL GAPTRAP_APP_URL GAPTRAP_TEMPLATE_ID GAPTRAP_FOLDER_ID GAPTRAP_MODE \
      GAPTRAP_POLL_INTERVAL ACFW_GAPTRAP_TRANSPORT ACFW_SPEC_FRESH ACFW_SPEC_SAME_REF ACFW_SPEC_REF 2>/dev/null || true

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p21gt.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp" "$WORK/tmpk" "$WORK/bin"
REPO="$WORK/repo"; git init -q "$REPO"; cd "$REPO" || exit 1
git config user.email t@t; git config user.name t
printf '.acfwhip/\n.env\n' > .gitignore; git add .gitignore; git commit -qm seed

# A key-shaped value built at runtime (no literal in the repo). It is only ever compared through
# grep -f <file> or pure bash, so no assertion puts it in an argv while ps might be looking.
KEY="gtmcp_$(printf '%s' "$$$(date +%s)" | git hash-object --stdin)AbCdEfGh_-"
printf '%s\n' "$KEY" > "$WORK/keyfile"
leaks(){ grep -rqF -f "$WORK/keyfile" "$@" 2>/dev/null; }

S1=Xy12pQ7rT3uV9wZ1aB4c S2=Qa77mN2bV8cX5zL0kJ3h CH=Ch1ldR9sT4uV6wX8yZ0a ORG=org7f3k2m9 AD=Ad0ptEdSp3cXyZ12345
CYCLE_ID=20260928-seat-notice
mkdir -p "$WORK/frozen"
cp "$FIX/plan.md" "$WORK/frozen/plan.md"; cp "$FIX/plan2.md" "$WORK/frozen/plan2.md"
chmod a-w "$WORK/frozen/plan.md" "$WORK/frozen/plan2.md"          # the engine's frozen copies are read-only
BLOB1=$(git hash-object "$WORK/frozen/plan.md"); BLOB2=$(git hash-object "$WORK/frozen/plan2.md")

# scen <name> <slot=fixture>... — a replay directory for fake-transport; sets SCEN
scen(){ local kv; SCEN="$WORK/scen/$1"; shift; rm -rf "$SCEN"; mkdir -p "$SCEN"
  for kv in "$@"; do cp "$FIX/${kv#*=}.http" "$SCEN/${kv%%=*}" || bad "missing fixture ${kv#*=}"; done; }
calls(){ [ -f "$SCEN/log" ] || { echo 0; return; }; awk -v k="$1" '$1==k{c++} END{print c+0}' "$SCEN/log"; }
ncalls(){ [ -f "$SCEN/log" ] || { echo 0; return; }; wc -l < "$SCEN/log" | tr -d ' '; }
args_of(){ awk -v k="$1" '$1==k{sub(/^[^ ]+ /,""); a=$0} END{print a}' "$SCEN/log" 2>/dev/null; }
req_arg(){ jq -r ".params.arguments.$3 // empty" "$1/log.req.$2" 2>/dev/null; }   # <scen dir> <slot.n> <field>

# seed <kind> <id> [age seconds] — a slot exactly as the driver writes one (default endpoint, no template)
seed(){ mkdir -p "$STATE/$1"; printf '%s\nvariant=app.gaptrap.ai||\nat=%s\n' "$2" "$(( $(date +%s) - ${3:-0} ))" > "$STATE/$1/$BLOB1"; }
# iso <epoch> — GapTrap's createdAt shape (Date.toISOString)
iso(){ jq -rn --argjson s "$1" '$s | todate | sub("Z$"; ".000Z")'; }
# mk_list <file> <spec-json>... — a list_specs reply built at run time, so createdAt can be "now"
mk_list(){ local out="$1"; shift
  { echo 200; printf '%s\n' "$@" | jq -cs '{jsonrpc:"2.0",id:1,result:{content:[{type:"text",text:({specs:.}|tojson)}]}}'; } > "$out"; }
spec_row(){ jq -cn --arg id "$1" --arg fn "$2" --arg at "$3" '{specId:$id, createdAt:$at, filename:$fn, status:"pending", isDraft:false, parentSpecId:null}'; }

# drive <verb> [NAME=value | -NAME]... — run the driver under /bin/bash in a subshell with the protocol env
# (FILE/BLOB/STATE/OUT default to plan.md, $STATE, $OUTD). -NAME unsets. Sets RC, OUT, ERR, ERR1.
RUNS=0
drive_env(){
  export ACFW_TRUNK_ROOT="$REPO" ACFW_SPEC_VERB="$1" ACFW_SPEC_STAGE=plan ACFW_SPEC_KEY="$CYCLE_ID" \
         ACFW_SPEC_FILE="$WORK/frozen/plan.md" ACFW_SPEC_BLOB="$BLOB1" ACFW_SPEC_STATE="$STATE" ACFW_SPEC_OUT="$OUTD" \
         ACFW_SPEC_DEADLINE=$(( $(date +%s) + 60 )) GAPTRAP_API_KEY="$KEY" GAPTRAP_POLL_INTERVAL=0 \
         ACFW_GAPTRAP_TRANSPORT="bash '$FIX/fake-transport'" GT_SCEN="$SCEN" GT_LOG="$SCEN/log" TMPDIR="$WORK/tmp"
  shift; local a
  for a in "$@"; do case "$a" in -*) unset "${a#-}" ;; *=*) export "$a" ;; esac; done
}
collect(){ OUT=$(cat "$1"); ERR=$(cat "$2"); ERR1=$(head -n 1 "$2"); RUNS=$((RUNS + 1)); cat "$1" "$2" >> "$WORK/all-output"; }
drive(){ local v="$1"; shift
  ( cd "$REPO" && drive_env "$v" "$@" && exec "$BASH32" "$DRIVER" "$v" ) > "$WORK/out" 2> "$WORK/err"; RC=$?
  collect "$WORK/out" "$WORK/err"
}
# drive_bg <verb> [env]... — the engine's watchdog shape: the driver leads its own process group (perl
# setpgrp, as acfw-spec does on macOS), so a signal can go to -pgid. Sets BGPID; bg_wait collects.
drive_bg(){ local v="$1"; shift
  ( cd "$REPO" && drive_env "$v" "$@" && exec perl -e 'setpgrp(0,0); exec @ARGV or die "exec: $!"' "$BASH32" "$DRIVER" "$v" ) \
    > "$WORK/bgout" 2> "$WORK/bgerr" &
  BGPID=$!
}
bg_wait(){ wait "$BGPID" 2>/dev/null; RC=$?; collect "$WORK/bgout" "$WORK/bgerr"; }   # 2>: bash's "Killed: 9" job notice
until_calls(){ local i=0; while [ "$i" -lt 150 ] && [ "$(calls "$1")" -lt "$2" ]; do sleep 0.1; i=$((i + 1)); done; }
has_line(){ printf '%s\n' "$OUT" | grep -qxF -- "$1"; }
finding(){ printf '%s\n' "$OUT" | grep -F "$1" | grep '^FINDING|' | head -n 1; }   # <title fragment>
fpf(){ finding "$1" | cut -d'|' -f3; }
locf(){ finding "$1" | cut -d'|' -f4; }
slot(){ sed -n 1p "$1" 2>/dev/null; }

echo "== static =="
check "driver is executable" '[ -x "$DRIVER" ]'
check "driver parses under /bin/bash (3.2 on macOS)" '"$BASH32" -n "$DRIVER"'
check "no bash4-only syntax, no sed -i" '! grep -nE "declare -A|mapfile|readarray|\\\$\\{[A-Za-z_]+(,,|\\^\\^)|\\|&|coproc|sed -i" "$DRIVER" >/dev/null'
check "the key is never a -H argv: Authorization appears only inside the -K <(printf ...) config" \
  '[ "$(grep -c Authorization "$DRIVER")" -ge 1 ] && ! grep -n Authorization "$DRIVER" | grep -v "K <(printf" | grep -qv "^[0-9]*:#"'
check "curl is invoked as 'curl -q' (curl reads -q only first: ~/.curlrc can then not trace the key)" \
  '[ "$(grep -cE "(^|[^A-Za-z_-])curl -" "$DRIVER")" -ge 1 ] && ! grep -E "(^|[^A-Za-z_-])curl -" "$DRIVER" | grep -v "^[[:space:]]*#" | grep -qv "curl -q "'
# The §7 secret-lint shapes (the engine's shared regex file is used too when it exists).
SHAPES="$WORK/shapes"; printf '%s\n' 'gtmcp_[A-Za-z0-9_-]{40,}' '(^|[^A-Za-z0-9_])sk-[A-Za-z0-9_-]{20,}' '(KEY|TOKEN|SECRET|PASSWORD)=[^$]{16,}' > "$SHAPES"
[ -f "$ACF_WHIP/spec-tools/secret-patterns" ] && grep -v '^[[:space:]]*#' "$ACF_WHIP/spec-tools/secret-patterns" | grep -v '^[[:space:]]*$' >> "$SHAPES"
check "shipped gaptrap files hold no key-shaped text (secret-lint shapes)" '! grep -nE -f "$SHAPES" "$DRIVER" "$EXAMPLE" "$GTREADME" >/dev/null'
check "README and example exist" '[ -f "$EXAMPLE" ] && [ -f "$GTREADME" ]'
check "no em dash in the new user-facing docs" '! grep -q "$(printf "\342\200\224")" "$EXAMPLE" "$GTREADME"'
EXV(){ sed -n "s/^$1=//p" "$EXAMPLE" | head -n 1; }
check "example: driver=gaptrap at=plan policy=advisory timeout=300" \
  '[ "$(EXV driver)" = gaptrap ] && [ "$(EXV at)" = plan ] && [ "$(EXV policy)" = advisory ] && [ "$(EXV timeout)" = 300 ]'
check "example: exactly one of driver/review/agent, and every other line is a comment, blank or key=value" \
  '[ "$(grep -cE "^(driver|review|agent)=" "$EXAMPLE")" = 1 ] && ! grep -vE "^[[:space:]]*(#|$)|^[a-z]+=[^[:space:]]+$" "$EXAMPLE" >/dev/null'
check "README covers the three onboarding steps, egress, cost and feature detection" \
  'grep -q "tools add gaptrap" "$GTREADME" && grep -qi "leaves your machine" "$GTREADME" && grep -q "1 billing unit\|1 spec unit\|one spec unit" "$GTREADME" && grep -q "get_spec" "$GTREADME" && grep -q "list_answers" "$GTREADME"'

echo "== capabilities: static VERBS, the probe only checks the key =="
STATE="$WORK/st/caps"; OUTD="$WORK/o/caps"; mkdir -p "$OUTD"
scen caps0 tools-list=tools-list-base
drive capabilities -GAPTRAP_API_KEY
check "no key: exit 0, every verb listed (pull and from included), no request made" \
  '[ "$RC" = 0 ] && has_line "VERBS|review push pull from" && has_line "NEEDS|GAPTRAP_API_KEY" && has_line "EGRESS|app.gaptrap.ai" && [ "$(ncalls)" = 0 ]'
check "no key: COST is printed (so the engine defaults rerun=ask)" 'printf "%s\n" "$OUT" | grep -q "^COST|1 GapTrap spec unit per review of new plan bytes"'
check "COST prose holds no comma (the engine splits capability values on commas)" '! printf "%s\n" "$OUT" | grep "^COST|" | grep -q ","'
COST0=$(printf '%s\n' "$OUT" | grep '^COST|')
drive capabilities
check "base tools/list: the same VERBS (a cached answer must never keep pull dark), one free probe" \
  '[ "$RC" = 0 ] && has_line "VERBS|review push pull from" && [ "$(calls tools-list)" = 1 ] && printf "%s" "$ERR" | grep -q "pull=off answers=off lineage=off idempotency=off"'
scen capsf tools-list=tools-list-full
drive capabilities
check "every feature listed: VERBS and COST are unchanged, stderr reports them on" \
  'has_line "VERBS|review push pull from" && [ "$(printf "%s\n" "$OUT" | grep "^COST|")" = "$COST0" ] && printf "%s" "$ERR" | grep -q "pull=on answers=on lineage=on idempotency=on"'
scen capsa tools-list=tools-list-answers
drive capabilities
check "list_answers alone: stderr says answers=on" 'has_line "VERBS|review push pull from" && printf "%s" "$ERR" | grep -q "pull=off answers=on lineage=off"'
scen caps1 tools-list=tools-list-base
drive capabilities GAPTRAP_MCP_URL=https://gaptrap-alt.example.invalid/mcp
check "EGRESS follows GAPTRAP_MCP_URL" 'has_line "EGRESS|gaptrap-alt.example.invalid"'
scen caps401 tools-list=err-401
drive capabilities
check "401 on the probe: exit 3, reason first, static records still printed" \
  '[ "$RC" = 3 ] && case "$ERR1" in unauthorized:*) true ;; *) false ;; esac && has_line "NEEDS|GAPTRAP_API_KEY" && printf "%s" "$OUT" | grep -q "^HINT|"'
scen caps503 tools-list=err-503
drive capabilities
check "a network blip on the probe is not a capabilities failure: exit 0, static records" \
  '[ "$RC" = 0 ] && has_line "VERBS|review push pull from" && printf "%s" "$ERR" | grep -q "probe did not complete"'

echo "== review: pending -> analyzing -> completed, and the write-2 NO-GO flip =="
STATE="$WORK/st/main"; OUTD="$WORK/o/main"; mkdir -p "$OUTD"
scen flip tools-list=tools-list-base create_spec=create-ok \
  get_analysis_status.1=status-pending-org get_analysis_status.2=status-analyzing-org get_analysis_status=status-completed-org \
  get_analysis_report.1=report-null get_analysis_report.2=report-extracting-go get_analysis_report=report-ready-nogo
drive review
MAIN_OUT=$OUT
check "extracting GO is not trusted: the final verdict is write-2's NO-GO (exit 1)" '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "^SUMMARY|verdict=nogo|3 findings (critical 0, high 2, medium 1, low 0)"'
check "polled status until completed, then the report until contractStatus=ready" '[ "$(calls get_analysis_status)" = 3 ] && [ "$(calls get_analysis_report)" = 3 ]'
check "exactly one create_spec, no initialize" '[ "$(calls create_spec)" = 1 ] && [ "$(calls initialize)" = 0 ]'
check "create_spec sends format=markdown and <cycle id>.<attempt tag>.md as filename, nothing unlisted" \
  'args_of create_spec | jq -e --arg c "$CYCLE_ID" "(keys == [\"filename\",\"format\"]) and .format == \"markdown\" and (.filename | test(\"^\" + \$c + \"\\\\.[0-9a-f]{8}\\\\.md$\"))" >/dev/null'
check "the spec text sent is the frozen file, byte for byte" \
  '[ "$(jq -r ".params.arguments.spec" "$SCEN/log.req.create_spec.1"; printf x)" = "$(cat "$WORK/frozen/plan.md"; echo; printf x)" ]'
check "write-2's synthesized missing-section finding is present with loc -" \
  'finding "Functional Acceptance Criteria is empty" | grep -q "^FINDING|high|[0-9a-f]\{12\}|-|Functional Acceptance Criteria is empty$"'
check "its fp comes from the section-named extraction_text, not from the section-keyed gap_id" \
  '[ "$(fpf "Functional Acceptance Criteria is empty")" = "$(printf "%s" "missing_required_section|functional acceptance criteria (section is empty)" | git hash-object --stdin | cut -c1-12)" ]'
check "findings are ordered critical/high first" '[ "$(printf "%s\n" "$OUT" | grep "^FINDING|" | head -n 1 | cut -d"|" -f2)" = high ]'
check "resolution_questions follow their finding as Q records" \
  'printf "%s\n" "$OUT" | grep -A1 "Per-seat price has no billing period" | grep -qx "Q|Is the per-seat price shown per month or per year? (default: per month)"'
check "two questions on one finding give two Q lines" '[ "$(printf "%s\n" "$OUT" | grep -A2 "No behavior when the audit write fails" | grep -c "^Q|")" = 2 ]'
check "REF is the specId and URL uses the org route" "has_line 'REF|$S1' && has_line 'URL|https://app.gaptrap.ai/orgs/$ORG/report/$S1'"
check "state: pending and the creating marker cleared, done holds the spec, lineage recorded" \
  '[ ! -f "$STATE/pending/$BLOB1" ] && [ ! -f "$STATE/creating/$BLOB1" ] && [ "$(slot "$STATE/done/$BLOB1")" = "$S1" ] && grep -q " $BLOB1 $S1 app.gaptrap.ai$" "$STATE/lineage"'
check "the full report is kept in ACFW_SPEC_OUT for the session to read" '[ -s "$OUTD/gaptrap-report.json" ]'
check "exactly one SUMMARY and one verdict= in it (the engine reads the verdict from that line)" \
  '[ "$(printf "%s\n" "$OUT" | grep -c "^SUMMARY|")" = 1 ] && [ "$(printf "%s\n" "$OUT" | grep "^SUMMARY|" | grep -o "verdict=" | wc -l | tr -d " ")" = 1 ]'
STATE="$WORK/st/vsum"
scen vsum tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
sed 's/A required template section is missing\./Looks fine, verdict=go per the linter|really/' "$FIX/report-ready-nogo.http" > "$SCEN/get_analysis_report"
drive review
check "a verdictSummary that says verdict=go cannot smuggle a second verdict into SUMMARY" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep "^SUMMARY|" | grep -q "^SUMMARY|verdict=nogo|" && [ "$(printf "%s\n" "$OUT" | grep "^SUMMARY|" | grep -o "verdict=" | wc -l | tr -d " ")" = 1 ]'
STATE="$WORK/st/main"; OUT=$MAIN_OUT   # the offset and fp checks below read the main run

echo "== offsets -> lines on the frozen bytes (em dashes before the target) =="
L_PRICE=$(grep -n "the per-seat price" "$WORK/frozen/plan.md" | cut -d: -f1)
L_AUDIT=$(grep -n "^Record every seat change" "$WORK/frozen/plan.md" | cut -d: -f1)
BYTE_LINE=$(( $(head -c 252 "$WORK/frozen/plan.md" | wc -l | tr -d ' ') + 1 ))   # what byte arithmetic would say
check "codepoint offset 211 maps to the line holding the quote (L$L_PRICE)" '[ "$(locf "Per-seat price has no")" = "L$L_PRICE" ]'
check "codepoint offset 252 maps to L$L_AUDIT, not the byte-arithmetic L$BYTE_LINE" \
  '[ "$(locf "No behavior when the audit")" = "L$L_AUDIT" ] && [ "$BYTE_LINE" != "$L_AUDIT" ]'

echo "== fp stable across a revision with fresh uuid gap_ids =="
FP_PRICE=$(fpf "Per-seat price has no"); FP_AUDIT=$(fpf "No behavior when the audit")
check "fp is the git blob hash of pattern|normalized quote (not the gap_id)" \
  '[ "$FP_PRICE" = "$(printf "%s" "undefined_behavior|the per-seat price" | git hash-object --stdin | cut -c1-12)" ]'
scen rerun tools-list=tools-list-base create_spec=create-ok-2 get_analysis_status=status-completed-org get_analysis_report=report-rerun-go
drive review ACFW_SPEC_FILE="$WORK/frozen/plan2.md" ACFW_SPEC_BLOB="$BLOB2"
check "the revision reviews GO (exit 0) with a new spec" '[ "$RC" = 0 ] && has_line "REF|$S2" && [ "$(calls create_spec)" = 1 ]'
check "same gap, new uuid, moved offset, changed case and a line wrap: same fp" '[ "$(fpf "Per-seat price has no")" = "$FP_PRICE" ]'
check "same gap, new uuid, different title: same fp (the quote decides)" '[ "$(fpf "Audit failure behavior is undefined")" = "$FP_AUDIT" ]'
check "same quote under a different pattern: a different fp" '[ -n "$(fpf "Price wording differs")" ] && [ "$(fpf "Price wording differs")" != "$FP_PRICE" ]'
check "camelCase gap keys are read (offset, quote, questions)" \
  '[ "$(locf "Price wording differs")" = L13 ] && printf "%s\n" "$OUT" | grep -qx "Q|Which wording is canonical? (default: per seat)"'
check "the wrapped quote lands on its first line (L13)" '[ "$(locf "Per-seat price has no")" = L13 ]'
check "base tools/list: no parentSpecId or idempotencyKey even with lineage on file" \
  '! args_of create_spec | grep -q "parentSpecId\|idempotencyKey"'

echo "== deadline while contract extraction runs, and write-2 that never lands =="
STATE="$WORK/st/dl1"; seed pending "$S1"
scen dl1 get_analysis_status=status-completed-org get_analysis_report=report-extracting-go
drive review ACFW_SPEC_DEADLINE=$(( $(date +%s) + 4 )) GAPTRAP_POLL_INTERVAL=1
check "a still-extracting GO at the deadline is an error, never GO" \
  '[ "$RC" = 2 ] && case "$ERR1" in timeout:*"not final"*) true ;; *) false ;; esac && ! printf "%s" "$OUT" | grep -q "verdict=go"'
check "the spec is kept in pending/ for a free resume" '[ "$(slot "$STATE/pending/$BLOB1")" = "$S1" ] && [ "$(calls create_spec)" = 0 ]'
STATE="$WORK/st/dl2"; seed pending "$S1"
scen dl2 get_analysis_status=status-completed-org get_analysis_report=report-extracting-nogo
drive review ACFW_SPEC_DEADLINE=$(( $(date +%s) + 4 )) GAPTRAP_POLL_INTERVAL=1
check "a still-extracting NO-GO is reported (write-2 only adds NO-GO), marked partial" \
  '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "^SUMMARY|verdict=nogo|.*contract extraction still running" && [ -f "$STATE/pending/$BLOB1" ]'
STATE="$WORK/st/xstuck"; seed pending "$S1" 7200
scen xstuck get_analysis_status=status-completed-org get_analysis_report=report-extracting-go
drive review
check "extracting 2 h after create: write-1's GO is accepted as GapTrap's timeout path would (exit 0), no new unit" \
  '[ "$RC" = 0 ] && printf "%s\n" "$OUT" | grep -q "^SUMMARY|verdict=go|.*contract extraction never finished" && [ "$(ncalls)" = 2 ] && [ "$(calls create_spec)" = 0 ]'
check "the accepted result is done/, carrying the creation time forward" \
  '[ "$(slot "$STATE/done/$BLOB1")" = "$S1" ] && [ ! -f "$STATE/pending/$BLOB1" ] && [ "$(sed -n "s/^at=//p" "$STATE/done/$BLOB1")" -le $(( $(date +%s) - 7000 )) ]'
scen xstuck2 get_analysis_status=status-completed-org get_analysis_report=report-extracting-go
drive review ACFW_SPEC_DEADLINE=$(( $(date +%s) + 4 )) GAPTRAP_POLL_INTERVAL=1
check "a re-read of that done/ spec is immediate too, not a loop to the deadline" '[ "$RC" = 0 ] && [ "$(calls get_analysis_report)" = 1 ]'
STATE="$WORK/st/xstuck3"; seed pending "$S1" 7200
scen xstuck3 get_analysis_status=status-completed-org get_analysis_report=report-extracting-nogo
drive review
check "an unfinished NO-GO is accepted the same way (exit 1)" '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "^SUMMARY|verdict=nogo|.*never finished"'

echo "== HTTP 401/403 versus HTTP 200 + isError =="
STATE="$WORK/st/err"; OUTD="$WORK/o/err"; mkdir -p "$OUTD"
scen e401 tools-list=err-401
drive review
check "HTTP 401: exit 3, reason names the key, nothing created" \
  '[ "$RC" = 3 ] && case "$ERR1" in unauthorized:*GAPTRAP_API_KEY*) true ;; *) false ;; esac && [ "$(calls create_spec)" = 0 ] && [ ! -f "$STATE/pending/$BLOB1" ]'
scen e403 tools-list=err-403
drive review
check "HTTP 403 plan_required: exit 3 naming the plan" '[ "$RC" = 3 ] && case "$ERR1" in plan_required:*solo*) true ;; *) false ;; esac'
scen quota tools-list=tools-list-base create_spec=quota
drive review
check "200 + isError quota_exceeded: exit 3, reason first, a HINT, no pending slot" \
  '[ "$RC" = 3 ] && case "$ERR1" in quota_exceeded:*) true ;; *) false ;; esac && printf "%s" "$OUT" | grep -q "^HINT|" && [ "$(calls create_spec)" = 1 ] && [ ! -f "$STATE/pending/$BLOB1" ]'
check "GapTrap's coded refusal means no spec exists: the creating marker is dropped" '[ ! -f "$STATE/creating/$BLOB1" ]'
scen big tools-list=tools-list-base create_spec=too-large
drive review
check "200 + isError spec_too_large: exit 3" '[ "$RC" = 3 ] && case "$ERR1" in spec_too_large:*) true ;; *) false ;; esac'
head -c 1100000 /dev/zero | tr '\0' 'a' > "$WORK/huge.md"
scen huge tools-list=tools-list-base create_spec=create-ok
drive review ACFW_SPEC_FILE="$WORK/huge.md" ACFW_SPEC_BLOB=hugeblob
check "a plan over 1 MiB is refused locally, before any request" '[ "$RC" = 3 ] && case "$ERR1" in spec_too_large:*) true ;; *) false ;; esac && [ "$(ncalls)" = 0 ]'
scen e404 tools-list=err-401
printf '404\n<html>Not Found</html>\n' > "$SCEN/tools-list"
drive review
check "HTTP 404: exit 3, check GAPTRAP_MCP_URL" '[ "$RC" = 3 ] && printf "%s" "$ERR1" | grep -q "check GAPTRAP_MCP_URL"'
STATE="$WORK/st/transient"
scen e503 tools-list=tools-list-base create_spec=create-ok get_analysis_status.1=err-503 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "a transient 503 while polling (a free call) is retried, not fatal" '[ "$RC" = 1 ] && [ "$(calls get_analysis_status)" = 2 ]'
STATE="$WORK/st/sse"
scen sse tools-list=tools-list-base create_spec=sse-create-ok get_analysis_status=status-completed-org get_analysis_report=sse-report-ready-nogo
drive review
check "an SSE-framed reply (event: message / data:) is read like JSON" '[ "$RC" = 1 ] && has_line "REF|$S1" && [ "$(printf "%s\n" "$OUT" | grep -c "^FINDING|")" = 3 ]'

echo "== create_spec is never resent blind: a lost reply is found again for free =="
STATE="$WORK/st/amb"
scen amb1 tools-list=tools-list-base create_spec.1=err-000 create_spec=create-ok
drive review
check "HTTP 000 on create_spec: exactly 1 create_spec, exit 2 'outcome unknown' first" \
  '[ "$RC" = 2 ] && [ "$(calls create_spec)" = 1 ] && case "$ERR1" in "create_spec outcome unknown"*) true ;; *) false ;; esac && printf "%s" "$OUT" | grep -q "^HINT|"'
check "the creating marker holds the attempt tag, and no pending slot was invented" \
  '[ -f "$STATE/creating/$BLOB1" ] && [ ! -f "$STATE/pending/$BLOB1" ] && [ "$CYCLE_ID.$(slot "$STATE/creating/$BLOB1").md" = "$(req_arg "$SCEN" create_spec.1 filename)" ]'
FN=$(req_arg "$SCEN" create_spec.1 filename); NOWS=$(date +%s)
scen amb2 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
mk_list "$SCEN/list_specs" "$(spec_row "$AD" "$FN" "$(iso "$NOWS")")" "$(spec_row "$S2" "other.md" "$(iso "$NOWS")")" \
  "$(spec_row "$S1" "$FN" "$(iso $((NOWS - 3600)))")"
drive review
check "the next review adopts the spec via list_specs with ZERO create_spec and no tools/list" \
  '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 0 ] && [ "$(calls list_specs)" = 1 ] && [ "$(calls tools-list)" = 0 ] && has_line "REF|$AD"'
check "it matched filename and time, not the older same-name spec or the newer other one; the marker is gone" \
  '[ "$(slot "$STATE/done/$BLOB1")" = "$AD" ] && [ ! -f "$STATE/creating/$BLOB1" ] && printf "%s" "$ERR" | grep -q "interrupted create_spec (0 units)"'
STATE="$WORK/st/amb502"
scen amb3 tools-list=tools-list-base create_spec.1=err-502 create_spec=create-ok
drive review
check "HTTP 502 on create_spec: 1 call, outcome unknown, marker kept" \
  '[ "$RC" = 2 ] && [ "$(calls create_spec)" = 1 ] && [ -f "$STATE/creating/$BLOB1" ] && case "$ERR1" in "create_spec outcome unknown"*) true ;; *) false ;; esac'
FN=$(req_arg "$SCEN" create_spec.1 filename)
scen amb4 tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
mk_list "$SCEN/list_specs" "$(spec_row "$S2" "other.md" "$(iso "$(date +%s)")")"
drive review
check "not listed yet and under 90 s old: exit 2 asking to rerun, still no second create_spec" \
  '[ "$RC" = 2 ] && [ "$(calls create_spec)" = 0 ] && [ -f "$STATE/creating/$BLOB1" ] && printf "%s" "$ERR1" | grep -q "has not shown up in GapTrap yet"'
sed "s/^at=.*/at=$(( $(date +%s) - 300 ))/" "$STATE/creating/$BLOB1" > "$WORK/m" && cat "$WORK/m" > "$STATE/creating/$BLOB1"
scen amb5 tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
mk_list "$SCEN/list_specs" "$(spec_row "$S2" "other.md" "$(iso "$(date +%s)")")" "$(spec_row "$CH" "$FN" "$(iso $(( $(date +%s) - 3600 )))")"
drive review
check "still absent 5 minutes later: GapTrap made nothing, so ONE create_spec with the same attempt tag" \
  '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 1 ] && [ "$(req_arg "$SCEN" create_spec.1 filename)" = "$FN" ] && [ "$(slot "$STATE/done/$BLOB1")" = "$S1" ] && [ ! -f "$STATE/creating/$BLOB1" ]'
STATE="$WORK/st/unsent"
scen unsent tools-list=tools-list-base create_spec.1=conn-refused create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "connection refused (never sent) is the one blind resend: 2 attempts, exit 1, no marker left" \
  '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 2 ] && [ "$(slot "$STATE/done/$BLOB1")" = "$S1" ] && [ ! -f "$STATE/creating/$BLOB1" ]'
STATE="$WORK/st/throw"
scen throw tools-list=tools-list-base create_spec=create-throw
drive review
check "plain-text isError from create_spec (a throw after the write): outcome unknown, marker kept" \
  '[ "$RC" = 2 ] && [ "$(calls create_spec)" = 1 ] && [ -f "$STATE/creating/$BLOB1" ] && printf "%s" "$ERR1" | grep -q "outcome unknown (Deadline exceeded"'
STATE="$WORK/st/idem"
scen idem tools-list=tools-list-full create_spec.1=err-502 create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "with idempotencyKey listed, a 502 is resent with the SAME key and filename, and the review completes" \
  '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 2 ] && [ -n "$(req_arg "$SCEN" create_spec.1 idempotencyKey)" ] && [ "$(req_arg "$SCEN" create_spec.1 idempotencyKey)" = "$(req_arg "$SCEN" create_spec.2 idempotencyKey)" ] && [ "$(req_arg "$SCEN" create_spec.1 filename)" = "$(req_arg "$SCEN" create_spec.2 filename)" ]'
check "the filename tag is the idempotencyKey's attempt id" \
  '[ "$(req_arg "$SCEN" create_spec.1 filename)" = "$CYCLE_ID.$(req_arg "$SCEN" create_spec.1 idempotencyKey | cut -c6-13).md" ]'
STATE="$WORK/st/budget"
scen budget tools-list=tools-list-base create_spec=create-ok
drive review ACFW_SPEC_DEADLINE=$(( $(date +%s) + 12 ))
check "under 20 s left: no create_spec is started (exit 2), and no marker is written" \
  '[ "$RC" = 2 ] && [ "$(calls create_spec)" = 0 ] && [ ! -f "$STATE/creating/$BLOB1" ] && printf "%s" "$ERR1" | grep -q "not enough time"'

echo "== signals: TERM after the reply, SIGKILL mid-request, SIGKILL mid-poll =="
REALJQ=$(command -v jq)
mkdir -p "$WORK/jqbin"
{ printf '#!/bin/bash\n'
  printf 'case "$*" in *create-reply*) if [ -n "${GT_JQ_HOLD:-}" ]; then : > "$GT_JQ_HOLD"; sleep 5; fi ;; esac\n'
  printf 'exec "%s" "$@"\n' "$REALJQ"; } > "$WORK/jqbin/jq"; chmod +x "$WORK/jqbin/jq"
STATE="$WORK/st/term"
scen term tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
rm -f "$WORK/hold"
drive_bg review PATH="$WORK/jqbin:$PATH" GT_JQ_HOLD="$WORK/hold"
i=0; while [ "$i" -lt 150 ] && [ ! -f "$WORK/hold" ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM -- "-$BGPID" 2>/dev/null; bg_wait
check "a TERM that lands after the create_spec reply arrived: exit 143" '[ -f "$WORK/hold" ] && [ "$RC" = 143 ]'
check "the handler parked the specId it already held (pending/, no marker), after exactly 1 create_spec" \
  '[ "$(slot "$STATE/pending/$BLOB1")" = "$S1" ] && [ ! -f "$STATE/creating/$BLOB1" ] && [ "$(calls create_spec)" = 1 ]'
scen term2 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "the next review resumes it: ZERO create_spec" '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 0 ] && has_line "REF|$S1"'

STATE="$WORK/st/kcreate"
scen kc1 tools-list=tools-list-base create_spec=create-ok
drive_bg review GT_DELAY=5 GT_DELAY_ON=create_spec TMPDIR="$WORK/tmpk"
until_calls create_spec 1
kill -KILL -- "-$BGPID" 2>/dev/null; bg_wait
check "SIGKILL while create_spec is in flight: killed, the marker was on disk before the request" \
  '[ "$RC" = 137 ] && [ "$(calls create_spec)" = 1 ] && [ -f "$STATE/creating/$BLOB1" ] && [ ! -f "$STATE/pending/$BLOB1" ]'
FN=$(req_arg "$SCEN" create_spec.1 filename)
scen kc2 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
mk_list "$SCEN/list_specs" "$(spec_row "$AD" "$FN" "$(iso "$(date +%s)")")"
drive review
check "the next review finds the killed request's spec: ZERO create_spec" '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 0 ] && has_line "REF|$AD"'

STATE="$WORK/st/kill"; OUTD="$WORK/o/kill"; mkdir -p "$OUTD"
scen kill1 tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-pending-org
drive_bg review ACFW_SPEC_DEADLINE=$(( $(date +%s) + 120 )) GAPTRAP_POLL_INTERVAL=1
until_calls get_analysis_status 2
kill -TERM -- "-$BGPID" 2>/dev/null; bg_wait
check "the watchdog's group TERM ends a poll promptly (exit 143)" '[ "$RC" = 143 ]'
check "the specId was on disk before polling began" '[ "$(slot "$STATE/pending/$BLOB1")" = "$S1" ] && [ "$(calls create_spec)" = 1 ]'
scen kill1b get_analysis_status=status-pending-org
drive_bg review ACFW_SPEC_DEADLINE=$(( $(date +%s) + 120 )) GAPTRAP_POLL_INTERVAL=1 TMPDIR="$WORK/tmpk"
until_calls get_analysis_status 2
kill -KILL -- "-$BGPID" 2>/dev/null; bg_wait
check "SIGKILL mid-poll: killed with no chance to clean up, after ZERO create_spec" '[ "$RC" = 137 ] && [ "$(calls create_spec)" = 0 ]'
scen kill2 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo   # no create_spec fixture at all
drive review
check "re-run on the same bytes resumes the spec: ZERO create_spec, zero tools/list" \
  '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 0 ] && [ "$(calls tools-list)" = 0 ] && has_line "REF|$S1" && printf "%s" "$ERR" | grep -q "resuming GapTrap spec $S1"'
scen kill3 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "a finished result is re-read for free on an engine cache miss" '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 0 ] && [ "$(slot "$STATE/done/$BLOB1")" = "$S1" ]'
check "no TERM-ended run left a temp directory behind" '[ -z "$(ls -A "$WORK/tmp")" ]'

echo "== a resumed spec that vanished =="
STATE="$WORK/st/gone"; seed pending "$S1"
scen gone tools-list=tools-list-base get_analysis_status.1=not-found create_spec=create-ok-2 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "status NOT_FOUND on the pending spec: the slot is dropped and exactly 1 create_spec replaces it" \
  '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 1 ] && has_line "REF|$S2" && [ "$(slot "$STATE/done/$BLOB1")" = "$S2" ] && [ ! -f "$STATE/pending/$BLOB1" ]'
check "the replacement is a new attempt: generation 1" '[ "$(slot "$STATE/gen/$BLOB1")" = 1 ]'

echo "== failed is memoized; --fresh and push are the paid ways past it =="
STATE="$WORK/st/failed"
scen fail1 tools-list=tools-list-full create_spec=create-ok get_analysis_status=status-failed-org
drive review
check "status failed: exit 2 with the reason first" '[ "$RC" = 2 ] && case "$ERR1" in failed:*) true ;; *) false ;; esac'
check "failed/<blob> holds the spec, pending/ is cleared" '[ "$(slot "$STATE/failed/$BLOB1")" = "$S1" ] && [ ! -f "$STATE/pending/$BLOB1" ]'
IDEM1=$(req_arg "$SCEN" create_spec.1 idempotencyKey); FN1=$(req_arg "$SCEN" create_spec.1 filename)
scen fail2 tools-list=tools-list-full create_spec=create-ok-2 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "the next card makes no request at all and says it is memoized" '[ "$RC" = 2 ] && [ "$(ncalls)" = 0 ] && printf "%s" "$ERR" | grep -q memoized'
drive review ACFW_SPEC_FRESH=1
check "ACFW_SPEC_FRESH=1 resubmits once and clears the memo" '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 1 ] && [ ! -f "$STATE/failed/$BLOB1" ]'
check "the fresh attempt gets a new idempotencyKey and filename tag (GapTrap must not hand back the failed spec)" \
  '[ -n "$IDEM1" ] && [ "$(req_arg "$SCEN" create_spec.1 idempotencyKey)" != "$IDEM1" ] && [ "$(req_arg "$SCEN" create_spec.1 filename)" != "$FN1" ] && [ "$(slot "$STATE/gen/$BLOB1")" = 1 ]'
STATE="$WORK/st/pushfail"; seed failed "$S2"
scen pf1 tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org
drive push
check "push over a failed memo pays for a new attempt (1 unit) and ends the memo" \
  '[ "$RC" = 0 ] && [ "$(calls create_spec)" = 1 ] && [ ! -f "$STATE/failed/$BLOB1" ] && [ "$(slot "$STATE/pending/$BLOB1")" = "$S1" ]'
scen pf2 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "the next review reads that paid spec instead of refusing on the old failure: ZERO create_spec" \
  '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 0 ] && has_line "REF|$S1"'
STATE="$WORK/st/freshold"; seed pending "$S2" 7200
scen fo tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review ACFW_SPEC_FRESH=1
check "--fresh drops a pending spec past the stuck age and resubmits (1 unit)" \
  '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 1 ] && has_line "REF|$S1" && ! grep -q "$S2" "$SCEN/log"'
STATE="$WORK/st/freshyoung"; seed pending "$S2" 60
scen fy tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review ACFW_SPEC_FRESH=1
check "--fresh keeps a young pending spec (still worth its unit): ZERO create_spec" '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 0 ] && has_line "REF|$S2"'

echo "== the real transport: key never in argv, never in output =="
ln -sf "$FIX/fake-curl" "$WORK/bin/curl"
STATE="$WORK/st/curl"; OUTD="$WORK/o/curl"; mkdir -p "$OUTD"
scen curl1 tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
export GT_FIX="$FIX" GT_CURL_LOG="$WORK/curl.log"; : > "$GT_CURL_LOG"
( cd "$REPO" && drive_env review -ACFW_GAPTRAP_TRANSPORT PATH="$WORK/bin:$PATH" GAPTRAP_MCP_URL=https://gaptrap.test.invalid/mcp \
    GT_EXPECT_KEY="$KEY" GT_CURL_DELAY=2 GT_CURL_DELAY_ON=create_spec && exec "$BASH32" "$DRIVER" review ) > "$WORK/cout" 2> "$WORK/cerr" &
CPID=$!
SEEN=0; i=0
while [ "$i" -lt 100 ]; do
  ps -A -o args= > "$WORK/ps.txt" 2>/dev/null
  if grep -q "bin/curl -q" "$WORK/ps.txt"; then SEEN=1; break; fi
  sleep 0.05; i=$((i + 1))
done
cp "$WORK/ps.txt" "$WORK/ps-during.txt"
wait "$CPID"; CRC=$?
cat "$WORK/cout" "$WORK/cerr" >> "$WORK/all-output"
check "ps caught the curl process mid-request" '[ "$SEEN" = 1 ]'
check "the key is in no process argv while curl runs" '! leaks "$WORK/ps-during.txt"'
check "curl got its header config from a pipe (-K /dev/fd/N), not a file or -H" 'grep "bin/curl" "$WORK/ps-during.txt" | grep -q -- "-K /dev/fd/"'
check "curl ran with -q as its first argument (no ~/.curlrc)" 'grep "bin/curl" "$WORK/ps-during.txt" | grep -q "bin/curl -q -sS"'
check "the real path completed the review (exit 1, NO-GO)" '[ "$CRC" = 1 ] && grep -qx "REF|$S1" "$WORK/cout"'
check "every request carried the Bearer header" '[ "$(grep -c "^call .*auth=ok" "$GT_CURL_LOG")" -ge 4 ] && ! grep -q "auth=missing" "$GT_CURL_LOG"'
check "POST with Content-Type application/json and Accept json + event-stream" \
  'grep -q "method=POST" "$GT_CURL_LOG" && grep -qx "hdr=Content-Type: application/json" "$GT_CURL_LOG" && grep -qx "hdr=Accept: application/json, text/event-stream" "$GT_CURL_LOG" && grep -q "url=https://gaptrap.test.invalid/mcp " "$GT_CURL_LOG"'
check "the key is in no output, state file or request body" '! leaks "$WORK/cout" "$WORK/cerr" "$STATE" "$OUTD" "$WORK/scen"'

echo "== .env: read only when gitignored and untracked, never exported =="
STATE="$WORK/st/dotenv"
printf '# local secrets\nexport GAPTRAP_API_KEY="%s"\nGAPTRAP_MCP_URL=https://from-dotenv.test.invalid/mcp\n' "$KEY" > "$REPO/.env"
scen dot1 tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
: > "$GT_CURL_LOG"
drive review -ACFW_GAPTRAP_TRANSPORT -GAPTRAP_API_KEY PATH="$WORK/bin:$PATH" GT_EXPECT_KEY="$KEY"
check "a gitignored .env supplies the key and the endpoint" '[ "$RC" = 1 ] && ! grep -q "auth=missing" "$GT_CURL_LOG" && grep -q "url=https://from-dotenv.test.invalid/mcp " "$GT_CURL_LOG"'
check "a key read from .env is not exported to curl" 'grep -q "env_key=absent" "$GT_CURL_LOG" && ! grep -q "env_key=present" "$GT_CURL_LOG"'
( cd "$REPO" && git add -f .env && git commit -qm "track env" )
STATE="$WORK/st/dotenv2"
drive review -ACFW_GAPTRAP_TRANSPORT -GAPTRAP_API_KEY PATH="$WORK/bin:$PATH"
check "a TRACKED .env is never read: exit 3 naming .env" '[ "$RC" = 3 ] && printf "%s" "$ERR1" | grep -q "\.env" && printf "%s" "$OUT" | grep -q "^HINT|.*ROTATE"'
( cd "$REPO" && git rm -q --cached .env && git commit -qm "untrack env" ); rm -f "$REPO/.env"

echo "== pull and from: listed always, performed only when GapTrap lists the tool =="
STATE="$WORK/st/pull"; OUTD="$WORK/o/pull1"; mkdir -p "$OUTD"
scen pull0 tools-list=tools-list-base get_analysis_status=status-completed-org
drive pull ACFW_SPEC_REF="$S1"
check "base tools: pull exits 3 'not offered yet' with a HINT and calls nothing beyond tools/list" \
  '[ "$RC" = 3 ] && printf "%s" "$ERR1" | grep -q "not offered yet" && printf "%s" "$OUT" | grep -q "^HINT|" && [ "$(ncalls)" = 1 ] && [ ! -f "$OUTD/remote.md" ]'
scen pull1 tools-list=tools-list-getspec get_analysis_status=status-completed-org list_specs=list-specs get_spec=get-spec
drive pull ACFW_SPEC_REF="$S1"
check "get_spec listed: pull follows the lineage past drafts to the newest child" '[ "$RC" = 0 ] && has_line "REF|$CH" && has_line "URL|https://app.gaptrap.ai/orgs/$ORG/report/$CH"'
check "remote.md is the child's content, byte for byte, sha256 verified" 'cmp -s "$OUTD/remote.md" "$FIX/plan2.md"'
check "get_spec alone never calls list_answers" '[ "$(calls list_answers)" = 0 ]'
OUTD="$WORK/o/pull1u"; mkdir -p "$OUTD"
scen pull1u tools-list=tools-list-getspec get_analysis_status=status-completed-org list_specs=list-specs get_spec=get-spec
drive pull ACFW_SPEC_REF="https://app.gaptrap.ai/orgs/$ORG/report/$S1?view=spec"
check "a report URL works as the pull ref" \
  '[ "$RC" = 0 ] && has_line "REF|$CH" && cmp -s "$OUTD/remote.md" "$FIX/plan2.md" && grep -q "\"specId\":\"$S1\"" "$SCEN/log"'
OUTD="$WORK/o/pullnc"; mkdir -p "$OUTD"
scen pullnc tools-list=tools-list-getspec get_analysis_status=status-completed-org list_specs=list-specs-norchild get_spec=get-spec
drive pull ACFW_SPEC_REF="$S1"
check "no child in the lineage: pull fetches the ref itself and returns REF of the ref" \
  '[ "$RC" = 0 ] && has_line "REF|$S1" && [ "$(args_of get_spec | jq -r .specId)" = "$S1" ] && [ -f "$OUTD/remote.md" ]'
OUTD="$WORK/o/pull2"; mkdir -p "$OUTD"
scen pull2 tools-list=tools-list-getspec get_analysis_status=status-completed-org list_specs=list-specs get_spec=get-spec-badsha
drive pull ACFW_SPEC_REF="$S1"
check "a contentSha256 mismatch writes nothing" '[ "$RC" = 2 ] && [ ! -f "$OUTD/remote.md" ]'
OUTD="$WORK/o/pullut"; mkdir -p "$OUTD"
scen pullut tools-list=tools-list-getspec get_analysis_status=status-completed-org list_specs=list-specs get_spec=unknown-tool
drive pull ACFW_SPEC_REF="$S1"
check "an unknown-tool isError (plain SDK text) is exit 2 with that text on the first stderr line" \
  '[ "$RC" = 2 ] && [ "$ERR1" = "get_spec: tool_error: MCP error -32602: Tool get_spec not found" ] && [ ! -f "$OUTD/remote.md" ]'
OUTD="$WORK/o/pull3"; mkdir -p "$OUTD"
scen pull3 tools-list=tools-list-answers get_analysis_status=status-completed-org list_answers=list-answers get_analysis_report=report-ready-nogo
drive pull ACFW_SPEC_REF="$S1"
check "list_answers listed: decisions come back as ANSWER records keyed by the review's fp" \
  '[ "$RC" = 0 ] && has_line "ANSWER|$FP_PRICE|Per month. Billed on the first of the month. (question: Is the per-seat price shown per month or per year? (default: per month))"'
check "an answer whose gap is unknown keeps fp -" 'has_line "ANSWER|-|Keep as is. (question: Unmapped question)"'
check "answers alone write no remote.md and walk no lineage" '[ ! -f "$OUTD/remote.md" ] && [ "$(calls list_specs)" = 0 ] && [ "$(calls get_spec)" = 0 ]'
OUTD="$WORK/o/from0"; mkdir -p "$OUTD"
scen from0 tools-list=tools-list-answers get_analysis_status=status-completed-org
drive from ACFW_SPEC_REF="$S1" ACFW_SPEC_KEY= -ACFW_SPEC_FILE -ACFW_SPEC_BLOB
check "from without get_spec (answers are no text): exit 3 'not offered yet' with a HINT, nothing written" \
  '[ "$RC" = 3 ] && printf "%s" "$ERR1" | grep -q "^from is not offered yet" && printf "%s" "$OUT" | grep -q "^HINT|" && [ "$(ncalls)" = 1 ] && [ ! -f "$OUTD/remote.md" ]'
OUTD="$WORK/o/from1"; mkdir -p "$OUTD"
scen from1 tools-list=tools-list-getspec get_analysis_status=status-completed-org get_spec=get-spec
drive from ACFW_SPEC_REF="https://app.gaptrap.ai/orgs/$ORG/report/$S1#gaps" ACFW_SPEC_KEY= -ACFW_SPEC_FILE -ACFW_SPEC_BLOB
check "from with get_spec: the named spec (from its report URL) lands in remote.md, sha256 verified, REF printed" \
  '[ "$RC" = 0 ] && has_line "REF|$S1" && cmp -s "$OUTD/remote.md" "$FIX/plan2.md" && [ "$(args_of get_spec | jq -r .specId)" = "$S1" ]'
check "from fetches exactly what was named: no lineage walk, no plan file needed" '[ "$(calls list_specs)" = 0 ] && [ "$(calls create_spec)" = 0 ]'
OUTD="$WORK/o/from2"; mkdir -p "$OUTD"
scen from2 tools-list=tools-list-getspec get_analysis_status=not-found
drive from ACFW_SPEC_REF="$S1" ACFW_SPEC_KEY= -ACFW_SPEC_FILE -ACFW_SPEC_BLOB
check "from on a spec this key cannot see: exit 3, nothing written" '[ "$RC" = 3 ] && printf "%s" "$ERR1" | grep -q "not visible to this key" && [ ! -f "$OUTD/remote.md" ]'

echo "== lineage and idempotency only when create_spec lists them =="
STATE="$WORK/st/lineage"; mkdir -p "$STATE"; cp "$WORK/st/main/lineage" "$STATE/lineage"
scen lin tools-list=tools-list-full create_spec=create-ok-2 get_analysis_status=status-completed-org get_analysis_report=report-rerun-go
drive review ACFW_SPEC_FILE="$WORK/frozen/plan2.md" ACFW_SPEC_BLOB="$BLOB2"
check "parentSpecId is the last reviewed spec for this plan key" '[ "$(args_of create_spec | jq -r .parentSpecId)" = "$S1" ]'
check "idempotencyKey is derived from key, blob, endpoint and generation" 'args_of create_spec | jq -r .idempotencyKey | grep -qE "^acfw-[0-9a-f]{40}$"'

echo "== push: SAME_REF reuse at 0 units, scope note =="
STATE="$WORK/st/push"; OUTD="$WORK/o/push"; mkdir -p "$OUTD"
scen push1 tools-list=tools-list-base get_analysis_status=status-completed-personal
drive push ACFW_SPEC_SAME_REF="$S2"
check "SAME_REF: no create_spec, REF is the reviewed spec" '[ "$RC" = 0 ] && [ "$(calls create_spec)" = 0 ] && has_line "REF|$S2"'
check "a personal key gets the personal route and the teammate note" \
  "has_line 'URL|https://app.gaptrap.ai/report/$S2' && printf '%s' \"\$OUT\" | grep -q '^HINT|personal key: only you can open this report'"
check "the push HINT is honest that GapTrap cannot send edits back yet" 'printf "%s" "$OUT" | grep -q "^HINT|GapTrap cannot send edits back yet"'
scen push2 tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org
drive push
check "no reviewed spec: push creates one (1 unit) and parks it in pending/" \
  '[ "$RC" = 0 ] && [ "$(calls create_spec)" = 1 ] && [ "$(slot "$STATE/pending/$BLOB1")" = "$S1" ] && printf "%s" "$ERR" | grep -q "1 unit"'
check "an org key gets the org route and no personal note" "has_line 'URL|https://app.gaptrap.ai/orgs/$ORG/report/$S1' && ! printf '%s' \"\$OUT\" | grep -q 'personal key'"
scen push3 tools-list=tools-list-base get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "a review after the push resumes that spec: zero create_spec" '[ "$RC" = 1 ] && [ "$(calls create_spec)" = 0 ]'
drive push
check "a second push of the same bytes reuses the spec (0 units)" '[ "$RC" = 0 ] && [ "$(calls create_spec)" = 0 ] && has_line "REF|$S1"'
STATE="$WORK/st/pushgone"; seed done "$S2"
scen pg tools-list=tools-list-base get_analysis_status.1=not-found create_spec=create-ok get_analysis_status=status-completed-org
drive push
check "push over a spec GapTrap deleted: the dead slot goes, 1 create_spec as a new attempt" \
  '[ "$RC" = 0 ] && [ "$(calls create_spec)" = 1 ] && has_line "REF|$S1" && [ ! -f "$STATE/done/$BLOB1" ] && [ "$(slot "$STATE/gen/$BLOB1")" = 1 ]'
STATE="$WORK/st/pushamb"
scen pa1 tools-list=tools-list-base create_spec=err-000
drive push
check "push shares the never-resend rule: 000 on create_spec leaves the marker, 1 call" '[ "$RC" = 2 ] && [ "$(calls create_spec)" = 1 ] && [ -f "$STATE/creating/$BLOB1" ]'
FN=$(req_arg "$SCEN" create_spec.1 filename)
scen pa2 tools-list=tools-list-base get_analysis_status=status-completed-org
mk_list "$SCEN/list_specs" "$(spec_row "$AD" "$FN" "$(iso "$(date +%s)")")"
drive push
check "the next push adopts the spec from list_specs: REF of it, ZERO create_spec" '[ "$RC" = 0 ] && [ "$(calls create_spec)" = 0 ] && has_line "REF|$AD"'

echo "== GAPTRAP_TEMPLATE_ID, GAPTRAP_APP_URL, and slot isolation =="
STATE="$WORK/st/tpl"
scen tpl tools-list=tools-list-base create_spec=create-ok get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review GAPTRAP_TEMPLATE_ID=tpl_acf_plan GAPTRAP_APP_URL=https://gaptrap.example.org/
check "templateId is sent when GAPTRAP_TEMPLATE_ID is set" '[ "$(args_of create_spec | jq -r .templateId)" = tpl_acf_plan ]'
check "report links use GAPTRAP_APP_URL" "has_line 'URL|https://gaptrap.example.org/orgs/$ORG/report/$S1'"
TPLFN=$(args_of create_spec | jq -r .filename)
scen tpl2 tools-list=tools-list-base create_spec=create-ok-2 get_analysis_status=status-completed-org get_analysis_report=report-ready-nogo
drive review
check "a result made under another template is not reused for the default template" '[ "$(calls create_spec)" = 1 ]'
check "and its attempt tag differs, so neither could adopt the other's spec" '[ "$(args_of create_spec | jq -r .filename)" != "$TPLFN" ]'

echo "== usage and safety refusals =="
STATE="$WORK/st/misc"
scen misc tools-list=tools-list-base create_spec=create-ok
drive review -GAPTRAP_API_KEY
check "no key: exit 3 naming GAPTRAP_API_KEY, a HINT, and no request" \
  '[ "$RC" = 3 ] && case "$ERR1" in *GAPTRAP_API_KEY*) true ;; *) false ;; esac && printf "%s" "$OUT" | grep -q "^HINT|" && [ "$(ncalls)" = 0 ]'
drive review GAPTRAP_MCP_URL=http://app.gaptrap.ai/mcp
check "a plaintext http endpoint is refused before the key can travel" '[ "$RC" = 3 ] && [ "$(ncalls)" = 0 ]'
drive review GAPTRAP_MODE=turbo
check "an unknown GAPTRAP_MODE is refused" '[ "$RC" = 3 ] && [ "$(ncalls)" = 0 ]'
drive frobnicate
check "an unknown verb exits 3 (verb not offered)" '[ "$RC" = 3 ]'
check "no run that exited on its own left a temp directory behind" '[ -z "$(ls -A "$WORK/tmp")" ]'
check "the key appeared in none of the $RUNS runs' stdout or stderr" '! leaks "$WORK/all-output"'
check "no JSON-RPC request body ever carried the key" '! leaks "$WORK/scen"'

echo
echo "phase21-gaptrap-driver: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
