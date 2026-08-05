#!/usr/bin/env bash
# phase12-multica-transition-log.test.sh — the multica adapter records transitions in the
# task document's "## Transition Log", not in issue comments.
#
# On this backend a comment thread is a LIVE AGENT CHANNEL: an assigned agent reads it and
# comment activity triggers comment-scoped tasks. Putting whip's audit trail there mixes
# orchestrator bookkeeping into a conversation, forces `read --materialize` to synthesize a
# document section no other adapter has, and makes `snapshot` pay a comment-list per
# in-review task just to answer hasCleanCheckoutToken.
#
# The adapter talks to a real API, so this suite drives it through a FAKE `multica` CLI
# (JSON files + jq) built below. That fake is deliberately NOT a general emulator — it
# covers only the invocation shapes this change touches, and the live-server wrapper
# (phase9-adapter-multica.test.sh) remains the authority on real CLI behavior.
#
# Run: bash acf-whip/tests/phase12-multica-transition-log.test.sh

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ACF_WHIP/adapters/multica/acfw-store-multica"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed (required by the multica adapter)"; exit 0; }
[ -x "$ADAPTER" ] || { echo "FATAL: adapter not executable: $ADAPTER" >&2; exit 1; }

PASS=0 FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 [cond: $2]"; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/acfw-p12.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/store/issues" "$WORK/specs"

# ---- the fake multica CLI --------------------------------------------------------------
cat > "$WORK/bin/multica" <<'FAKECLI'
#!/usr/bin/env bash
# Fake `multica` — only the subcommands acfw-store-multica invokes. State: one JSON file
# per issue under $FAKE_STORE/issues, comments alongside as <id>.comments.json.
set -u
S="$FAKE_STORE"
die(){ echo "$2" >&2; exit "$1"; }
T(){ mktemp "$S/tmp.XXXXXX"; }
put(){ mv "$1" "$S/issues/$2.json"; }
need(){ [ -f "$S/issues/$1.json" ] || die 4 "issue not found: $1"; }

[ "${1:-}" = "issue" ] || die 1 "fake: unsupported group '${1:-}'"
shift
CMD="${1:-}"; shift || true

case "$CMD" in
create)
  title=""; status="backlog"; prio=""; desc=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --priority) prio="$2"; shift 2 ;;
      --description-stdin) desc=$(cat); shift ;;
      --parent|--stage|--project|--output) shift 2 ;;
      *) shift ;;
    esac
  done
  n=$(( $(cat "$S/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/seq"
  id=$(printf 'iss-%04d' "$n")
  jq -n --arg id "$id" --arg t "$title" --arg d "$desc" --arg st "$status" --arg p "$prio" \
        --arg ident "$(printf 'FAKE-%d' "$n")" \
    '{id:$id, identifier:$ident, title:$t, description:$d, status:$st, priority:$p, metadata:{}}' \
    > "$S/issues/$id.json"
  echo "$id" >> "$S/order"
  jq -c . "$S/issues/$id.json"
  ;;
get)
  id="$1"; need "$id"; jq -c . "$S/issues/$id.json"
  ;;
list)
  limit=50; offset=0; mk=""; mv=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --metadata) mk="${2%%=*}"; mv="${2#*=}"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --offset) offset="$2"; shift 2 ;;
      --project|--status|--output|--sort|--direction|--priority) shift 2 ;;
      *) shift ;;
    esac
  done
  all=$(T); : > "$all"
  if [ -f "$S/order" ]; then
    while read -r i; do [ -f "$S/issues/$i.json" ] && jq -c . "$S/issues/$i.json" >> "$all"; done < "$S/order"
  fi
  # FAKE_LIST_NO_DESC models a server whose `issue list` omits description — the adapter's
  # snapshot must still find the token (via `issue get`), so this switch has to be testable.
  if [ -n "${FAKE_LIST_NO_DESC:-}" ]; then
    d=$(T); jq -c 'del(.description)' "$all" > "$d" && mv "$d" "$all"
  fi
  jq -s --arg mk "$mk" --arg mv "$mv" --argjson lim "$limit" --argjson off "$offset" '
    (if $mk == "" then . else map(select(((.metadata[$mk] // "") | tostring) == $mv)) end) as $f
    | { issues: $f[$off:($off + $lim)], has_more: (($f | length) > ($off + $lim)) }
  ' "$all"
  ;;
update)
  id="$1"; shift; need "$id"
  while [ $# -gt 0 ]; do
    case "$1" in
      --description-stdin)
        [ -n "${FAKE_FAIL_UPDATE:-}" ] && die 5 "validation error: description update rejected (injected)"
        d=$(cat); t=$(T); jq --arg d "$d" '.description = $d' "$S/issues/$id.json" > "$t" && put "$t" "$id"
        shift ;;
      --priority) t=$(T); jq --arg p "$2" '.priority = $p' "$S/issues/$id.json" > "$t" && put "$t" "$id"; shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac
  done
  jq -c . "$S/issues/$id.json"
  ;;
status)
  id="$1"; st="$2"; need "$id"
  t=$(T); jq --arg s "$st" '.status = $s' "$S/issues/$id.json" > "$t" && put "$t" "$id"
  jq -c . "$S/issues/$id.json"
  ;;
metadata)
  sub="$1"; shift; id="$1"; shift; need "$id"
  k=""; v=""; ty="string"
  while [ $# -gt 0 ]; do
    case "$1" in
      --key) k="$2"; shift 2 ;;
      --value) v="$2"; shift 2 ;;
      --type) ty="$2"; shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac
  done
  case "$sub" in
    set) t=$(T)
         if [ "$ty" = "number" ]; then
           [ -n "$v" ] || v=0
           jq --arg k "$k" --argjson v "$v" '.metadata[$k] = $v' "$S/issues/$id.json" > "$t"
         else
           jq --arg k "$k" --arg v "$v" '.metadata[$k] = $v' "$S/issues/$id.json" > "$t"
         fi
         put "$t" "$id"; echo '{"ok":true}' ;;
    get) jq -c --arg k "$k" '.metadata[$k] // ""' "$S/issues/$id.json" ;;
    delete) t=$(T); jq --arg k "$k" 'del(.metadata[$k])' "$S/issues/$id.json" > "$t"; put "$t" "$id"; echo '{"ok":true}' ;;
    *) die 1 "fake: unsupported metadata subcommand '$sub'" ;;
  esac
  ;;
