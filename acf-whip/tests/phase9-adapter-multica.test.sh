#!/usr/bin/env bash
# phase9-adapter-multica.test.sh — runs the frozen store-conformance suite against the multica
# adapter, OFFLINE by default, plus multica-specific assertions the frozen spec cannot express.
#
# This used to SKIP unless a live throwaway server was provided, and run-all.sh treats a SKIP as a
# pass. So the adapter shipped untested on every developer machine and in CI, and a whole class of
# defects — a snapshot field answered for one state only, an inert card raised to a gate FATAL, a
# transient silently converted into a definite answer — was invisible until a user hit it.
#
# The seam that makes an offline run possible already existed: every backend call funnels through
# multica_call -> "$MULTICA_BIN", and MULTICA_BIN is ${ACFW_MULTICA_BIN:-multica}. That is the same
# shape phase9-adapter-linear.test.sh uses for Linear via ACFW_LINEAR_TRANSPORT. All that was missing
# was the stand-in, so this suite installs one (tests/fixtures/multica-fake.sh, shared with
# phase20-cycle): a JSON-file-backed fake of the CLI surface the adapter actually uses, with fault
# injection so the transient paths can be exercised deliberately.
#
# Live server (optional, additive): export MULTICA_TEST_SERVER, MULTICA_TEST_TOKEN and
# MULTICA_TEST_WORKSPACE_ID to ALSO run the frozen suite against a real workspace.

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ACF_WHIP/adapters/multica/acfw-store-multica"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (required by the multica adapter)"; exit 0; }
[ -x "$ADAPTER" ] || { echo "FATAL: adapter not executable: $ADAPTER" >&2; exit 1; }

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-mc.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
FAKE="$WORK/multica-fake"

# ---- the offline stand-in (no network; one JSON file is the whole store) ----
# The fake lives in tests/fixtures/multica-fake.sh so phase20-cycle drives the SAME stand-in: two
# copies of a CLI emulator drift, and the one that stops matching the adapter keeps passing while
# testing nothing.
FIXTURE="$ACF_WHIP/tests/fixtures/multica-fake.sh"
[ -r "$FIXTURE" ] || { echo "FATAL: missing fixture: $FIXTURE" >&2; exit 1; }
. "$FIXTURE"
multica_fake_install "$FAKE"

mkstore() {  # <dir> — a fresh repo + empty fake store, echoed as the state path
  local d="$1"
  mkdir -p "$d" && ( cd "$d" && git init -q -b trunk . && git config user.email t@t && git config user.name t \
    && echo seed > seed && git add -A && git commit -qm seed ) >/dev/null 2>&1
  printf '{"issues":{},"seq":0}\n' > "$d/state.json"
  printf '%s' "$d/state.json"
}

mktask() {  # <file> <id> <slug> [deps]
  printf -- '- **ID**: %s\n- **Status**: pending\n- **Priority**: high\n- **Assigned Agent**: none\n- **Worktree**: %s\n- **PR Group**: %s\n- **Touches Globs**: none\n- **Dependencies**: %s\n\n# Task\n\nbody\n' \
    "$2" "$3" "$3" "${4:-none}" > "$1"
}

# ============================================================================
echo "== multica adapter: frozen store-conformance, OFFLINE =="
CONF=$(mkstore "$WORK/conf")
( export ACFW_TRUNK_ROOT="$WORK/conf" ACFW_MULTICA_BIN="$FAKE" MC_FAKE_STATE="$CONF"
  ADAPTER="$ADAPTER" bash "$ACF_WHIP/tests/phase9-store-conformance.test.sh" ) > "$WORK/conf.out" 2>&1
CONF_RC=$?
sed 's/^/    /' "$WORK/conf.out" | tail -3
check "frozen conformance spec passes against multica with no server" "[ $CONF_RC -eq 0 ]"

