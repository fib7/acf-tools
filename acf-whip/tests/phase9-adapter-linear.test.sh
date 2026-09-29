#!/usr/bin/env bash
# phase9-adapter-linear.test.sh — exercise the linear (linear.app) store adapter.
#
# TWO PARTS:
#  1. Emulator conformance (ALWAYS runs, no network). The test writes a small Node
#     GraphQL emulator that implements exactly the operations the adapter uses —
#     issueCreate/issueUpdate, attachmentCreate (upsert-by url+issueId), attachmentsForURL
#     (multi-hit), issues(filter by label, nested attachments, Relay paging),
#     team(states/labels)/teams(by key), commentCreate + issue comments, issueLabelCreate,
#     issueRelationCreate, viewer — persisting state in a JSON file. It pins the two
#     doc-verified behaviors the adapter leans on: attachment UPSERT keyed by url+issueId,
#     and attachmentsForURL returning every attachment that carries the exact URL. We then
#     point the frozen store-conformance spec at the adapter (must be 36/36), and add
#     linear-specific assertions the backend-agnostic suite can't express.
#  2. Live path (only when LINEAR_TEST_API_KEY AND LINEAR_TEST_TEAM are set) — otherwise a
#     SKIP note; we NEVER touch the real API without those vars.
#
# Requires node (already a repo test dependency) and jq (required by the adapter).