comment)
  sub="$1"; shift; id="$1"; shift; need "$id"
  f="$S/issues/$id.comments.json"; [ -f "$f" ] || echo '[]' > "$f"
  case "$sub" in
    add) c=""
         while [ $# -gt 0 ]; do
           case "$1" in --content-stdin) c=$(cat); shift ;; --content) c="$2"; shift 2 ;; --output) shift 2 ;; *) shift ;; esac
         done
         n=$(( $(cat "$S/cseq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/cseq"
         t=$(T); jq --arg c "$c" --arg ts "$(printf '2026-08-05T00:00:00.%06dZ' "$n")" \
           '. + [{content:$c, created_at:$ts}]' "$f" > "$t" && mv "$t" "$f"
         echo '{"ok":true}' ;;
    list) jq -c . "$f" ;;
    *) die 1 "fake: unsupported comment subcommand '$sub'" ;;
  esac
  ;;
*) die 1 "fake: unsupported issue subcommand '$CMD'" ;;
esac
FAKECLI
chmod +x "$WORK/bin/multica"

export FAKE_STORE="$WORK/store"
export ACFW_MULTICA_BIN="$WORK/bin/multica"
FAKE="$WORK/bin/multica"

# ---- fixtures --------------------------------------------------------------------------

# A task document shaped like the template: a Transition Log table with a seed row, and a
# section AFTER it so we can prove rows splice IN rather than dangle at EOF.
mktask(){ # <stem>
  cat > "$WORK/$1.md" <<EOF
# Task: $1

## Metadata

- **ID**: $1
- **Status**: pending
- **Priority**: high
- **Assigned Agent**: backend-agent
- **Worktree**: slug-$1
- **PR Group**: slug-$1
- **Touches Globs**: none
- **Dependencies**: none
- **Rejection Count**: 0
- **Block-Count**: 0

## Description

BODY-SENTINEL-$1

## Transition Log

| Date Time | From | To | Agent | Reason/Comment |
| --------- | ---- | -- | ----- | -------------- |
| 2026-08-05 00:00:00 | draft | pending | task-engineer | Initial task creation |

## Implementation Notes

TAIL-SENTINEL
EOF
}

uuid_of(){ "$FAKE" issue list --metadata "whip_key=$1" --limit 1 --output json | jq -r '.issues[0].id // empty'; }
ncomments(){ "$FAKE" issue comment list "$(uuid_of "$1")" --full --output json | jq 'length'; }
body_of(){ "$ADAPTER" read --body "$1" | jq -r '.body'; }
# rows in the Transition Log table body (data rows only — header and separator excluded)
nrows(){ body_of "$1" | awk '/^## Transition Log/{i=1;next} i && /^\|/{if ($0 !~ /^\| *-+ *\|/ && $0 !~ /Date Time/) n++} i && !/^\|/ && !/^$/ && !/^## Transition Log/{i=0} END{print n+0}'; }

TOKEN='| 2026-08-05 10:00:00 | clean-checkout | ok | clean-checkout-before-task | slug-a | worktree/slug-a |'