# ============================================================================
# Transient handling. A three-valued question — the key holds X / the key is absent / I could not ask
# — answered with one value lets any timeout or 5xx masquerade as a definite answer, and the
# read-modify-write callers then WRITE that fabrication. Each case below corrupts durable state.
echo
echo "== transient reads must never become definite answers =="
TRI=$(mkstore "$WORK/tri")
export ACFW_TRUNK_ROOT="$WORK/tri" ACFW_MULTICA_BIN="$FAKE" MC_FAKE_STATE="$TRI"
mktask "$WORK/tri.md" t-001 sa "dep-a, dep-b, dep-c"
"$ADAPTER" create --file "$WORK/tri.md" --stem t-001-x --folder pending >/dev/null

cycle() { for s in in-progress completed in-review; do "$ADAPTER" transition t-001-x "$s" o d 0 0 >/dev/null; done; }
cycle; "$ADAPTER" transition t-001-x rejected q bad 1 0 >/dev/null
"$ADAPTER" transition t-001-x pending o retry 0 0 >/dev/null
cycle; "$ADAPTER" transition t-001-x rejected q bad2 1 0 >/dev/null
RC0=$("$ADAPTER" read t-001-x | jq -r '.fields.rejection_count')
check "baseline: two real rejections counted" "[ \"$RC0\" = '2' ]"

"$ADAPTER" transition t-001-x pending o retry 0 0 >/dev/null; cycle
OUT=$(MC_FAKE_FAIL="metadata get+whip_rejections:2" "$ADAPTER" transition t-001-x rejected q bad3 1 0 2>&1); TR_RC=$?
RC1=$("$ADAPTER" read t-001-x | jq -r '.fields.rejection_count')
check "a transient on the counter read is refused, not fabricated" "[ $TR_RC -ne 0 ]"
# The fault hits ONLY the read, so the write path is live: without the guard the fabricated 0 is
# written and the counter drops from 2 to 1. Failing the write too would mask exactly that.
check "the rejection counter is NOT reset by it (still 2, would be 1 if fabricated)" "[ \"$RC1\" = '2' ]"
check "the refusal says what it was protecting" "printf '%s' \"\$OUT\" | grep -q 'RESET the counter'"
# The backend's own words must reach the operator. The helpers run inside $(...), so MC_ERR is set in a
# subshell and is empty by the time a caller interpolates it — the messages printed a dangling colon
# and nothing else. The detail is emitted from inside the helper now, on stderr, which does escape.
check "the failure names the backend detail, not just an exit code" \
  "printf '%s' \"\$OUT\" | grep -q \"metadata get 'whip_rejections' failed\""
check "...and does not end in a dangling colon" "! printf '%s' \"\$OUT\" | grep -qE '\\(exit [0-9]+\\): *$'"

DEP0=$("$ADAPTER" read t-001-x | jq -r '.fields.dependencies')
OUT=$(MC_FAKE_FAIL="metadata get+whip_deps:2" "$ADAPTER" update-field t-001-x --add-dep dep-d 2>&1); DEP_RC=$?
DEP1=$("$ADAPTER" read t-001-x | jq -r '.fields.dependencies')
check "a transient on the dependency read is refused" "[ $DEP_RC -ne 0 ]"
check "the dependency list survives intact (would collapse to just dep-d)" "[ \"$DEP1\" = \"$DEP0\" ] && [ \"$DEP1\" != 'dep-d' ]"

# The idempotence guard reads current state first. A fabricated "" makes it MISS, so an
# already-applied transition re-runs as a forward one, re-bumping counters and re-appending audit.
OUT=$(MC_FAKE_FAIL="metadata get+whip_state:2" "$ADAPTER" transition t-001-x rejected q again 1 0 2>&1); ST_RC=$?
check "a transient on the state read is refused, not treated as a state change" "[ $ST_RC -ne 0 ]"
RC2=$("$ADAPTER" read t-001-x | jq -r '.fields.rejection_count')
check "no counter was bumped by the refused transition" "[ \"$RC2\" = \"$RC1\" ]"

# A genuinely ABSENT key is not a transient: it must still answer normally.
"$ADAPTER" update-field t-001-x --set 'Priority=low' >/dev/null 2>&1
check "an absent metadata key still reads as absent, not as a failure" "[ \$? -eq 0 ]"

