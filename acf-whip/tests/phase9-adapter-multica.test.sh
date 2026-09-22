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
# was the stand-in, so this file writes one: a JSON-file-backed fake of the CLI surface the adapter
# actually uses, with fault injection so the transient paths can be exercised deliberately.
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
cat > "$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
# multica-fake — an offline stand-in for the `multica` CLI, backed by one JSON file.
#
# The adapter funnels every backend call through multica_call -> "$MULTICA_BIN", and MULTICA_BIN is
# ${ACFW_MULTICA_BIN:-multica}. That single seam is all an offline conformance run needs — the same
# shape phase9-adapter-linear.test.sh already uses for Linear via ACFW_LINEAR_TRANSPORT.
#
# State:   $MC_FAKE_STATE (JSON: {"issues":{<uuid>:{...}},"seq":N})
# Faults:  $MC_FAKE_FAIL  — "<pattern>:<exit>" pairs, comma separated. A pattern is one or more
#            substrings joined by "+", ALL of which must appear in the joined argv. The AND form is
#            what makes a fault precise: "metadata get+whip_rejections" fails the READ of that key
#            without also failing the WRITE, which would mask the very fabrication under test.
#          $MC_FAKE_FAIL_ONCE — same, but each pattern fires once then clears (via $MC_FAKE_FIRED)
set -u
STATE="${MC_FAKE_STATE:?MC_FAKE_STATE must be set}"
[ -f "$STATE" ] || printf '{"issues":{},"seq":0}\n' > "$STATE"

ARGV="$*"
matches_all() { # <pattern-with-+-separators> — every part must appear in $ARGV
  local part
  for part in $(printf '%s' "$1" | tr '+' '\n'); do
    case "$ARGV" in *"$part"*) ;; *) return 1 ;; esac
  done
  return 0
}
fault() { # honour MC_FAKE_FAIL / MC_FAKE_FAIL_ONCE against the joined argv
  local spec pat code OLDIFS
  # Split on COMMAS only. `$(... | tr ',' ' ')` word-splits on spaces too, so an AND-pattern containing
  # one ("metadata get+whip_state") became two broken specs, the first of which ("metadata") matched
  # every metadata call — defeating the precision the AND form exists to provide.
  OLDIFS="$IFS"; IFS=','
  for spec in ${MC_FAKE_FAIL_ONCE:-}; do
    IFS="$OLDIFS"
    pat="${spec%:*}"; code="${spec##*:}"
    if matches_all "$pat"; then
      if [ -n "${MC_FAKE_FIRED:-}" ] && [ -f "$MC_FAKE_FIRED" ] && grep -qxF "$spec" "$MC_FAKE_FIRED"; then continue; fi
      [ -n "${MC_FAKE_FIRED:-}" ] && echo "$spec" >> "$MC_FAKE_FIRED"
      echo "fake: injected transient for '$pat'" >&2; exit "$code"
    fi
    IFS=','
  done
  IFS="$OLDIFS"
  IFS=','
  for spec in ${MC_FAKE_FAIL:-}; do
    IFS="$OLDIFS"
    pat="${spec%:*}"; code="${spec##*:}"
    case "$code" in ''|*[!0-9]*) echo "fake: malformed MC_FAKE_FAIL spec '$spec' (want <pattern>:<exit>)" >&2; exit 64 ;; esac
    matches_all "$pat" && { echo "fake: injected failure for '$pat'" >&2; exit "$code"; }
    IFS=','
  done
  IFS="$OLDIFS"
}
fault

jqs() { jq "$@" "$STATE"; }
save() { local t; t=$(mktemp); jq "$@" "$STATE" > "$t" && mv "$t" "$STATE"; }

SUB="${1:-}"; shift || true
[ "$SUB" = "issue" ] || { echo "fake: unsupported command '$SUB'" >&2; exit 2; }
ACT="${1:-}"; shift || true