set -u
ACF_WHIP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ACF_WHIP/adapters/linear/acfw-store-linear"
[ -x "$ADAPTER" ] || { echo "FATAL: linear adapter not executable: $ADAPTER" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed (required by the linear emulator/test)"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq not installed (required by the linear adapter)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/acfw-p9linear.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
EMU="$WORK/linear-emulator.js"
STATE="$WORK/state.json"

# ---- the GraphQL emulator (no network; a JSON-file-backed fake of api.linear.app) ----
cat > "$EMU" <<'EMUJS'
'use strict';
const fs = require('fs');
const stateFile = process.argv[2];
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', d => input += d);
process.stdin.on('end', () => {
  const out = o => process.stdout.write(JSON.stringify(o));
  let req;
  try { req = JSON.parse(input); } catch (e) { out({ errors: [{ message: 'bad request json: ' + e.message }] }); return; }
  const q = String(req.query || '');
  const v = req.variables || {};
  let st;
  try { st = JSON.parse(fs.readFileSync(stateFile, 'utf8')); } catch (e) { out({ errors: [{ message: 'state read: ' + e.message }] }); return; }
  let data;
  try { data = dispatch(q, v, st); }
  catch (e) { out({ errors: [{ message: String((e && e.message) || e) }] }); return; }
  try { fs.writeFileSync(stateFile, JSON.stringify(st)); } catch (e) { out({ errors: [{ message: 'state write: ' + e.message }] }); return; }
  out({ data });
});

function dispatch(q, v, st) {
  const has = s => q.indexOf(s) !== -1;
  const nid = p => { st.seq = (st.seq || 0) + 1; return p + '-' + st.seq; };
  const nowISO = () => { st.seq = (st.seq || 0) + 1; return new Date(1752566400000 + st.seq * 1000).toISOString(); };
  const issueRef = iid => { const i = (st.issues || []).find(x => x.id === iid); return i ? { id: i.id, identifier: i.identifier } : null; };
  const stateOf = sid => { const s = (st.states || []).find(x => x.id === sid); return s ? { id: s.id, name: s.name, type: s.type } : null; };

  // --- mutations (specific field tokens first) ---
  if (has('issueCreate')) {
    const inp = v.input || {};
    st.issueSeq = (st.issueSeq || 0) + 1;
    const team = (st.teams || []).find(t => t.id === inp.teamId);
    const iss = {
      id: 'iss-' + st.issueSeq,
      identifier: (team ? team.key : 'T') + '-' + st.issueSeq,
      title: inp.title || '', description: inp.description || '',
      priority: inp.priority || 0, stateId: inp.stateId || '', teamId: inp.teamId || '',
      labelIds: inp.labelIds || [], parentId: inp.parentId || null, projectId: inp.projectId || null
    };
    st.issues = st.issues || []; st.issues.push(iss);
    return { issueCreate: { issue: { id: iss.id, identifier: iss.identifier }, success: true } };
  }
  if (has('issueUpdate')) {
    const iss = (st.issues || []).find(x => x.id === v.id);
    if (!iss) return { issueUpdate: { success: false } };
    const inp = v.input || {};
    if ('stateId' in inp) iss.stateId = inp.stateId;
    if ('description' in inp) iss.description = inp.description;
    if ('priority' in inp) iss.priority = inp.priority;
    if ('parentId' in inp) iss.parentId = inp.parentId;
    return { issueUpdate: { success: true } };
  }
  if (has('issueLabelCreate')) {
    st.labels = st.labels || [];
    let lbl = st.labels.find(l => l.name === v.name && l.teamId === v.teamId);
    if (!lbl) { lbl = { id: nid('lbl'), name: v.name, teamId: v.teamId }; st.labels.push(lbl); }
    return { issueLabelCreate: { issueLabel: { id: lbl.id, name: lbl.name }, success: true } };
  }
  if (has('issueRelationCreate')) {
    const inp = v.input || {};
    st.relations = st.relations || [];
    st.relations.push({ id: nid('rel'), issueId: inp.issueId, relatedIssueId: inp.relatedIssueId, type: inp.type });
    return { issueRelationCreate: { success: true } };
  }
  if (has('attachmentCreate')) {
    const inp = v.input || {};
    st.attachments = st.attachments || [];
    // UPSERT keyed by (url, issueId): the doc-verified idempotency contract.
    let att = st.attachments.find(a => a.url === inp.url && a.issueId === inp.issueId);
    if (att) { att.title = inp.title; att.subtitle = inp.subtitle; att.metadata = inp.metadata || {}; }
    else { att = { id: nid('att'), url: inp.url, issueId: inp.issueId, title: inp.title, subtitle: inp.subtitle, metadata: inp.metadata || {} }; st.attachments.push(att); }
    return { attachmentCreate: { attachment: { id: att.id, url: att.url }, success: true } };
  }
  if (has('attachmentsForURL')) {
    // Reverse lookup by EXACT url — may return >1 node when several issues carry it.
    const nodes = (st.attachments || []).filter(a => a.url === v.url)
      .map(a => ({ id: a.id, url: a.url, metadata: a.metadata || {}, issue: issueRef(a.issueId) }));
    return { attachmentsForURL: { nodes } };
  }
  if (has('commentCreate')) {
    const inp = v.input || {};
    st.comments = st.comments || [];
    const c = { id: nid('cmt'), issueId: inp.issueId, body: inp.body || '', createdAt: nowISO() };
    st.comments.push(c);
    return { commentCreate: { comment: { id: c.id }, success: true } };
  }
  // --- queries ---
  if (has('teams(')) {
    const nodes = (st.teams || []).filter(t => t.key === v.key).map(t => ({ id: t.id, key: t.key }));
    return { teams: { nodes } };
  }
  if (has('team(')) {
    const team = (st.teams || []).find(t => t.id === v.id) || { id: v.id };
    if (has('states')) {
      const nodes = (st.states || []).filter(s => s.teamId === v.id).map(s => ({ id: s.id, name: s.name, type: s.type, position: s.position }));
      return { team: { id: team.id, states: { nodes } } };
    }
    if (has('labels')) {
      const nodes = (st.labels || []).filter(l => l.teamId === v.id).map(l => ({ id: l.id, name: l.name }));
      return { team: { id: team.id, labels: { nodes } } };
    }
    return { team: { id: team.id } };
  }
  if (has('issues(')) {
    const labelIds = (st.labels || []).filter(l => l.name === v.label).map(l => l.id);
    const nodes = (st.issues || [])
      .filter(iss => (iss.labelIds || []).some(lid => labelIds.indexOf(lid) !== -1))
      .map(iss => ({
        id: iss.id, identifier: iss.identifier, title: iss.title, priority: iss.priority,
        state: stateOf(iss.stateId),
        attachments: { nodes: (st.attachments || []).filter(a => a.issueId === iss.id).map(a => ({ url: a.url, metadata: a.metadata || {} })) }
      }));
    // Small fixtures fit one Relay page.
    return { issues: { pageInfo: { hasNextPage: false, endCursor: null }, nodes } };
  }
  if (has('issue(')) {
    const iss = (st.issues || []).find(x => x.id === v.id);
    if (has('comments')) {
      // Fault injection: LIN_EMU_FAIL_COMMENTS=<issueId>[,<issueId>...] makes the comments read for those
      // issues answer with a GraphQL error on EVERY attempt, so the adapter's one retry fails as well.
      // Each refusal is appended to LIN_EMU_FAIL_LOG, which is how the test proves the retry happened.
      const failIds = String(process.env.LIN_EMU_FAIL_COMMENTS || '').split(',').filter(Boolean);
      if (failIds.indexOf(v.id) !== -1) {
        if (process.env.LIN_EMU_FAIL_LOG) fs.appendFileSync(process.env.LIN_EMU_FAIL_LOG, v.id + '\n');
        throw new Error('Rate limit exceeded (emulated)');
      }
      const nodes = (st.comments || []).filter(c => c.issueId === v.id)
        .sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0))
        .map(c => ({ body: c.body, createdAt: c.createdAt }));
      return { issue: iss ? { id: iss.id, comments: { nodes } } : null };
    }
    return { issue: iss ? { id: iss.id, description: iss.description } : null };
  }
  if (has('viewer')) return { viewer: { id: 'viewer-1' } };
  if (has('projects(')) {
    const nodes = (st.projects || []).filter(p => p.name === v.name).map(p => ({ id: p.id, name: p.name }));
    return { projects: { nodes } };
  }
  throw new Error('unsupported operation: ' + q.slice(0, 80));
}
EMUJS