echo "== multica adapter: transitions land in the Transition Log =="

# ---- A0: the harness is not vacuous ----------------------------------------------------
# phase5 once passed vacuously against a mock that never engaged the code under test. Prove
# the fake + adapter round-trip BEFORE asserting anything about where rows go.
mktask a
"$ADAPTER" create --file "$WORK/a.md" --folder pending >/dev/null 2>&1
check "A0a: create round-trips through the fake CLI" "[ -n \"\$(uuid_of a)\" ]"
check "A0b: read --body returns the stored document" "body_of a | grep -q 'BODY-SENTINEL-a'"
check "A0c: the seed Transition Log row is present" "[ \"\$(nrows a)\" = 1 ]"

# ---- A1-A3: transition writes a table row, not a comment -------------------------------
"$ADAPTER" transition a in-progress orchestrator dispatch 0 0 >/dev/null 2>&1
D=$(body_of a)
SEP=$(printf '%s\n' "$D" | grep -n '^| *-\+ *|' | head -1 | cut -d: -f1)
ROW=$(printf '%s\n' "$D" | grep -n '| pending | in-progress | orchestrator | dispatch |' | head -1 | cut -d: -f1)
TAIL=$(printf '%s\n' "$D" | grep -n '^TAIL-SENTINEL' | head -1 | cut -d: -f1)
check "A1a: the transition row is in the document" "[ -n \"$ROW\" ]"
check "A1b: it sits directly under the header separator (newest-first splice)" "[ -n \"$SEP\" ] && [ -n \"$ROW\" ] && [ \"$ROW\" -eq \$((SEP + 1)) ]"
check "A1c: it splices INTO the table, not after the last section" "[ -n \"$TAIL\" ] && [ \"$ROW\" -lt \"$TAIL\" ]"
check "A2: transition created NO comment" "[ \"\$(ncomments a)\" = 0 ]"
check "A3a: the row uses the files table shape" "printf '%s\n' \"\$D\" | grep -qE '^\\| [0-9-]+ [0-9:]+ \\| pending \\| in-progress \\| orchestrator \\| dispatch \\|\$'"
check "A3b: the legacy 'whip-transition |' comment shape is gone" "! printf '%s\n' \"\$D\" | grep -q 'whip-transition'"
check "A3c: the seed row survived (rows accumulate)" "[ \"\$(nrows a)\" = 2 ]"

# ---- A4: a pipe or newline in NOTES cannot break the table -----------------------------
"$ADAPTER" transition a completed backend-agent "$(printf 'saw a|b\nand more')" 0 0 >/dev/null 2>&1
D=$(body_of a)
check "A4a: NOTES with a pipe/newline still yields exactly one new row" "[ \"\$(nrows a)\" = 3 ]"
check "A4b: the pipe is escaped, not column-splitting" "printf '%s\n' \"\$D\" | grep -q 'saw a\\\\|b and more'"
check "A4c: every table line still opens and closes with a pipe" "! printf '%s\n' \"\$D\" | awk '/^## Transition Log/{i=1;next} i && /^\\|/{ if (\$0 !~ /\\|\$/) print }' | grep -q ."

# ---- A5-A6: log-event and the token, with zero comments --------------------------------
"$ADAPTER" transition a in-review orchestrator premove 0 0 >/dev/null 2>&1
"$ADAPTER" log-event a --row "$TOKEN" >/dev/null 2>&1
check "A5a: the clean-checkout token is in the Transition Log" "body_of a | grep -qF '| clean-checkout | ok |'"
check "A5b: log-event created NO comment" "[ \"\$(ncomments a)\" = 0 ]"
check "A6: snapshot sees the token from the description alone" \
  "\"\$ADAPTER\" snapshot | jq -e '.tasks[] | select(.stem==\"a\") | .hasCleanCheckoutToken == true' >/dev/null"
check "A6b: snapshot still finds it when list omits description (issue get fallback)" \
  "FAKE_LIST_NO_DESC=1 \"\$ADAPTER\" snapshot | jq -e '.tasks[] | select(.stem==\"a\") | .hasCleanCheckoutToken == true' >/dev/null"

# ---- A8/A10: materialize ---------------------------------------------------------------
MAT=$("$ADAPTER" read --materialize "$WORK/specs" a)
check "A8: materialize exposes the token with no comments on the issue" "grep -qF '| clean-checkout | ok |' \"$MAT\""
check "A8b: materialize refreshed Status from live metadata" "grep -qE '^- \\*\\*Status\\*\\*: in-review' \"$MAT\""
printf 'looks good to me\n' | "$ADAPTER" comment a --author reviewer >/dev/null 2>&1
MAT=$("$ADAPTER" read --materialize "$WORK/specs" a)
check "A10a: comment still creates a real comment" "[ \"\$(ncomments a)\" = 1 ]"
check "A10b: it renders under ## Store Comments" "grep -q '^## Store Comments' \"$MAT\" && grep -q 'looks good to me' \"$MAT\""
check "A10c: the retired ## Store Audit Trail heading is gone" "! grep -q 'Store Audit Trail' \"$MAT\""

