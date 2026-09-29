#!/usr/bin/env bash
# make-fixtures.sh — regenerates the recorded GapTrap replies (*.http) that phase21-gaptrap-driver replays.
# Shapes follow gaptrap-live: mcp.ts ok()/fail() envelopes, specService.ts status/report/list cores,
# firestore_client.py StoredReport + gap dict. Values are synthetic.
set -eu
FIX="$(cd "$(dirname "$0")" && pwd)"
cd "$FIX"
S1=Xy12pQ7rT3uV9wZ1aB4c S2=Qa77mN2bV8cX5zL0kJ3h CH=Ch1ldR9sT4uV6wX8yZ0a DR=Dr4ftK2mP7nQ5rS3tU1v OT=Oth3rJ8hG6fD4sA2qW0e
ORG=org7f3k2m9 UID_=u9Hq2Lw5Zp
TS=2026-09-28T10:00:00.000Z

rpc_ok() { # <file> <payload-json>  -> 200 + tools/call result with one JSON text block
  { echo 200; jq -cn --argjson p "$2" '{jsonrpc:"2.0",id:1,result:{content:[{type:"text",text:($p|tojson)}]}}'; } > "$1.http"
}
rpc_err() { # <file> <code> <message>  -> 200 + isError (mcp.ts fail())
  { echo 200; jq -cn --arg c "$2" --arg m "$3" '{jsonrpc:"2.0",id:1,result:{content:[{type:"text",text:({error:{code:$c,message:$m}}|tojson)}],isError:true}}'; } > "$1.http"
}
http_err() { # <file> <status> <body-json>
  { echo "$2"; printf '%s\n' "$3"; } > "$1.http"
}
sse_of() { # <src> <dst>  -> the same reply framed as one SSE event
  { head -n 1 "$1.http"; printf 'event: message\n'; printf 'data: %s\n\n' "$(sed 1d "$1.http")"; } > "$2.http"
}