# ---- seed the emulator: team ENG + a full workflow-state set (one per type) ----
cat > "$STATE" <<'SEEDJSON'
{
  "teams": [{ "id": "team-eng", "key": "ENG" }],
  "states": [
    { "id": "st-backlog", "name": "Backlog",     "type": "backlog",   "position": 0, "teamId": "team-eng" },
    { "id": "st-todo",    "name": "Todo",        "type": "unstarted", "position": 1, "teamId": "team-eng" },
    { "id": "st-prog",    "name": "In Progress", "type": "started",   "position": 2, "teamId": "team-eng" },
    { "id": "st-review",  "name": "In Review",   "type": "started",   "position": 3, "teamId": "team-eng" },
    { "id": "st-done",    "name": "Done",        "type": "completed", "position": 4, "teamId": "team-eng" },
    { "id": "st-cancel",  "name": "Canceled",    "type": "canceled",  "position": 5, "teamId": "team-eng" }
  ],
  "labels": [], "issues": [], "attachments": [], "comments": [], "relations": [], "projects": [],
  "seq": 0, "issueSeq": 0
}
SEEDJSON

# ---- env: point the adapter at the emulator, with a fixed URL namespace ----
export LINEAR_API_KEY="test-key"
export ACFW_LINEAR_TEAM="ENG"
export ACFW_LINEAR_LABEL="acf-whip"
export ACFW_LINEAR_URL_NS="conftest"
export ACFW_LINEAR_TRANSPORT="node '$EMU' '$STATE'"

kurl() { printf 'https://acfw.fib7.ai/conftest/%s' "$1"; }
mkdoc() { # <stem> <worktree> <deps>
  cat <<EOF
# Task: Linear $1

## Metadata

- **ID**: $1
- **Status**: pending
- **Priority**: high
- **Assigned Agent**: test-agent
- **Worktree**: $2
- **PR Group**: $2
- **Touches Globs**: none
- **Dependencies**: $3
- **Rejection Count**: 0
- **Block-Count**: 0

## Description

Linear-specific probe for $1.
EOF
}

# ---- 1. the frozen conformance spec ----------------------------------------
echo "== store conformance against the linear adapter (emulated api.linear.app) =="
ADAPTER="$ADAPTER" bash "$ACF_WHIP/tests/phase9-store-conformance.test.sh"
CONF_RC=$?

# ---- 2. linear-specific assertions -----------------------------------------
echo
echo "== linear-specific checks =="
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# (A) duplicate create → typed conflict (exit 4), no side effect.
mkdoc lin-dup slug-dup none > "$WORK/lin-dup.md"
"$ADAPTER" create --file "$WORK/lin-dup.md" --folder pending >/dev/null 2>&1; R1=$?
"$ADAPTER" create --file "$WORK/lin-dup.md" --folder pending >/dev/null 2>&1; R2=$?
if [ $R1 -eq 0 ] && [ $R2 -eq 4 ]; then ok "duplicate create is exit 4 (create is never an upsert)"; else bad "dup create rc: first=$R1 second=$R2 (want 0 then 4)"; fi