# ============================================================================
echo
echo "== snapshot fidelity the frozen spec cannot express =="
SNP=$(mkstore "$WORK/snap")
export ACFW_TRUNK_ROOT="$WORK/snap" MC_FAKE_STATE="$SNP"
mktask "$WORK/s1.md" s-001 sa; "$ADAPTER" create --file "$WORK/s1.md" --stem s-001-a --folder pending >/dev/null
mktask "$WORK/s2.md" s-002 sb; "$ADAPTER" create --file "$WORK/s2.md" --stem s-002-b --folder pending >/dev/null

# hasCleanCheckoutToken in EVERY state. This adapter answered it for in-review alone, so a task the
# orchestrator lifted from completed into review read its token as absent and had its review skipped.
"$ADAPTER" transition s-001-a in-progress o d 0 0 >/dev/null
"$ADAPTER" log-event s-001-a --row '| 2026-07-15 10:00:00 | clean-checkout | ok | x | sa | worktree/sa |' >/dev/null 2>&1
TOK_IP=$("$ADAPTER" snapshot | jq -r '.tasks[] | select(.stem=="s-001-a") | .hasCleanCheckoutToken')
check "token is reported in IN-PROGRESS" "[ \"$TOK_IP\" = 'true' ]"
"$ADAPTER" transition s-001-a completed s d 0 0 >/dev/null
TOK_C=$("$ADAPTER" snapshot | jq -r '.tasks[] | select(.stem=="s-001-a") | .hasCleanCheckoutToken')
check "token is reported in COMPLETED (the state the review queue is built from)" "[ \"$TOK_C\" = 'true' ]"
"$ADAPTER" transition s-001-a in-review o r 0 0 >/dev/null
"$ADAPTER" transition s-001-a accepted q ship 0 0 >/dev/null
TOK_A=$("$ADAPTER" snapshot | jq -r '.tasks[] | select(.stem=="s-001-a") | .hasCleanCheckoutToken')
check "token is reported in ACCEPTED (the generic doctor warns on false)" "[ \"$TOK_A\" = 'true' ]"
TOK_N=$("$ADAPTER" snapshot | jq -r '.tasks[] | select(.stem=="s-002-b") | .hasCleanCheckoutToken')
check "a task that never logged one still reports false" "[ \"$TOK_N\" = 'false' ]"

# An out-of-vocabulary whip_state is inert, not corrupt: no scheduler path can act on it.
UUID=$(jq -r '.issues | to_entries[] | select(.value.metadata.whip_key=="s-002-b") | .key' "$SNP")
ACFW_MULTICA_BIN="$FAKE" "$FAKE" issue metadata set "$UUID" --key whip_state --value in-external-review --type string >/dev/null
DOC=$("$ADAPTER" doctor 2>/dev/null); DOC_RC=$?
check "an out-of-vocabulary state is WARN, not FATAL" "printf '%s\n' \"\$DOC\" | grep -q '^WARN|invalid-state|'"
check "...and therefore does not fail the gate" "[ $DOC_RC -eq 0 ]"
check "...and names the remedy" "printf '%s\n' \"\$DOC\" | grep -q 'transition s-002-b archive'"
# ---- a human HOLD is an instruction, not drift (3.4.0) ----------------------------------------
# `/go` runs `doctor --fix` at bootstrap. Repairing a native blocked/cancelled back to the whip state
# meant every run silently un-parked every card the team had parked — the board-level equivalent of
# reverting someone's work. It is reported and left alone now, with the supported way to park a task
# named in the finding.
HOLD_UUID=$(jq -r '.issues | to_entries[] | select(.value.metadata.whip_key=="s-001-a") | .key' "$SNP")
ACFW_MULTICA_BIN="$FAKE" "$FAKE" issue metadata set "$HOLD_UUID" --key whip_state --value pending --type string >/dev/null
jq --arg u "$HOLD_UUID" '.issues[$u].status = "cancelled"' "$SNP" > "$SNP.t" && mv "$SNP.t" "$SNP"
DOCH=$("$ADAPTER" doctor 2>/dev/null)
check "a natively cancelled card whose whip_state is runnable is a HOLD, not drift" \
  "printf '%s\n' \"\$DOCH\" | grep -q '^WARN|native-hold|s-001-a|'"