case "$ACT" in
  create)
    TITLE=""; DESC=""; STATUS="todo"; PRIO=""
    while [ $# -gt 0 ]; do case "$1" in
      --title) TITLE="$2"; shift 2 ;;
      --description-stdin) DESC=$(cat); shift ;;
      --status) STATUS="$2"; shift 2 ;;
      --priority) PRIO="$2"; shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac; done
    ID="iss-$(jqs -r '.seq + 1')"
    save --arg id "$ID" --arg t "$TITLE" --arg d "$DESC" --arg s "$STATUS" --arg p "$PRIO" \
      '.seq += 1 | .issues[$id] = {id:$id, identifier:("T-"+($id|ltrimstr("iss-"))), title:$t, description:$d, status:$s, priority:$p, metadata:{}, comments:[]}'
    jqs -r --arg id "$ID" '.issues[$id] | {id, identifier, title, status}'
    ;;
  list)
    LIMIT=1000; OFFSET=0; MKEY=""; MVAL=""
    while [ $# -gt 0 ]; do case "$1" in
      --limit) LIMIT="$2"; shift 2 ;;
      --offset) OFFSET="$2"; shift 2 ;;
      --metadata) MKEY="${2%%=*}"; MVAL="${2#*=}"; shift 2 ;;
      --project) shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac; done
    # Real shape: {"issues":[...],"has_more":bool} — the adapter paginates on has_more and counts
    # .issues|length, so a bare array breaks both.
    jqs -r --argjson lim "$LIMIT" --argjson off "$OFFSET" --arg mk "$MKEY" --arg mv "$MVAL" '
      ([.issues[]]
       | if $mk == "" then . else map(select(((.metadata[$mk] // "") | tostring) == $mv)) end
       | sort_by(.id)) as $all
      | {issues: $all[$off:($off + $lim)], has_more: (($off + $lim) < ($all | length))}'
    ;;
  get)
    ID="$1"; shift
    jqs -e -r --arg id "$ID" '.issues[$id] // empty' || { echo "fake: no such issue $ID" >&2; exit 4; }
    ;;
  status)
    ID="$1"; ST="$2"
    jqs -e --arg id "$ID" '.issues | has($id)' >/dev/null || { echo "fake: no such issue $ID" >&2; exit 4; }
    save --arg id "$ID" --arg s "$ST" '.issues[$id].status = $s'
    jqs -r --arg id "$ID" '.issues[$id] | {id, status}'
    ;;
  update)
    ID="$1"; shift
    while [ $# -gt 0 ]; do case "$1" in
      --description-stdin) D=$(cat); save --arg id "$ID" --arg d "$D" '.issues[$id].description = $d'; shift ;;
      --priority) save --arg id "$ID" --arg p "$2" '.issues[$id].priority = $p'; shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac; done
    jqs -r --arg id "$ID" '.issues[$id] | {id}'
    ;;
  metadata)
    MACT="${1:-}"; shift || true
    ID="$1"; shift
    KEY=""; VAL=""; TYPE="string"
    while [ $# -gt 0 ]; do case "$1" in
      --key) KEY="$2"; shift 2 ;;
      --value) VAL="$2"; shift 2 ;;
      --type) TYPE="$2"; shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac; done
    case "$MACT" in
      set) if [ "$TYPE" = "number" ]; then save --arg id "$ID" --arg k "$KEY" --argjson v "${VAL:-0}" '.issues[$id].metadata[$k] = $v'
           else save --arg id "$ID" --arg k "$KEY" --arg v "$VAL" '.issues[$id].metadata[$k] = $v'; fi
           printf '{"ok":true}\n' ;;
      # --output json means JSON, not a bare word: the adapter pipes this through jq.
      get) jqs -e --arg id "$ID" --arg k "$KEY" '.issues[$id].metadata[$k] // empty' \
             || { echo "fake: no such metadata key $KEY" >&2; exit 4; } ;;
      *)   echo "fake: unsupported metadata action '$MACT'" >&2; exit 2 ;;
    esac
    ;;
  comment)
    CACT="${1:-}"; shift || true
    ID="$1"; shift
    case "$CACT" in
      add)  C=""; while [ $# -gt 0 ]; do case "$1" in --content-stdin) C=$(cat); shift ;; --output) shift 2 ;; *) shift ;; esac; done
            save --arg id "$ID" --arg c "$C" '.issues[$id].comments += [{content:$c}]'; printf '{"ok":true}\n' ;;
      list) jqs -r --arg id "$ID" '.issues[$id].comments // []' ;;
      *)    echo "fake: unsupported comment action '$CACT'" >&2; exit 2 ;;
    esac
    ;;
  *) echo "fake: unsupported issue action '$ACT'" >&2; exit 2 ;;
esac
FAKEEOF
chmod +x "$FAKE"

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