schema() { jq -cn --argjson p "$1" --argjson r "$2" '{type:"object",properties:$p,required:$r,additionalProperties:false,"$schema":"http://json-schema.org/draft-07/schema#"}'; }
CREATE_P='{"spec":{"type":"string","minLength":1,"description":"The spec text to analyze."},"format":{"type":"string","enum":["text","markdown"]},"filename":{"type":["string","null"]},"mode":{"type":"string","enum":["standard","multipass"]},"templateId":{"type":"string"},"folderId":{"type":["string","null"],"description":"Target folder id; omit for no folder."}}'
SPECID_P='{"specId":{"type":"string","minLength":1}}'
tool() { jq -cn --arg n "$1" --arg d "$2" --argjson s "$3" '{name:$n,description:$d,inputSchema:$s}'; }
BASE=$(jq -cn \
  --argjson a "$(tool create_spec "Submit a spec for analysis. Returns immediately with {specId, status:'pending'}; analysis runs asynchronously." "$(schema "$CREATE_P" '["spec"]')")" \
  --argjson b "$(tool get_analysis_status "Read a spec's analysis status and light metadata." "$(schema "$SPECID_P" '["specId"]')")" \
  --argjson c "$(tool get_analysis_report "Read a spec's latest analysis report plus feedback and convention-note resolutions. \`report\` is null until analysis completes." "$(schema "$SPECID_P" '["specId"]')")" \
  --argjson d "$(tool list_specs "List the caller's specs, newest first, cursor-paginated." "$(schema '{"limit":{"type":"integer","exclusiveMinimum":0},"cursor":{"type":"string"}}' '[]')")" \
  --argjson e "$(tool list_folders "List the caller's folders." "$(schema '{}' '[]')")" \
  --argjson f "$(tool create_folder "Create a folder." "$(schema '{"name":{"type":"string","minLength":1}}' '["name"]')")" \
  --argjson g "$(tool move_spec "Move a spec into a folder." "$(schema '{"specId":{"type":"string","minLength":1},"folderId":{"type":["string","null"]}}' '["specId"]')")" \
  '[$a,$b,$c,$d,$e,$f,$g]')
GETSPEC=$(tool get_spec "Read a spec's submitted content." "$(schema "$SPECID_P" '["specId"]')")
ANSW=$(tool list_answers "List the answers recorded against a spec's gap questions." "$(schema "$SPECID_P" '["specId"]')")
CREATE_FULL=$(tool create_spec "Submit a spec for analysis." "$(schema "$(jq -cn --argjson p "$CREATE_P" '$p + {parentSpecId:{type:"string"},idempotencyKey:{type:"string"}}')" '["spec"]')")

list_of() { { echo 200; jq -cn --argjson t "$1" '{jsonrpc:"2.0",id:1,result:{tools:$t}}'; } > "$2.http"; }
list_of "$BASE" tools-list-base
list_of "$(jq -cn --argjson b "$BASE" --argjson a "$ANSW" '$b + [$a]')" tools-list-answers
list_of "$(jq -cn --argjson b "$BASE" --argjson s "$GETSPEC" '$b + [$s]')" tools-list-getspec
list_of "$(jq -cn --argjson b "$BASE" --argjson c "$CREATE_FULL" --argjson s "$GETSPEC" --argjson a "$ANSW" '[$c] + $b[1:] + [$s, $a]')" tools-list-full

rpc_ok create-ok   "{\"specId\":\"$S1\",\"status\":\"pending\"}"
rpc_ok create-ok-2 "{\"specId\":\"$S2\",\"status\":\"pending\"}"

st_org() { rpc_ok "$1" "$(jq -cn --arg s "$S1" --arg o "$ORG" --arg st "$2" --arg ts "$TS" --arg t "$3" '{specId:$s,orgId:$o,status:$st,createdAt:$ts,generatedTitle:(if $t=="" then null else $t end),analysisMode:"standard",folderId:null}')"; }
st_org status-pending-org   pending   ""
st_org status-analyzing-org analyzing ""
st_org status-completed-org completed "Owner seat increase notice"
st_org status-failed-org    failed    ""
rpc_ok status-completed-personal "$(jq -cn --arg s "$S1" --arg u "$UID_" --arg ts "$TS" '{specId:$s,uid:$u,status:"completed",createdAt:$ts,generatedTitle:"Owner seat increase notice",analysisMode:"standard",folderId:null}')"

G1='{"gap_id":"3f0c9a52-1d7e-4b8a-9c11-2e5f7a6b8d01","pattern":"undefined_behavior","severity":"high","title":"Per-seat price has no billing period","description":"The notice quotes a per-seat price but never says whether it is monthly or annual.","impact_summary":"Owners may misread the charge and dispute it.","extraction_text":"the per-seat price","source_offset":[211,229],"resolution_questions":[{"question":"Is the per-seat price shown per month or per year? (default: per month)","impact":"Sets the unit the email quotes."}]}'
G2='{"gap_id":"8b2d4e6f-0a1c-4d3e-8f5a-6b7c9d0e1f23","pattern":"missing_state_handling","severity":"medium","title":"No behavior when the audit write fails","description":"Nothing says what happens to the seat change when the audit row cannot be written.","impact_summary":"A silent audit gap on billing events.","extraction_text":"Record every seat change","source_offset":[252,276],"resolution_questions":[{"question":"Should a failed audit write block the seat change?","impact":"Decides consistency versus availability."},{"question":"How long are audit rows kept? (default: forever)","impact":""}]}'
# G3 is write-2's synthesized card for an absent required template section, in the exact shape
# gap_detector.py synthesize_missing_section_gaps builds and firestore_client.py stores: a stable
# section-keyed gap_id (not a uuid), "<Title> is empty", extraction_text "<Title> (section is empty)",
# source_offset [0,0], and the template's missing_question (feature_contract.yaml functional_acceptance).
G3_ID="missing-section-functional_acceptance-$(printf '%s' functional_acceptance | shasum -a 1 | cut -c1-16)"
G3=$(jq -cn --arg id "$G3_ID" --arg t "Functional Acceptance Criteria" '{gap_id:$id, pattern:"missing_required_section", severity:"high",
  title:("\($t) is empty"), description:("The \($t) section is required but the spec leaves it empty. It must be filled before the spec is build-ready."),
  impact_summary:("Without the \($t) section, an AI agent has no grounding for this required part of the spec."),
  extraction_text:("\($t) (section is empty)"), source_offset:[0,0],
  resolution_questions:[{question:"What should be true before, what does the user do, and what should they see afterwards?",
                         impact:("The \($t) section stays empty and blocks the verdict until it is filled.")}]}')
# plan2.md revision: fresh uuid4 gap_ids, moved offsets, a quote that now wraps a line and changes case.
G1R='{"gap_id":"e1f2a3b4-c5d6-4e7f-8a9b-0c1d2e3f4a5b","pattern":"undefined_behavior","severity":"high","title":"Per-seat price has no billing period","description":"Still no billing period.","impact_summary":"Owners may misread the charge.","extraction_text":"the Per-Seat\nprice","source_offset":[295,313],"resolution_questions":[{"question":"Is the per-seat price shown per month or per year? (default: per month)","impact":""}]}'
G2R='{"gap_id":"0a9b8c7d-6e5f-4a3b-9c2d-1e0f9a8b7c6d","pattern":"missing_state_handling","severity":"medium","title":"Audit failure behavior is undefined","description":"Unchanged.","impact_summary":"","extraction_text":"Record every seat change","source_offset":[365,389],"resolution_questions":[]}'
# Same quote as G1R under a different pattern, with camelCase keys (the report's key casing is mixed).
G4R='{"gap_id":"5d6e7f80-9a1b-4c2d-8e3f-4a5b6c7d8e9f","pattern":"contradiction","severity":"low","title":"Price wording differs from the billing page","description":"The billing page says per member.","impactSummary":"","extractionText":"the Per-Seat\nprice","sourceOffset":[295,313],"resolutionQuestions":[{"question":"Which wording is canonical? (default: per seat)","impact":""}]}'

report() { # <file> <verdict> <contractStatus> <gaps-json> <summary>
  rpc_ok "$1" "$(jq -cn --arg s "$S1" --arg o "$ORG" --arg v "$2" --arg cs "$3" --argjson g "$4" --arg sum "$5" --arg ts "$TS" '
    ($g | map(.severity) ) as $sev
    | {specId:$s, orgId:$o, feedback:{}, conventionResolutions:{},
       report:{report_id:"r-0001", verdict:$v, verdictSummary:$sum, completeness_score:62, confidence_score:80,
               analysis_time_ms:12840, total_gaps:($g|length),
               critical:($sev|map(select(.=="critical"))|length), high:($sev|map(select(.=="high"))|length),
               medium:($sev|map(select(.=="medium"))|length), low:($sev|map(select(.=="low"))|length),
               gaps:$g, contract:(if $cs=="ready" then {outcome_and_why:{value:"Owners know what a new seat costs"}} else null end),
               linter:null, handoffGate:null, contractStatus:$cs, createdAt:$ts, analysisMode:"standard",
               conventionNotes:[], kbProvenance:null}}')"
}
report report-extracting-go   GO    extracting "[$G1,$G2]"      "Two findings, none blocking."
report report-extracting-nogo NO-GO extracting "[$G1,$G2]"      "An undecided item blocks the handoff."
report report-ready-nogo      NO-GO ready      "[$G1,$G2,$G3]"  "A required template section is missing."
report report-rerun-go        GO    ready      "[$G1R,$G2R,$G4R]" "Three findings, none blocking."
rpc_ok report-null "$(jq -cn --arg s "$S1" --arg o "$ORG" '{specId:$s,orgId:$o,report:null,feedback:{},conventionResolutions:{}}')"

http_err err-401 401 '{"error":{"code":"unauthorized","message":"Invalid or revoked API key"}}'
http_err err-403 403 "{\"error\":{\"code\":\"plan_required\",\"requiredPlan\":\"solo\",\"scope\":\"$ORG\"}}"
http_err err-503 503 '{"error":{"code":"internal","message":"Internal server error"}}'
# A load balancer's 502 after the function ran, and a reply that never came (curl --max-time or a reset
# after the request was sent): for create_spec both leave the outcome unknown.
{ echo 502; echo '<html><body>502 Bad Gateway</body></html>'; } > err-502.http
echo 000 > err-000.http
# fake-transport reads "exit:<n>" as "exit with n and print nothing": 7 is curl's "failed to connect",
# a request that provably never left, so it is the one create_spec failure that is safe to resend.
echo exit:7 > conn-refused.http
# An uncaught throw inside create_spec (after GapTrap may have written the spec) reaches the client as
# isError with the SDK's plain text, not GapTrap's {error:{code}}.
{ echo 200; jq -cn '{jsonrpc:"2.0",id:1,result:{content:[{type:"text",text:"Deadline exceeded while reserving the spec unit"}],isError:true}}'; } > create-throw.http
rpc_err quota     quota_exceeded "Your team's spec quota is exhausted."
rpc_err too-large spec_too_large "Spec is too large (1200000 tokens; limit 1048576 tokens)."
rpc_err not-found NOT_FOUND      "Spec not found"
# The SDK wraps an unknown tool as isError with PLAIN text (mcp.js createToolError), not a JSON body.
{ echo 200; jq -cn '{jsonrpc:"2.0",id:1,result:{content:[{type:"text",text:"MCP error -32602: Tool get_spec not found"}],isError:true}}'; } > unknown-tool.http

sse_of create-ok sse-create-ok
sse_of report-ready-nogo sse-report-ready-nogo

CONTENT=$(cat plan2.md; printf x); CONTENT=${CONTENT%x}
SHA=$(printf '%s' "$CONTENT" | shasum -a 256 | awk '{print $1}')
rpc_ok get-spec "$(jq -cn --arg c "$CONTENT" --arg p "$S1" --arg h "$SHA" --arg ch "$CH" --arg o "$ORG" '{specId:$ch,content:$c,format:"markdown",parentSpecId:$p,contentSha256:$h,webUrl:("https://app.gaptrap.ai/orgs/"+$o+"/report/"+$ch)}')"
rpc_ok get-spec-badsha "$(jq -cn --arg c "$CONTENT" --arg p "$S1" --arg ch "$CH" '{specId:$ch,content:$c,format:"markdown",parentSpecId:$p,contentSha256:"0000000000000000000000000000000000000000000000000000000000000000"}')"
rpc_ok list-specs "$(jq -cn --arg s "$S1" --arg ch "$CH" --arg dr "$DR" --arg ot "$OT" '{specs:[
  {specId:$dr,createdAt:"2026-09-28T12:00:00.000Z",filename:null,status:"draft",verdict:null,gapCount:null,generatedTitle:null,isDraft:true,parentSpecId:$ch,parentSpecRef:{specId:$ch},createdBy:"u9Hq2Lw5Zp",folderId:null},
  {specId:$ch,createdAt:"2026-09-28T11:00:00.000Z",filename:"20260928-seat-notice.md",status:"completed",verdict:"GO",gapCount:null,generatedTitle:"Owner seat increase notice",isDraft:false,parentSpecId:$s,parentSpecRef:{specId:$s},createdBy:"u9Hq2Lw5Zp",folderId:null},
  {specId:$ot,createdAt:"2026-09-28T10:30:00.000Z",filename:"other.md",status:"completed",verdict:"NO-GO",gapCount:null,generatedTitle:"Unrelated",isDraft:false,parentSpecId:null,parentSpecRef:null,createdBy:"u9Hq2Lw5Zp",folderId:null},
  {specId:$s,createdAt:"2026-09-28T10:00:00.000Z",filename:"20260928-seat-notice.md",status:"completed",verdict:"NO-GO",gapCount:null,generatedTitle:"Owner seat increase notice",isDraft:false,parentSpecId:null,parentSpecRef:null,createdBy:"apikey:k1",folderId:null}]}')"
rpc_ok list-specs-norchild "$(jq -cn --arg s "$S1" --arg ot "$OT" '{specs:[
  {specId:$ot,createdAt:"2026-09-28T10:30:00.000Z",status:"completed",isDraft:false,parentSpecId:null},
  {specId:$s,createdAt:"2026-09-28T10:00:00.000Z",status:"completed",isDraft:false,parentSpecId:null}]}')"
rpc_ok list-answers '{"answers":[{"gapId":"3f0c9a52-1d7e-4b8a-9c11-2e5f7a6b8d01","questionIndex":0,"question":"Is the per-seat price shown per month or per year? (default: per month)","answerText":"Per month.\nBilled on the first of the month."},{"gapId":"ffffffff-0000-4000-8000-000000000000","questionIndex":0,"question":"Unmapped question","answerText":"Keep as is."}]}'