# (B) native workflow-state drift is repaired by doctor --fix.
mkdoc lin-drift slug-drift none > "$WORK/lin-drift.md"
"$ADAPTER" create --file "$WORK/lin-drift.md" --folder pending >/dev/null 2>&1
DIID=$(jq -r --arg u "$(kurl lin-drift)" '.attachments[] | select(.url==$u) | .issueId' "$STATE")
# corrupt the native state (drift it away from the pending→Todo projection)
jq --arg id "$DIID" '(.issues[] | select(.id==$id) | .stateId) = "st-backlog"' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
DOC_OUT=$("$ADAPTER" doctor 2>/dev/null || true)
if printf '%s\n' "$DOC_OUT" | grep -q '^REPAIRABLE|status-drift|lin-drift|'; then ok "doctor reports native status-drift"; else bad "doctor did not report status-drift (got: $DOC_OUT)"; fi
"$ADAPTER" doctor --fix >/dev/null 2>&1 || true
FIXED=$(jq -r --arg id "$DIID" '.issues[] | select(.id==$id) | .stateId' "$STATE")
if [ "$FIXED" = "st-todo" ]; then ok "doctor --fix repaired native state (→ Todo)"; else bad "post-fix stateId=$FIXED (want st-todo)"; fi

# (C) materialize renders the audit trail incl. the clean-checkout token.
mkdoc lin-mat slug-mat none > "$WORK/lin-mat.md"
"$ADAPTER" create --file "$WORK/lin-mat.md" --folder pending >/dev/null 2>&1
"$ADAPTER" log-event lin-mat --row '| 2026-07-15 10:00:00 | clean-checkout | ok | clean-checkout-before-task | slug-mat | worktree/slug-mat |' >/dev/null 2>&1
mkdir -p "$WORK/specs"
MAT=$("$ADAPTER" read --materialize "$WORK/specs" lin-mat 2>/dev/null)
if [ -f "$MAT" ] && grep -q '## Store Audit Trail' "$MAT" && grep -q '| clean-checkout | ok |' "$MAT"; then
  ok "materialized doc carries ## Store Audit Trail + clean-checkout token"
else
  bad "materialized doc missing audit trail or token (path: $MAT)"
fi

# (D) attachment metadata upsert does NOT duplicate attachments.
mkdoc lin-up slug-up none > "$WORK/lin-up.md"
"$ADAPTER" create --file "$WORK/lin-up.md" --folder pending >/dev/null 2>&1
"$ADAPTER" transition lin-up in-progress orchestrator "dispatch" 0 0 >/dev/null 2>&1
"$ADAPTER" transition lin-up completed  specialist   "done"     0 0 >/dev/null 2>&1
"$ADAPTER" transition lin-up in-review  orchestrator "review"   0 0 >/dev/null 2>&1
NATT=$(jq --arg u "$(kurl lin-up)" '[.attachments[] | select(.url==$u)] | length' "$STATE")
if [ "$NATT" = "1" ]; then ok "attachment upsert kept exactly one key attachment across 3 transitions"; else bad "key attachment count=$NATT (want 1 — upsert should update in place)"; fi

# (E) snapshot exposes the clean-checkout token for an in-review task (comment scan).
SNAP=$("$ADAPTER" snapshot 2>/dev/null)
HAS_TOK=$(printf '%s' "$SNAP" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{let j=JSON.parse(d);let t=j.tasks.find(x=>x.stem==="lin-up");process.stdout.write(String(t&&t.hasCleanCheckoutToken))}catch(e){process.stdout.write("ERR")}})' 2>/dev/null || echo ERR)
# lin-up carries no clean-checkout comment, so its token flag must be false; lin-mat is pending (not scanned) → also false. Assert the scan ran and is boolean-correct for lin-up.
if [ "$HAS_TOK" = "false" ]; then ok "snapshot token scan returns a correct boolean (lin-up in-review, no token → false)"; else bad "snapshot hasCleanCheckoutToken for lin-up = $HAS_TOK (want false)"; fi