check "...never REPAIRABLE (that is what made --fix overwrite it)" \
  "! printf '%s\n' \"\$DOCH\" | grep -q '^REPAIRABLE|status-drift|s-001-a|'"
check "...and it names the supported way to park a task" \
  "printf '%s\n' \"\$DOCH\" | grep -q 'transition s-001-a draft'"
"$ADAPTER" doctor --fix >/dev/null 2>&1
AFTER=$(jq -r --arg u "$HOLD_UUID" '.issues[$u].status' "$SNP")
check "--fix leaves the human hold in place" "[ \"\$AFTER\" = 'cancelled' ]"
# ...while ordinary drift (native status behind an ordinary whip state) is still repaired.
DRIFT_UUID=$(jq -r '.issues | to_entries[] | select(.value.metadata.whip_key=="s-002-b") | .key' "$SNP")
jq --arg u "$DRIFT_UUID" '.issues[$u].status = "todo" | .issues[$u].metadata.whip_state = "in-progress"' "$SNP" > "$SNP.t" && mv "$SNP.t" "$SNP"
DOCD=$("$ADAPTER" doctor 2>/dev/null)
check "ordinary status drift is still REPAIRABLE" \
  "printf '%s\n' \"\$DOCD\" | grep -q '^REPAIRABLE|status-drift|s-002-b|'"
"$ADAPTER" doctor --fix >/dev/null 2>&1
DAFTER=$(jq -r --arg u "$DRIFT_UUID" '.issues[$u].status' "$SNP")
check "...and --fix still repairs it" "[ \"\$DAFTER\" = 'in_progress' ]"
# restore the fixture for the assertions that follow
jq --arg u "$DRIFT_UUID" '.issues[$u].metadata.whip_state = "in-external-review"' "$SNP" > "$SNP.t" && mv "$SNP.t" "$SNP"

DOCQ=$("$ADAPTER" doctor --quiet 2>/dev/null)
check "--quiet drops the advisory but keeps the SUMMARY" \
  "! printf '%s\n' \"\$DOCQ\" | grep -q '^WARN|' && printf '%s\n' \"\$DOCQ\" | grep -q '^SUMMARY|'"