# ---- A7/A9: a task upgraded mid-flight keeps its comment-borne token --------------------
mktask legacy
"$ADAPTER" create --file "$WORK/legacy.md" --folder pending >/dev/null 2>&1
"$ADAPTER" transition legacy in-review orchestrator premove 0 0 >/dev/null 2>&1
printf '%s' "$TOKEN" | "$FAKE" issue comment add "$(uuid_of legacy)" --content-stdin --output json >/dev/null
check "A7a: the legacy token is a comment, NOT in the document" \
  "[ \"\$(ncomments legacy)\" = 1 ] && ! body_of legacy | grep -qF '| clean-checkout | ok |'"
check "A7b: snapshot still reports the token (comment fallback)" \
  "\"\$ADAPTER\" snapshot | jq -e '.tasks[] | select(.stem==\"legacy\") | .hasCleanCheckoutToken == true' >/dev/null"
MATL=$("$ADAPTER" read --materialize "$WORK/specs" legacy)
check "A9: materialize still surfaces the legacy comment token" "grep -qF '| clean-checkout | ok |' \"$MATL\""

# ---- A11: an idempotent no-op writes nothing -------------------------------------------
BEFORE=$(nrows legacy)
"$ADAPTER" transition legacy in-review orchestrator repeat 0 0 >/dev/null 2>&1
check "A11: transition to the current state adds no row" "[ \"\$(nrows legacy)\" = \"$BEFORE\" ]"

# ---- A12: the table body is capped -----------------------------------------------------
mktask cap
"$ADAPTER" create --file "$WORK/cap.md" --folder pending >/dev/null 2>&1
i=0
while [ $i -lt 10 ]; do
  if [ $((i % 2)) -eq 0 ]; then ACFW_LOG_ROW_CAP=5 "$ADAPTER" transition cap in-progress orchestrator "churn $i" 0 0 >/dev/null 2>&1
  else ACFW_LOG_ROW_CAP=5 "$ADAPTER" transition cap pending orchestrator "churn $i" 0 0 >/dev/null 2>&1; fi
  i=$((i + 1))
done
check "A12: the Transition Log body is capped at ACFW_LOG_ROW_CAP" "[ \"\$(nrows cap)\" -le 5 ]"
check "A12b: the document is still well-formed after churn" "body_of cap | grep -q '^## Implementation Notes'"

# ---- A13: a document with no table must never lose a row -------------------------------
# This is the shape phase9-adapter-multica.test.sh's mat-tok fixture uses.
cat > "$WORK/notable.md" <<'EOF'
# Task: notable

## Metadata

- **ID**: notable
- **Status**: pending
- **Worktree**: slug-notable
- **Dependencies**: none
- **Rejection Count**: 0
- **Block-Count**: 0

## Description

no transition log table here
EOF
"$ADAPTER" create --file "$WORK/notable.md" --folder pending >/dev/null 2>&1
"$ADAPTER" log-event notable --row "$TOKEN" >/dev/null 2>&1
check "A13: a table-less document keeps the row (EOF fallback)" "body_of notable | grep -qF '| clean-checkout | ok |'"

# ---- A14: failure handling is asymmetric by design --------------------------------------
mktask fail
"$ADAPTER" create --file "$WORK/fail.md" --folder pending >/dev/null 2>&1
ERR="$WORK/fail.err"
FAKE_FAIL_UPDATE=1 "$ADAPTER" transition fail in-progress orchestrator dispatch 0 0 >/dev/null 2>"$ERR"; TRC=$?
check "A14a: a lost row does not fail an already-committed transition" "[ $TRC -eq 0 ]"
check "A14b: it WARNs instead of failing silently" "grep -q 'WARN:.*Transition Log row was not written' \"$ERR\""
check "A14c: the state move itself still landed" \
  "\"\$ADAPTER\" read fail | jq -e '.folder == \"in-progress\"' >/dev/null"
FAKE_FAIL_UPDATE=1 "$ADAPTER" log-event fail --row "$TOKEN" >/dev/null 2>&1; LRC=$?
check "A14d: log-event is STRICT — a lost token is a hard failure" "[ $LRC -ne 0 ]"

echo ""
echo "==================================================="
echo "Phase 12 multica transition-log test: $PASS passed, $FAIL failed"
echo "==================================================="
[ $FAIL -eq 0 ]