# (G) a token read that FAILS is unknown (null), never absent (false). false is the value the review
# gate parks a task on, so projecting a rate-limited comments read as false started a park -> unblock
# -> re-dispatch -> park livelock driven by nothing but the rate limit. lin-unk HAS its token: the
# failed read must not turn that into false, and must not guess true either.
for s in lin-tok lin-unk; do
  mkdoc "$s" "slug-${s#lin-}" none > "$WORK/$s.md"
  "$ADAPTER" create --file "$WORK/$s.md" --folder pending >/dev/null 2>&1
  "$ADAPTER" transition "$s" in-progress orchestrator "dispatch" 0 0 >/dev/null 2>&1
  "$ADAPTER" log-event "$s" --row "| 2026-07-15 10:00:00 | clean-checkout | ok | clean-checkout-before-task | slug-${s#lin-} | worktree/slug-${s#lin-} |" >/dev/null 2>&1
  "$ADAPTER" transition "$s" completed specialist "done" 0 0 >/dev/null 2>&1
  "$ADAPTER" transition "$s" in-review orchestrator "review" 0 0 >/dev/null 2>&1
done
UIID=$(jq -r --arg u "$(kurl lin-unk)" '.attachments[] | select(.url==$u) | .issueId' "$STATE")
tok_of() { printf '%s' "$1" | jq -r --arg s "$2" '.tasks[] | select(.stem==$s) | .hasCleanCheckoutToken | tostring' 2>/dev/null; }
: > "$WORK/fail.log"
GSNAP=$(LIN_EMU_FAIL_COMMENTS="$UIID" LIN_EMU_FAIL_LOG="$WORK/fail.log" "$ADAPTER" snapshot 2>"$WORK/g.err")
G_UNK=$(tok_of "$GSNAP" lin-unk); G_TOK=$(tok_of "$GSNAP" lin-tok); G_NO=$(tok_of "$GSNAP" lin-up)
if [ "$G_UNK" = "null" ]; then ok "a failed comments read projects hasCleanCheckoutToken: null"; else bad "lin-unk token = $G_UNK (want null)"; fi
if [ "$G_TOK" = "true" ] && [ "$G_NO" = "false" ]; then ok "...while readable issues still answer true (lin-tok) and false (lin-up)"; else bad "lin-tok=$G_TOK (want true) lin-up=$G_NO (want false)"; fi
G_TRIES=$(grep -c . "$WORK/fail.log" || true)
if [ "${G_TRIES:-0}" = "2" ]; then ok "the read was retried once before being reported unknown"; else bad "failed comments reads for lin-unk: ${G_TRIES:-0} (want 2: one try + one retry)"; fi
if grep -q 'reported as unknown (hasCleanCheckoutToken: null)' "$WORK/g.err"; then ok "the stderr WARN says unknown, not 'no token'"; else bad "WARN missing or still says absent: $(cat "$WORK/g.err")"; fi
G_OK=$("$ADAPTER" snapshot 2>/dev/null)
if [ "$(tok_of "$G_OK" lin-unk)" = "true" ]; then ok "...and once the read works again the same issue reads true"; else bad "lin-unk without the fault = $(tok_of "$G_OK" lin-unk) (want true)"; fi

# The null must survive the dispatcher's raw path too: adapter -> acfw-enrich-snapshot.sh -> relay
# post-stage. The enricher used `// false`, which in jq erases null exactly as it fills a missing key.
DREPO="$WORK/drepo"
git init -q -b trunk "$DREPO" && ( cd "$DREPO" && git config user.email t@t && git config user.name t \
  && echo seed > seed && git add -A && git commit -qm seed ) >/dev/null 2>&1
DSNAP=$(LIN_EMU_FAIL_COMMENTS="$UIID" ACFW_STORE=linear ACFW_TRUNK_ROOT="$DREPO" ACFW_TRUNK_BRANCH=trunk \
  bash "$ACF_WHIP/skills/lib/bin/acfw-store" snapshot 2>/dev/null)
if [ "$(tok_of "$DSNAP" lin-unk)" = "null" ] && [ "$(tok_of "$DSNAP" lin-tok)" = "true" ] && [ "$(tok_of "$DSNAP" lin-up)" = "false" ]; then
  ok "null survives enrichment through acfw-store snapshot (true/false unchanged)"
else
  bad "through the dispatcher: lin-unk=$(tok_of "$DSNAP" lin-unk) lin-tok=$(tok_of "$DSNAP" lin-tok) lin-up=$(tok_of "$DSNAP" lin-up) (want null/true/false)"