# --quiet must keep the GATE DECISION, not just the SUMMARY. Without doctor-complete the dispatcher
# recomputes ok= from the lines it receives, so a swallowed FATAL flips /go's startup gate from refuse
# to proceed. The assertion above cannot see that: on a board with zero FATALs it compares 0 to 0 and
# the pre-fix code (which suppressed everything) passes it. Induce a REAL FATAL first.
# duplicate-key is multica's remaining native FATAL now that invalid-state is a WARN: clone an issue
# so two share one whip_key. Done LAST because it corrupts the fixture board.
DUP=$(jq -r '.issues | keys[0]' "$SNP")
python3 - "$SNP" "$DUP" <<'PY'
import json, sys
p, src = sys.argv[1], sys.argv[2]
d = json.load(open(p))
clone = dict(d["issues"][src]); clone["id"] = "iss-clone"
d["issues"]["iss-clone"] = clone
json.dump(d, open(p, "w"))
PY
DF=$("$ADAPTER" doctor 2>/dev/null); DF_N=$(printf '%s\n' "$DF" | grep -c '^FATAL|' || true); DF_N=${DF_N//[^0-9]/}
DQ=$("$ADAPTER" doctor --quiet 2>/dev/null); DQ_N=$(printf '%s\n' "$DQ" | grep -c '^FATAL|' || true); DQ_N=${DQ_N//[^0-9]/}
check "the fixture really does carry a native FATAL (guards against a vacuous compare)" "[ \"\${DF_N:-0}\" -ge 1 ]"
check "--quiet keeps every FATAL the verbose run reported" "[ \"\${DQ_N:-0}\" -eq \"\${DF_N:-0}\" ]"
check "--quiet still suppresses the advisories" "! printf '%s\n' \"\$DQ\" | grep -qE '^(WARN|REPAIRABLE)\\|'"
check "--quiet and verbose agree on ok=" \
  "[ \"\$(printf '%s\n' \"\$DF\" | sed -n 's/.*|ok=\\(.*\\)/\\1/p' | tail -1)\" = \"\$(printf '%s\n' \"\$DQ\" | sed -n 's/.*|ok=\\(.*\\)/\\1/p' | tail -1)\" ]"

# ============================================================================
# A transition-log row is ONE LINE by construction. cmd_transition guarantees that via log_row/logcell;
# log-event took the row pre-formatted and spliced it in verbatim, so an embedded newline tore the
# table in half — and a torn table is the collapsed-task-file corpse doctor.sh has a dedicated
# NON-repairable FATAL for, because it marks a write that cannot be safely healed.
echo
echo "== log-event cannot tear the transition log =="
LG=$(mkstore "$WORK/lg")
export ACFW_TRUNK_ROOT="$WORK/lg" MC_FAKE_STATE="$LG"
mktask "$WORK/lg.md" l-001 sl
"$ADAPTER" create --file "$WORK/lg.md" --stem l-001-x --folder pending >/dev/null
# The injected second line must itself LOOK like a row, or counting ^| lines proves nothing.
"$ADAPTER" log-event l-001-x --row "$(printf '| ts | clean-checkout | ok |\n| EVIL | x |')" >/dev/null
BODY=$("$ADAPTER" read --body l-001-x | jq -r '.body')
ROWS=$(printf '%s\n' "$BODY" | grep -c '^|' || true)
check "an embedded newline is flattened into ONE row, not two" "[ \"\$ROWS\" = '1' ]"
check "...and the token is still greppable in the single row" "printf '%s' \"\$BODY\" | grep -q 'clean-checkout | ok'"
LG_OUT=$("$ADAPTER" log-event l-001-x --row "not a table row" 2>&1); LG_RC=$?
check "a row that is not pipe-delimited is a usage error (exit 2)" "[ $LG_RC -eq 2 ]"
check "...and says what shape it wanted" "printf '%s' \"\$LG_OUT\" | grep -q 'single pipe-delimited table row'"

# ============================================================================
# A token the snapshot could not read is UNKNOWN (null), never absent (false). false is the value the
# review gate parks a task on, so a transient projected as false parks the task, the unblock pass
# re-dispatches it, and the next failed read parks it again. The token has two homes (the description
# since 3.2.0, comments before that), so "absent" needs BOTH read.
echo
echo "== a token that could not be read is null, not false =="
UNK=$(mkstore "$WORK/unk")
export ACFW_TRUNK_ROOT="$WORK/unk" MC_FAKE_STATE="$UNK"
mkrev() {  # <stem> <slug> — create, then walk it to in-review
  mktask "$WORK/$1.md" "$1" "$2"; "$ADAPTER" create --file "$WORK/$1.md" --stem "$1" --folder pending >/dev/null
  for st in in-progress completed in-review; do "$ADAPTER" transition "$1" "$st" o d 0 0 >/dev/null; done
}
uuid_of() { jq -r --arg k "$1" '.issues | to_entries[] | select(.value.metadata.whip_key==$k) | .key' "$UNK"; }
tok_of() { printf '%s' "$1" | jq -r --arg s "$2" '.tasks[] | select(.stem==$s) | .hasCleanCheckoutToken | tostring'; }
mkrev u-tok ua; mkrev u-none ub; mkrev u-cfail uc; mkrev u-gfail ud; mkrev u-nodesc ue
"$ADAPTER" log-event u-tok --row '| 2026-07-15 10:00:00 | clean-checkout | ok | x | ua | worktree/ua |' >/dev/null 2>&1
# u-cfail's token is LEGACY (a comment, not in the document): readable it is true, so the null below
# is hiding a true, which is exactly the task the old false would have parked.
printf '%s' '| 2026-07-15 10:00:00 | clean-checkout | ok | x | uc | worktree/uc |' \
  | "$FAKE" issue comment add "$(uuid_of u-cfail)" --content-stdin --output json >/dev/null
# u-nodesc models a list that omitted the description: only `issue get` can read the document.
jq --arg u "$(uuid_of u-nodesc)" '.issues[$u].description = ""' "$UNK" > "$UNK.t" && mv "$UNK.t" "$UNK"
BASE=$("$ADAPTER" snapshot 2>/dev/null)
check "baseline, no faults: the legacy comment token reads true" "[ \"\$(tok_of \"\$BASE\" u-cfail)\" = 'true' ]"

FAULTS="comment list+$(uuid_of u-cfail):1,issue get+$(uuid_of u-gfail):1,issue get+$(uuid_of u-nodesc):1"
USNAP=$(MC_FAKE_FAIL="$FAULTS" "$ADAPTER" snapshot 2>"$WORK/unk.err")
check "a failed comment list is unknown (null), not false" "[ \"\$(tok_of \"\$USNAP\" u-cfail)\" = 'null' ]"
check "a failed issue get when the list omitted the description is null, even with a clean comment scan" \
  "[ \"\$(tok_of \"\$USNAP\" u-nodesc)\" = 'null' ]"
# Control: the listed description WAS read (and carried no token), so a failed get changes nothing.
check "...but a failed issue get after the list carried the description is still a definite false" \
  "[ \"\$(tok_of \"\$USNAP\" u-gfail)\" = 'false' ]"
check "readable tasks still answer true and false" \
  "[ \"\$(tok_of \"\$USNAP\" u-tok)\" = 'true' ] && [ \"\$(tok_of \"\$USNAP\" u-none)\" = 'false' ]"
check "the stderr WARN counts the unknowns and says null, not 'no token'" \
  "grep -q 'could not be read for 2 task(s); they are reported as unknown (hasCleanCheckoutToken: null)' \"$WORK/unk.err\""

# Through the dispatcher's raw path: adapter -> acfw-enrich-snapshot.sh -> relay post-stage.
DSNAP=$(MC_FAKE_FAIL="$FAULTS" ACFW_STORE=multica bash "$ACF_WHIP/skills/lib/bin/acfw-store" snapshot 2>/dev/null)
check "null survives enrichment through acfw-store snapshot" \
  "[ \"\$(tok_of \"\$DSNAP\" u-cfail)\" = 'null' ] && [ \"\$(tok_of \"\$DSNAP\" u-nodesc)\" = 'null' ]"
check "...alongside unchanged true/false, on a snapshot that really was enriched" \
  "[ \"\$(tok_of \"\$DSNAP\" u-tok)\" = 'true' ] && [ \"\$(tok_of \"\$DSNAP\" u-gfail)\" = 'false' ] && printf '%s' \"\$DSNAP\" | jq -e '.store == \"multica\" and has(\"relay\") and (has(\"raw\") | not)' >/dev/null"

# ============================================================================
if [ -n "${MULTICA_TEST_SERVER:-}" ] && [ -n "${MULTICA_TEST_TOKEN:-}" ] && [ -n "${MULTICA_TEST_WORKSPACE_ID:-}" ]; then
  echo
  echo "== ALSO running the frozen suite against the live server $MULTICA_TEST_SERVER =="
  export MULTICA_SERVER_URL="$MULTICA_TEST_SERVER" MULTICA_TOKEN="$MULTICA_TEST_TOKEN" MULTICA_WORKSPACE_ID="$MULTICA_TEST_WORKSPACE_ID"
  unset ACFW_MULTICA_BIN MC_FAKE_STATE
  ADAPTER="$ADAPTER" bash "$ACF_WHIP/tests/phase9-store-conformance.test.sh"
  check "frozen conformance spec passes against the live server" "[ $? -eq 0 ]"
fi

echo
echo "phase9-adapter-multica: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