fi
if printf '%s' "$DSNAP" | jq -e '.store == "linear" and .raw == null and (.relay.tasks == (.tasks|length))' >/dev/null 2>&1; then
  ok "...and that snapshot really took the raw path (store injected, enriched, relay header)"
else
  bad "dispatcher snapshot did not look enriched: $(printf '%s' "$DSNAP" | head -c 200)"
fi

echo

# (F) --quiet must not swallow the gate decision. DONE LAST: it corrupts the fixture board.
# The assertion this replaces compared 0 to 0 — no fixture in this suite ever produced a FATAL, so
# reverting the adapter's --quiet branch to "suppress everything" still went ALL GREEN, while in
# production acfw-store recomputes ok= from the lines it receives and would hand /go's startup hard
# gate ok=true on a FATAL board. multica got the inducer plus an anti-vacuity check in 3.3.0; linear
# did not. Blank one key attachment's metadata to trip the adapter's missing-metadata FATAL.
BLANK_URL=$(kurl lin-up)
jq --arg u "$BLANK_URL" '(.attachments[] | select(.url==$u) | .metadata) = {}' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
LF=$("$ADAPTER" doctor 2>/dev/null);         LF_N=$(printf '%s\n' "$LF" | grep -c '^FATAL|' || true); LF_N=${LF_N//[^0-9]/}
LQ=$("$ADAPTER" doctor --quiet 2>/dev/null); LQ_N=$(printf '%s\n' "$LQ" | grep -c '^FATAL|' || true); LQ_N=${LQ_N//[^0-9]/}
if [ "${LF_N:-0}" -ge 1 ]; then ok "the fixture really does carry a native FATAL (guards against a vacuous compare)"; else bad "fixture produced no FATAL (LF_N=$LF_N) — the --quiet compare below would be vacuous"; fi
if [ "${LQ_N:-0}" -eq "${LF_N:-0}" ]; then ok "--quiet keeps every FATAL the verbose run reported"; else bad "--quiet FATAL count=$LQ_N verbose=$LF_N"; fi
if ! printf '%s\n' "$LQ" | grep -qE '^(WARN|REPAIRABLE)\|'; then ok "--quiet still suppresses the advisories"; else bad "--quiet leaked an advisory line"; fi
LF_OK=$(printf '%s\n' "$LF" | sed -n 's/.*|ok=\(.*\)/\1/p' | tail -1)
LQ_OK=$(printf '%s\n' "$LQ" | sed -n 's/.*|ok=\(.*\)/\1/p' | tail -1)
if [ "$LF_OK" = "$LQ_OK" ]; then ok "--quiet and verbose agree on ok="; else bad "ok= disagrees: verbose='$LF_OK' quiet='$LQ_OK'"; fi

echo "phase9-adapter-linear: conformance rc=$CONF_RC; linear-specific $PASS passed, $FAIL failed"

# ---- 3. live path (guarded) ------------------------------------------------
echo
if [ -n "${LINEAR_TEST_API_KEY:-}" ] && [ -n "${LINEAR_TEST_TEAM:-}" ]; then
  echo "== linear adapter conformance (LIVE api.linear.app, team ${LINEAR_TEST_TEAM}) =="
  echo "  NOTE: the live path creates conf-a/conf-b/etc. issues in team ${LINEAR_TEST_TEAM}; clean them up manually."
  (
    unset ACFW_LINEAR_TRANSPORT
    export LINEAR_API_KEY="$LINEAR_TEST_API_KEY"
    export ACFW_LINEAR_TEAM="$LINEAR_TEST_TEAM"
    [ -n "${LINEAR_TEST_PROJECT:-}" ] && export ACFW_LINEAR_PROJECT="$LINEAR_TEST_PROJECT"
    export ACFW_LINEAR_URL_NS="acfw-livetest"
    "$ADAPTER" init >/dev/null || { echo "  live init failed (auth/team/endpoint)"; exit 1; }
    ADAPTER="$ADAPTER" bash "$ACF_WHIP/tests/phase9-store-conformance.test.sh"
  )
  LIVE_RC=$?
  echo "  live conformance rc=$LIVE_RC"
else
  echo "SKIP: linear adapter live test needs LINEAR_TEST_API_KEY and LINEAR_TEST_TEAM (never touches the real API without them)"
  LIVE_RC=0
fi

[ "$CONF_RC" -eq 0 ] && [ "$FAIL" -eq 0 ] && [ "$LIVE_RC" -eq 0 ]
